# Nudge Product Plan

## Product Goal

Nudge is a remote shell workspace for people running coding agents such as Claude Code and Codex. It should feel like the tab/session part of Zellij, but without panes, layouts, plugins, or multiple sessions. Each computer has exactly one long-lived daemon session. That session contains ordered shell tabs. A computer-side CLI and a native phone app can attach, detach, reconnect, view status, and send input without killing the session.

The phone and computer must not need to be on the same network. A Node/TypeScript relay service is required.

## Current Product Decisions

- Computer side has no desktop GUI app.
- Computer side is a native Rust CLI plus daemon/server, installed by a native installer script such as `curl -fsSL https://nudgecode.dev/install.sh | bash`.
- Running `nudge` opens the interactive terminal client and attaches to the only session automatically.
- There is no `nudge tab new/list/attach` command surface for normal use.
- One computer has one daemon-owned session.
- One session has many tabs.
- There are no panes.
- Tab limits are entitlement limits, not a core architecture limit.
- CLI and phone do not share an active tab. Each client has its own selected tab.
- Phone can bind to multiple computers.
- For the first version, one computer binds to only one phone.
- Free version limit: one bound computer per phone account/device and one tab per computer session.
- Phone app is native-first, iOS first.
- iOS distribution is TestFlight-only first.
- iOS terminal rendering uses a native app shell with embedded WebView/xterm.js for MVP.
- iOS is portrait-only for MVP.
- Relay/server side is Node/TypeScript.
- Relay is hosted-service first.
- End-to-end encryption between phone and daemon is required in MVP.
- Protocol schemas are protobuf-first, generated into Rust, TypeScript, and Swift.
- CLI supports macOS and Linux.
- Daemon should never exit because all clients disconnected.
- Client disconnect means detach, like Zellij attach/detach.
- CLI rendering should follow the Zellij model: daemon owns the terminal grid/render state; CLI is a thin raw-mode renderer/input client.
- Phone can view tabs, send raw terminal input, send commands, and send agent prompts.
- Phone is first-class control surface and can always control a tab.
- Each tab has either phone width or computer width. No custom width in MVP.
- During binding, the daemon records the phone portrait terminal profile so the CLI can switch tabs to phone width even when the phone is offline.
- Mobile keyboard should adapt to the detected foreground app: shell, Claude, Codex, etc.
- Claude/Codex waiting or approval states can be detected from terminal text, but this must be treated as heuristic.

## Rust Computer Core Strategy

The computer-side core should be Rust from the start.

Reasons:

- Nudge's hardest part is terminal multiplexing, not ordinary web service code.
- Rust gives better direct control over PTYs, process groups, signals, nonblocking file descriptors, resize behavior, and backpressure.
- Zellij proves this shape works well for long-lived attach/detach terminal sessions.
- A native binary avoids `node-pty` installation and native module compatibility issues.
- The daemon and interactive CLI can share a single protocol, terminal grid, and low-level terminal handling model.

The user-facing install path can still be simple:

```text
curl -fsSL https://nudgecode.dev/install.sh | bash
nudge
```

The installer should:

- detect macOS/Linux and CPU architecture
- download a prebuilt signed release artifact
- verify checksum/signature before installing
- install `nudge` into `~/.local/bin`, `/usr/local/bin`, or another explicit target
- offer service setup for launchd/systemd when needed
- never require Node on the user's computer for the terminal app

Node/TypeScript remains the right choice for the hosted relay service.

## How Zellij Works And What Nudge Should Borrow

Zellij's normal flow is client/server:

1. The `zellij` command decides whether to create or attach to a session.
2. If needed, it spawns the same binary in server mode.
3. The interactive client connects to the server over a local Unix socket.
4. The client enters raw mode and alternate screen, then forwards keyboard, mouse, paste, and terminal resize events.
5. The server owns the session, panes/tabs, PTYs, terminal buffers, and render state.
6. The server reads PTY bytes, parses ANSI/VT sequences into a terminal grid, and sends rendered output back to clients.
7. Client exit sends a detach/client-exited message; the server and PTYs keep running.

Useful implementation ideas for Nudge:

- local client/server split, even on the same computer
- Unix socket local IPC with private permissions instead of public TCP
- daemon owns all tabs, PTYs, scrollback, snapshots, process detection, and relay connection
- CLI is an attachable renderer/input client, not the session owner or terminal state owner
- one command, `nudge`, starts or locates the daemon and attaches to the only session
- dedicated PTY write/resize path to avoid blocking reads and to handle backpressure
- VT parser plus terminal grid on the daemon for reconnect and mobile snapshots
- local CLI render frames can be produced from the daemon grid, similar to Zellij's server-to-client render message
- explicit attach, resize, input, render, and client-exited protocol messages
- Nudge Rust core shape: native `openpty`/`login_tty`, nonblocking FD reads/writes, thread/task channels, and a screen/grid model similar to Zellij but without panes, plugins, layouts, or multiple sessions

## Why Not Build Directly On Zellij

Zellij is the right inspiration, but not the right first codebase to strip down.

Useful Zellij ideas:

- daemon/client separation
- attach/detach mental model
- long-lived terminal workspace
- tab actions and tab metadata
- mature terminal process thinking
- interaction style: one command attaches to the only session, with a tab bar, prefix-key actions, and mouse tab selection

Reasons not to start from Zellij:

- panes are a central abstraction
- sessions, layouts, plugins, modes, and keybindings are deeply integrated
- the protocol is larger than Nudge needs
- mobile-first interaction would still need major new work

## What To Borrow From Dinotty

Dinotty is complex, but still useful as a reference.

Useful Dinotty ideas:

- websocket terminal transport
- server-side virtual terminal snapshot/reconnect
- mobile shortcut keyboard patterns
- tab sync concepts
- xterm.js local terminal rendering patterns for future web/dev tools

Pieces to remove or defer:

- Tauri desktop app
- file browser
- web preview
- plugins
- multi-pane assumptions
- local-only binding
- detached session cleanup

## Main Components

1. `nudge` daemon/server mode
   - Rust daemon/server mode running on the computer, launched by the `nudge` binary.
   - Owns PTYs, tabs, screen snapshots, agent detection, and durable session metadata.
   - Maintains an outbound connection to the relay.
   - Exposes private local Unix socket IPC for the CLI on macOS/Linux.
   - Should be installed as part of the native `nudge` binary.

2. `nudge` CLI
   - Computer-side Rust command-line tool.
   - Default behavior: start or locate daemon, then attach to the only session.
   - Provides an interactive terminal UI similar to Zellij.
   - Creates, closes, renames, and switches tabs inside the interactive client.
   - Supports keyboard shortcuts and mouse tab selection.
   - Shows relay status and phone binding flow.
   - Prints pairing QR code or pairing URL/code in the terminal.
   - Confirms or revokes phone binding.
   - Exiting the CLI detaches only; it must not stop daemon tabs.

3. `nudge-mobile`
   - Native mobile app.
   - iOS first.
   - Native app shell with embedded WebView/xterm.js terminal renderer for MVP.
   - Stores multiple bound computers.
   - Connects through relay.
   - Shows tab status, terminal snapshots, and agent state.
   - Provides adaptive shortcut keyboards for shell, Claude, Codex, and approval/waiting states.

4. `nudge-relay`
   - Node/TypeScript server.
   - Required for binding and remote routing.
   - Hosted relay is the first product target.
   - Accepts outbound daemon and phone connections.
   - Authenticates devices.
   - Routes encrypted messages between bound phone and computer.
   - Stores device and binding metadata.
   - Should not store terminal output by default.

## MVP Scope

In scope:

- Native Rust daemon and CLI for macOS and Linux.
- Native installer script for prebuilt `nudge` binaries.
- Native iOS app.
- Portrait-only iPhone UI for MVP.
- Node/TypeScript relay.
- Hosted relay first.
- End-to-end encrypted terminal/control streams between phone and daemon.
- CLI support for macOS and Linux.
- Relay-mediated binding.
- One phone bound per computer.
- Multiple computers per phone.
- Free entitlement enforcement: one bound computer and one tab. The product architecture still supports multiple computers and multiple tabs for future paid tiers.
- One daemon session per computer.
- Ordered shell tabs.
- Create, rename, close, and select tabs inside the interactive CLI and mobile app.
- Independent selected tab per client.
- Terminal attach/detach/reconnect.
- Screen snapshot restore.
- Phone-first terminal width model.
- Phone portrait terminal profile captured during binding and updated on phone viewport/font changes.
- Per-tab width mode: phone or computer.
- CLI can toggle a tab between phone width and computer width.
- Phone can control in both width modes.
- In computer width, phone adapts with scale, horizontal scroll, and cursor-follow.
- Phone command and prompt sender.
- Claude/Codex process detection.
- Basic text heuristics for `needs_approval` and `waiting_for_input`.
- Agent-aware mobile keyboards.
- Protobuf protocol generation for Rust, TypeScript, and Swift.

Out of scope for MVP:

- desktop GUI app
- panes/splits
- multiple sessions
- cloud terminal storage
- collaborative multi-user
- file browser
- web preview
- plugins
- full Zellij keybinding/mode system
- guaranteed process resurrection after daemon restart
- automatic approval of dangerous prompts

## Key Risks

- Native binary distribution, signing, and update flow need careful implementation.
- `curl | bash` is convenient but security-sensitive; the installer must verify release artifacts and be transparent about paths/actions.
- Foreground process detection is platform-specific.
- Terminal emulation correctness is hard; the daemon needs fixtures for resize, scrollback, alternate screen, cursor, and common TUIs.
- iOS xterm.js rendering can diverge from daemon grid state; daemon grid remains authoritative for snapshots and detection.
- Text-based Claude/Codex state detection can break when those tools change UI text.
- Width switching will trigger terminal resize/reflow in Claude/Codex and other TUIs.
- Phone rendering in computer width needs good scale, pan, and cursor-follow behavior.
- Relay security needs careful device identity and authorization.
- Native mobile background behavior limits persistent connections.
- Accidentally approving prompts from a phone is dangerous; approval actions need clear friction.

## Success Criteria

The first usable product succeeds when:

- `curl -fsSL https://nudgecode.dev/install.sh | bash` gives the user a working `nudge` CLI.
- Running `nudge` starts or locates the daemon and attaches to the only session.
- The daemon can keep tabs alive after all clients disconnect.
- Free version blocks creating a second tab.
- The CLI can attach back to the same tabs.
- A phone can bind through relay from another network.
- Free version blocks binding a second computer to the same phone account/device.
- A phone can view every tab's current state.
- A phone can select a tab and send input.
- Daemon records phone width during binding, and CLI can switch a tab to phone width.
- Phone can still control a tab while it is using computer width.
- A phone can send a command/prompt to a Claude or Codex tab.
- Claude/Codex tabs show different mobile shortcut keyboards.
- Basic approval/waiting states are surfaced in the tab list.

## Open Questions

- Hosted relay operations: deployment platform is undecided. Current candidates are AWS EC2 or a managed/SaaS hosting service. Abuse/rate-limit policy and self-hosting story are later decisions.

## Deliverables

- [ARCHITECTURE.md](./ARCHITECTURE.md)
- [IMPLEMENTATION_PLAN.md](./IMPLEMENTATION_PLAN.md)
