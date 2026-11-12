# QuickAsk: implementation plan

This plan amends the original brief. Where they differ, this file wins.

## Environment (checked 2026-11-12)
- macOS 26.5.1, Apple Silicon (arm64)
- Command Line Tools only (no Xcode): Swift 6.0.3, macOS SDK 15.2
- No code-signing identities in the keychain yet
- Xcode is not needed. `swift build` plus a script that assembles the `.app` is enough.

## Amendments to the brief

1. **Model request shape.** `claude-haiku-5-5` is confirmed (Sonnet: `claude-sonnet-5-5`). Haiku 5.5 thinks by default, which adds a pause before the first word appears. Requests send:
   - Haiku: `thinking: {type: "disabled"}` + `output_config.effort: "low"`
   - Sonnet 5.5: `thinking: {type: "between_tools"}` + effort `low` (Sonnet 5.5 rejects `disabled`)
   - Any other model: effort `low` only
   - No `temperature` (rejected on API version `2026-10-21`). Header: `anthropic-version: 2026-10-21`.
   - `max_tokens: 2048`. Render only `text_delta` events and skip thinking blocks.
2. **Signing.** A "stable ad-hoc signature" isn't possible: ad-hoc signatures change on every build, so macOS forgets Screen Recording and Accessibility permissions and the Keychain asks again. Use a **self-signed local code-signing certificate** ("QuickAsk Local Signing") instead. This is a one-time step.
3. **Permissions are tied to the app's location.** Grant them to `/Applications/QuickAsk.app`, not to the copy in the build folder. `./build.sh install` copies the app there and relaunches it.
4. **Key in M2.** Apps started from Finder don't see shell environment variables, so skip the temporary env var. M2 includes a minimal Keychain and API-key field. The full Settings window comes in M3.
5. **Selected text needs Accessibility permission.** Both `AXSelectedText` and the simulated Cmd+C need it. The hotkey alone doesn't. Arc and other Chromium browsers often don't expose `AXSelectedText`, so the Cmd+C fallback does most of the work there. The simulated Cmd+C sets its modifier flags explicitly, so Control still being held from Ctrl+M doesn't turn it into Ctrl+Cmd+C.
6. **Screenshot UX is now concrete:**
   - **Ctrl+Shift+M** opens the popup with the front window already attached.
   - A camera button toggles the screenshot for the current question.
   - A small thumbnail chip shows when one is attached.
   - The capture happens *before* the panel appears, so the panel itself is never in the shot.
7. **Which screen.** The popup appears on the screen that contains the mouse pointer.
8. **Speed.** The panel is built once at launch and only shown or hidden afterwards. When it opens, a cheap `GET /v1/models?limit=1` warms up the TLS connection while you type.
9. **Escape while an answer is streaming** cancels the request.
10. **Context on follow-ups.** Selected text and screenshots are attached to the first question only, not repeated on follow-ups. The conversation stays append-only.
11. **Extra errors handled:** `stop_reason: "refusal"`, `max_tokens` (shown as "answer cut off"), and HTTP 529 (overloaded).
12. **Hotkey: no package.** The hotkey is hand-written Carbon `RegisterEventHotKey` code plus a small recorder in `HotkeyManager.swift`, so no Accessibility permission is needed. The app has zero dependencies and is built with `swiftc` directly, not SwiftPM.
13. **Toolchain.** The installed Command Line Tools 16.2 are broken on macOS 26 (compiler and SDK builds don't match). Command Line Tools for Xcode 26.6 must be installed before anything compiles.

## File structure
```
Santa's Little Helper/
├── Package.swift
├── build.sh                  # build | install | run | reset-permissions
├── Resources/
│   ├── Info.plist            # LSUIElement, usage strings, bundle id com.guillem.quickask
│   └── QuickAsk.entitlements
├── Sources/QuickAsk/
│   ├── App.swift             # entry point, menu-bar item, wiring
│   ├── HotkeyManager.swift
│   ├── PanelController.swift # NSPanel: non-activating, floating, all Spaces
│   ├── ChatView.swift        # SwiftUI input, streamed answer, copy
│   ├── ChatModel.swift       # conversation state, send/cancel
│   ├── AnthropicClient.swift # URLSession.bytes SSE streaming
│   ├── ContextCapture.swift  # selected text + ScreenCaptureKit
│   ├── SettingsView.swift
│   └── Keychain.swift
└── README.md
```

## Milestones
- **M0** Signing certificate, project skeleton, `build.sh`.
- **M1** Menu-bar icon, Ctrl+M toggles the panel over Arc and over a full-screen app. Escape and clicking outside close it.
- **M2** Keychain-backed key field, streaming answers from Haiku.
- **M3** Settings: model, system prompt, hotkey recorder, toggles, launch at login.
- **M4** Follow-ups, Cmd+N, copy, error messages, polish.
- **M5** Selected-text prefill.
- **M6** Screenshot context.
- **Docs** README with build, install, permissions, and troubleshooting.

## Known risks
- Ctrl+M is Return in terminals. While QuickAsk runs, Ctrl+M is captured everywhere, so in Terminal or iTerm it opens the popup instead of acting as Return. You can change the hotkey in Settings.
- macOS 15+ asks again from time to time whether to keep allowing Screen Recording. That's system behaviour and can't be avoided.
- Typing into a non-activating panel is handled with an `NSPanel` subclass (`canBecomeKey = true`), the same approach as Spotlight-style launchers.
- The Command Line Tools are older than the OS (SDK 15.2 vs macOS 26). The app still runs fine. Updating them via System Settings → General → Software Update is optional.
