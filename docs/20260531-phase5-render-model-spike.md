# Phase 5 Design Spike — One Authoritative State Model (M3)

- **Date:** 2026-05-31
- **Status:** Spike for go/no-go. No code changed.
- **Scope:** Roadmap §4 Phase 5 / §6.5 — eliminate the daemon-`vt100`-vs-phone-`xterm.js` divergence class (M3).
- **Input read:** `crates/nudge-terminal/src/lib.rs`, `crates/nudge-daemon/src/lib.rs` (relay loop + payloads), `crates/nudge-cli/src/main.rs` (RenderCache), iOS apply path + bridge, the vendored `vt100 0.16.2` `Screen`.

---

## 1. Recommendation

**Build option (a): daemon-authoritative render frames + `contents_diff`.** Phase it in behind a capability flag; it is **incremental on top of the shipped absolute-offset contract**, not a rewrite. The deciding fact: the entire authoritative-render-and-diff loop **already exists and ships in this repo** — the CLI client does exactly it (`nudge-cli/src/main.rs:1323-1360` `RenderCache`), and the diff primitive it relies on (`vt100::Screen::contents_diff`) is a stable, documented vt100 0.16.2 API (`vt100 0.16.2 screen.rs:311`). Phase 5(a) is "point the relay loop at `render_frame`/`contents_diff` instead of raw PTY bytes, and reuse the offset contract to order the frames." The phone keeps xterm.js unchanged — it still receives escape-sequence bytes via `term.write` (`index.html:248-253`); only the *source* of those bytes moves from the PTY to the daemon's grid.

Reject option (b): it does not remove the divergence class, it only narrows it, and the residual gaps (below, §3) are exactly the M3 failures we are trying to kill. (a) makes the daemon's grid the single source of truth, which structurally retires M3 and the harder parts of R2/R3.

---

## 2. How option (a) works in *this* codebase

### 2.1 What the daemon emits

Today the relay loop broadcasts **raw PTY bytes** stamped with an offset (`TerminalChange { offset, data }`, flushed in `flush_pending_terminal_outputs`, `lib.rs:3217`). Under (a) the daemon instead emits **rendered grid bytes**:

- **Full frame** = `TerminalGrid::render_frame(row_offset)` (`nudge-terminal/src/lib.rs:125`). It already produces a self-contained, position-anchored ANSI redraw (per-row `\x1b[2K` clear, SGR, absolute cursor) — i.e. the screen rendered as escape sequences.
- **Diff frame** = `next.screen().contents_diff(prev.screen())` (`vt100 0.16.2 screen.rs:311`). vt100's own contract: *"rendering `prev.contents_formatted()` followed by `self.contents_diff(prev)` is equivalent to rendering `self.contents_formatted()`."* So a phone that holds frame N can be advanced to frame N+1 with a diff that touches only changed cells + SGR + cursor — mosh-style, cheap.

The CLI already runs precisely this two-mode loop (diff when the previous parser exists and sizes match, full redraw otherwise — `main.rs:1350-1355`). Phase 5(a) lifts that `RenderCache` logic out of the CLI and into the daemon's per-tab relay state.

### 2.2 How the offset contract maps (mostly reused)

The shipped absolute-offset machinery (Phases 0–3) **carries over almost verbatim**, because a frame stream needs the same three guarantees a byte stream does — ordering, gap detection, idempotent resync:

- The grid's `total_bytes` (`lib.rs:39`, advanced in `process`, `lib.rs:53`) stays the **frame-sequence axis**. A frame is stamped with the `total_bytes` value it was rendered at, read under the grid lock — identical to how `terminal_snapshot` reads `(snapshot(), state_frame())` coherently today (`lib.rs:1907-1915`).
- A **diff frame** is `{ baseOffset, atOffset, bytes }`: "valid only if you are currently at `baseOffset`; applies up to `atOffset`." The phone's existing `nextOffset` check (`AppModel.swift:925`, `offset == next`) becomes `baseOffset == nextOffset`. A mismatch (`baseOffset != nextOffset`) is a gap → request a full frame. This is the **same** `applyTerminalDelta` state machine (`AppModel.swift:898-941`), with "contiguous bytes" reinterpreted as "diff against the frame I hold."
- A **full frame** plays the role today's `state_frame()` snapshot plays: adopt `nextOffset = offset` unconditionally, reset render (`applyTerminalSnapshot`, `AppModel.swift:846-868`).

So the trim/gap/snapshot logic, the `requestResyncSnapshot` watchdog (`AppModel.swift:943`), and the unconditional-snapshot-adoption rule are **reused, not retired**. What changes is the *payload contents* and the per-tab daemon-side render cache.

One subtlety the offset axis must absorb: `total_bytes` counts **input** bytes, but two different input chunks can render to the *same* grid (e.g. a no-op cursor query, or bytes that overwrite then restore). Two distinct frames can therefore share visual state. That is harmless — the diff between them is empty and the offset still advances monotonically, so ordering holds. The reverse (same offset, different frame) cannot happen because offset is read under the grid lock at render time.

### 2.3 How the phone applies frames (xterm.js is **kept**)

xterm.js is **not** replaced by a dumb cell renderer. `render_frame`/`contents_diff` emit ordinary VT escape sequences, and the phone already feeds escape bytes straight into `term.write` (`index.html` `writeBytes`/`writeOutputBase64`, `index.html:248-283`). The divergence (M3) goes away not because xterm stops parsing escapes, but because the **only** escapes it ever sees are a tiny, fixed vocabulary the daemon emits (cursor moves `CUP`, `\x1b[2K`, SGR, `\x1b[?25h/l`) — see `push_move_to`/`push_cursor_visibility`/`push_offset_cursor_moves` (`lib.rs:148-196`) and vt100's `write_contents_diff` (cursor + grid + SGR only, `screen.rs:319-326`). The app no longer relays arbitrary program output (DECSTBM, charset shifts, OSC, etc.) for xterm to (mis)interpret; the daemon's vt100 absorbs all of that and re-emits a normalized subset. xterm and vt100 only have to agree on that subset, which is trivial, instead of on the full ECMA-48 + xterm-extensions surface, which is M3.

JS-side change is small: `writeOutputBase64` already just decodes + `term.write`s (`index.html:278-283`). A diff frame is applied the same way (it *is* escape bytes). A full frame goes through `resetAndReplay` (`index.html:255-263`) which already does `term.reset()` then write — exactly the full-frame semantics.

### 2.4 Bandwidth model

- **Raw-byte stream (today):** bandwidth = program output volume. A `yes`/`cat bigfile` burst is megabytes; today this is what trips the 64KB overflow → snapshot path (`accumulate_terminal_change`, `lib.rs:3197`).
- **Frame-diff stream (a):** bandwidth = *visible change* per flush tick, capped at one full frame. At the 16ms floor (`relay_terminal_flush_interval`, default 16, `lib.rs:3151`), a `yes` flood collapses to ~1 small diff per tick (only the scrolled region changed) instead of the raw flood. A full frame is bounded by screen size: `rows × cols × ~worst-case-bytes-per-cell`. For 80×24 that is single-digit KB; for a 200×50 computer-width tab, low tens of KB — still well under the existing 64KB cap, and the **common** case (a few changed cells) is bytes, not KB.
- Net: (a) is **strictly better** on bursty output and on idle (an idle screen diffs to empty), and slightly worse only in the pathological case of a full-screen repaint every tick — which a full-frame cap already bounds. The L1/L2 base64 inefficiencies (Phase 4) apply equally to both models and are orthogonal.

### 2.5 What Phase 0–3 machinery is reused vs. retired

| Machinery | Under (a) |
|---|---|
| `total_bytes` axis + grid-lock-coherent offset capture (`lib.rs:39/53/1912`) | **Reused** as the frame-sequence axis. |
| Overflow → snapshot, `Lagged` → snapshot (`lib.rs:2653-2660`, `accumulate_terminal_change`) | **Reused** — "can't send a contiguous run" becomes "can't send a valid diff" → full frame. |
| Adaptive flush (16ms floor + immediate-on-idle, `lib.rs:2639/2695`) | **Reused** as the frame cadence. |
| iOS gap detection / trim / unconditional snapshot adoption (`AppModel.swift:898-941/846-868`) | **Reused**, reinterpreted (offset → frame base). |
| `state_frame()` (reset + modes + contents, `lib.rs:101`) | **Partly retired**: the daemon now owns mode state, so the phone's xterm never needs alt-screen/bracketed-paste/mouse modes restored — `render_frame` draws cells into a plain screen. `state_frame` may still seed the very first frame. The mode-restoration complexity (and its vt100 origin-mode/charset *limitation*, `lib.rs:97-100`) **stops mattering on the phone** — a real Phase 5 win. |
| Raw PTY `output_tail` as scrollback (`nudge-pty`) | **Retired** for the phone render path. |
| Per-delta raw byte buffering (`PendingOutput`, `lib.rs:3165`) | **Replaced** by a per-tab `RenderCache` (prev parser + last offset). |

---

## 3. Option (b) sketch, and why it is weaker

(b) keeps raw-byte streaming and tries to make the phone's xterm.js byte-identical to the daemon's vt100 by pinning config/capabilities. Concretely: lock `term` options (`index.html:65-80`) and feature flags so escape interpretation matches.

Why it does not close M3:

1. **Different parser implementations, not just config.** vt100 0.16.2 is a Rust state machine; xterm.js is a separate TS implementation. Pinning options cannot make two independent parsers agree on edge cases (ambiguous-width Unicode, malformed/partial CSI, tab stops, DECSTBM scroll-region semantics, wrap-at-margin/DECAWM, REP, SCS charset). Any single mismatch on a long-lived TUI (Claude/Codex alt-screen) silently drifts — the exact M3 symptom.
2. **vt100's own gaps leak to the phone.** The daemon's grid already *doesn't track* origin mode / scroll region / charset (documented at `lib.rs:97-100`). Under (b) the phone's xterm *does* honor them (from the raw stream), so the two ends interpret the same bytes **differently by construction** — (b) can make divergence *worse* than (a), where the daemon's normalized output never contains them.
3. **Fragile forever.** Every xterm.js upgrade or vt100 bump is a regression surface. (a) reduces the contract to a handful of escapes; (b) keeps the entire ECMA-48 + xterm-extension surface as the contract.

(b) is cheaper to start but buys a permanent, untestable-in-the-large divergence risk. It is at best a stopgap, and Phases 0–3 already mitigate the *resync* failures (b) would otherwise help with.

---

## 4. Migration path / phasing

**Incremental, on top of the shipped contract.** Not a rewrite. The protocol fields are additive (mirroring how `offset` was added), gated by a capability marker (roadmap §6.1) so a mixed-version phone/daemon falls back to raw-byte streaming.

Smallest valuable first step → full rollout:

- **5a.0 (S) — Prototype/measure, daemon-only.** Add a daemon-side `RenderCache` (copy from `nudge-cli/src/main.rs:1334-1360`) and, behind an env flag (e.g. `NUDGE_RENDER_FRAMES=1`), have `flush_pending_terminal_outputs` emit `render_frame`/`contents_diff` bytes instead of raw PTY bytes. **Offset-axis caveat (review):** the phone is *not* literally unchanged-and-correct if frames go through the delta payload as-is — `applyTerminalDelta` advances `nextOffset` by the payload's decoded byte length and gap-checks `offset == nextOffset`, but the daemon stamps a delta's `offset` from the **input** `total_bytes` axis (`accumulate_terminal_change`), which is unrelated to a *diff*'s byte length (and an empty visual diff has length 0 while `total_bytes` still advances). Shipped naively, every frame after the first reads as a gap → forces a snapshot → **full-frame-per-flush thrash that invalidates the very bandwidth number 5a.0 exists to produce.** Two honest options: **(a)** stamp frame deltas on a cumulative **sent-byte** axis (the running sum of emitted frame/diff bytes) instead of `total_bytes` — then the phone's `offset == next` / `next += len` arithmetic holds and the diff bytes append correctly via `term.write`; phone stays unchanged, daemon changes the offset source for frame mode. **(b)** ship each frame on the **snapshot** payload (the phone applies it as a full replace via `resetAndReplay`, no offset arithmetic) — simpler, but measures *full-frame* not *diff* bandwidth. **Recommend (a)** for a true diff measurement. Either way it's daemon-only + reversible. **This is the recommended next step.**
- **5a.1 (M) — Frame-aware payload + capability marker.** Replace the byte `offset` semantics with `{ baseOffset, atOffset }` on diff frames and a `capabilities: ["render-frames"]` marker; phone advertises support, daemon falls back to raw bytes otherwise. Reinterpret the iOS gap state machine (offset → frame base).
- **5a.2 (M) — Retire mode-restoration on the phone path.** Once frames are authoritative, drop `state_frame`'s mode prologue from the phone snapshot (daemon owns modes); keep it only if still seeding xterm. Simplifies R3 and sidesteps the vt100 mode-tracking limitation entirely on-device.
- **5a.3 (S, optional) — Scrollback (M1).** With the daemon authoritative, scrollback becomes "render the last N grid rows into the frame" rather than replaying raw history — folds the deferred M1 into the same model.

No phase regresses 0–3: each is additive and flag-gated.

---

## 5. Risks, open questions, effort (S/M/L per piece)

| Item | Effort | Risk / note |
|---|---|---|
| Daemon `RenderCache` (lift from CLI) | **S** | Logic already proven in-tree (`main.rs:1334`). Per-tab state in the relay loop. |
| Flag-gated frame emission (5a.0) | **S** | Daemon-only; reversible; on-device-measurable. Must stamp frame deltas on a sent-byte offset axis (or ship as snapshots) so the phone's offset arithmetic doesn't gap every frame — see 5a.0 caveat. |
| Frame-aware payload + capability negotiation (5a.1) | **M** | Mixed-version fallback is the main correctness surface. |
| iOS gap-state reinterpretation (offset→frame) | **M** | Reuses `applyTerminalDelta`; risk is the diff-base bookkeeping. |
| Retire phone-side mode restoration (5a.2) | **S** | Pure simplification once 5a.1 lands. |
| Scrollback in frames (M1) | **M–L** | vt100 0.16 still doesn't expose scrollback rows (roadmap §6.2); may need a newer vt100 or a custom grid. |

Open questions:

1. **Diff cost at scale.** `contents_diff` allocates a fresh `Vec` and walks the grid each flush (`screen.rs:311`). At 60fps × many tabs, is the daemon CPU acceptable vs. today's raw passthrough? → **measure in 5a.0** (this is the go/no-go number).
2. **Full-frame size on wide/tall computer-mode tabs.** Bound it; confirm worst-case stays under the relay cap (§2.4).
3. **Cursor/visibility fidelity through diff.** vt100's diff includes hide-cursor + cursor move (`screen.rs:319`), and `render_frame` re-emits position; confirm xterm lands the cursor identically (the CLI's round-trip via a second parser is the existing evidence; add an xterm-side check on-device).
4. **Does any phone feature need raw bytes?** e.g. bracketed-paste echo, OSC title. Audit before retiring the raw path entirely; frames can carry a side-channel for OSC/title if needed.
5. **Capability/versioning** (roadmap §6.1) — additive-field + marker vs. v2 payload. Recommend additive + marker, consistent with how `offset` shipped.

---

## 6. Recommended next step

**Build the 5a.0 prototype + take the bandwidth/CPU measurement.** Concretely:

1. Add a per-tab `RenderCache` to the relay loop (copy `nudge-cli/src/main.rs:1334-1360`).
2. Behind `NUDGE_RENDER_FRAMES=1`, in `flush_pending_terminal_outputs` (`lib.rs:3217`): instead of shipping `pending.data` raw, render the tab's grid (`render_frame` for a full frame, `contents_diff(prev)` for an incremental) and ship *those* bytes — but stamp the delta's `offset` on a **cumulative sent-byte axis** (running total of emitted frame bytes), NOT the input `total_bytes`, so the phone's `offset == nextOffset` / `next += len` arithmetic holds (option (a) above). Alternatively ship each frame on the snapshot payload (full replace, no offset math) to measure full-frame cost. Do NOT ship diffs through the delta payload with the input-offset axis — it gaps every frame.
3. Measure, on-device, against the existing raw path: (a) bytes-on-wire and daemon CPU for `yes`/`cat bigfile`, an idle Claude/Codex alt-screen session, and normal typing; (b) visual correctness of the alt-screen TUIs and cursor.

If the bandwidth wins materialize and CPU is acceptable, proceed to 5a.1 (frame-aware payload + capability marker). If diff CPU is the bottleneck, that is the signal to reconsider scope — but option (b) does **not** become more attractive, because it never solves M3.

**Key evidence this is low-risk:** the authoritative-render-and-diff loop is not new code to invent — it is the CLI's shipping render path (`nudge-cli/src/main.rs:1323-1360`) over a stable vt100 primitive (`contents_diff`, `vt100 0.16.2 screen.rs:311`). Phase 5(a) is moving that loop behind the relay, with the Phase 0–3 offset contract reused to order the frames.
