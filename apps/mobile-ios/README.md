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
- first-pass relay claim client.
- adaptive shortcut keyboard model for shell, Claude, Codex, and approval/waiting states.

Still open:

- camera QR scanner.
- Keychain-backed phone identity key.
- signed relay authentication.
- websocket session sync.
- E2E encrypted terminal/control stream.
- real xterm.js integration.
