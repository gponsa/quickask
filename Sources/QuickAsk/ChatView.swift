import AppKit
import SwiftUI

/// What's inside the popup: optional context chips, the conversation, and the input.
struct ChatView: View {
    @ObservedObject var model: ChatModel
    var onHeightChange: (CGFloat) -> Void
    var openSettings: () -> Void

    @State private var inputHeight: CGFloat = 22
    @State private var transcriptHeight: CGFloat = 0
    private let maxTranscriptHeight: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.selectedText != nil || model.screenshotJPEG != nil || model.isCapturing {
                contextChips.padding(.horizontal, 16).padding(.top, 12)
            }
            if let notice = model.contextNotice {
                Label(notice, systemImage: "lock.shield")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.top, 12)
            }

            if !model.turns.isEmpty {
                transcript
                Divider().padding(.horizontal, 12)
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                InputTextView(model: model, height: $inputHeight)
                    .frame(height: inputHeight)
                    .overlay(alignment: .topLeading) {
                        if model.input.isEmpty {
                            Text("Ask anything…")
                                .font(.system(size: 17))
                                .foregroundStyle(.tertiary)
                                .allowsHitTesting(false)   // clicks go through to the text field
                        }
                    }
                if model.isStreaming {
                    ProgressView().controlSize(.small).padding(.top, 2)
                }
                // Attach / remove a screenshot of your screen.
                Button { model.toggleScreenshot(); model.focusInput?() } label: {
                    Image(systemName: model.screenshotJPEG == nil ? "camera" : "camera.fill")
                        .font(.system(size: 15))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(model.screenshotJPEG == nil ? .secondary : .primary)
                .padding(.top, 2)
                .help("Attach a screenshot of your screen (⌃⇧M)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .frame(width: 640)
        .fixedSize(horizontal: false, vertical: true)
        // Report our natural height so the window can match it.
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { onHeightChange(proxy.size.height) }
                .onChange(of: proxy.size.height) { _, h in onHeightChange(h) }
        })
    }

    // MARK: - Pieces

    private var contextChips: some View {
        HStack(spacing: 8) {
            if let text = model.selectedText {
                chip(icon: "text.quote", label: "“\(text.prefix(60))\(text.count > 60 ? "…" : "")”") {
                    model.selectedText = nil
                }
            }
            if model.isCapturing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Taking screenshot…")
                }
                .font(.callout).foregroundStyle(.secondary)
            } else if let jpeg = model.screenshotJPEG {
                HStack(spacing: 6) {
                    if let image = NSImage(data: jpeg) {
                        Image(nsImage: image)
                            .resizable().aspectRatio(contentMode: .fit)
                            .frame(height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    Text("Screenshot attached")
                    Button { model.screenshotJPEG = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(4).padding(.trailing, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    /// Small "globe + site name" links under an answer that used the web. They open in
    /// your browser (only https links open, see the openURL rule below).
    private func sourceLinks(_ sources: [Source]) -> some View {
        HStack(spacing: 6) {
            ForEach(sources, id: \.url) { source in
                Link(destination: source.url) {
                    Label(Self.siteName(source.url), systemImage: "globe")
                        .lineLimit(1)
                }
                .help(source.title)
                .font(.caption)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
            }
        }
    }

    /// "www.theguardian.com" → "theguardian.com"
    static func siteName(_ url: URL) -> String {
        let host = url.host ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func chip(icon: String, label: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(label).lineLimit(1).truncationMode(.tail)
            Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }

    /// Questions and answers. Grows with the content up to a max height, then scrolls.
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.turns) { turn in
                        VStack(alignment: .leading, spacing: 6) {
                            if model.turns.count > 1 || turn.answer.isEmpty {
                                Text(turn.question).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                            }
                            if let status = turn.searchStatus {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.mini)
                                    Text(status).lineLimit(1).truncationMode(.tail)
                                }
                                .font(.callout).foregroundStyle(.secondary)
                            }
                            // Whatever arrived before an error stays visible above it.
                            if !turn.answer.isEmpty {
                                Text(Self.markdown(turn.answer))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                if !turn.sourcesToShow.isEmpty {
                                    sourceLinks(turn.sourcesToShow)
                                }
                            }
                            if let notice = turn.notice {
                                Text(notice).font(.caption).italic().foregroundStyle(.secondary)
                            }
                            if let error = turn.error {
                                Label(error, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                        .id(turn.id)
                    }
                    if let last = model.turns.last, !last.answer.isEmpty, !model.isStreaming {
                        HStack {
                            Spacer()
                            Button { model.copyLastAnswer() } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.borderless).font(.caption)
                            .help("Copy the answer (⌘C)")
                            Button { model.reset() } label: { Label("New", systemImage: "plus") }
                                .buttonStyle(.borderless).font(.caption)
                                .help("Start a new conversation (⌘N)")
                        }
                    }
                }
                .font(.system(size: 14))
                // Links in answers only open if they're ordinary https web links. Anything
                // else (file://, app-launching schemes…) is ignored, so a crafted answer
                // can't open local files or other apps.
                .environment(\.openURL, OpenURLAction { url in
                    url.scheme?.lowercased() == "https" ? .systemAction : .discarded
                })
                .padding(.horizontal, 16).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { p in
                    Color.clear
                        .onAppear { transcriptHeight = p.size.height }
                        .onChange(of: p.size.height) { _, h in transcriptHeight = h }
                })
            }
            .frame(height: min(transcriptHeight, maxTranscriptHeight))
            .onChange(of: model.turns.last?.answer) { _, _ in
                if let id = model.turns.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    /// Light Markdown (bold, italics, `code`, links), keeping line breaks.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

// MARK: - Input field

/// A plain AppKit text view, because SwiftUI's TextField can't do
/// "Enter sends, Shift+Enter adds a line" reliably on macOS.
struct InputTextView: NSViewRepresentable {
    @ObservedObject var model: ChatModel
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: 17)
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.setAccessibilityPlaceholderValue("Ask anything…")
        context.coordinator.textView = tv
        model.focusInput = { [weak tv] in tv?.window?.makeFirstResponder(tv) }
        model.isInputFocused = { [weak tv] in tv != nil && tv?.window?.firstResponder === tv }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let tv = scroll.documentView as! NSTextView
        if tv.string != model.input {           // model cleared it (after send / New)
            tv.string = model.input
            context.coordinator.updateHeight()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InputTextView
        weak var textView: NSTextView?

        init(_ parent: InputTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.model.input = tv.string
            updateHeight()
        }

        /// Grow with the text, 1 to ~5 lines.
        func updateHeight() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let h = max(22, min(lm.usedRect(for: tc).height, 110))
            if abs(parent.height - h) > 0.5 { parent.height = h }
        }

        // Keyboard commands inside the text field.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)   // Shift+Enter: new line
                } else {
                    parent.model.send()                              // Enter: send
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):         // Escape: close
                parent.model.close?()
                return true
            default:
                return false
            }
        }
    }
}
