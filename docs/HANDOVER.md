# Nudge Handover

Date: 2026-05-29

Repo: `/Users/hhe/Projects/code-mule`

Current target: local-first first version. TestFlight, permanent hosted relay deployment, and `nudgecode.dev` install hosting are intentionally out of scope for the next validation pass.

## Product Shape

- Computer side: Rust `nudge` CLI/daemon.
- Relay side: Node/TypeScript, npm workspaces.
- Phone side: native iOS app.
- Current local path: run relay on the development machine, bind the Rust daemon/CLI to the iOS simulator, physical iPhone on the same LAN, or a temporary Cloudflare Tunnel URL.
- Canonical relay URL env: `NUDGE_RELAY_URL`.
- Physical iPhone URL must not be `127.0.0.1`; use the Mac LAN URL such as `http://10.10.10.xxx:8787` or a Cloudflare Tunnel URL.
- iOS app target: iOS 17.0+, portrait-first. iPhone 13 is compatible when running iOS 17.0 or newer.

## Latest Committed Baseline

Latest committed baseline before this handover slice:

```text
073461a phase 6: add ios launch smoke
```

Recent relevant commits before that:

```text
de2c3c4 phase 6: use relay url env for local bind
6cc4130 phase 6: support local first run
fd251ed phase 9: add deployment handoff preflight
edf96eb phase 6: add mobile pairing deep links
471701f phase 6: handle mobile app lifecycle reconnect
702d8cb phase 6: revoke mobile bindings
17a6fdc phase 6: forward mobile terminal raw input
```

## Current Tab-Action Slice

This handover includes the mobile tab-action slice.

Changed files in the slice:

```text
apps/mobile-ios/NudgeMobile/Sources/NudgeMobile/AppModel.swift
apps/mobile-ios/NudgeMobile/Sources/NudgeMobile/RelayClient.swift
apps/mobile-ios/NudgeMobile/Sources/NudgeMobile/TerminalWorkspaceView.swift
apps/mobile-ios/NudgeMobile/Tests/NudgeMobileTests/BindingClaimTests.swift
apps/mobile-ios/NudgeMobile/Tests/NudgeMobileTests/RelayClientTests.swift
crates/nudge-daemon/src/lib.rs
```

What the slice adds:

- Rust daemon relay control support for:
  - `create_tab`
  - `rename_tab`
  - `close_tab`
  - `restart_tab`
- iOS `RelayClient` one-shot methods for those tab actions.
- iOS AppModel methods:
  - `createRemoteTab`
  - `renameSelectedTab`
  - `closeSelectedTab`
  - `restartSelectedTab`
- iOS toolbar tab menu with New, Rename, Restart, and Close.
- Tests for daemon tab-action control responses.
- Tests for iOS RelayClient tab-action wire payloads.
- Tests for AppModel applying tab-action session state.

Design note:

- AppModel tab actions currently use one-shot relay control requests even when the long-lived relay session is open. This is intentional: free plan can reject `create_tab` because the first version free limit is one computer and one tab. One-shot control gives a direct accepted/rejected result and avoids turning the long-lived sync loop into a generic reconnect on expected action rejection.

## Verification Already Run

These passed during this handoff session:

```sh
xcodebuild test \
  -project apps/mobile-ios/NudgeMobile.xcodeproj \
  -scheme NudgeMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  '-only-testing:NudgeMobileTests/RelayClientTests'
```

Result: Swift Testing reported 21 tests passed in the "Relay client" suite.

```sh
xcodebuild test \
  -project apps/mobile-ios/NudgeMobile.xcodeproj \
  -scheme NudgeMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  '-only-testing:NudgeMobileTests/BindingClaimTests'
```

Result: Swift Testing reported 29 tests passed in the "Binding claim flow" suite.

The earlier crash report pointed at `BindingClaimTests.appModelReconnectsRelaySessionAfterDrop`; that test passed in the latest run.

Additional checks run after the latest WIP:

```sh
cargo test -p nudge-daemon relay_control_tab_actions_return_session_state
npm run check:local-first
npm run smoke:ios-launch
scripts/smoke-ios-relay-claim.sh
```

Results:

- Rust focused daemon test passed: 1 passed.
- Local-first readiness check passed.
- iOS simulator launch smoke passed.
- Live local relay + real daemon + simulator claim/session/input smoke passed with a temporary local relay URL.

Final whitespace check also passed:

```sh
git diff --check
```

## Local-First Runbook

From repo root:

```sh
npm install
npm run build
cargo build -p nudge-cli
```

Start local relay:

```sh
npm run relay:local
```

Simulator path:

```sh
NUDGE_RELAY_URL=http://127.0.0.1:8787 npm run bind:local
```

Physical iPhone on same LAN:

```sh
NUDGE_RELAY_URL=http://10.10.10.xxx:8787 npm run bind:local
```

Cloudflare Tunnel path:

```sh
cloudflared tunnel --url http://127.0.0.1:8787
NUDGE_RELAY_URL=https://example.trycloudflare.com npm run bind:local
```

Then open Nudge on iOS, scan or paste the printed `nudge://pair?...` app pairing URL, tap Claim And Wait, and confirm the bind in the computer CLI.

Reference doc:

```text
docs/local-first-run.md
```

## Important Current UI Observation

The current iOS first screen can look almost empty when there are no bound machines. That state is not a data bug: it means there is no selected/bound computer yet. However, it is not acceptable first-version UX.

Recommended next UI task:

- Add a proper empty state in the iOS root/detail view:
  - show "Bind Computer" as the primary action
  - expose Scan QR Code and paste pairing URL flow
  - show a short local-first hint that physical phone needs the Mac LAN URL or tunnel URL
  - avoid leaving only a title and tiny QR toolbar button

The existing `BindingView` already has the paste URL, scan QR, pending claim, and phone profile controls. The work is mostly navigation/empty-state presentation, not a new binding backend.

## Next Implementation Tasks

1. Do the empty-state UI task as a separate commit.

Suggested commit:

```text
phase 6: add mobile bind empty state
```

## First-Version Gap List

Highest priority for local-first handoff:

- iOS empty state is too blank before binding.
- Need real physical iPhone test on `10.10.10.xxx` LAN or Cloudflare Tunnel.
- Need decide how to surface free-plan tab limit in UI. Current `New Tab` can be rejected by daemon; UI only sets machine status text to "Unable to create tab".
- Need verify tab action UX under free entitlement:
  - rename default tab should work
  - restart default tab should work
  - close only tab should be disabled in UI
  - create second tab should fail gracefully under free plan

Broader but not needed for immediate local-first validation:

- TestFlight packaging.
- Permanent hosted relay deployment.
- `nudgecode.dev` installer hosting.
- Hosted database/backups/ops runbook.
- Account/subscription implementation beyond current entitlement plumbing.

## Quick Status Estimate

Local-first first version is close but not finished.

What is already strong:

- Rust daemon/CLI session model.
- Relay hosted-mode security plumbing.
- Binding, signed websocket challenges, E2E envelopes.
- iOS bind/session/reconnect/input/output path in simulator tests.
- Local-first run scripts and docs.

What blocks a confident handoff to physical-device testing:

- Improve the blank initial iOS state.
- Run one manual iPhone 13 bind using LAN or Cloudflare Tunnel.

Practical estimate from this point:

- One commit to improve the iOS empty state.
- One commit if physical-device testing reveals URL, ATS, local network permission, or QR/deep-link issues.
