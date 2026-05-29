# Nudge Mobile iOS

Native iOS app scaffold for the Nudge phone-first MVP.

- Distribution: TestFlight-only first.
- Orientation: portrait-only for MVP.
- Protocol: generated from `proto/nudge.proto`.

## Project

The Xcode project is generated from `project.yml`:

```sh
xcodegen generate --spec project.yml
xcodebuild -project NudgeMobile.xcodeproj -scheme NudgeMobile -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Current scaffold:

- SwiftUI app shell.
- machine list and tab strip.
- terminal preview rendered through `WKWebView`, ready to replace with xterm.js assets.
- phone/computer width segmented control.
- pairing URL parser and pending binding screen.
- Keychain-backed phone signing identity.
- relay claim client using the phone public key.
- machine binding metadata storage for later websocket attach.
- one-shot relay binding status refresh when opening a pending machine.
- first `/ws/mobile` attach path that requests daemon session state.
- adaptive shortcut keyboard model for shell, Claude, Codex, and approval/waiting states.

Still open:

- camera QR scanner.
- signed relay authentication.
- continuous websocket session sync.
- E2E encrypted terminal/control stream.
- real xterm.js integration.
