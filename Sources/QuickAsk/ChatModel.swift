import AppKit
import SwiftUI

/// The popup's state: what you're typing, the conversation so far, and the
/// answer currently streaming in.
@MainActor
final class ChatModel: ObservableObject {
    struct Turn: Identifiable {
        let id = UUID()
        let question: String
        var answer: String
        var error: String?
        var notice: String?   // e.g. "answer cut off": shown in the UI, never sent to Claude
        var searchStatus: String?        // "Searching the web for …", while a search runs
        var sources: [Source] = []       // pages the answer cites
        var results: [Source] = []       // pages the search found (shown if nothing is cited)

        /// Links to show under the answer: cited pages, or else the top search results.
        var sourcesToShow: [Source] { Array((sources.isEmpty ? results : sources).prefix(4)) }
    }

    @Published var input = ""
    @Published var turns: [Turn] = []
    @Published var isStreaming = false

    /// Optional context for the NEXT question (cleared once it's sent).
    @Published var selectedText: String?
    @Published var screenshotJPEG: Data?
    @Published var isCapturing = false
    /// A short status about context, e.g. a missing permission. Shown above the input.
    @Published var contextNotice: String?
    /// The display the popup opened on (what a screenshot captures).
    var targetDisplayID: CGDirectDisplayID?

    /// Set by the input view so the panel can put the cursor in it on open.
    var focusInput: (() -> Void)?
    /// Set by the input view: is the cursor currently in the input field?
    var isInputFocused: (() -> Bool)?
    /// Set by the panel so the input view can close the popup (Escape).
    var close: (() -> Void)?

    /// What was actually sent for each turn (with context), so follow-ups keep it.
    private var history: [ChatMessage] = []
    private var streamTask: Task<Void, Never>?
    /// Bumped on cancel/reset so a stream that finishes late knows to stay quiet.
    private var generation = 0

    func send() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isStreaming else { return }
        guard let apiKey = Keychain.apiKey() else {
            turns.append(Turn(question: question, answer: "", error: AskError.missingKey.errorDescription))
            input = ""
            return
        }

        // Selected text goes above the question in tags, so Claude knows what "this"
        // refers to and treats it as material to look at, not as instructions.
        var text = question
        if let selected = selectedText {
            let safe = selected.replacingOccurrences(of: "</selected_text>", with: "</selected-text>")
            text = "<selected_text>\n\(safe)\n</selected_text>\n\n\(question)"
        }
        history.append(ChatMessage(role: .user, text: text, imageJPEG: screenshotJPEG))
        turns.append(Turn(question: question, answer: ""))
        input = ""
        selectedText = nil
        screenshotJPEG = nil

        // Settings are trimmed so a stray space or an emptied box can't break every request.
        let defaults = UserDefaults.standard
        let typedModel = (defaults.string(forKey: Prefs.model) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let model = typedModel.isEmpty ? Prefs.defaultModel : typedModel
        let system = (defaults.string(forKey: Prefs.systemPrompt) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let webSearch = defaults.bool(forKey: Prefs.webSearch)
        let messages = history
        let turnID = turns[turns.count - 1].id

        isStreaming = true
        let myGeneration = generation
        streamTask = Task {
            var answer = ""
            var failure: String?
            do {
                for try await event in AnthropicClient.shared.stream(
                    messages: messages, system: system, model: model, apiKey: apiKey, webSearch: webSearch) {
                    // Look the turn up by id each time: ⌘N may have cleared the list meanwhile.
                    guard let i = turns.firstIndex(where: { $0.id == turnID }) else { continue }
                    switch event {
                    case .text(let chunk):
                        answer += chunk
                        turns[i].answer = answer
                        turns[i].searchStatus = nil
                    case .notice(let note):
                        turns[i].notice = note
                    case .searching(let query):
                        // Anything written before a search is a preamble ("Let me look that
                        // up…"); the real answer comes after the results, so start fresh.
                        answer = ""
                        turns[i].answer = ""
                        turns[i].searchStatus = query.map { "Searching the web for “\($0)”…" } ?? "Searching the web…"
                    case .result(let source):
                        if !turns[i].results.contains(where: { $0.url == source.url }) { turns[i].results.append(source) }
                    case .cited(let source):
                        if !turns[i].sources.contains(where: { $0.url == source.url }) { turns[i].sources.append(source) }
                    }
                }
            } catch {
                failure = error.localizedDescription
                if let i = turns.firstIndex(where: { $0.id == turnID }) { turns[i].error = failure }
            }
            // If cancel()/reset() ran meanwhile, they've already tidied up. Do nothing.
            guard generation == myGeneration else { return }
            // Keep the API history strictly alternating user/assistant: a successful answer
            // is appended; a failed or empty one removes its question so a retry starts clean.
            if failure == nil, !answer.isEmpty {
                history.append(ChatMessage(role: .assistant, text: answer))
            } else if history.last?.role == .user {
                history.removeLast()
            }
            isStreaming = false
        }
    }

    /// Stops an answer that's still streaming (Escape, ⌘N, closing the popup).
    func cancel() {
        guard isStreaming else { return }
        generation += 1
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        // The interrupted question has no answer, so drop it from what we send next time.
        if history.last?.role == .user { history.removeLast() }
    }

    /// ⌘N: forget the conversation and start fresh.
    func reset() {
        cancel()
        generation += 1   // also makes a screenshot that's still being taken get dropped
        turns = []
        history = []
        input = ""
        selectedText = nil
        screenshotJPEG = nil
        isCapturing = false
        contextNotice = nil
    }

    /// Camera button / ⌃⇧M: attach (or remove) a screenshot of your screen.
    func toggleScreenshot() {
        if screenshotJPEG != nil { screenshotJPEG = nil; return }
        guard !isCapturing else { return }
        isCapturing = true
        contextNotice = nil
        let myGeneration = generation
        Task {
            let result = await ContextCapture.screenshot(displayID: targetDisplayID)
            guard generation == myGeneration else { return }   // popup was closed meanwhile
            isCapturing = false
            switch result {
            case .image(let jpeg):
                screenshotJPEG = jpeg
            case .needsPermission:
                contextNotice = "Screenshots need permission: System Settings → Privacy & Security → "
                    + "Screen & System Audio Recording → turn on QuickAsk. Then quit QuickAsk (menu-bar icon) and reopen it."
            case .failed:
                contextNotice = "Couldn't capture the screen."
            }
        }
    }

    var lastAnswer: String? { turns.last(where: { !$0.answer.isEmpty })?.answer }

    func copyLastAnswer() {
        guard let answer = lastAnswer else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
    }
}
