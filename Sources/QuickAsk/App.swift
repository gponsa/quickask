import AppKit
import SwiftUI

/// All user preferences live in UserDefaults under these keys (the API key does NOT,
/// it lives in the Keychain, see Keychain.swift).
enum Prefs {
    static let model = "model"
    static let systemPrompt = "systemPrompt"
    static let captureSelection = "captureSelection"
    static let keepConversation = "keepConversation"

    static let defaultModel = "claude-haiku-5-5"
    static let defaultSystemPrompt = """
    You are a fast lookup assistant. Answer in one short paragraph of at most 3 sentences unless asked for more. \
    No preamble, no filler, no markdown headings. If the user gives a single word or phrase, define or translate it. \
    Reply in the language of the question.
    """

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            model: defaultModel,
            systemPrompt: defaultSystemPrompt,
            captureSelection: false,
            keepConversation: false,
        ])
    }
}

@main
@MainActor
enum QuickAskMain {
    // Held statically so it lives for the whole run (NSApplication.delegate is weak).
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // belt and braces alongside LSUIElement
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: PanelController!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        installEditMenu()

        // Build the popup once up front, so showing it later is instant.
        panel = PanelController(openSettings: { [weak self] in self?.openSettings() })

        // Menu-bar icon and its menu.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: "QuickAsk")
        let menu = NSMenu()
        menu.addItem(withTitle: "Ask…", action: #selector(showPanel), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit QuickAsk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        // Global hotkeys: ⌃M opens the popup, ⌃⇧M opens it with a screenshot attached.
        // Both can be changed in Settings.
        HotkeyManager.shared.handlers[.toggle] = { [weak self] in self?.panel.toggle(withScreenshot: false) }
        HotkeyManager.shared.handlers[.screenshot] = { [weak self] in self?.panel.toggle(withScreenshot: true) }
        HotkeyManager.shared.registerAll()

        // First run: no key yet, so open Settings straight away.
        if Keychain.apiKey() == nil { openSettings() }
    }

    /// A menu-bar app never shows a menu bar, but macOS still routes ⌘V/⌘C/⌘X/⌘A/⌘Z
    /// through an (invisible) Edit menu. Without one, pasting into the Settings window
    /// just beeps.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem())   // first item is the (hidden) app menu
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    /// Opening QuickAsk again (Applications folder, Spotlight, Launchpad) while it's
    /// already running opens Settings, handy if the menu-bar icon is hidden by the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    @objc private func showPanel() { panel.show(withScreenshot: false) }

    @objc func openSettings() {
        panel.hide()
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "QuickAsk Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        // A menu-bar app has to activate itself, or the window opens behind others.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
