import AppKit
import SwiftUI

/// A borderless panel that can take keyboard input WITHOUT activating QuickAsk.
/// That's the trick Spotlight-style launchers use: the app you were in (Arc, Notes…)
/// stays the active app, so its selection and context are untouched.
final class KeyPanel: NSPanel {
    var onCommandKey: ((String) -> Bool)?
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }    // borderless windows refuse key status by default
    override var canBecomeMain: Bool { false }

    // Escape closes the popup wherever the focus is (input field, answer text, a button).
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    // A menu-bar app has no Edit menu in view, so ⌘C/⌘V/⌘X/⌘A/⌘Z wouldn't reach the
    // text field on their own. We route them by hand, plus our own ⌘N and ⌘C.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only ⌃/⌥/⌘ matter here; Caps Lock, Fn and Shift are ignored.
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .control, .option]) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        if onCommandKey?(key) == true { return true }
        let action: Selector? = switch key {
            case "x": #selector(NSText.cut(_:))
            case "c": #selector(NSText.copy(_:))
            case "v": #selector(NSText.paste(_:))
            case "a": #selector(NSText.selectAll(_:))
            case "z": event.modifierFlags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
            default: nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let model = ChatModel()
    private let panel: KeyPanel
    private var hosting: NSHostingView<ChatView>!
    private var clickOutsideMonitor: Any?
    private static let width: CGFloat = 640
    /// The pixel duck on top of the popup (nil if its images are missing from the app).
    private lazy var duck: DuckWindow? = DuckSprites.isAvailable ? DuckWindow(width: Self.width, observing: model) : nil

    init(openSettings: @escaping () -> Void) {
        panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 60),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        super.init()

        panel.isFloatingPanel = true
        panel.level = .statusBar                      // above normal windows, incl. full-screen apps
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none               // no fade: appear instantly
        panel.delegate = self

        // Translucent, blurred background with rounded corners (follows light/dark mode).
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: 14)

        let root = ChatView(
            model: model,
            onHeightChange: { [weak self] height in self?.resize(toHeight: height) },
            openSettings: openSettings)
        hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []                    // we size the window ourselves (top edge fixed)
        // Plain "stretch with the parent" resizing rather than Auto Layout constraints:
        // with constraints, the background sometimes kept an old size after the window
        // was resized, so the visible bar and the window (where the duck stands) disagreed.
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = background.bounds
        background.addSubview(hosting)
        panel.contentView = background

        model.close = { [weak self] in self?.hide() }
        panel.onEscape = { [weak self] in self?.hide() }
        panel.onCommandKey = { [weak self] key in
            guard let self else { return false }
            switch key {
            case "n":
                self.model.reset(); return true
            case "c":
                // ⌘C copies the whole answer only when you're in the input field with
                // nothing selected. If you've selected part of the answer, the focus is in
                // the answer text instead, and a normal copy takes just that selection.
                guard self.model.isInputFocused?() == true,
                      let tv = self.panel.firstResponder as? NSTextView,
                      tv.selectedRange().length == 0,
                      self.model.lastAnswer != nil else { return false }
                self.model.copyLastAnswer(); return true
            case ",":
                self.hide(); openSettings(); return true
            default:
                return false
            }
        }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle(withScreenshot: Bool) {
        // ⌃⇧M while the popup is open attaches a screenshot instead of closing it.
        if isVisible && !withScreenshot { hide() } else { show(withScreenshot: withScreenshot) }
    }

    func show(withScreenshot: Bool) {
        // Already open (e.g. "Ask…" chosen from the menu): just put the cursor back.
        guard !panel.isVisible else {
            focusInput()
            if withScreenshot, model.screenshotJPEG == nil { model.toggleScreenshot() }
            return
        }
        if let key = Keychain.apiKey() { AnthropicClient.shared.warmUp(apiKey: key) }

        // Selected text has to be read BEFORE the popup takes the keyboard focus.
        if UserDefaults.standard.bool(forKey: Prefs.captureSelection) {
            model.selectedText = ContextCapture.selectedText()
        }

        // Open on the screen the mouse pointer is on, centred, ~18% down from the top.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        // A screenshot captures this same screen.
        model.targetDisplayID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        if let visible = screen?.visibleFrame {
            // Measure the content now. The window's current height can be left over from
            // a longer conversation: macOS doesn't redraw hidden windows, so the shrink
            // after closing may not have happened yet.
            let height = contentHeight()
            let top = visible.maxY - visible.height * 0.18
            panel.setFrame(NSRect(x: visible.midX - Self.width / 2, y: top - height,
                                  width: Self.width, height: height), display: false)
            fitContentToWindow()
        }

        panel.makeKeyAndOrderFront(nil)
        focusInput()
        // The duck starts its entrance once the popup is already on screen.
        if UserDefaults.standard.bool(forKey: Prefs.showDuck) { duck?.show(above: panel.frame) }
        // Check once more after SwiftUI's first on-screen layout pass, then refresh the
        // shadow so it matches the real shape.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.resize(toHeight: self.contentHeight())
            self.panel.invalidateShadow()
        }
        // The screenshot is taken after the popup appears (so opening stays instant);
        // the popup itself is left out of the picture.
        if withScreenshot { model.toggleScreenshot() }

        // Close when you click anywhere outside the popup (in another app).
        // Watching mouse clicks in other apps does not need any permission.
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        model.cancel()
        panel.orderOut(nil)
        duck?.hide()
        if let monitor = clickOutsideMonitor { NSEvent.removeMonitor(monitor) }
        clickOutsideMonitor = nil
        // Forget the conversation now (not on next open), so questions, selected text and
        // screenshots don't linger in memory, and the popup reopens at its small size.
        if !UserDefaults.standard.bool(forKey: Prefs.keepConversation) { model.reset() }
    }

    /// Puts the cursor in the input field. Also retried on the next run-loop turn: on the
    /// very first open, SwiftUI may not have created the text field yet.
    private func focusInput() {
        model.focusInput?()
        DispatchQueue.main.async { [weak self] in self?.model.focusInput?() }
    }

    /// Grows/shrinks the popup to fit its content while keeping the TOP edge in place
    /// (macOS window coordinates start at the bottom-left, hence the arithmetic).
    private func resize(toHeight height: CGFloat) {
        var frame = panel.frame
        guard height > 1, abs(frame.height - height) > 0.5 else { return }
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
        fitContentToWindow()
        duck?.place(above: panel.frame)               // the duck always stands on the real top edge
        // Recompute the shadow once the new size has been drawn (doing it immediately can
        // capture the old shape, which leaves a ghost outline).
        panel.invalidateShadow()
        DispatchQueue.main.async { [weak self] in self?.panel.invalidateShadow() }
    }

    /// Makes the background (and the content on it) exactly fill the window. Normally
    /// automatic; done by hand too, because a mismatch is what left the duck floating.
    private func fitContentToWindow() {
        guard let content = panel.contentView else { return }
        let bounds = NSRect(origin: .zero, size: panel.frame.size)
        if content.frame != bounds { content.frame = bounds }
        if hosting.frame != content.bounds { hosting.frame = content.bounds }
    }

    /// The height the content actually needs right now (forces SwiftUI to lay out first).
    private func contentHeight() -> CGFloat {
        hosting.layoutSubtreeIfNeeded()
        let height = ceil(hosting.fittingSize.height)
        return height > 1 ? height : panel.frame.height
    }

    // Also close if the panel loses focus some other way (e.g. ⌘Tab).
    func windowDidResignKey(_ notification: Notification) { hide() }

    // If you drag the popup, the duck comes along.
    func windowDidMove(_ notification: Notification) { duck?.place(above: panel.frame) }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

