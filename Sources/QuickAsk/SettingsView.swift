import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @AppStorage(Prefs.model) private var model = Prefs.defaultModel
    @AppStorage(Prefs.systemPrompt) private var systemPrompt = Prefs.defaultSystemPrompt
    @AppStorage(Prefs.captureSelection) private var captureSelection = false
    @AppStorage(Prefs.keepConversation) private var keepConversation = false
    @AppStorage(Prefs.showDuck) private var showDuck = true

    @State private var apiKey = ""
    @State private var keySaved = Keychain.apiKey() != nil
    @State private var keyWarning: String?
    @State private var checking = false
    @State private var accessibilityOK = ContextCapture.hasAccessibility(prompt: false)

    /// Before saving, asks Anthropic whether the key actually works, so a half-pasted
    /// or wrong key is caught here instead of on your first question.
    private func saveKey() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        checking = true
        keyWarning = nil
        Task {
            let result = await AnthropicClient.shared.checkKey(key)
            checking = false
            switch result {
            case .rejected(let message):
                keyWarning = message
                return
            case .unknown(let message):
                keyWarning = message
            case .valid:
                break
            }
            Keychain.setAPIKey(key)
            apiKey = ""
            keySaved = Keychain.apiKey() != nil
        }
    }
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Anthropic API key") {
                HStack {
                    SecureField(keySaved ? "Saved in Keychain (paste to replace)" : "Paste your API key", text: $apiKey)
                    Button(checking ? "Checking…" : "Save") { saveKey() }
                        .disabled(checking || apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let keyWarning {
                    Text(keyWarning).font(.caption).foregroundStyle(.orange)
                }
                if keySaved {
                    HStack {
                        Label("Key saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Spacer()
                        Button("Remove key") { Keychain.setAPIKey(""); keySaved = false }
                            .buttonStyle(.link)
                    }
                } else {
                    Text("Create one at console.anthropic.com → API Keys.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Model") {
                TextField("Model ID", text: $model)
                Text("Default: claude-haiku-5-5 (fastest). For harder questions try claude-sonnet-5-5.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Hotkeys") {
                LabeledContent("Open QuickAsk") { HotkeyRecorder(action: .toggle) }
                LabeledContent("Open with screenshot") { HotkeyRecorder(action: .screenshot) }
            }

            Section("Behaviour") {
                Toggle("Include selected text as context", isOn: $captureSelection)
                    .onChange(of: captureSelection) { _, on in
                        // Ask for Accessibility right away, rather than on the next ⌃M.
                        if on { accessibilityOK = ContextCapture.hasAccessibility(prompt: true) }
                    }
                if captureSelection && !accessibilityOK {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Needs Accessibility permission: System Settings → Privacy & Security → Accessibility → turn on QuickAsk.")
                            .font(.caption).foregroundStyle(.orange)
                        HStack {
                            Button("Open System Settings") {
                                NSWorkspace.shared.open(URL(string:
                                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }
                            Button("I've turned it on") {
                                accessibilityOK = ContextCapture.hasAccessibility(prompt: false)
                            }
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                }
                Toggle("Keep conversation when reopening", isOn: $keepConversation)
                Toggle("Show the duck 🐤", isOn: $showDuck)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
            }

            Section("System prompt") {
                TextEditor(text: $systemPrompt)
                    .font(.body)
                    .frame(height: 110)
                Button("Reset to default") { systemPrompt = Prefs.defaultSystemPrompt }
                    .buttonStyle(.link)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change this: \(error.localizedDescription). Install the app in /Applications first."
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
