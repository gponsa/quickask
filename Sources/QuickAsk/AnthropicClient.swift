import Foundation

/// One message in the conversation we send to the API.
struct ChatMessage {
    enum Role: String { case user, assistant }
    let role: Role
    let text: String
    var imageJPEG: Data? = nil   // only ever set on the first user message
}

/// What the stream hands back: answer text, or a status note for the UI only.
enum StreamEvent {
    case text(String)
    case notice(String)
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
        config.timeoutIntervalForRequest = 30      // max silence between bytes
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
    func stream(messages: [ChatMessage], system: String, model: String, apiKey: String)
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
                        withJSONObject: Self.body(messages: messages, system: system, model: model))

                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0

                    guard status == 200 else {
                        // Error responses are a small JSON body, not a stream.
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        throw Self.error(status: status, body: data, model: model)
                    }

                    // SSE: lines like `event: …` and `data: {json}`. We only need the data lines.
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        // A malformed event is skipped, never a crash.
                        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                              let type = obj["type"] as? String else { continue }

                        switch type {
                        case "content_block_delta":
                            // Only visible text. Thinking blocks (if any) are ignored.
                            if let delta = obj["delta"] as? [String: Any],
                               delta["type"] as? String == "text_delta",
                               let text = delta["text"] as? String {
                                continuation.yield(.text(text))
                            }
                        case "message_delta":
                            let stop = (obj["delta"] as? [String: Any])?["stop_reason"] as? String
                            if stop == "max_tokens" { continuation.yield(.notice("Answer cut off (length limit).")) }
                            if stop == "refusal" { continuation.yield(.notice("Claude declined to answer this.")) }
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

    static func body(messages: [ChatMessage], system: String, model: String) -> [String: Any] {
        let encoded: [[String: Any]] = messages.map { encode($0) }
        var body: [String: Any] = [:]
        body["model"] = model
        body["max_tokens"] = 2048
        body["stream"] = true
        if !system.isEmpty { body["system"] = system }   // an empty system prompt is just left out
        body["messages"] = encoded

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
