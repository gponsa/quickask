import AppKit
import Carbon.HIToolbox
import SwiftUI

/// System-wide hotkeys via Carbon's RegisterEventHotKey. It's old, but it's still the
/// API macOS uses for this, and unlike keyboard monitoring it needs NO Accessibility
/// permission. The shortcut is "reserved" for QuickAsk while the app runs.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    enum Action: UInt32, CaseIterable {
        case toggle = 1, screenshot = 2

        var defaultsKey: String { "hotkey.\(rawValue)" }
        var defaultShortcut: Shortcut {
            switch self {
            case .toggle: Shortcut(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey), display: "⌃M")
            case .screenshot: Shortcut(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | shiftKey), display: "⌃⇧M")
            }
        }
    }

    struct Shortcut: Codable, Equatable {
        var keyCode: UInt32
        var modifiers: UInt32   // Carbon modifier bits (controlKey, optionKey, …)
        var display: String     // e.g. "⌃M", for showing in Settings
    }

    var handlers: [Action: () -> Void] = [:]
    private var refs: [Action: EventHotKeyRef] = [:]
    private var handlerInstalled = false

    func shortcut(for action: Action) -> Shortcut {
        guard let data = UserDefaults.standard.data(forKey: action.defaultsKey),
              let s = try? JSONDecoder().decode(Shortcut.self, from: data) else { return action.defaultShortcut }
        return s
    }

    /// Saves a new shortcut and activates it. Returns an error message (and keeps the
    /// old shortcut) if it clashes with the other QuickAsk hotkey or another app.
    func setShortcut(_ shortcut: Shortcut, for action: Action) -> String? {
        for other in Action.allCases where other != action {
            let o = self.shortcut(for: other)
            if o.keyCode == shortcut.keyCode && o.modifiers == shortcut.modifiers {
                return "\(shortcut.display) is already your other QuickAsk shortcut."
            }
        }
        let previous = self.shortcut(for: action)
        save(shortcut, for: action)
        if registerAll().contains(action) {
            save(previous, for: action)
            registerAll()
            return "\(shortcut.display) is taken by macOS or another app. Try a different one."
        }
        return nil
    }

    private func save(_ shortcut: Shortcut, for action: Action) {
        UserDefaults.standard.set(try? JSONEncoder().encode(shortcut), forKey: action.defaultsKey)
    }

    /// Registers every hotkey. Returns the ones that couldn't be registered.
    @discardableResult
    func registerAll() -> Set<Action> {
        installHandlerOnce()
        unregisterAll()
        var failed = Set<Action>()
        for action in Action.allCases {
            let s = shortcut(for: action)
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x516B4173) /* 'QkAs' */, id: action.rawValue)
            if RegisterEventHotKey(s.keyCode, s.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr,
               let ref {
                refs[action] = ref
            } else {
                failed.insert(action)
            }
        }
        return failed
    }

    /// Used while recording a new shortcut, so pressing the old one doesn't open the popup.
    func unregisterAll() {
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }

    private func installHandlerOnce() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // A plain C callback: it can't capture anything, so it reads the hotkey id
        // from the event and hops to the main thread.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let raw = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let action = Action(rawValue: raw) { HotkeyManager.shared.handlers[action]?() }
                }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Turns a key press (from the recorder) into a Shortcut. Requires ⌃, ⌥ or ⌘.
    static func shortcut(from event: NSEvent) -> Shortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.control, .option, .command]).isEmpty else { return nil }
        var carbon = 0, symbols = ""
        if flags.contains(.control) { carbon |= controlKey; symbols += "⌃" }
        if flags.contains(.option) { carbon |= optionKey; symbols += "⌥" }
        if flags.contains(.shift) { carbon |= shiftKey; symbols += "⇧" }
        if flags.contains(.command) { carbon |= cmdKey; symbols += "⌘" }
        let key = keyName(event)
        return Shortcut(keyCode: UInt32(event.keyCode), modifiers: UInt32(carbon), display: symbols + key)
    }

    private static func keyName(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        default:
            if let f = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
                .firstIndex(of: Int(event.keyCode)) { return "F\(f + 1)" }
            return (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }
}

/// The "click, then press your shortcut" control in Settings.
struct HotkeyRecorder: View {
    let action: HotkeyManager.Action
    @State private var display: String
    @State private var recording = false
    @State private var monitor: Any?
    @State private var warning: String?

    init(action: HotkeyManager.Action) {
        self.action = action
        _display = State(initialValue: HotkeyManager.shared.shortcut(for: action).display)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                Button(recording ? "Press shortcut… (Esc cancels)" : display) {
                    recording ? stop() : start()
                }
                .frame(minWidth: 150)
                if action.defaultShortcut.display != display, !recording {
                    Button("Reset") { apply(action.defaultShortcut) }
                        .buttonStyle(.link)
                }
            }
            if let warning {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear { if recording { stop() } }
    }

    private func apply(_ shortcut: HotkeyManager.Shortcut) {
        warning = HotkeyManager.shared.setShortcut(shortcut, for: action)
        display = HotkeyManager.shared.shortcut(for: action).display
    }

    private func start() {
        recording = true
        warning = nil
        HotkeyManager.shared.unregisterAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            if let s = HotkeyManager.shortcut(from: event) {
                stop()
                apply(s)
            }
            return nil   // swallow the key press
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        HotkeyManager.shared.registerAll()
    }
}
