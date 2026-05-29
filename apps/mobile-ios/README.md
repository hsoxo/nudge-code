# Nudge Mobile iOS

Native iOS app scaffold for the Nudge phone-first MVP.

- Distribution: TestFlight-only first.
- Orientation: portrait-only for MVP.
- Minimum OS: iOS 17.0. iPhone 13 is compatible on iOS 17.0 or newer.
- Protocol: generated from `proto/nudge.proto`.

## Project

The Xcode project is generated from `project.yml`:

```sh
xcodegen generate --spec project.yml
xcodebuild -project NudgeMobile.xcodeproj -scheme NudgeMobile -destination 'platform=iOS Simulator,name=iPhone 17' test
```

The first real relay/daemon integration smoke runs the iOS simulator test process against a hosted-mode local relay and a real `nudge bind phone --wait` flow. It claims the pairing, waits for daemon confirmation, opens the native relay session, requests tab state/output, and sends input through the real daemon:

```sh
../../scripts/smoke-ios-relay-claim.sh
```

To verify the app binary itself launches on the local simulator before manual testing:

```sh
../../scripts/smoke-ios-launch.sh
```

For manual local-first testing, run the relay on the development computer and bind with either a simulator-local URL, a same-network LAN URL, or a temporary Cloudflare Tunnel URL. See `../../docs/local-first-run.md`.

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
- pairing URL parser, `nudge://pair` deep links, and pending binding screen.
- camera QR scanner for pairing URLs.
- Keychain-backed phone signing identity.
- relay claim client using the phone public key.
- persisted machine binding metadata storage, including peer public identity keys for websocket attach and E2E handshake validation.
- one-shot relay binding status refresh when opening a pending machine.
- long-lived `/ws/mobile` session for state, snapshot, byte-safe replayed/live terminal bytes, input-response, phone-profile, and width-mode sync.
- automatic relay session reconnect with stale-state banner and app background/foreground session restart handling.
- bundled xterm.js runtime assets copied from `@xterm/xterm`.
- terminal snapshot fetch, bounded base64 replay buffer, and ephemeral daemon-pushed live terminal bytes into the native terminal preview.
- terminal input over relay from shortcut buttons and the composer.
- adaptive shortcut keyboard model for shell, Claude, Codex, and approval/waiting states.
- relay-issued signed mobile websocket challenges with the Keychain-backed phone identity.
- relay revocation handling that marks the machine binding revoked and stops reconnecting.
- SwiftProtobuf-generated E2E handshake and encrypted envelope protocol types.
- CryptoKit E2E handshake/envelope helpers for transcript signatures, X25519/HKDF/ChaCha20-Poly1305 encryption, and replay checks.
- E2E relay handshake exchange and encrypted request/response handling in `RelayClient`.
- in-process relay-session coverage for encrypted terminal input, daemon-pushed live output, and reconnect replay handling.
- gated iOS simulator integration coverage for claiming a real relay binding while the real daemon-side CLI waits and confirms, then opening the native relay session for state/output/input against the real daemon.

Still open:

- Physical-device mobile app terminal-session coverage against a hosted relay and real daemon.
