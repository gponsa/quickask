# QuickAsk

A tiny menu-bar app: press **⌃M** anywhere, type a question, get a short answer from Claude.

## Build & install
```bash
./build.sh install
```
This compiles the app, copies it to `/Applications/QuickAsk.app` and starts it. Run the same command after any code change. Plain `./build.sh` only builds into `build/`.

Requirements: Command Line Tools for Xcode 26.x (no full Xcode needed), and the "QuickAsk Local Signing" certificate in your login keychain (see Troubleshooting).

## First run
1. A Settings window opens. Paste your API key (console.anthropic.com → API Keys) and click **Save**. It's stored in your Keychain, never in a file.
2. Press **⌃M** in any app.

## Using it
| Key | Action |
|---|---|
| ⌃M | open / close the popup |
| ⌃⇧M or camera button | attach a screenshot of your screen (the popup is left out) |
| Enter | send |
| Shift+Enter | new line |
| Esc / click outside | close |
| ⌘N | new conversation |
| ⌘C (nothing selected) | copy the last answer |
| ⌘, | settings |

## Live answers from the web
With **Settings → Search the web when needed** on (the default), Claude searches the web by itself when a question needs current information: news, prices, scores, weather, anything recent. Ordinary questions are answered straight away without searching. While it searches you'll see "Searching the web for …", and the answer comes with small links to its sources.

- The search runs on Anthropic's servers, so QuickAsk still only talks to api.anthropic.com.
- Cost: about $0.01 per search plus the results' tokens (roughly 1 cent per searched question with Haiku). At most 3 searches per question.
- If searches fail with "web search is not enabled", an admin turned it off at platform.claude.com/settings/capabilities.

## Changing the hotkey
Menu-bar icon → Settings… → Hotkeys. Click the shortcut and press a new one (it must include ⌃, ⌥ or ⌘). If another app already uses it, you'll see a warning and the old one stays.

Note: while QuickAsk runs, ⌃M is reserved for it everywhere. In Terminal, ⌃M normally acts as Return, so change the hotkey if that bothers you.

## Permissions
- **Hotkey:** none needed.
- **Selected text** (Settings → "Include selected text"): Accessibility. System Settings → Privacy & Security → Accessibility.
- **Screenshots:** Screen Recording. System Settings → Privacy & Security → Screen & System Audio Recording.

Grant permissions to `/Applications/QuickAsk.app`, not the copy in `build/`.

## Troubleshooting
**Permissions stuck or not working.** Reset them, then let QuickAsk ask again:
```bash
./build.sh reset-permissions
```

**Signing certificate missing.** `build.sh` signs with a self-signed certificate called "QuickAsk Local Signing", so macOS remembers permissions across rebuilds. To recreate it: Keychain Access → menu Keychain Access → Certificate Assistant → Create a Certificate… → Name: `QuickAsk Local Signing`, Identity Type: Self-Signed Root, Certificate Type: Code Signing → Create.

**"Model not found".** Check the model name in Settings (default `claude-haiku-5-5`).

**Launch at login won't switch on.** The app must be in /Applications (use `./build.sh install`).

**Uninstall.** Quit from the menu-bar icon, delete `/Applications/QuickAsk.app`, then run `./build.sh reset-permissions`. To remove the key, open Keychain Access and delete the `com.guillem.quickask` item.
