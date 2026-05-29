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

Shared protocol types are generated from the repo protobuf schema:

```sh
../../scripts/generate-swift-proto.sh
```

Current scaffold:

- SwiftUI app shell.
- SwiftProtobuf-generated protocol types from `proto/nudge.proto`.
- machine list and tab strip.
- terminal preview rendered through bundled xterm.js inside `WKWebView`.
- phone/computer width segmented control backed by relay width-mode updates.
- pairing URL parser and pending binding screen.
- camera QR scanner for pairing URLs.
- Keychain-backed phone signing identity.
- relay claim client using the phone public key.
- machine binding metadata storage, including peer public identity keys for later websocket attach and E2E handshake validation.
- one-shot relay binding status refresh when opening a pending machine.
- long-lived `/ws/mobile` session for state, snapshot, replayed/live terminal bytes, input-response, phone-profile, and width-mode sync.
- automatic relay session reconnect with stale-state banner.
- bundled xterm.js runtime assets copied from `@xterm/xterm`.
- terminal snapshot fetch and ephemeral daemon-pushed live terminal bytes into the native terminal preview.
- terminal input over relay from shortcut buttons and the composer.
- adaptive shortcut keyboard model for shell, Claude, Codex, and approval/waiting states.
- relay-issued signed mobile websocket challenges with the Keychain-backed phone identity.
- relay revocation handling that marks the machine binding revoked and stops reconnecting.
- SwiftProtobuf-generated E2E handshake and encrypted envelope protocol types.
- CryptoKit E2E handshake/envelope helpers for transcript signatures, X25519/HKDF/ChaCha20-Poly1305 encryption, and replay checks.

Still open:

- E2E encrypted terminal/control stream handshake exchange and live relay wiring.
