# Terminal Sync Roadmap

- **Date:** 2026-05-30
- **Status:** Phases 0–2 shipped + reviewed CLEAN; Phase 3 (3.1/3.2) shipped; Phase 4 (4.2 buffers, 4.3 focused-tab) shipped, 4.1 binary-frames **blocked** (relay not in this repo); Phase 5 spike done (2026-05-31)
- **Progress:**
  - Phase 0 complete — 0.1 overflow→snapshot `0bbb5ae`, 0.3 adaptive flush `f3c8f1f`, 0.2 placeholder clear `8367704`.
  - Phase 1 complete (absolute-offset stream contract) — 1.2a delta offset `ff55d06`, 1.2b snapshot offset `240ae94`, 1.3 iOS gap detection `b7a7439`, 1.4 retire tail `9503aef`.
  - Phase 2 complete (full-state snapshots) — 2.1 `state_frame()` `d209115`, 2.2/2.3 daemon+iOS wiring `cc0c286`. Scrollback (M1) deferred: `vt100 0.16` exposes modes but not scrollback rows for the frame. **Pending on-device verification** (daemon/relay stack down this session) — the `state_frame()` round-trip is vt100-tested, not yet xterm.js-tested.
  - Phase 3 (3.1/3.2) shipped — post-resize re-baseline (phone-initiated) `95af572`; reflow (3.3) deferred. On-device visual verification pending.
  - Phase 4 — 4.2 buffer efficiency (Data-backed replay buffer) `563925b`; 4.3 focused-tab priority `cbd6cf0`. **4.1 binary WS frames blocked**: the relay is a hosted service not in this repo (`docs/relay-hosted.md`) and can't be verified to route binary frames; the daemon currently treats inbound binary as UTF-8 text — shipping a binary wire format blind risks breaking the connection. Needs relay-side verification + on-device testing (stack down). JS-side ring buffer (part of 4.2) also deferred.
  - Phase 5 spike done — recommends daemon render-frames (a); `docs/20260531-phase5-render-model-spike.md` `f81a95a`. Implementation gated on the 5a.0 prototype's on-device CPU measurement.
  - Code review (critic + Codex) of Phases 3–5 → **both CLEAN** after fixes (2 review rounds). Round 1 caught a HIGH the mock-based unit test missed: `set_focused_tab` had been sent correlated as `.sessionState`, so the daemon's `{accepted:true}` ack decoded to an empty session state and **wiped all tabs on every tab switch** — fixed (fire-and-forget ack) + wire-level regression test; also fixed an idle-refocus staleness regression + two perf/ordering minors. A follow-up round on 3–5 caught a focus-lifecycle black-hole (**closing the focused tab** left `focused_tab` dangling → all surviving tabs background-filtered → no live output) — fixed `4128b0b` (clear focus on close + reset on reconnect, with a test); and corrected the Phase 5 spike's 5a.0 prototype (offset-axis: diff frames + snapshots must share a cumulative sent-byte axis, else full-frame thrash invalidates the measurement) `f8ec6b5`/`5492ccb`.
  - Code review (critic + Codex) of Phases 0–2, **4 rounds → both CLEAN** — C1 stuck-awaiting freeze `7894c48`; state_frame cursor + canonical modes `cdb505e`; flush clamp `5e18d46`; M-1 lost-reply self-heal `423e0e5`; M-2 redundant `cursor_state_formatted` removed `74df73c`; minors (`droppingFirst` clamp, `terminal_snapshot` comment) `c193948`; watchdog for lost-reply-on-silent-stream `0d0af27`. Accepted/deferred: drop-deltas flicker, per-delta base64 re-decode (Phase 4.2), origin-mode/scroll-region/charset (vt100 limitation), on-device/xterm.js verification.
- **Scope:** computer (daemon) ↔ phone (iOS `xterm.js`) terminal synchronization — latency, accuracy ("不出混乱"), robustness, resize/reflow, efficiency.
- **Inputs:** independent reviews by Claude and Codex (Codex confirmed all of Claude's findings and added the deeper correctness items). Findings IDs below are the merged set.

---

## 1. Current architecture

```
PTY (shell) ──bytes──▶ daemon vt100 grid (nudge-terminal)
                         │                       │
                         │ broadcast(TerminalChange{tab_id, bytes})
                         ▼
              relay loop (nudge-daemon/src/lib.rs ~2585-2663)
                 • pending_terminal_outputs: BTreeMap<tab_id, Vec<u8>>
                 • flush every 100ms  → send delta (raw bytes, base64-in-JSON)
                 • on overflow >64KB  → drain head, still send a delta
                 • on broadcast Lagged→ send a snapshot
                         │
                    relay (WS, ephemeral) ──▶ iOS RelaySession.receiveEvent
                         │
                 AppModel.applyTerminalOutput / applyTerminalSnapshot
                 • live delta: write to xterm + append to 64KB replay buffer
                 • snapshot:   reset xterm + replay formatted dump
                         │
                  TerminalWebView (WKWebView) + index.html
                 • setSnapshot / setReplayOutputBase64 / writeOutputBase64
```

Two **resync** mechanisms exist today, both unsound:

1. **Visible-cell snapshot** — `contents_formatted()` of the *visible* screen only (`nudge-terminal/src/lib.rs:63`). No scrollback, no terminal modes (alt-screen, cursor-keys, bracketed-paste), no charset.
2. **Raw byte-tail replay** — `output_tail(max_bytes)` (`nudge-pty`/`nudge-daemon`), the primary subscribe path (`AppModel.swift:723`), which starts at an **arbitrary byte offset** and is replayed into a freshly-reset xterm as if it were complete state.

Key constants: flush `100ms`, pending cap `64KB` (head-dropped), grid `scrollback = 0`, replay buffer `64KB` on both iOS (`maxReplayOutputBytes`) and JS.

---

## 2. Problem summary (merged findings)

**Root cause:** the stream has *no per-tab contract* (no epoch/offset), and "resync" is either visible-only or a raw mid-stream tail. Bytes are truncated at several points and can be cut mid-escape-sequence. That produces 混乱 (garbling/divergence) on bursts, packet loss, reconnect, resize, and alt-screen transitions. Latency is a separate, simpler problem (the fixed 100ms flush).

| ID | Sev | Issue | Where |
|----|-----|-------|-------|
| **R1** | HIGH | Unsafe resync: subscribe/reconnect replays a raw byte **tail** (arbitrary start) as if it were full state (✅ fixed Phase 1.4 `9503aef`) | `AppModel.swift:723`, `index.html:257` |
| **R2** | HIGH | Truncation cuts mid-sequence: overflow drain / PTY tail cap / replay trims can split UTF-8/CSI/OSC/SGR/alt-screen | `lib.rs:2601`, `nudge-pty:167`, `AppModel.swift:892`, `index.html:244` |
| **R3** | HIGH | Snapshot has no mode state: visible cells only; no alt-screen/modes/charset → post-reset deltas misread (✅ fixed Phase 2 `state_frame()` `d209115`/`cc0c286`) | `nudge-terminal:63`, `index.html:257` |
| **R4** | HIGH | Snapshot↔live race: independent counters (`replayOutputSequence` vs `outputSequence`), no shared offset → an old snapshot can clobber newer output (✅ fixed Phase 1: absolute offset, grid-lock-coherent, `240ae94`/`b7a7439`) | `AppModel.swift:818/836`, `TerminalWorkspaceView.swift:490` |
| **R5** | HIGH | No gap detection: deltas carry only `tabId`+`bytes`; relay/WS loss is invisible (✅ fixed Phase 1.3 `b7a7439`) | `lib.rs:3206` |
| **R6** | HIGH | Burst overflow sends a partial delta instead of a snapshot (✅ fixed Phase 0.1 `0bbb5ae`) | `lib.rs:2599-2646` |
| **P1** | HIGH | Fixed 100ms flush = local-echo lag (✅ fixed Phase 0.3 `f3c8f1f`) | `lib.rs:2586` |
| **M1** | MED | Grid `scrollback=0`; resyncs collapse history | `nudge-terminal:36` |
| **M2** | MED | Resize: no reflow + no post-resize snapshot → stale bytes at new geometry (✅ post-resize re-baseline Phase 3.1 `95af572`; scrollback reflow 3.3 deferred) | `nudge-terminal:49`, `lib.rs:2074` |
| **M3** | MED | Daemon `vt100` vs phone `xterm.js` are two divergent emulators | `nudge-terminal:40`, `index.html:66` |
| **M4** | MED | Background (non-focused) tabs flush at focused-tab cadence (✅ fixed Phase 4.3 `cbd6cf0`: focused-tab hint; background tabs skipped, re-baseline on refocus) | `lib.rs:2644` |
| **L1** | LOW | base64-in-JSON-in-WS, doubled under E2E | `lib.rs:3209`, `e2e.rs:184` |
| **L2** | LOW | iOS re-base64 of 64KB/delta (O(n²)); JS per-byte buffers (✅ iOS Data-backed buffer Phase 4.2 `563925b`; JS ring buffer deferred) | `AppModel.swift:831`, `index.html:238` |
| **L3** | LOW | Placeholder text persists on the tail-replay path (✅ fixed `8367704`) | `AppModel.swift:825` |

---

## 3. Target model & design principles

1. **Per-tab stream contract.** Every tab has a single monotonic **absolute byte offset** owned by the daemon's grid (`total_bytes`, incremented in `process()`). Deltas are `{offset, bytes}`; snapshots declare the `offset` they represent, read **atomically with the grid contents under the grid lock**. The phone tracks the next expected offset and trims/drops anything it already has. *No epoch:* an absolute offset is monotonic per tab and lets the phone dedupe snapshot↔delta overlap arithmetically (`delta.offset < nextOffset` ⇒ already have it), which a per-epoch *relative* offset cannot — it's the only representation that closes the R4 micro-race, because the offset shares one axis with the snapshot.
2. **Truncation/gap ⇒ snapshot, never a partial delta.** Any time the daemon cannot send a contiguous byte run (overflow, broadcast lag, resize, alt-screen change) it bumps the epoch and sends a complete state frame.
3. **Snapshots are complete, restorable state** (screen + cursor + SGR + modes + alt-screen + bounded scrollback) — not visible cells, not a raw tail.
4. **Idempotent, ordered apply.** The phone applies a delta only if `offset == nextOffset`; an earlier-offset delta is trimmed/dropped (already applied), a later-offset delta is a gap → request a snapshot. A snapshot resets the baseline to its `offset` **unconditionally** (restart and daemon-restart reset the byte axis, so adoption must not be gated on `offset >= nextOffset`).
5. **Latency is adaptive.** Echo flushes immediately when idle; coalescing only kicks in under sustained load.
6. **One authoritative state model** (long-term): eliminate daemon-vs-phone emulator divergence.

---

## 4. Iteration plan

Sequenced **correctness → latency → efficiency**, with the cheap high-value wins pulled into Phase 0. Each phase ships and verifies independently.

### Phase 0 — Quick wins (effort: S, ~1 day, no protocol change)

**Goal:** stop the most common garbling and the worst typing lag with localized changes.
**Findings:** R6, R2 (daemon side), L3, P1.

**0.1 Overflow → snapshot (R6, R2-daemon)** — `nudge-daemon/src/lib.rs` relay loop (~2585-2663).
- Add a per-tab dirty set alongside the pending map:
  ```rust
  let mut pending_terminal_outputs: BTreeMap<String, Vec<u8>> = BTreeMap::new();
  let mut snapshot_required: HashSet<String> = HashSet::new();
  ```
- On `terminal_changes.recv()` overflow (currently `output.drain(..overflow)` at ~2599-2602): **clear** the buffer and mark the tab instead of draining the head:
  ```rust
  if output.len() > 64 * 1024 {
      output.clear();
      snapshot_required.insert(change.tab_id.clone());
  }
  ```
- On flush (~2643-2662): for the union of `outputs.keys()` and `snapshot_required`, send a snapshot when the tab is in `snapshot_required` (or `data.is_empty()`), else a delta; drain `snapshot_required` as you go. Reuse `live_terminal_snapshot_payload`.
- On `Lagged` (~2604) also insert into `snapshot_required` (it already forces an empty entry → snapshot; make it explicit).

**0.2 Clear placeholder on any output (L3)** — `AppModel.swift` `applyTerminalOutput` (~823-838): set `tab.previewText = ""` in **both** the `isReplay` and live branches (today only the formatted-snapshot path clears it).

**0.3 Adaptive flush (P1)** — `nudge-daemon/src/lib.rs:2586`.
- Replace the single 100ms tick with a fast floor + immediate-on-idle:
  ```rust
  let min_interval = Duration::from_millis(env_or(16)); // ~60fps burst floor
  let mut flush_timer = interval(min_interval);
  flush_timer.set_missed_tick_behavior(MissedTickBehavior::Skip);
  let mut last_flush = Instant::now()
      .checked_sub(min_interval).unwrap_or_else(Instant::now);
  ```
  In the `terminal_changes.recv()` arm, after appending: if `last_flush.elapsed() >= min_interval` and pending is non-empty, **flush now** (idle keystroke → ~0ms). Otherwise the `flush_timer` tick coalesces the burst. Set `last_flush = Instant::now()` on every flush.
- Keep 0.1 so bursts become snapshots, not 64KB deltas at 60fps.
- Make `min_interval` an env knob (`NUDGE_TERMINAL_FLUSH_MS`) for tuning.

**Tests / verify**
- Daemon unit test: feed >64KB in one window → assert a snapshot payload (not a delta) is produced for that tab; `Lagged` → snapshot.
- Manual on-device: `yes`/`cat bigfile` stay coherent; typing echo feels instant (measure round-trip before/after).

**Risk:** low. 0.3 timing is best validated on-device; gate `min_interval` behind an env var.

---

### Phase 1 — Stream contract + safe resync (effort: M–L) — *the backbone*

**Goal:** give every tab a single monotonic **absolute byte offset** so loss/reorder is detectable and resync is a real snapshot (not a raw tail). Validated by an architecture review: the offset must be the *grid's* byte position, captured atomically with the snapshot under the grid lock — that is what closes the R4 snapshot↔live race with **no residual window**. (A relative/epoch offset cannot: a chunk that enters the grid just after a snapshot is taken gets a fresh epoch, and the phone can't tell it overlaps the snapshot → double-render. With one absolute axis, overlap is detectable arithmetically.)
**Findings:** R1, R4, R5, R2 (general).

**1.2a Grid byte counter + delta offset (`nudge-terminal`, `nudge-daemon`)**
- `TerminalGrid`: add `total_bytes: u64`; change `process(&mut self, bytes) -> u64` to return the **start** offset, then advance `total_bytes`. Keep `total_bytes` across `resize` (resize re-renders geometry; it does not discontinue the byte axis).
- PTY callback (`lib.rs:~2493`): stamp the offset **inside** the grid-lock guard — `let offset = grid.lock().process(bytes);` then `terminal_changes.send(TerminalChange { offset, data })`. Sending after unlock is fine; the offset is already pinned to the grid position. This atomicity is the linchpin.
- `TerminalChange`: add `offset: u64`.
- Relay loop: `pending` becomes `(first_offset, Vec<u8>)` per tab. `accumulate_terminal_change` records `first_offset` when the entry is (re)created empty and **asserts contiguity** on each append (`change.offset == first_offset + buf.len()`); a mismatch (impossible absent `Lagged`, but cheap) → `snapshot_required` + reset. Delta JSON (`terminal_output_json`) gains `offset`.

**1.2b Snapshot offset + re-baseline (`nudge-daemon`)**
- `terminal_snapshot` returns the grid's `total_bytes` as the snapshot `offset`, read **under the same grid-lock acquisition** as `contents`/`formatted`. Snapshot JSON (`terminal_snapshot_json`) gains `offset`.
- `Lagged`/overflow already route through `snapshot_required` (Phase 0.1) and re-baseline (the snapshot offset is the new high-water mark). The solicited `requestTerminalSnapshot` (`handle_relay_control_request`) is **automatically coherent** — it reads the same counter under the grid lock — so it stays a synchronous reply (no deferred-action seam, no `refreshTabSnapshot` change).
- *Invariant:* every tab-id stream opens with a snapshot (guaranteed by `tab_requires_snapshot` returning true on an empty buffer). This protects new/recycled tab ids from a small-offset delta being trimmed as a false duplicate.

**1.3 iOS gap detection (`RelayClient.swift` decode, `AppModel.swift` apply)**
- Decode optional `offset` on delta + snapshot (absent ⇒ legacy daemon ⇒ apply-as-before, no gap detection).
- Track per-tab `nextOffset`. On **delta**: `offset == nextOffset` → apply, `nextOffset += len`; `offset < nextOffset` → trim the overlap (drop if fully behind); `offset > nextOffset` → gap → **request a snapshot**, ignore deltas until it arrives. On **snapshot**: adopt `nextOffset = offset` **unconditionally**, reset render, discard buffered deltas with `offset < snapshot.offset`. (Keep the WebView `replayOutputSequence`/`outputSequence` as a render-dedupe detail driven by the new logic.)

**1.4 Retire tail-as-state (R1)** — `applyRelaySessionEvent` `.sessionState` (`AppModel.swift:712-724`): request a **snapshot** per tab (not `requestTerminalOutput`/raw tail) for the initial state. `refreshTabSnapshot` stays a synchronous `fetchTerminalSnapshot` (now trivially coherent). Keep the raw tail only as optional scrollback *below* the snapshot (Phase 2), never as the primary reconstruction.

**Tests / verify**
- `nudge-terminal`: `process` returns contiguous start offsets; `total_bytes` survives `resize`.
- Daemon: offsets contiguous across deltas; snapshot carries the grid offset; **the micro-window test** — a chunk that enters the grid between the prior `recv` and the snapshot read is trimmed by offset on the phone, not double-applied (the test the epoch model cannot pass); `Lagged`/overflow re-baseline.
- iOS: gap → snapshot request; earlier-offset delta trimmed; snapshot adopted unconditionally (restart/daemon-restart); in-order apply.
- Integration (relay or mock transport): drop/reorder/dup deltas → phone self-heals.

**Risk:** medium — touches `nudge-terminal` + `TerminalChange` + both ends, but removes epoch/deferred-action/drain. Fields additive; gap detection degrades gracefully when the daemon omits `offset`.

---

### Phase 2 — Complete state frames (effort: M)

**Goal:** snapshots restore *full* terminal state so post-resync deltas are interpreted correctly.
**Findings:** R3, M1, and the alt-screen boundary.

**2.1 `nudge-terminal` — `state_frame()`** (new) producing bytes that, written into a freshly-reset xterm, reconstruct: reset → mode-setters (alt-screen `?1049h`, application cursor `?1h`, bracketed paste `?2004h`, mouse modes, charset) → SGR → screen contents (`contents_formatted`) → cursor position → cursor visibility.
- **Spike done (✅ 2026-05-30):** `vt100 0.16.2` `Screen` exposes **all** needed modes directly — `alternate_screen()`, `application_cursor()`, `application_keypad()`, `bracketed_paste()`, `hide_cursor()`, `mouse_protocol_mode() -> MouseProtocolMode`, `mouse_protocol_encoding() -> MouseProtocolEncoding`. No stream-sniffing fallback required; `state_frame()` can read these accessors directly.
- Bounded **scrollback** (M1): construct `vt100::Parser::new(rows, cols, N)` (e.g. 1000–2000) and include the last N rows in the state frame if vt100 exposes scrollback rows; otherwise document the cap and keep scrollback in the replay buffer only.

**2.2 Daemon** — snapshot payload carries `state_frame()` instead of bare `contents_formatted`. Detect **alt-screen enter/leave** (mode flip in `process`/`refresh`) and force a snapshot (epoch bump) on transition.

**2.3 iOS / JS** — `applyTerminalSnapshot` feeds the state frame through the replay path; `index.html` `resetAndReplay` already does `term.reset()` then writes — ensure the state frame's leading reset+mode-setters run before any live delta resumes.

**Tests / verify**
- `nudge-terminal`: `state_frame()` round-trips alt-screen + SGR + cursor through a second `vt100::Parser`.
- On-device: start Claude/Codex (alt-screen), force a resync mid-session → screen + colors + cursor intact; leave alt-screen → snapshot fires, normal screen restored cleanly.

**Risk:** low–medium — the vt100 spike landed (all modes exposed), so the risky stream-sniffing fallback is off the table.

---

### Phase 3 — Resize / reflow resync (effort: S–M) — 3.1/3.2 shipped

**Goal:** no stale/mis-wrapped content after rotation, font change, or width change.
**Findings:** M2, plus A3/reflow.

**3.1 Post-resize re-baseline (✅ shipped, phone-initiated)** — In the absolute-offset model the daemon's resize *control* handler can't reach the relay loop (the architecture-review seam), so the phone re-baselines instead: after a successful `setPhoneProfile`/`setWidthMode` over the live session, `updatePhoneProfile`/`updateSelectedTabWidth` call `requestResyncSnapshot` for the affected tab. The daemon resizes the PTY+grid (`total_bytes` preserved across `resize`), and the state-frame snapshot at the new geometry re-bases the phone, so it adopts the daemon's re-rendered grid rather than diverging via independent xterm reflow. Rate-limited (coalesces rapid keyboard-toggle resizes); the watchdog covers a lost reply. *On-device verification (rotate/font/width visual correctness) pending — stack down.*
**3.2 Pin cols (✅ already in place)** — the phone measures cols and reports them via `setPhoneProfile`/`setWidthMode`; the daemon resizes the PTY to match, so wrapping is decided once, on the computer.
**3.3 Reflow (deferred, longer-term)** — `nudge-terminal` `resize` rebuilds the parser from `contents_formatted` (no scrollback reflow). Evaluate a newer `vt100` with a resize API, or a reflow-aware grid. The post-resize re-baseline covers the common case meanwhile.

**Tests / verify:** unit — a resize over a live session requests a re-baseline snapshot (`appModelReBaselinesVisibleTabAfterResize`). On-device — rotate / change font with a wrapped buffer → no duplicated/mis-wrapped lines; cursor lands correctly.

**Risk:** low–medium.

---

### Phase 4 — Transport + buffer efficiency (effort: M) — 4.2/4.3 shipped; 4.1 blocked

**Goal:** cut bandwidth/CPU under bursts and for multi-tab.
**Findings:** L1, L2, M4.

**4.1 Binary frames (L1) — ⛔ BLOCKED.** Sending deltas as binary WS frames needs the *relay* to route binary; the relay is a hosted service **not in this repo** (`docs/relay-hosted.md`), and the daemon currently treats inbound binary as UTF-8 text (`lib.rs` relay recv). Shipping a binary wire format blind risks breaking the connection. Requires relay-side verification/update + on-device testing (stack down). Deferred until the relay can be confirmed/updated.
**4.2 iOS/JS buffers (L2) — ✅ iOS shipped `563925b`.** iOS: `TerminalTab.replayOutputData: Data` backs a computed `replayOutputBase64`; the live append decodes only the delta (no whole-buffer re-encode). JS ring buffer (`index.html`) deferred (untested path; lower value).
**4.3 Focused-tab priority (M4) — ✅ shipped `cbd6cf0`.** Phone sends a `set_focused_tab` hint on select/attach; the daemon skips background-tab output at flush (`tab_is_focus_filtered`); background tabs re-baseline on refocus via the existing gap→snapshot. Chose skip-background over slow-cadence (simpler, reuses Phase 1). Backward-compatible (no focus ⇒ stream all).

**Tests / verify:** bandwidth + CPU benchmark on a burst (`cat` of a large file) before/after; background tabs idle on the wire.

**Risk:** medium — binary framing is the riskiest part (relay protocol). Can ship 4.2/4.3 independently of 4.1.

---

### Phase 5 — One authoritative state model (effort: L, strategic — *decision required*)

**Goal:** eliminate the daemon-`vt100`-vs-phone-`xterm` divergence class (M3) at the root.
**Options:**
- **(a) Daemon-authoritative render frames + diff.** The daemon's `render_frame()` (already used for the CLI client, `nudge-terminal:67`) is the source of truth; the phone applies *frames/diffs*, not raw PTY bytes. Subsumes most earlier fixes (state is always the daemon's) but changes the streaming model (mosh-style diffing to keep it cheap).
- **(b) Guaranteed-matching xterm.** Keep raw-byte streaming but pin the phone xterm config/capabilities to match `vt100` exactly. Cheaper, but fragile to any escape-support divergence.

**Spike done (✅ 2026-05-31 → `docs/20260531-phase5-render-model-spike.md`):** recommends **option (a)**, phased behind a capability flag, **reusing the shipped absolute-offset contract** (offset axis, gap detection, unconditional snapshot adoption, adaptive flush) — the iOS `applyTerminalDelta` reinterprets "contiguous bytes" as "diff against the held frame" and xterm.js is kept (diffs are ordinary escape sequences). The decider: the authoritative render-and-diff loop **already ships** in the CLI client (`nudge-cli` `RenderCache` over vt100 `contents_diff`), so 5(a) is relocating that loop behind the relay, not inventing it. Reject (b) — two independent parsers can't be made to agree by config (vt100's untracked origin/scroll-region/charset modes leak to xterm under raw streaming). **Recommended next step:** the 5a.0 prototype — per-tab `RenderCache` in the relay loop emitting `render_frame`/`contents_diff` behind `NUDGE_RENDER_FRAMES=1` (zero phone changes), then measure daemon CPU + bandwidth vs. the raw path on-device; that CPU number is the go/no-go.

---

## 5. Testing strategy (cross-cutting)

- **Unit:** daemon stream-position bookkeeping (epoch/offset, overflow→snapshot, resize→snapshot); `nudge-terminal` `state_frame()` round-trip; iOS gap-detection/discard logic.
- **Property/fuzz:** feed random byte streams + random cut points; assert the phone never diverges after a forced resync (compare phone xterm buffer to daemon grid `contents()`).
- **Integration (mock transport):** drop / reorder / duplicate deltas → self-heal.
- **On-device (idb + simulator):** typing-echo latency; `yes`/`cat` coherence; alt-screen (Claude/Codex) resync; rotate/font resize. (Bring the daemon/relay back up — note the binding URL is loopback after the last env change.)

---

## 6. Open decisions (confirm before/while building)

1. **Protocol evolution:** additive optional fields + capability marker (recommended) vs. a `v2` payload. Affects mixed-version daemon/phone.
2. **vt100 0.16 capabilities (Phase 2):** ✅ resolved — `vt100 0.16.2` `Screen` exposes all needed modes (`alternate_screen`/`application_cursor`/`application_keypad`/`bracketed_paste`/`hide_cursor`/`mouse_protocol_mode`/`mouse_protocol_encoding`). Scrollback rows are still not exposed (M1 stays as documented).
3. **Scrollback depth (M1):** target rows (e.g. match xterm's 2000) vs. memory on the daemon.
4. **Binary frames (Phase 4.1):** is changing the relay wire format acceptable, or keep base64 and only fix buffers (4.2)?
5. **Phase 5 direction:** ✅ spike done — **render-frames (a)**, phased, reusing the offset contract (`docs/20260531-phase5-render-model-spike.md`). Go/no-go gated on the 5a.0 prototype's on-device daemon-CPU measurement.

---

## 7. Suggested cut line

Phases **0–2** eliminate essentially all garbling and the worst latency — the highest-value, lowest-regret work. **3–4** are polish/scale. **5** is a strategic call to make once 0–2 are stable.

## Appendix — file/function index

- Daemon stream loop / flush / overflow / snapshot-vs-delta: `crates/nudge-daemon/src/lib.rs:2585-2663`
- Snapshot/output payloads: `crates/nudge-daemon/src/lib.rs:3092-3240`
- `set_phone_profile` (resize): `crates/nudge-daemon/src/lib.rs:~2074`
- E2E envelope: `crates/nudge-daemon/src/e2e.rs:~184`
- Grid (process/snapshot/render_frame/resize, scrollback arg): `crates/nudge-terminal/src/lib.rs`
- PTY output tail: `crates/nudge-pty/src/lib.rs:~165`
- iOS apply (snapshot/output, replay cap): `apps/mobile-ios/NudgeMobile/Sources/NudgeMobile/AppModel.swift:~806-895`
- iOS session loop / events: `apps/mobile-ios/NudgeMobile/Sources/NudgeMobile/AppModel.swift:~682-726`
- iOS WebView bridge (Coordinator): `apps/mobile-ios/NudgeMobile/Sources/NudgeMobile/TerminalWorkspaceView.swift:~379-560`
- xterm JS bridge: `apps/mobile-ios/NudgeMobile/Resources/TerminalWeb/index.html`
- Relay client decode / errors: `apps/mobile-ios/NudgeMobile/Sources/NudgeMobile/RelayClient.swift`
