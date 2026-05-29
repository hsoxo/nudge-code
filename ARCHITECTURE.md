# Nudge Architecture

## Overview

Nudge has three product surfaces plus one shared protocol package:

```text
Native phone app
    |
    | outbound authenticated websocket
    v
Node/TypeScript relay
    ^
    | outbound authenticated websocket
    |
computer daemon <-> local Unix socket <-> nudge CLI
```

The computer daemon is the terminal authority. The relay is the device and routing authority. The CLI and phone are clients.

Nudge is managed as a monorepo. The Rust workspace, Node/npm workspaces, protobuf schema, installer scripts, docs, and native iOS app belong in one repository because the product depends on synchronized protocol, entitlement, relay, daemon, and mobile changes. Split repositories would add coordination overhead before the APIs are stable.

MVP platform targets:

- CLI/daemon: macOS and Linux.
- CLI/daemon implementation: Rust native binary, installed by a native installer script.
- Mobile: iOS, TestFlight-only first, portrait-only for MVP.
- Relay: hosted Node/TypeScript service first.
- Terminal/control streams: end-to-end encrypted between phone and daemon.
- Protocol source of truth: protobuf schemas generated into Rust, TypeScript, and Swift.

## Authority Boundaries

### Daemon Authority

The daemon owns:

- machine session
- tab list and tab order
- PTY processes
- terminal input/output
- terminal screen snapshots
- scrollback used for reconnect
- tab lifecycle
- foreground process detection
- agent status detection
- per-tab metadata

The daemon must keep running after CLI and phone clients detach.

### Relay Authority

The relay owns:

- device registration
- phone/computer binding
- connection presence
- route authorization
- message forwarding
- revocation

The relay should not be the source of truth for terminal state. It should not persist terminal output by default.

The relay is the entitlement authority for cross-device limits such as how many computers a phone can bind.

### Client Authority

Each client owns:

- its selected tab
- its current local viewport
- local client preferences
- native secure storage for its private key

CLI and phone selected tabs are independent.

## Zellij-Like Local Runtime

Nudge should copy Zellij's local runtime shape, not its full feature set.

Zellij's relevant model:

- The interactive command is a client.
- A separate server process owns the long-lived terminal session.
- The client connects to the server over a private local socket.
- The client enters raw terminal mode, forwards keyboard/mouse/paste/resize events, and renders server output.
- The server owns PTYs, terminal buffers, tab/pane state, and lifecycle.
- The server can send render frames to the client instead of making the client reconstruct all terminal state.
- When the client exits, it detaches. The server keeps PTYs alive.

Nudge's equivalent:

```text
nudge command
  -> locate private local socket
  -> start daemon if socket is missing or stale
  -> attach to the single daemon session
  -> enter raw mode / alternate screen
  -> forward input, mouse tab clicks, paste, and resize
  -> render daemon-produced frames for active tab plus Nudge tab bar/status line
  -> detach on exit without stopping daemon tabs
```

Daemon internals should follow the same authority split:

```text
local IPC server
  -> session/tab manager
  -> PTY manager
  -> PTY writer and resize queue
  -> terminal parser/grid/snapshot store
  -> agent/process detector
  -> relay connection
```

This structure is the primary Rust computer-side architecture.

## Component Design

### `nudge` Daemon/Server Mode

Language: Rust.

Main dependencies:

- `nix` or equivalent for `openpty`, `login_tty`, signals, process groups, and terminal resize
- Tokio or similar async runtime for nonblocking PTY reads and sockets
- `vte`, `vt100`, or equivalent terminal parser
- Unix-domain-socket IPC
- `serde` for protocol types
- `prost` or equivalent for generated protobuf messages
- `tokio-tungstenite` or equivalent for relay websocket connection
- platform-specific process inspection for foreground command detection

Main responsibilities:

- start at login or automatically when `nudge` runs
- open PTYs
- run the user's shell in each tab
- maintain one machine session
- persist session metadata
- keep PTYs alive while detached
- maintain terminal grid/render state for each tab
- expose private local Unix socket framed IPC for CLI
- connect outbound to relay
- classify foreground app per tab
- classify agent state from screen/output text

Suggested modules:

```text
crates/nudge-daemon/
  src/
    main.rs
    ipc.rs
    session.rs
    tab.rs
    pty.rs
    pty_writer.rs
    terminal_grid.rs
    relay.rs
    agent.rs
    security.rs
    persistence.rs
```

The daemon should be smaller than Zellij:

- no panes
- no layouts
- no plugins
- no multiple sessions
- no full mode/keybinding system in the daemon
- no direct dependency on Zellij internals unless a later spike proves that vendoring a small component is cleaner

Entitlement behavior:

- daemon enforces local tab limits after receiving entitlement state from relay
- if relay is unreachable, daemon should keep existing tabs usable but should not create tabs beyond the last known entitlement
- free version entitlement allows one tab per computer session

### `nudge` CLI

Language: Rust, shipped as the same `nudge` native binary. The binary can run in client mode by default and daemon/server mode internally.

Main dependencies:

- `crossterm`, `termwiz`, or equivalent for raw-mode input, mouse events, paste, resize, and alternate screen
- lower-level ANSI renderer for Zellij-like tab bar/status rendering
- QR rendering crate for pairing QR output

Responsibilities:

- default command starts or locates daemon and attaches to the only session
- render an interactive terminal UI similar to Zellij
- attach local terminal to daemon-produced render/input streams for the selected tab
- create/rename/close/select tabs inside the interactive UI
- support keyboard shortcuts for new tab, close tab, next/previous tab, rename tab, and detach
- support mouse selection on the tab bar
- show tab and agent status
- show daemon and relay status
- start phone binding
- show pairing QR code or fallback pairing URL/code in terminal
- confirm or revoke phone binding
- detach cleanly when the CLI exits

Normal usage:

```text
nudge
```

Inside the interactive client:

```text
Ctrl-g c        new tab
Ctrl-g x        close tab
Ctrl-g n        next tab
Ctrl-g p        previous tab
Ctrl-g r        rename tab
Ctrl-g R        restart tab
Ctrl-g d        detach
mouse click     select tab
```

Management commands:

```text
nudge bind phone
nudge bind revoke
nudge daemon status
nudge daemon stop
nudge relay status
```

The CLI should communicate through the same logical protocol as mobile, but over a private local Unix socket. The CLI should avoid owning terminal parsing state; the daemon's grid is authoritative.

### `nudge-mobile`

Preferred first target: native iOS.

Terminal renderer: native iOS app shell with embedded WebView/xterm.js for MVP. This keeps the app native while using a mature terminal renderer for PTY bytes.

Rendering authority:

- daemon terminal grid is authoritative for snapshots, reconnect, agent text detection, and CLI render frames
- iOS xterm.js is a presentation renderer for terminal output and snapshots
- if iOS display and daemon grid disagree, daemon grid wins for status, detection, and reconnect state

Responsibilities:

- store phone device key in Keychain
- store multiple computer bindings
- report portrait terminal profile during binding and whenever portrait viewport/font changes
- connect to relay
- list computers
- show computer presence
- show tabs and agent status
- view tab snapshots
- control tabs in both phone-width and computer-width modes
- adapt computer-width rendering with scale, horizontal scroll, and cursor-follow
- send commands and prompts
- present adaptive shortcut keyboards
- receive push notifications later

MVP limitations:

- portrait orientation only
- no landscape terminal profile
- no custom tab width beyond phone/computer modes

Keyboard layers:

```text
base terminal keyboard
  + app keyboard: shell | claude | codex | unknown
  + state keyboard: running | waiting_for_input | needs_approval
```

### `nudge-relay`

Language: Node/TypeScript.

Suggested stack:

- Fastify or Hono for HTTP
- `ws` for raw websockets
- PostgreSQL for devices/bindings
- Redis optional for presence and fanout
- protobuf-generated TypeScript types plus boundary validation

Responsibilities:

- register devices
- issue pairing challenges
- claim and confirm binding
- rate-limit pairing claim attempts by client address and pairing code
- enforce one-phone-per-computer rule
- route messages between bound phone and computer daemon
- expose presence
- revoke devices/bindings
- avoid terminal data persistence
- enforce binding entitlements

## Installation And Updates

Computer install path:

```text
curl -fsSL https://nudgecode.dev/install.sh | bash
```

Installer responsibilities:

- detect OS and CPU architecture
- download the matching prebuilt `nudge` artifact
- verify checksum/signature before installing
- install into a user-writable bin directory by default
- print the exact install path
- optionally set up launchd/systemd user service
- support update and uninstall commands

The installer should not require Node, npm, Cargo, Xcode, or a Rust toolchain on the user's computer. Build toolchains belong in CI/release automation, not in the normal user install path.

## Data Model

### Daemon State

```ts
interface Machine {
  id: string
  name: string
  publicKey: string
  daemonVersion: string
  boundPhoneId?: string
  phoneTerminalProfile?: PhoneTerminalProfile
  entitlement?: Entitlement
}

interface Entitlement {
  plan: 'free' | 'paid'
  maxBoundComputers: number
  maxTabsPerComputer: number
  updatedAt: string
}

interface PhoneTerminalProfile {
  deviceId: string
  displayName: string
  current: { cols: number; rows: number; orientation: 'portrait' }
  portrait?: { cols: number; rows: number }
  fontScale?: number
  updatedAt: string
}

interface MachineSession {
  id: 'default'
  tabs: TerminalTab[]
  createdAt: string
  updatedAt: string
}

interface TerminalTab {
  id: string
  title: string
  cwd?: string
  command?: string
  status: 'running' | 'exited' | 'needs_attention' | 'needs_restart'
  exitCode?: number
  createdAt: string
  lastActivityAt: string
  viewport: TabViewport
  agentStatus?: AgentStatus
}

interface TabViewport {
  widthMode: 'phone' | 'computer'
  cols: number
  rows: number
  updatedByDeviceId?: string
  updatedAt: string
}

interface ClientAttachment {
  clientId: string
  deviceId: string
  selectedTabId?: string
  localViewport?: { cols: number; rows: number }
  lastSeenAt: string
}
```

### Agent State

```ts
type AgentKind =
  | 'claude'
  | 'codex'
  | 'opencode'
  | 'openclaw'
  | 'shell'
  | 'unknown'

type AgentInteractionState =
  | 'running'
  | 'idle'
  | 'waiting_for_input'
  | 'needs_approval'
  | 'needs_attention'
  | 'exited'

interface AgentStatus {
  kind: AgentKind
  state: AgentInteractionState
  confidence: 'high' | 'medium' | 'low'
  detectedFrom: 'process' | 'screen_text' | 'output_text' | 'hook'
  foregroundPid?: number
  foregroundCommand?: string
  message?: string
  updatedAt: string
}
```

### Relay State

```ts
interface Device {
  id: string
  kind: 'computer' | 'phone'
  publicKey: string
  displayName: string
  accountId?: string
  entitlementPlan?: 'free' | 'paid'
  createdAt: string
  revokedAt?: string
}

interface Binding {
  id: string
  accountId?: string
  computerDeviceId: string
  phoneDeviceId: string
  status: 'pending' | 'active' | 'revoked'
  createdAt: string
  confirmedAt?: string
  revokedAt?: string
}

interface PairingChallenge {
  id: string
  computerDeviceId: string
  codeHash: string
  expiresAt: string
  claimedPhoneDeviceId?: string
}
```

Free version limits:

- `maxBoundComputers = 1`
- `maxTabsPerComputer = 1`
- relay rejects a second active computer binding for the same phone account/device
- daemon rejects a second tab for a free entitlement
- paid tiers can raise these limits without changing the session model

Pairing claim rate limits:

- apply to every `/api/bind/claim` attempt before code lookup
- key by client address and normalized pairing code in the hosted MVP
- return `429 pairing_rate_limited` and `Retry-After` when exceeded
- move the counters to Redis or managed storage before running multiple relay instances

## Protocol

Use protobuf as the canonical protocol schema. Generate Rust types for the computer binary, TypeScript types for the relay, and Swift types for iOS. The relay wraps and routes messages; it should not reinterpret terminal semantics or decrypt terminal/control payloads.

Important local message families, modeled after Zellij's client/server contract:

- `attach_client`
- `client_exited`
- `terminal_resize`
- `terminal_input`
- `tab_action`
- `render` for CLI-oriented terminal frames
- `terminal_snapshot`
- `terminal_output` for mobile/xterm.js-oriented byte stream and replay
- `terminal_exit`
- `relay_status`
- `bind_status`

### Local Daemon API

Transport: private Unix domain socket on macOS/Linux. Use length-prefixed protobuf frames for production local IPC. Avoid localhost TCP for production local IPC.

```text
client -> daemon:
  AttachClient
  ClientExited
  TerminalResize
  TerminalInput
  CreateTab
  CloseTab
  RenameTab
  SelectTab
  SetWidthMode
  StartBinding
  RevokeBinding
  GetState

daemon -> client:
  Attached
  SessionState
  TabUpdated
  TerminalRender
  TerminalSnapshot
  AgentStatusChanged
  RelayStatus
  BindingStatus
  Error
```

`TerminalRender` is optimized for the local CLI. `TerminalOutput` and `TerminalSnapshot` are used by mobile/xterm.js through the relay path.

### Relay API

```text
POST /api/devices/register
POST /api/ws/challenge
POST /api/bind/start
POST /api/bind/claim
POST /api/bind/confirm
POST /api/bind/revoke
GET  /api/computers
WS   /ws/daemon
WS   /ws/mobile
```

Websocket auth:

- client requests `POST /api/ws/challenge` with its device id and active binding id
- relay issues a short-lived, one-shot challenge message
- client signs the challenge with its long-lived Ed25519 identity key
- websocket URL carries `authChallengeId` and `authChallengeSignature`
- relay consumes the challenge during upgrade and rejects replayed or expired challenges

Phone terminal profile updates travel as encrypted daemon-bound control messages after binding. The daemon is the source of truth for the latest phone terminal profile. The relay should not store terminal profile details in MVP.

### Protobuf Message Families

State messages:

- `SessionState`
- `TabCreated`
- `TabUpdated`
- `TabClosed`
- `ClientSelectedTab`
- `TabWidthChanged`
- `PhoneTerminalProfileUpdated`
- `AgentStatusChanged`
- `PresenceChanged`
- `EntitlementUpdated`

Terminal messages:

- `TerminalOutput`
- `TerminalRender`
- `TerminalSnapshot`
- `TerminalReconnected`
- `TerminalExit`

`TerminalRender` is for the local CLI, where Nudge controls the surrounding tab bar/status UI. `TerminalOutput` and `TerminalSnapshot` are for mobile and replay paths that render through xterm.js.

Input/control messages:

- `TerminalInput`
- `SendCommand`
- `SendPrompt`
- `SetWidthMode`
- `ApprovalAction`

## Binding Flow

1. Daemon starts and creates/loads computer device keypair.
2. Daemon connects outbound to relay.
3. User runs `nudge bind phone`.
4. CLI asks daemon/relay to start pairing.
5. Relay creates short-lived pairing challenge.
6. CLI prints a terminal QR code and fallback pairing URL/code containing relay URL, computer device id, pairing code, computer public key, and expiration.
7. Phone scans QR code.
8. Phone creates/loads phone device keypair.
9. Phone claims pairing challenge through relay.
10. CLI shows pending phone and asks for confirmation.
11. CLI confirms binding.
12. Relay records active binding.
13. Daemon records bound phone id.
14. Phone sends encrypted portrait terminal profile to daemon: current portrait cols/rows and font scale.
15. Relay forwards the encrypted profile update without storing terminal profile details.
16. Daemon decrypts and caches the latest phone terminal profile locally.
17. Phone stores machine profile.

## Security Design

Baseline:

- every device has a long-lived Ed25519 identity keypair
- private keys stay local
- daemon stores its identity key in the user's Nudge data directory with strict file permissions
- phone stores its identity key in Keychain
- relay stores public identity keys only
- every websocket authenticates with a relay-issued signed challenge
- binding is explicit and revocable
- relay revocation closes participant sockets with `binding_revoked`; daemon and iOS persist/surface revoked local state and stop reconnect loops
- relay enforces route authorization
- terminal/control payloads are end-to-end encrypted between phone and daemon
- terminal data is not logged

E2E envelope:

- phone and daemon establish an ephemeral X25519 session over the authenticated relay route
- each side signs the handshake transcript with its Ed25519 identity key
- derive directional message keys with HKDF-SHA256
- encrypt protobuf payload bytes with ChaCha20-Poly1305
- include monotonically increasing sequence numbers to reject replay
- relay sees route metadata, device ids, message type class, and ciphertext length, but not terminal/control contents

Preferred future hardening:

- key rotation
- device revocation list
- audit log for binding and approval actions
- push notification signing

## Terminal Lifecycle

Tab lifecycle:

```text
nudge starts -> locate socket -> spawn daemon if needed -> attach client
create tab -> spawn PTY -> running
client disconnect -> detach only
client reconnect -> replay scrollback/snapshot -> attached
process exits -> tab status exited
user closes tab -> kill PTY and remove tab
daemon restarts -> restore metadata, mark old PTYs needs_restart
```

The daemon should not destroy a tab because no clients are attached.

## Width Semantics

One PTY has one real size. Nudge is phone-first, but a tab can explicitly switch between two width modes:

- `phone`: daemon resizes PTY to the saved phone terminal profile.
- `computer`: daemon resizes PTY to the current CLI terminal size.

There is no custom width in MVP.

Phone control:

- Phone can always send input, commands, prompts, and approvals.
- In phone width, Claude/Codex layout is optimized for mobile.
- In computer width, phone renders the wider terminal with scale, horizontal scroll, and cursor-follow.

CLI control:

- CLI can toggle the selected tab between phone width and computer width.
- Suggested shortcut: `Ctrl-g w`.
- Status line should show `width: phone` or `width: computer`.
- If no phone terminal profile exists yet, CLI cannot switch to phone width and should show a clear message.

Phone profile updates:

- Binding records the initial phone terminal profile.
- Phone updates the profile on portrait font, safe-area, or viewport changes.
- Relay keeps the binding copy; daemon caches the latest profile locally for offline width switching.
- CLI can switch to phone width even if the phone is offline, using the latest saved profile.

Switching width sends a real PTY resize event. TUIs may redraw; this is expected and should be visible in status.

Implementation note from Zellij: PTY writes and PTY resize should go through a dedicated queue/path instead of being mixed directly into the read loop. This avoids deadlocks and gives the daemon a place to apply backpressure, coalesce resize events, and drop excessive pending writes safely.

## Agent Detection

Detection order:

1. Foreground process detection.
2. Visible screen text classification.
3. Raw output classification.
4. Future agent hooks.

Foreground process detection identifies `kind`.

Text classification identifies interaction state:

- `needs_approval`
- `waiting_for_input`
- `needs_attention`
- `idle`

This classification is probabilistic and should carry confidence.

Do not automatically approve actions based only on text detection.

## Adaptive Mobile Keyboard

Keyboard profile selection:

```text
if kind == claude:
  use Claude profile
else if kind == codex:
  use Codex profile
else:
  use shell profile

if state == needs_approval:
  add approval action row
if state == waiting_for_input:
  add prompt composer action row
```

Base keyboard:

- Ctrl-C
- Esc
- Tab
- Enter
- arrows
- paste
- clear
- modifier keys

Claude profile:

- continue
- approve
- reject
- yes
- no
- send prompt
- interrupt

Codex profile:

- approve
- deny
- continue
- send prompt
- interrupt

Shell profile:

- `ls`
- `cd`
- `git status`
- `clear`
- history

Approval actions should require deliberate taps and clear labeling.
