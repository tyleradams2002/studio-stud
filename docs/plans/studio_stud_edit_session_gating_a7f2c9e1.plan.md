---
name: Studio Stud — Fix 1 Edit-Session Gating (pause all daemon comms during play sessions)
overview: Studio Stud is a standard edit-DataModel plugin, but during play/run sessions its capture + live pipeline streams the running-game DataModel tree (observed 49096 instances) to the same single-per-place daemon DB that holds the static edit baseline (observed 41597), and they collide — the daemon reported "corrected 90693 drifted instances" (49096 + 41597 = 90693). Each collision rebuilds a 40-49K-instance snapshot synchronously inside the single-threaded Studio process, starving the running playtest and causing the hitching Clayton reported on daemon v0.3.1 / plugin v0.3.7. Fix 1 gates ALL daemon communication (captures, delta pushes, verifies, and Cursor write/pushes) on RunService:IsEdit() so Studio Stud talks to the daemon ONLY while the genuine persistent edit session is active. During any play session (Play / Play Here / Run / Team Test) the plugin suspends all comms; on return to edit it does a smart catch-up (fingerprint check first, full re-baseline only on detected drift), emits one readiness log line, and resumes live delta streaming. The daemon gains session-mode awareness so the CLI/Cursor side refuses captures and write-token issuance while frozen and reports staleness clearly. No client-trust or gameplay logic is touched; this is tooling-only.
todos: []
isProject: false
---

# Studio Stud — Fix 1: Edit-Session Gating Execution Plan

Status: **READY TO EXECUTE.** Source of the diagnosis: playtest debug-log screenshots from
Clayton's Studio instance (daemon v0.3.1, plugin v0.3.7) + code review of
`tools/studio_stud/plugin/StudioStud.plugin.lua` and `tools/studio_stud/src/live.rs`.

This plan implements **Fix 1 only** (edit-session gating). The two other candidate fixes
(yield-in-walk, structural-only verify) are explicitly out of scope — yield-in-walk risks
torn snapshots during active play and does not stop the dual-tree collision; structural-only
verify would clobber the daemon's property state and requires coordinated Rust changes.

---

## 0. Locked decisions (do not revisit)

1. **Guard primitive = `RunService:IsEdit()`** (documented inverse of `IsRunning()`),
   evaluated at each comms action site **and** driven as a state machine from the always-alive
   3 s poll loop. `IsRunning()` / `IsRunMode()` are fallback conjuncts only if Phase 0 shows
   `IsEdit()` alone is insufficient.
2. **Short-circuit before building the snapshot.** The hitch is the synchronous 40-49K-instance
   `Capture.buildSnapshot()` walk. Guards must early-return *before* the build, not merely before
   the HTTP send.
3. **Catch-up on return = SMART.** Query `/live/fingerprint`; if it still matches the pre-play
   edit baseline, just resume live. Run a full re-baseline **only** on detected drift.
4. **Resume behavior = PASSIVE recompute + one readiness log line.** The daemon already recomputes
   findings / critical-presence / class-counts / fingerprint automatically inside any
   capture/verify, so queries are valid the instant catch-up completes. Do NOT auto-run
   `analyze` / `project diff` on resume.
5. **Scope = FULL (Phases 0-4)**, including daemon/CLI session-mode signaling so Cursor pushes and
   queries hold off while Studio is frozen.
6. **Tooling-only.** No gameplay, economy, or client-trust logic is touched. Plugin is read-only
   to the place; daemon changes are additive.

---

## 1. Root cause (confirmed evidence)

- `tools/studio_stud/plugin/StudioStud.plugin.lua` is a standard edit-DM plugin
  (`plugin:CreateToolbar` @2737, `plugin:CreateDockWidgetPluginGui` @2734, `plugin.Unloading` @3480).
- Every colliding log string is a plugin call: `live mode started` (@1785),
  `running initial capture` (@1842), `-removing` (@2104), `delta POST` (@2256),
  `delta OK` (@2259), `pausing live` (@2670), `daemon is back` (@2660).
- Daemon keeps **one live DB per place** (`resolve_place` in `live.rs`); `compute_drift_ids`
  unions the two instance sets, so two distinct trees → `49096 + 41597 = 90693` reported drift.
- There is **no** `IsEdit` / `IsRunMode` / `IsClient` / `IsServer` guard anywhere in the plugin
  (grep-confirmed), and Studio Stud is **not** synced into `src/` (grep-confirmed) — the second
  copy is the plugin observing the running simulation's DataModel, not a synced game script.

---

## 2. Phase 0 — Empirical mechanism confirmation (do first; throwaway logging)

Add temporary debug logging at each comms site printing `RunService:IsEdit()`, `IsRunning()`,
`IsRunMode()`, `IsServer()`, `IsClient()`, and the DataModel identity (`game:GetDebugId(0)`).
Reproduce locally in each mode and record which sessions tick the plugin and what `IsEdit()`
returns:

- **F5 Play**
- **Play Here**
- **F8 Run**
- **Team Test**

**Success criterion / gate-off for the whole feature:** ticking play/run contexts report
`IsEdit() == false`; the genuine edit session reports `true`. After Phase 1, **no StudioStud lines
tagged Server/Client appear during any play session.** Pick the final primitive from this data
before writing Phase 1. Remove the throwaway logging once confirmed.

---

## 3. Phase 1 — Core edit-session gate (plugin-only; eliminates the hitch)

- Cache `RunService` alongside `HttpService` (top of file, lines 7-9).
- Add a small `Session` helper: `Session.isEdit()` → `RunService:IsEdit()` (plus any Phase 0-confirmed
  conjuncts); `Session.mode()` → `"edit" | "play"`.
- Insert early-return guards (before any snapshot build / HTTP send) at:
  - `startupConnectAndCapture` (@1831) and `syncFn` (@1698) — blocks initial + auto captures.
  - `Live.sendVerify` (@2347) — blocks the verify snapshot build.
  - `Live.flushDirty` (delta send, ~@2256) — blocks delta pushes.
  - poll-loop body (@2652-2666) — no capture/reconnect trigger while non-edit.
- Existing `while Live.liveRunning` loops (`startDebounceLoop` @2445, `startVerifyLoop` @2466) stop
  via `Live.teardown()` in Phase 2; the action-site guards above are defense-in-depth.

**Result:** during a play session, zero snapshots are built and zero bytes reach the daemon →
both the hitch and the dual-tree collision disappear.

---

## 4. Phase 2 — Suspend / resume state machine + smart catch-up (plugin-only)

Drive transitions from the always-alive 3 s poll loop (@2646):

- **edit → play (`onEnterPlay`):** call `Live.teardown()` (@2525) to drop `DescendantAdded` /
  `DescendantRemoving` + per-instance connections and clear dirty sets (no connections ⇒ no dirty
  accumulation); set status `"Paused — Studio in play session"`; keep only the lightweight 3 s
  heartbeat.
- **play → edit (`onReturnToEdit`):** debounce ~1-2 s for the DM to settle, then **smart catch-up**:
  1. Request `/live/fingerprint`; if daemon fingerprint + instance-count still match the pre-play
     edit baseline → resume live (re-arm via `setupAfterBaseline`), no expensive capture.
  2. On divergence → full re-baseline capture (daemon auto-recomputes findings / critical-presence /
     counts), then resume live.
  3. On success → emit one readiness line:
     `Live resumed — rev N · X instances · Y findings · ready`; clear the paused flag.

Note: the Studio Stop button restores the edit tree to its pre-play state, so case (1) is the
common path — honoring the "catch up the data" intent without paying a full capture on every exit.

---

## 5. Phase 3 — Daemon/CLI session signaling (Rust + CLI)

So Cursor does not push or query into a frozen window:

- Plugin sends `sessionMode` (`edit` / `play`) on each poll/heartbeat.
- Daemon (`live.rs` / `storage.rs`) records it; `ping` / `status` expose `sessionMode`,
  `staleSince`, `revision`.
- Daemon **refuses** capture-request fulfillment and **write-token issuance / write-apply**
  (`/studio-stud/write/token`, plugin @1003) while `sessionMode != edit`, returning a clear
  `studio_in_play_session` error.
- CLI `status` + write/capture commands fail fast:
  `"Studio is in a play session; world state frozen as of rev N — retry after the playtest."`

This phase is separable from Phases 1-2 (which already stop the hitch) but is in scope per the
"pause pushes from cursor" requirement.

---

## 6. Phase 4 — Tests, docs, versioning

- Extend the `SelfTest` harness (@3223; existing `live.teardown` assertions @3413):
  - gate blocks comms when `IsEdit()` is false,
  - teardown on enter-play,
  - smart resume / re-baseline on return-to-edit.
- Bump `PLUGIN_VERSION` (@13) → `0.3.8`; bump daemon version for Phase 3.
- Update `docs/studio-stud.md` and `.cursor/rules/studio-stud.mdc` with the edit-only behavior
  and the play-session pause/catch-up contract.

---

## 7. Risks & mitigations

- **Primitive correctness** hinges on Phase 0 → de-risked by confirming before coding.
- **F5 with a suspended edit DM** is self-solving (frozen loop ⇒ no traffic ⇒ no pollution); the
  state machine still resumes cleanly when the edit DM ticks again.
- **Re-baseline cost** is paid in edit mode only (never affects a playtest); the fingerprint
  short-circuit keeps the common path cheap.
- **Run-persisted changes (F8):** the only case where the edit tree can differ across a session; the
  smart catch-up's drift branch handles it. Auto-`project diff` was intentionally NOT added
  (passive_summary decision) — revisit only if F8-persisted edits become a real workflow.

---

## 8. Empirical acceptance test

1. Start `studio-stud serve`, load plugin in Studio (edit) — confirm normal live capture + deltas.
2. Enter F5 Play / Play Here / F8 Run / Team Test — confirm: status shows "Paused",
   **no** Server/Client-tagged StudioStud lines, no `delta POST` / `verify` traffic, no hitching.
3. Stop the playtest — confirm one readiness line, fingerprint short-circuit (no full re-baseline
   when tree unchanged), live delta streaming resumes.
4. While in a play session, run `studio-stud status` and a write/capture command — confirm
   `studio_in_play_session` fast-fail with the friendly message.

---

## 9. Re-validation addendum — 2026-06-04 (executed at v0.4.10 → 0.4.11)

This plan was written at plugin v0.3.7 and never executed; the codebase advanced to v0.4.10
through the validation-remediation work. Confirmed via a live test with Clayton on 2026-06-04 that
the tool still captures during play (the symptom this plan was meant to kill). Re-validated against
current code; architecture intact, line anchors refreshed below.

### Decisions for this execution
- **Branch:** implement directly on `development` (maintainer will run the live acceptance test).
- **Primitive:** `RunService:IsEdit()` primary + `not RunService:IsRunning()` defensive conjunct.
  Transitions logged behind the existing `debugLogging` setting so the maintainer can confirm
  `IsEdit()`/`IsRunning()` across F5 Play / Play Here / F8 Run / Team Test (no throwaway Phase 0).
- **Versioning:** plugin `PLUGIN_VERSION` and daemon `Cargo.toml` → `0.4.11`. Protocol stays **v1**
  (`sessionMode` is additive/optional, defaults to `edit`).
- **Heartbeat channel:** carry `sessionMode` as a query param on the existing 3 s
  `GET /studio-stud/capture/request` poll. Backward-compatible.
- **DEVIATION from original Phase 3 storage plan — session state is IN-MEMORY, not persisted.**
  Keep `session_mode` + a heartbeat freshness timestamp in `DaemonState` (http.rs), NOT in the
  `LiveState` SQLite schema. Rationale: session mode is ephemeral runtime state. Persisting it means
  a daemon restart mid-play (or a crashed plugin) leaves the DB pinned to `"play"` forever, locking
  out Cursor writes. In-memory + freshness timeout gives the correct failure mode: restart → defaults
  to `edit`; heartbeats stop → goes stale → reverts to `edit`. No schema migration needed.
- **CLI reads live daemon, not the DB:** CLI `status`/`capture`/write commands already ping the
  daemon, so they read `sessionMode` from the ping response — no persisted field required.

### Refreshed anchors (v0.4.10)
Plugin `plugin/StudioStud.plugin.lua` (3689 lines):
- Requires block lines 7–9 → add `RunService` at line 10. `PLUGIN_VERSION` line 13.
- `syncFn` def @1773 · `startupConnectAndCapture` @1939 · `Live` table @1956 (`liveRunning` init @1957)
- `Live.flushDirty` @2286 (POST `/live/delta` @2365) · `Live.sendVerify` @2455 · `Live.teardown` @2633
- `Live.setupAfterBaseline` @2666 (spawns loops @2740–2741) · `startDebounceLoop` @2553 · `startVerifyLoop` @2574
- 3 s poll loop @2754–2793 (GET `/capture/request` @2760) · write-token fetch @1055
- `Transport.requestJson` @1007 / `requestBody` @1125 · `setStatus` @2873 / `setConnected` @2886
- `SelfTest` @3400 (run @3411, teardown asserts @3600–3608, global @3654) · `plugin.Unloading` @3668

Daemon (Rust `src/`):
- `http.rs`: dispatcher @79; `DaemonState` @69; GET/POST `/capture/request` @98–99/@133–153;
  `/live/delta` @243; `/live/fingerprint` @263; `/write/token` @331; `/write/{validate,preview,apply}`
  @334–340; `handle_write_route` @409 (token check @444); `manifest_json_with_update` @879 (ping body @889–900)
- `live.rs`: `apply_delta` @100 (returns `{ok:false,error:...}` on reject — natural gate site)
- `storage.rs`: `LiveState` @17 (already has `revision`) — **no change needed under in-memory design**
- `cli.rs`: `status` @471, `capture` @641 · write cmds in `stage3_cli.rs` (@160/@172/@184)
- `Cargo.toml` version @8 · `util.rs` `PROTOCOL_VERSION` @17

### Execution order (this session)
Plugin Phases 1–2 first (self-contained core fix, stops the hitch with zero daemon changes), then
daemon/CLI Phase 3 with strict cargo TDD, then Phase 4 (versions/docs/sweep). Rust changes are
red-green TDD; the Lua gate is covered by the in-plugin `SelfTest` harness + the §8 live acceptance
test (no headless Luau runtime available locally).

### Open detail resolved during impl
Daemon staleness behavior: refuse writes ONLY on a *fresh* `play` heartbeat; if the last heartbeat is
stale (beyond timeout) or absent, report `staleSince` but ALLOW writes — a closed plugin must not
freeze Cursor.
