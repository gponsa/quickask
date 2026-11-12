import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ScreenCaptureKit

/// Grabs optional context for a question: the text selected in the app you were using,
/// or a screenshot of its front window. Both fail silently (return nil / a status)
/// rather than getting in your way.
@MainActor
enum ContextCapture {

    // MARK: - Selected text (needs Accessibility permission)

    private static var promptedForAccessibility = false

    /// True if QuickAsk may read other apps' selected text. The first time it's asked
    /// (per launch), macOS shows its "allow accessibility" dialog.
    @discardableResult
    static func hasAccessibility(prompt: Bool) -> Bool {
        let ask = prompt && !promptedForAccessibility
        if ask { promptedForAccessibility = true }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: ask] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// The text selected in the front app, or nil. MUST run before the popup takes the
    /// keyboard focus, otherwise the simulated ⌘C would go to QuickAsk itself.
    static func selectedText() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              hasAccessibility(prompt: true) else { return nil }

        let text = accessibilitySelection(pid: app.processIdentifier) ?? copySelection()
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(8000))   // keep it to a sensible size
    }

    /// Method 1: ask the app directly through the Accessibility API. Instant, and doesn't
    /// touch the clipboard, but many apps (notably Chromium ones like Arc) don't support it.
    private static func accessibilitySelection(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.2)   // never hang on a slow app
        // Chromium/Electron apps only build their accessibility info when asked like this.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success
        else { return nil }
        return selected as? String
    }

    /// Method 2: press ⌘C for you, read the clipboard, then put your clipboard back.
    private static func copySelection() -> String? {
        let pasteboard = NSPasteboard.general
        // Save everything currently on the clipboard (all formats) to restore afterwards.
        let saved: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        let before = pasteboard.changeCount

        postCommandC()

        // Wait up to 250 ms for the app to copy. If the clipboard never changes, nothing
        // was selected. We then return nil instead of whatever was already on the
        // clipboard (which could be a password).
        let deadline = Date().addingTimeInterval(0.25)
        while pasteboard.changeCount == before, Date() < deadline { usleep(10_000) }
        guard pasteboard.changeCount != before else { return nil }

        let text = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        if !saved.isEmpty { pasteboard.writeObjects(saved) }
        return text
    }

    private static func postCommandC() {
        // A private event source plus explicit flags: the ⌃ you're still holding from ⌃M
        // is not added, so the app sees a clean ⌘C (not ⌃⌘C).
        let source = CGEventSource(stateID: .privateState)
        let key = CGKeyCode(kVK_ANSI_C)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Screenshot (needs Screen Recording permission)

    enum ScreenshotResult { case image(Data), needsPermission, failed }

    /// Captures everything visible on one display (the one the popup opened on), minus
    /// QuickAsk's own windows, downscaled so the long edge is at most 1568 px (what
    /// Claude reads best), as JPEG. Nothing is written to disk.
    static func screenshot(displayID: CGDirectDisplayID?) async -> ScreenshotResult {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()   // macOS shows its permission prompt (first time only)
            return .needsPermission
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first
            else { return .failed }

            // Leave QuickAsk itself (the popup) out of the picture.
            let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])

            let scale = CGFloat(filter.pointPixelScale)   // 2 on Retina screens
            let width = CGFloat(display.width) * scale, height = CGFloat(display.height) * scale
            let fit = min(1, 1568 / max(width, height, 1))
            let config = SCStreamConfiguration()
            config.width = max(1, Int(width * fit))
            config.height = max(1, Int(height * fit))
            config.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard let jpeg = NSBitmapImageRep(cgImage: image)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return .failed }
            return .image(jpeg)
        } catch {
            return .failed
        }
    }
}
