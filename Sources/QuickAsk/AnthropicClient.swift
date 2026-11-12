import Foundation

/// One message in the conversation we send to the API.
struct ChatMessage {
    enum Role: String { case user, assistant }
    let role: Role
    let text: String
    var imageJPEG: Data? = nil   // only ever set on the first user message
}

/// A web page Claude looked at or cited.
struct Source: Equatable {
    let title: String
    let url: URL
}

/// What the stream hands back: answer text, or things for the UI only.
enum StreamEvent {
    case text(String)
    case notice(String)
    case searching(String?)   // Claude started a web search (with the query, once known)
    case result(Source)       // a page the search returned
    case cited(Source)        // a page the answer cites
}

/// Friendly, user-facing errors.
enum AskError: LocalizedError {
    case missingKey, invalidKey, rateLimited, overloaded, noNetwork, timeout
    case modelNotFound(String)
    case api(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: return "No API key yet. Open Settings (⌘,) and paste your key."
        case .invalidKey: return "That API key was rejected. Check it in Settings."
        case .rateLimited: return "Rate limit hit. Wait a few seconds and try again."
        case .overloaded: return "Anthropic is overloaded right now. Try again in a moment."
        case .noNetwork: return "No internet connection."
        case .timeout: return "The request timed out. Try again."
        case .modelNotFound(let m): return "Model “\(m)” wasn't found. Check the model name in Settings."
        case .api(let message): return message
        }
    }
}

/// Talks to the Anthropic Messages API with streaming (Server-Sent Events).
/// The only network destination in the app is api.anthropic.com.
final class AnthropicClient: @unchecked Sendable {
    static let shared = AnthropicClient()

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let apiVersion = "2026-10-21"

    // One shared session for every request, so the HTTPS connection is reused
    // (no new TLS handshake per question). "Ephemeral" = nothing (cookies, cache)
    // is written to disk.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60      // max silence between bytes (web searches take a few s)
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    /// Refuses HTTP redirects, so the API key can never be forwarded to another host.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    /// Opens the HTTPS connection early (while you're still typing) with a cheap,
    /// free request, so the real question doesn't pay for the TLS handshake.
    func warmUp(apiKey: String) {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!)
        addHeaders(to: &request, apiKey: apiKey)
        session.dataTask(with: request).resume()
    }

    enum KeyCheck { case valid, rejected(String), unknown(String) }

    /// Asks Anthropic whether a key works (free call that lists one model).
    func checkKey(_ apiKey: String) async -> KeyCheck {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!)
        addHeaders(to: &request, apiKey: apiKey)
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return .valid }
            let message = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"]
                           as? [String: Any])?["message"] as? String
            if status == 401 || status == 403 {
                return .rejected("Anthropic rejected this key\(message.map { " (\($0))" } ?? ""). Not saved.")
            }
            return .unknown("Couldn't verify the key (HTTP \(status)), saved anyway.")
        } catch {
            return .unknown("Couldn't reach Anthropic to verify the key, saved anyway.")
        }
    }

    /// Streams the answer as text chunks (plus UI-only notices). The stream finishes
    /// normally at the end of the answer, or throws an `AskError`.
    func stream(messages: [ChatMessage], system: String, model: String, apiKey: String, webSearch: Bool)
        -> AsyncThrowingStream<StreamEvent, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    addHeaders(to: &request, apiKey: apiKey)
                    request.setValue("application/json", forHTTPHeaderField: "content-type")
                    request.httpBody = try JSONSerialization.data(
                        withJSONObject: Self.body(messages: messages, system: system, model: model, webSearch: webSearch))

                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0

                    guard status == 200 else {
                        // Error responses are a small JSON body, not a stream.
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        throw Self.error(status: status, body: data, model: model)
                    }

                    // The answer arrives as numbered "content blocks": text, and (with web
                    // search) a search call whose query streams in as JSON, then its results.
                    var blockTypes: [Int: String] = [:]
                    var searchInput: [Int: String] = [:]

                    // SSE: lines like `event: …` and `data: {json}`. We only need the data lines.
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        // A malformed event is skipped, never a crash.
                        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                              let type = obj["type"] as? String else { continue }
                        let index = obj["index"] as? Int ?? -1

                        switch type {
                        case "content_block_start":
                            guard let block = obj["content_block"] as? [String: Any],
                                  let blockType = block["type"] as? String else { break }
                            blockTypes[index] = blockType
                            if blockType == "server_tool_use" {
                                continuation.yield(.searching(nil))
                            } else if blockType == "web_search_tool_result",
                                      let results = block["content"] as? [[String: Any]] {   // an error is an object, not a list
                                for r in results { if let s = Self.source(r) { continuation.yield(.result(s)) } }
                            }
                        case "content_block_delta":
                            guard let delta = obj["delta"] as? [String: Any] else { break }
                            switch delta["type"] as? String {
                            case "text_delta":     // visible answer text (thinking blocks are ignored)
                                if let text = delta["text"] as? String { continuation.yield(.text(text)) }
                            case "input_json_delta":   // the search query, arriving in pieces
                                searchInput[index, default: ""] += delta["partial_json"] as? String ?? ""
                            case "citations_delta":
                                if let c = delta["citation"] as? [String: Any], let s = Self.source(c) {
                                    continuation.yield(.cited(s))
                                }
                            default: break
                            }
                        case "content_block_stop":
                            if blockTypes[index] == "server_tool_use",
                               let input = searchInput[index],
                               let parsed = try? JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any] {
                                continuation.yield(.searching(parsed["query"] as? String))
                            }
                        case "message_delta":
                            let stop = (obj["delta"] as? [String: Any])?["stop_reason"] as? String
                            if stop == "max_tokens" { continuation.yield(.notice("Answer cut off (length limit).")) }
                            if stop == "refusal" { continuation.yield(.notice("Claude declined to answer this.")) }
                            if stop == "pause_turn" { continuation.yield(.notice("The web search took too long. Try asking again.")) }
                        case "error":
                            let err = obj["error"] as? [String: Any]
                            if err?["type"] as? String == "overloaded_error" { throw AskError.overloaded }
                            throw AskError.api(err?["message"] as? String ?? "The answer stream failed.")
                        default:
                            break   // message_start, ping, content_block_start/stop, message_stop
                        }
                    }
                    continuation.finish()
                } catch let error as URLError {
                    switch error.code {
                    case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost:
                        continuation.finish(throwing: AskError.noNetwork)
                    case .timedOut:
                        continuation.finish(throwing: AskError.timeout)
                    case .cancelled:
                        continuation.finish()
                    default:
                        continuation.finish(throwing: AskError.api(error.localizedDescription))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }   // Escape / New cancels the request
        }
    }

    // MARK: - Request building

    private func addHeaders(to request: inout URLRequest, apiKey: String) {
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
    }

    static func body(messages: [ChatMessage], system: String, model: String, webSearch: Bool) -> [String: Any] {
        let encoded: [[String: Any]] = messages.map { encode($0) }
        var body: [String: Any] = [:]
        body["model"] = model
        body["max_tokens"] = 2048
        body["stream"] = true
        body["system"] = fullSystemPrompt(system, webSearch: webSearch)
        body["messages"] = encoded

        if webSearch {
            // Anthropic's own web search tool: the search runs on Anthropic's servers, so
            // QuickAsk still only talks to api.anthropic.com. Claude decides per question
            // whether to search; at most 3 searches per question (≈ $0.01 each).
            var tool: [String: Any] = ["type": "web_search_20250305", "name": "web_search", "max_uses": 3]
            // Your time zone (no city or address) helps with "today" and local news.
            tool["user_location"] = ["type": "approximate", "timezone": TimeZone.current.identifier] as [String: String]
            body["tools"] = [tool]
        }

        // Speed: newer models "think" before answering by default, which delays the
        // first word. For quick lookups we turn that off / down. Each model family
        // accepts slightly different settings, hence the branches.
        let lowEffort: [String: String] = ["effort": "low"]
        if model.hasPrefix("claude-haiku-5") {
            body["thinking"] = ["type": "disabled"] as [String: String]
            body["output_config"] = lowEffort
        } else if model.hasPrefix("claude-sonnet-5-5") {
            body["thinking"] = ["type": "between_tools"] as [String: String]   // Sonnet 5.5's "no thinking" mode
            body["output_config"] = lowEffort
        } else if model.range(of: #"^claude-(opus|sonnet|fable)-5"#, options: .regularExpression) != nil {
            body["output_config"] = lowEffort
        }
        return body
    }

    /// Your system prompt from Settings, plus today's date (so "today" and "latest" mean
    /// something) and, with web search on, when to search.
    private static func fullSystemPrompt(_ userPrompt: String, webSearch: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        var parts = [userPrompt]
        parts.append("The current date and time is \(formatter.string(from: Date())) (\(TimeZone.current.identifier)).")
        if webSearch {
            parts.append("""
            You can search the web. Search only when the question needs current or recent information \
            (news, prices, scores, weather, schedules, anything that may have changed since your training); \
            otherwise answer from your own knowledge without searching. Don't announce that you're searching; \
            just give the answer, and keep it as short as usual.
            """)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// A web page from a search result or citation (only http(s) links are kept).
    private static func source(_ dict: [String: Any]) -> Source? {
        guard let urlString = dict["url"] as? String, let url = URL(string: urlString),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let title = (dict["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url.host ?? urlString
        return Source(title: title, url: url)
    }

    private static func encode(_ m: ChatMessage) -> [String: Any] {
        // (Explicit types here: nested [String: Any] literals make the compiler very slow.)
        guard let jpeg = m.imageJPEG else { return ["role": m.role.rawValue, "content": m.text] }
        let source: [String: Any] = ["type": "base64", "media_type": "image/jpeg",
                                     "data": jpeg.base64EncodedString()]
        let image: [String: Any] = ["type": "image", "source": source]
        let text: [String: Any] = ["type": "text", "text": m.text]
        let content: [[String: Any]] = [image, text]
        return ["role": m.role.rawValue, "content": content]
    }

    private static func error(status: Int, body: Data, model: String) -> AskError {
        let err = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any]
        let message = err?["message"] as? String
        switch status {
        case 401: return .invalidKey
        case 429: return .rateLimited
        case 529: return .overloaded
        case 404: return .modelNotFound(model)
        default: return .api(message ?? "Request failed (HTTP \(status)).")
        }
    }
}
