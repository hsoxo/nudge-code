# Nudge Implementation Plan

## Phase 0: Repo And Package Setup

Goals:

- establish Rust-first computer app structure
- keep daemon, CLI, relay, mobile, and protocol boundaries clear

Repository management:

- Use a monorepo. The Rust workspace, npm workspaces, protobuf schema, relay, installer scripts, docs, and native iOS app should ship from one repository while the protocol and product shape are still changing quickly.
- Avoid splitting CLI, relay, and mobile into separate repositories until public APIs, release cadence, and ownership boundaries are stable.

Tasks:

- Create workspace layout:

```text
nudge/
  apps/mobile-ios/
  crates/
    nudge-cli/
    nudge-daemon/
    nudge-protocol/
    nudge-terminal/
    nudge-pty/
    nudge-agent/
  packages/
    relay/
    protocol-ts/
  proto/
    nudge.proto
  scripts/
    install.sh
  docs/
```

- Use a Rust Cargo workspace for computer-side crates.
- Use npm workspaces only for the hosted relay and TypeScript protocol mirror.
- Put canonical protocol definitions in `proto/nudge.proto`.
- Generate Rust protocol types into `crates/nudge-protocol`.
- Generate TypeScript protocol types into `packages/protocol-ts`.
- Generate Swift protocol types for `apps/mobile-ios`.
- Add Rust CLI binary named `nudge`.
- Add internal daemon/server mode, launched by `nudge` when needed.
- Add release artifact naming for macOS and Linux.
- Add installer script skeleton at `scripts/install.sh`.
- Set package support target to macOS and Linux for CLI/daemon.
- Document naming rules: `tab`, not `pane`; `selected_tab`, not shared `active_tab`.

Exit criteria:

- `cargo build` works.
- `nudge --help` works.
- daemon/server mode can start a placeholder process.
- relay package can start HTTP server.
- installer script can select a platform/arch artifact in dry run mode.

## Phase 1: Rust Daemon MVP

Goals:

- build the long-lived local terminal authority
- prove tabs survive client detach

Tasks:

- Add native PTY support with `openpty`/`login_tty`.
- Implement `MachineSession`.
- Implement ordered `TerminalTab` metadata.
- Implement tab create/rename/close.
- Implement entitlement-aware tab creation limit.
- Implement PTY spawn per tab.
- Implement nonblocking PTY output reads.
- Implement dedicated PTY input write queue.
- Implement resize queue with coalescing.
- Implement no-client detach behavior.
- Persist metadata to `~/.nudge/state/session.json`.
- Add daemon restart behavior:
  - restore machine/session/tab metadata
  - mark non-resurrected tabs as `needs_restart`
- Add private local Unix socket IPC with length-prefixed protobuf frames.
- Ensure socket path is private to the current user and stale sockets are recoverable.

Exit criteria:

- daemon can be started automatically by `nudge`.
- daemon API can create a default shell tab if none exists.
- free entitlement rejects creating a second tab.
- daemon keeps tabs alive when no clients are connected.
- a minimal local test client can attach, detach, and reattach without killing the tab.
- local IPC socket is private to the current user.
- local IPC messages round-trip through generated protobuf types.

## Phase 2: Terminal Snapshot And Reconnect

Goals:

- restore useful terminal state after reconnect
- support phone-first width switching

Tasks:

- Add a headless terminal screen/grid model.
- Use `vte`, `vt100`, or equivalent parser.
- Feed PTY output into virtual screen.
- Keep bounded scrollback.
- Add terminal snapshot API.
- Add daemon-produced render frames for the local CLI.
- Add terminal output websocket replay for mobile/xterm.js:
  - connected/reconnected event
  - scrollback chunks
  - current snapshot
  - live output
- Add resize API.
- Add tab width mode state: phone or computer.
- Add phone terminal profile storage.
- Add `set_width_mode` API.
- Resize PTY to saved phone profile for phone width.
- Resize PTY to current CLI size for computer width.

Exit criteria:

- reconnect redraws useful terminal screen.
- CLI can redraw from daemon render frames without owning terminal parser state.
- tab can switch to phone width.
- tab can switch to computer width.
- phone profile can be saved and reused when phone is offline.

## Phase 3: CLI Tool

Goals:

- provide the computer-side interactive terminal client
- validate daemon APIs locally before relay/mobile

Current implementation status:

- Running `nudge` starts or attaches to the daemon and enters a raw-mode alternate-screen terminal client.
- The first client renders a Nudge tab/status chrome plus daemon-produced terminal render frames, forwards basic key input, handles resize, and detaches with `Ctrl-d`.
- `Ctrl-g` opens a Zellij-like prefix layer: `c` new tab, `x` close tab, `n`/`p` switch tabs, `r` rename, `R` restart, `w` toggle phone/computer width, `d` detach.
- Free entitlement currently rejects `Ctrl-g c` until paid/multi-tab entitlement exists.
- Mouse tab selection, rename inside the TUI, and daemon-produced embedded ANSI render frames are implemented. Incremental render diffing remains open Phase 3 work.

Tasks:

- Implement default `nudge` command:
  - start daemon if needed
  - attach to the only session
  - create a default tab if session is empty
- Locate the daemon through a private Unix socket.
- Treat stale socket files as daemon-not-running and recover automatically.
- Implement interactive TUI:
  - tab bar
  - active terminal area
  - status line
  - help/command hint line
- Implement in-client tab actions:
  - new tab
  - close tab
  - rename tab
  - next/previous tab
  - mouse click tab selection
- Implement Zellij-like keybinding layer.
- Attach local terminal raw mode to selected tab render/input stream.
- Forward terminal resize from local CLI attach.
- Add `Ctrl-g w` width toggle between phone and computer.
- Show current width mode in status line.
- Implement clean detach on shortcut, Ctrl-D, or CLI exit.
- Show daemon status.
- Show relay status.
- Keep management commands minimal:
  - `nudge daemon status`
  - `nudge daemon stop`
  - `nudge bind phone`
  - `nudge bind revoke`

Exit criteria:

- `nudge` feels like opening a Zellij-style single-session client.
- CLI can manage tabs inside the interactive client.
- selected tab behaves like a normal terminal.
- terminal parser/grid state stays daemon-owned.
- CLI can switch selected tab between phone width and computer width.
- exiting CLI does not kill tabs.
- rerunning CLI attaches back.
- stale daemon socket recovery works.

## Phase 4: Relay MVP

Goals:

- make phone and computer independent of LAN
- establish device identity and routing

Tasks:

- Create Node/TypeScript relay service.
- Design hosted relay deployment as the first target.
- Keep relay deployment platform undecided for now; compare AWS EC2 and managed/SaaS hosting before broader launch.
- Add device registration.
- Add signed websocket authentication.
- Add E2E encrypted message envelope between phone and daemon.
- Implement Ed25519 device identity signatures.
- Implement ephemeral X25519 session handshake.
- Implement HKDF-SHA256 directional key derivation.
- Implement ChaCha20-Poly1305 encrypted payload envelopes.
- Add sequence numbers and replay rejection.
- Add `POST /api/bind/start`.
- Add `POST /api/bind/claim`.
- Add `POST /api/bind/confirm`.
- Add `POST /api/bind/revoke`.
- Enforce one-phone-per-computer binding.
- Add daemon websocket endpoint.
- Add mobile websocket endpoint.
- Add route authorization.
- Add free entitlement: one active computer binding per phone account/device.
- Add entitlement state sync from relay to daemon.
- Forward messages between bound phone and daemon.
- Forward phone terminal profile updates as encrypted daemon-bound control messages.
- Ensure terminal payloads are not logged.

Current implementation status:

- Relay has device registration, bind start/claim/confirm/revoke, daemon/mobile websocket endpoints, participant route authorization, free one-computer binding enforcement, and message forwarding.
- Relay revocation closes active participant websockets, rejects new websocket attaches for revoked bindings, and drops queued messages for the revoked binding.
- Relay can persist devices and bindings to a local JSON file when `NUDGE_RELAY_STATE_PATH` is set; queued messages remain process-local so terminal/control payloads are not written to disk by default.
- Relay supports Ed25519 signed websocket auth query parameters with in-memory nonce replay rejection in compatibility mode, and can require signatures with `NUDGE_RELAY_REQUIRE_WS_SIGNATURE=1`.
- Relay issues short-lived, one-shot websocket auth challenges through `POST /api/ws/challenge`; daemon and iOS sign those challenges before opening their websocket, and hosted deployments can require them with `NUDGE_RELAY_REQUIRE_WS_CHALLENGE=1`.
- Relay rate-limits pairing claim attempts by client address and normalized pairing code; this protects the short pairing code from simple online guessing while keeping the limits configurable for hosted deployment.
- Relay can require E2E setup/encrypted payloads with `NUDGE_RELAY_REQUIRE_E2E_PAYLOAD=1`; in that mode it rejects plaintext control payloads and only forwards `e2e_handshake_start`, `e2e_handshake_finish`, or `e2e_envelope` payloads.
- Relay can disable legacy unauthenticated HTTP message send/poll endpoints with `NUDGE_RELAY_DISABLE_HTTP_MESSAGES=1`; hosted deployments should use signed websocket routing for cross-device control.
- Relay exposes `/readyz` with config flags, runtime counts, and warnings for weak hosted settings such as missing persistence, unsigned websockets, missing websocket challenges, legacy HTTP messages, and non-required E2E envelopes.
- Relay binding responses include route-authorized daemon and phone public identity keys so both endpoints can verify the upcoming E2E handshake transcript.
- Canonical protobuf schema now includes E2E handshake and encrypted envelope messages, with Rust, TypeScript, and Swift protocol mirrors.
- Daemon has tested X25519/HKDF/ChaCha20-Poly1305 envelope helpers with route-bound associated data, sequence replay rejection, canonical relay JSON setup/envelope payloads, Ed25519 handshake transcript signing/verification, and handler-level live E2E handshake plus encrypted control response coverage.
- iOS has matching CryptoKit E2E envelope and handshake helpers with tests for encryption/decryption, replay rejection, route checks, canonical relay JSON payloads, transcript signature tamper rejection, and RelayClient E2E handshake/encrypted request coverage.
- Daemon persists a long-lived Ed25519 identity in the user state file, registers its public key during pairing, caches the phone public key after binding confirmation, and signs relay websocket URLs before connecting.
- iOS sends signed mobile websocket URLs using its Keychain-backed signing identity and stores the daemon public key from binding claim/status responses.
- Daemon marks a relay-revoked binding as revoked locally and stops reconnecting; iOS maps `binding_revoked` relay errors to a revoked/offline machine instead of a generic reconnect loop.
- Daemon/iOS live relay paths perform a phone-initiated E2E handshake when binding public keys are available, wrap phone-to-daemon control requests, daemon responses, and post-handshake live terminal updates in encrypted envelopes, and fall back to plaintext only for legacy bindings without peer public keys.
- A spawned-process E2E smoke now starts relay plus daemon and drives a simulated websocket phone client through E2E handshake, encrypted state request, encrypted terminal input, encrypted live terminal output, and reconnect replay. Managed database storage, hosted deployment, entitlement downgrade behavior, and broader account/device revocation remain open.

Exit criteria:

- daemon connects outbound to relay.
- simulated phone connects to relay.
- relay routes state request/response.
- relay refuses unbound phone.
- relay refuses a second active computer binding for free entitlement.
- spawned-process smoke starts relay and daemon, binds a simulated phone, performs E2E handshake, sends encrypted terminal input, receives encrypted daemon response/live output, reconnects the simulated phone, and replays encrypted terminal output.

## Phase 5: Binding CLI

Goals:

- make binding usable from terminal
- keep security explicit

Current implementation status:

- `nudge bind phone` starts relay pairing, stores a pending binding in daemon session state, and prints a fallback pairing URL/code.
- `nudge bind phone` renders a terminal QR code and can `--wait --yes` for simulated phone claim and computer confirmation.
- Hidden smoke helpers can simulate phone claim and computer confirmation until the native iOS binding UI exists.
- `nudge bind revoke` revokes the relay binding and clears local binding state.
- Native iOS QR scanning, phone signed websocket URLs, daemon signed websocket URLs, participant public key caching, live relay E2E encryption wiring, and spawned relay/daemon/simulated-phone E2E smoke coverage are implemented. Reconnect and true mobile-app process integration coverage remain open Phase 5/relay work.

Tasks:

- Implement `nudge bind phone`.
- Generate terminal QR code.
- Print fallback pairing URL/code.
- Show pairing challenge expiration.
- Show pending phone info.
- Ask for confirmation in CLI.
- Implement `nudge bind revoke`.
- Daemon stores bound phone id.
- Daemon stores latest phone terminal profile locally.
- Relay stores binding state.
- Relay forwards phone terminal profile updates to daemon.
- Relay does not persist phone terminal profile details in MVP.

Exit criteria:

- phone simulator can claim QR pairing.
- CLI confirms binding.
- relay activates binding.
- second phone is rejected until revocation.
- second computer binding is rejected for free entitlement until upgrade or revocation.

## Phase 6: Native iOS MVP

Goals:

- native-first phone experience
- view and control computer tabs through relay

Current implementation status:

- `apps/mobile-ios` has an XcodeGen-backed SwiftUI scaffold that builds and tests on iPhone simulator.
- The scaffold includes machine list, tab strip, terminal preview WebView with bundled xterm.js assets, relay-backed phone/computer width control, pairing URL parsing, pending binding UI, camera QR scanning, SwiftProtobuf-generated protocol types, Keychain-backed phone signing identity, relay claim client with machine binding metadata storage, one-shot binding status refresh, long-lived mobile websocket sync for session state/snapshots/input responses, phone profile reporting, automatic relay session reconnect with stale-state banner, terminal snapshot fetch, replayed terminal output tail, throttled ephemeral daemon-pushed live terminal byte updates, terminal input over relay, and adaptive shortcut keyboard model/tests for Claude/Codex approval/waiting states.
- iOS and daemon websocket signatures are implemented; E2E handshake/encrypted relay requests are implemented in RelayClient. Richer scrollback replay, reconnect integration, and true mobile-app process integration coverage remain open.

Tasks:

- Create Swift/SwiftUI app.
- Target TestFlight-only distribution for the first iOS release.
- Generate Swift protocol types from protobuf.
- Generate/load phone device keypair in Keychain.
- Scan QR pairing code.
- Store multiple computer profiles.
- Implement native app shell with embedded WebView/xterm.js terminal renderer.
- Report portrait terminal profile after binding.
- Update portrait terminal profile on font/viewport changes.
- Connect to relay.
- List computers.
- Show computer online/offline state.
- Show tab list.
- Show tab status and agent status.
- Open terminal view.
- Control tabs in both phone width and computer width.
- Render computer-width tabs with scale, horizontal scroll, and cursor-follow.
- Add phone/computer width segmented control.
- Send raw input.
- Send command.
- Send prompt.
- Add reconnect and stale-state UI.

Exit criteria:

- iPhone can bind to computer through relay.
- iPhone can view tab list from another network.
- iPhone renders terminal bytes through WebView/xterm.js inside native app shell.
- iPhone can send command/prompt to selected tab.
- iPhone can control a computer-width tab using adapted rendering.
- iPhone profile updates allow CLI to switch to phone width.

## Phase 7: Agent Detection

Goals:

- identify Claude/Codex tabs
- surface useful waiting/approval states

Current implementation status:

- `AgentStatus` is part of the shared Rust/TypeScript/protobuf tab state.
- The daemon refreshes conservative title/screen-text heuristics when serving session state, snapshots, and render frames.
- The daemon records the spawned PTY command name/PID and uses the command name as a process-source signal when it directly identifies Claude, Codex, Opencode, OpenClaw, or a shell.
- On macOS/Linux, the daemon scans the PTY child process descendants through `ps -axo pid=,ppid=,stat=,comm=` and prefers foreground (`STAT` contains `+`) agent/non-shell descendants before falling back to descendant agent commands, root shell command, title, and screen heuristics.
- The daemon has fixture-backed classifier tests for Claude approval, Codex waiting-for-input, and low-confidence unknown output.
- Current heuristic kinds: `claude`, `codex`, `opencode`, `openclaw`, `shell`, `unknown`.
- Current heuristic states: `running`, `waiting_for_input`, `needs_approval`, `exited`.
- Direct controlling-terminal process group queries, event emission, and broader classifier fixture expansion remain open Phase 7 work.

Tasks:

- Implement foreground-aware process detection on macOS and Linux.
- Walk process tree for PTY foreground and agent process signals.
- Classify process command:
  - `claude`
  - `codex`
  - `opencode`
  - `openclaw`
  - shell
  - unknown
- Add `AgentStatus` to tab metadata.
- Emit `agent_status_changed` events.
- Implement screen text classifier.
- Implement raw output classifier.
- Add pattern fixtures for representative Claude/Codex screens.
- Add confidence level to every classification.

Exit criteria:

- daemon labels Claude tab as `kind=claude`.
- daemon labels Codex tab as `kind=codex`.
- foreground process detection works on supported macOS and Linux targets.
- visible approval prompt sets `state=needs_approval`.
- visible waiting prompt sets `state=waiting_for_input`.
- uncertain detection does not produce high confidence.

## Phase 8: Adaptive Mobile Keyboard

Goals:

- make phone interaction fast for shell and coding agents

Tasks:

- Define keyboard profile schema.
- Implement base terminal keyboard.
- Implement shell profile.
- Implement Claude profile.
- Implement Codex profile.
- Implement state-specific rows:
  - approval row
  - waiting/prompt row
- Bind profile selection to `AgentStatus`.
- Add command composer.
- Add prompt composer.
- Add approval-action friction:
  - clear label
  - deliberate tap
  - optional confirmation for dangerous actions

Exit criteria:

- shell tab shows shell keyboard.
- Claude tab shows Claude keyboard.
- Codex tab shows Codex keyboard.
- approval state adds approval controls.
- waiting state emphasizes prompt composer.

## Phase 9: Packaging And Service Management

Goals:

- make native install practical
- keep daemon alive without a desktop app

Current implementation status:

- `scripts/install.sh` detects macOS/Linux architecture, downloads a release tarball, verifies a `.sha256` file unless `NUDGE_SKIP_CHECKSUM=1`, installs `nudge` into the configured user bin directory, and supports local release URL overrides for smoke tests.
- `scripts/package-release.sh` packages an existing `nudge` binary as `nudge-{macos|linux}-{aarch64|x86_64}.tar.gz` and writes the matching `.sha256` file.
- `scripts/smoke-install.sh` verifies the installer against a release artifact generated by `scripts/package-release.sh`.
- `nudge service install --dry-run` renders the platform-specific user service file.
- macOS service support writes `~/Library/LaunchAgents/dev.nudgecode.nudge.daemon.plist` and uses `launchctl bootstrap/kickstart`.
- Linux service support writes `~/.config/systemd/user/nudge.service` and uses `systemctl --user enable --now`.
- `nudge service uninstall --dry-run`, `nudge service status`, and `nudge service logs` have first-pass command wiring.
- `nudge update` re-runs the native installer from `https://nudgecode.dev/install.sh` by default, supports dry-run, version override, install-dir override, checksum skip forwarding, and local installer paths for tests.
- CI-built multi-platform release artifacts, signature verification beyond SHA-256 checksums, and hosted install URL publishing remain open.

Tasks:

- Add `curl -fsSL https://nudgecode.dev/install.sh | bash` install path.
- Build precompiled release artifacts for macOS and Linux.
- Add checksum/signature verification.
- Install binary into `~/.local/bin` by default, with override support.
- Add uninstall/update path.
- Add `nudge service install` for launchd on macOS.
- Add `nudge service install` for systemd user services on Linux.
- Add `nudge service uninstall`.
- Add logs command.
- Add update command.
- Add clear diagnostics for unsupported OS/architecture.

Exit criteria:

- clean install on macOS.
- clean install on Linux.
- daemon can be launched at login.
- user can inspect logs and status from CLI.

## Phase 10: Security Hardening

Goals:

- reduce relay and approval risk before broader use

Tasks:

- Harden signed websocket auth with server-issued challenges.
- Add binding revocation propagation.
- Add entitlement revocation/downgrade behavior.
- Validate E2E encrypted envelope for terminal/control streams.
- Validate handshake transcript signatures.
- Validate replay rejection and session rekey behavior.
- Add terminal log redaction in relay.
- Add audit events for binding and approval actions.
- Add device key rotation design.
- Add rate limits for pairing attempts.

Current implementation status:

- Signed websocket auth supports relay-issued one-shot challenges; daemon and iOS both request and sign challenges before websocket connect, and relay can reject legacy timestamp/nonce auth when challenge enforcement is enabled.
- Binding revocation propagates to active daemon and iOS sessions through relay websocket errors; both clients stop reconnecting and surface revoked state locally.
- Pairing claim attempts are rate-limited in the relay by client address and normalized pairing code, returning `429 pairing_rate_limited` with `Retry-After` when exceeded.
- Relay audit logging can be enabled with `NUDGE_RELAY_AUDIT_PATH`; it writes JSONL metadata events for device registration, binding start/claim/confirm/revoke, websocket challenge/authorization/rejection, message routing/queueing, and polling.
- Relay audit records intentionally omit terminal/control payloads, pairing codes, and device public keys. Message events only record route metadata plus `payloadType`.
- Relay E2E payload enforcement can be enabled with `NUDGE_RELAY_REQUIRE_E2E_PAYLOAD=1`; it rejects plaintext relay payloads and forwards only E2E handshake setup or opaque encrypted envelope payloads.
- Shared protobuf types define E2E handshake and encrypted envelope messages. Daemon and iOS cover encryption, replay rejection, relay JSON conversion, transcript signature validation, and live relay request/response encryption.
- Relay legacy HTTP message endpoints can be disabled with `NUDGE_RELAY_DISABLE_HTTP_MESSAGES=1`, leaving signed websocket routing active.
- The in-memory challenge and rate-limit stores are appropriate for the single-process hosted MVP; production multi-instance deployment should move them to Redis or the managed data store.

Exit criteria:

- relay cannot route messages between unbound devices.
- revoked phone loses access quickly.
- relay logs contain no terminal text.

## Test Plan

Daemon tests:

- generated protobuf compatibility
- tab ordering
- create/rename/close
- free entitlement rejects second tab
- detach does not kill PTY
- reconnect snapshot
- metadata restore after daemon restart
- stale local socket recovery
- PTY write/read backpressure under heavy output
- resize behavior in full-screen TUIs
- phone width resize uses saved phone profile
- computer width resize uses CLI dimensions
- phone can send input in both width modes

CLI tests:

- default `nudge` starts/locates daemon and attaches
- in-client new/close/rename/switch tab
- mouse tab selection
- Zellij-like keybindings
- attach/detach behavior
- terminal resize forwarding
- width toggle shortcut
- width status indicator
- binding QR command
- service install command dry run

Relay tests:

- device registration
- signed websocket auth
- E2E envelope enforcement rejects plaintext relay payloads
- hosted-mode HTTP message endpoints disabled while websocket routing still works
- readiness endpoint surfaces hosted relay hardening warnings
- replayed encrypted payload rejected
- pairing challenge expiration
- pairing claim rate limiting
- audit log redaction for terminal payloads, pairing codes, and public keys
- one-phone-per-computer enforcement
- free entitlement one-computer binding enforcement
- route authorization
- revocation
- no terminal payload logging
- spawned-process relay + daemon + simulated phone integration test for E2E handshake, encrypted terminal input, encrypted daemon response, and encrypted live terminal output

Agent tests:

- process classifier fixtures
- foreground process detection on macOS
- foreground process detection on Linux
- Claude approval text fixture
- Codex approval text fixture
- waiting-for-input text fixture
- low confidence on unknown text

iOS tests:

- keypair stored in Keychain
- QR bind flow
- portrait phone terminal profile reporting
- phone/computer width segmented control
- multiple computer profiles
- tab list rendering
- adaptive keyboard profile selection
- command/prompt sending
- reconnect after app background

Manual end-to-end tests:

- install Nudge with native installer script
- run `nudge` and enter the interactive client
- bind phone to computer through relay
- open CLI and phone on different networks
- create tab inside CLI and view it from phone
- bind phone, save phone profile, switch CLI tab to phone width
- switch tab to computer width and control it from phone with adapted rendering
- send command from phone and see output in CLI-attached tab
- run Claude and see Claude keyboard
- run Codex and see Codex keyboard
- trigger approval prompt and see mobile status update
- close all clients and verify daemon keeps tabs alive

## Initial Milestones

1. Rust workspace and CLI skeleton.
2. Rust daemon shell tabs.
3. Virtual screen reconnect.
4. Interactive `nudge` client attach/detach.
5. In-client tab bar, keybindings, and mouse tab switching.
6. Relay websocket routing.
7. Device binding through CLI QR.
8. Native iOS machine and tab list.
9. Phone-first width switching.
10. Phone command/prompt sender.
11. Claude/Codex process detection.
12. Agent state text detection.
13. Adaptive mobile keyboards.
14. Native packaging and daemon service management.
