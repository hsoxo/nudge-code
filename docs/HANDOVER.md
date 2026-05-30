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

## Simulator Validation (2026-05-30)

Branch: `fix/bind-validation-quickwins`. Fix commit `c8b2f52` (pairing-code expiry detection, already-`active` binding reconfirm, free-tab notice scope).

Environment: iPhone 17 simulator, iOS 26.1, macOS host. Relay and daemon run locally on the host; the smoke uses an isolated daemon state/runtime dir and an ephemeral relay port `http://127.0.0.1:<port>` with hosted-mode hardening on (`NUDGE_RELAY_REQUIRE_E2E_PAYLOAD`, `NUDGE_RELAY_REQUIRE_WS_SIGNATURE`, `NUDGE_RELAY_REQUIRE_WS_CHALLENGE`, `NUDGE_RELAY_DISABLE_HTTP_MESSAGES`).

Whole-flow result: PASS. The CLI bind reached `binding active`, and the relay audit log recorded the full hardened path:

```text
device_registered x2  (daemon + phone)
binding_started -> binding_claimed -> binding_confirmed
socket_challenge_issued x2 -> socket_authorized x2   (signed-WS challenge handshake)
message_routed x11    (all ephemeral E2E payloads: session-state / output-replay / input / live-output)
```

Commands run (all green):

```sh
npm run smoke:ios-launch                                              # build+install+launch fixed app; no launch crash
scripts/smoke-ios-relay-claim.sh                                     # live hardened relay + daemon + simulator claim->session->input->output
xcodebuild test ... -only-testing:NudgeMobileTests/RelayClientTests  # 21 passed (incl. live integration claim/session/input/output)
xcodebuild test ... -only-testing:NudgeMobileTests/BindingClaimTests # 31 passed
cargo test -p nudge-daemon relay_control_tab_actions                 # 1 passed
cargo test -p nudge-cli                                              # 12 passed (incl. 3 new pairing-expiry tests)
```

Step 3 checklist coverage on the simulator:

- send shell command from composer: covered. Integration smoke sends `echo <marker>` over an E2E session and verifies live daemon output.
- width mode switch: covered (`appModelUpdatesWidthThroughOpenRelaySession`, `setWidthModeSendsRelayControlRequest`).
- rename / restart / close default tab: covered (`appModelCreatesRenamesRestartsAndClosesTabsThroughOneShotRelay`, daemon `relay_control_tab_actions_return_session_state`).
- create second tab shows the free-plan notice: covered (`appModelShowsNoticeWhenFreeTabLimitRejectsCreateTab`, plus `appModelKeepsActionFallbackNoticeWhenTabErrorIsNotFreeLimit` guarding the scoped-notice fix).
- background/foreground reconnect: covered (`appModelSuspendsRelaySessionWhenAppBackgrounds`, `appModelResumesRelaySessionWhenAppReturnsForeground`, `appModelReconnectsRelaySessionAfterDrop`).

Visual check: launched the installed app on the simulator and confirmed the native `Bind Computer` screen renders (Pair Computer + Phone Profile sections, default Rows 32 / Columns 48). `xcrun simctl openurl 'nudge://pair?...'` is recognized and routed to the app (iOS shows the `Open in "Nudge"?` scheme prompt).

Not exercised on the simulator (still needs the physical device or a UI-automation harness):

- Literal human tap-through of the live UI (tap `Claim And Wait`, type in the composer, open the tab menu, toggle width). No `idb`/XCUITest UI target is installed, and `simctl` cannot tap arbitrary SwiftUI controls. The same code paths are covered functionally by the integration smoke and the logic suites above.
- Local Network and Camera permission prompts. The simulator + `127.0.0.1` path does not raise the Local Network prompt, and the QR scanner was not opened. Verify both on the physical iPhone 13.

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

## Initial iOS Bind Screen

The iOS first screen now opens directly to `BindingView` when there are no bound machines. This avoids the earlier iPhone state where `NavigationSplitView` showed only an empty machine sidebar with a small QR toolbar button.

Current behavior:

- no machines: `NavigationStack { BindingView() }`
- one or more machines: `NavigationSplitView` with machine list and terminal/binding detail
- binding screen title: `Bind Computer`
- existing paste URL, scan QR, pending claim, and phone profile controls stay in `BindingView`

## Next Implementation Tasks

1. Run one manual iPhone 13 bind using a LAN relay URL or Cloudflare Tunnel URL.
2. Validate first-version controls on the physical phone.
3. Add physical-device notes after the first successful iPhone bind.

## Free-Plan Tab Limit Notice

The mobile app now has explicit feedback for free-plan tab-limit rejections.

Behavior:

- `AppModel` has `workspaceNoticeText`.
- failed tab actions set a visible workspace notice.
- daemon rejection messages containing the free tab-limit error are shown as `Free version is limited to one tab on this computer.`
- `TerminalWorkspaceView` shows this as a native `Tab Action Failed` alert.
- `clearWorkspaceNotice()` dismisses it.

Verification:

```sh
xcodebuild test \
  -project apps/mobile-ios/NudgeMobile.xcodeproj \
  -scheme NudgeMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  '-only-testing:NudgeMobileTests/BindingClaimTests'
```

Result: Swift Testing reported 30 tests passed in the "Binding claim flow" suite, including `appModelShowsNoticeWhenFreeTabLimitRejectsCreateTab`.

```sh
npm run smoke:ios-launch
```

Result: iOS simulator launch smoke passed.

`git diff --check` also passed before commit.

## First-Version Gap List

Highest priority for local-first handoff:

- Need real physical iPhone test on `10.10.10.xxx` LAN or Cloudflare Tunnel. (Simulator whole-flow validation is now done; see `Simulator Validation (2026-05-30)`.)
- Tab action UX under free entitlement is validated on the simulator via automated tests; still confirm the live tap-through on the physical phone:
  - rename default tab works (validated: `appModelCreatesRenamesRestartsAndClosesTabsThroughOneShotRelay`)
  - restart default tab works (validated: same test + daemon `relay_control_tab_actions_return_session_state`)
  - close only tab disabled in UI (close path validated in the same AppModel test; button-disabled state is a UI affordance to eyeball on device)
  - create second tab shows the `Tab Action Failed` notice under free plan (validated: `appModelShowsNoticeWhenFreeTabLimitRejectsCreateTab`)

Broader but not needed for immediate local-first validation:

- TestFlight packaging.
- Permanent hosted relay deployment.
- `nudgecode.dev` installer hosting.
- Hosted database/backups/ops runbook.
- Account/subscription implementation beyond current entitlement plumbing.

## Remaining Task Plan

### Step 1: Run Local Relay For iPhone

Goal: expose the development relay to the iPhone 13.

LAN path:

```sh
npm run relay:local
NUDGE_RELAY_URL=http://10.10.10.xxx:8787 npm run bind:local
```

Tunnel path:

```sh
npm run relay:local
cloudflared tunnel --url http://127.0.0.1:8787
NUDGE_RELAY_URL=https://example.trycloudflare.com npm run bind:local
```

Exit criteria:

- relay `/healthz` is reachable from the chosen URL
- CLI prints `app_pairing_url=nudge://pair?...`
- computer CLI is waiting for phone claim/confirmation

### Step 2: Bind On iPhone 13

Goal: prove the native app can bind to the real local daemon through the relay.

Manual flow:

1. Open Nudge on iPhone 13.
2. Scan QR code or paste `nudge://pair?...`.
3. Tap `Claim And Wait`.
4. Confirm the binding in the computer CLI.
5. Open the machine in the app.

Exit criteria:

- machine appears in the app
- binding becomes active
- terminal session opens without reconnect loop
- default tab output renders

### Step 3: Validate First-Version Controls

Goal: verify phone-first terminal controls against the free entitlement.

Checklist:

- send a shell command from the composer
- shortcut keyboard sends expected keys/prompts
- width mode can switch between phone and computer
- rename default tab works
- restart default tab works
- close only tab remains disabled
- new tab shows the free-plan tab-limit notice
- background/foreground app once and confirm reconnect resumes

Exit criteria:

- no app crash
- no daemon crash
- terminal remains usable after reconnect
- any failed action is visible to the user, not hidden in machine-list status text

### Step 4: Record Device Findings

Goal: update handover/local docs with real iPhone behavior.

Update:

- `docs/HANDOVER.md`
- `docs/local-first-run.md`
- optionally `apps/mobile-ios/README.md`

Record:

- iPhone model and iOS version
- relay URL style used: LAN or Cloudflare Tunnel
- whether Local Network permission appeared
- whether Camera permission appeared
- any ATS/network issue
- any terminal rendering or keyboard issue

Suggested commit:

```sh
git add docs/HANDOVER.md docs/local-first-run.md apps/mobile-ios/README.md
git commit -m "docs: record iphone local-first validation"
```

## Quick Status Estimate

Local-first first version is close but not finished.

What is already strong:

- Rust daemon/CLI session model.
- Relay hosted-mode security plumbing.
- Binding, signed websocket challenges, E2E envelopes.
- iOS bind/session/reconnect/input/output path in simulator tests.
- Local-first run scripts and docs.

What blocks a confident handoff to physical-device testing:

- Run one manual iPhone 13 bind using LAN or Cloudflare Tunnel. The simulator whole-flow path (bind -> active -> E2E session -> output -> input, plus tab actions, free-tab notice, and background/foreground reconnect) is validated on the fixed build as of 2026-05-30; the physical-device run is the remaining manual confirmation (including Local Network and Camera prompts).

Practical estimate from this point:

- One commit if physical-device testing reveals URL, ATS, local network permission, or QR/deep-link issues.
