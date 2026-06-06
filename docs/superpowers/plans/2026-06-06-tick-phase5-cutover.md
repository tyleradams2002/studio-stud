# Phase 5 — The `/tick` protocol cutover

**Branch:** `feature/tick-phase5-tick-cutover` (off `development` @ 0.4.18)
**Decisions:** D1, D3, D4, D5, D7, D10–D13; design §4–§9. **This is the breaking change** — protocol v2,
delete the 5 legacy endpoints, land plugin + daemon together.

**Two decisions locked for this phase (2026-06-06):**
- **FP-1 — Plugin-authoritative fingerprints.** The plugin is the *sole* hash authority: it computes
  each instance's fingerprint (Luau) and sends it; the daemon **stores** it per-instance and **XORs**
  it into per-service accumulators. The daemon **never recomputes** an instance hash. This eliminates
  the Luau↔Rust canonical-format parity problem entirely (nothing to mismatch). Drift still catches
  lost ops / desync. (Daemon-side row corruption is not caught by the hot path — acceptable; covered
  later by an offline integrity tool if ever needed.)
- **SRC-1 — Base64-faithful binary source.** The plugin base64-encodes any non-UTF-8 `Source` and
  marks `sourceEncoding="base64"`; the daemon decodes and stores it faithfully, hashing the raw
  decoded bytes. Valid-UTF-8 source stays as-is (`sourceEncoding="utf8"`, normalized + hashed as today).

**Execution order** (build/verify incrementally; protocol bump + legacy deletion land last, together):
- **5A** Daemon: `/tick` + `/tick/bulk/*` (legacy endpoints KEPT, protocol still 1) → CI-verifiable alone.
- **5B** Daemon: per-place writer-lane worker model (separable — see note).
- **5C** Plugin: per-instance + per-service fingerprints (fast hash, incremental) + base64 source.
- **5D** Plugin: one tick loop replacing the 3 loops + packet build + drift recovery.
- **5E** Cutover: delete 5 legacy endpoints, bump `PROTOCOL_VERSION`/`MIN_PLUGIN_PROTOCOL_VERSION` → 2,
  remove dead plugin code.
- **5F** Gate (folds the deferred "Option A" checks).

Compose for Composer as **two prompts**: Prompt 1 = 5A (+5B), CI-gated; Prompt 2 = 5C–5E, Studio-gated.

---

## Grounding facts (verified 2026-06-06, current line numbers)

### Daemon
- `handle_daemon_request` — `src/http.rs:145`; `match (method, path)` dispatch at **159–475**.
  - Legacy to delete in 5E: `/capture/request|status|start|body|chunk|complete` (184–336),
    `/live/delta` (336), `/live/fingerprint` (362), `/live/verify/start|body|chunk|complete` (366–406).
  - Keep: `/ping`, `/studio-stud/manifest`, `/write/*`, `/context*`, `/addons/*`, `/admin/shutdown`,
    `/allowlist`.
- `apply_delta` — `src/live.rs:102`; `apply_delta_tx` — `src/live.rs:214`; `parse_delta_request` —
  `src/live.rs:36`. The `/tick` ops path **reuses** these.
- Fingerprints today (Phase 1): `xor_service_fp` (`live.rs:330`), `fingerprint_instance` /
  `canonical_instance_value` (`capture.rs:661/679`). FP-1 **replaces** the daemon-computed hash with
  the plugin-provided one.
- `service_fingerprints` table exists (Phase 1). `insert_instance` (`capture.rs:440`) /
  `upsert_instance` (`capture.rs:428`) / `delete_instance_rows` (`capture.rs:406`) — single funnel.
- Bulk reuse: `capture/start|chunk|complete` internals + `materialize_snapshot` (`capture.rs:38`).
- `cmd_serve` worker model — `src/cli.rs:940–968`: `SERVE_WORKERS=4`, one `mpsc` drained by 4 threads
  via `Arc<Mutex<Receiver>>`; `handle_daemon_request` per request. Per-place writes already serialized
  by the conn registry's writer mutex (Phase 1).
- `script_sources(capture_id, instance_id, source_text, source_hash, last_synced_hash)` —
  `storage.rs` (Phase 1). `upsert_script_source` — `storage.rs:808`.
- Hash recipe (projection parity): `sha256_hex(normalize_newlines(src))` — `src/write/safety.rs:17/21`.
- `PROTOCOL_VERSION` / `MIN_PLUGIN_PROTOCOL_VERSION` — `src/util.rs`.

### Plugin (`plugin/StudioStud.plugin.lua`)
- **Three loops to collapse:** debounce-flush `task.spawn` @**2879** (`while liveRunning: wait; flushDirty`);
  verify-heartbeat `task.spawn` @**2903** (stats + `/live/fingerprint` count check + `sendVerify`);
  poll-reconnect `task.spawn` @**3135** (`pollGeneration`, session catch-up).
- `Live.flushDirty` @**2597** (POST `/live/delta`), `Live.sendVerify` @**2770** (full snapshot →
  `/live/verify/*`). Both retire in 5D.
- `buildUpsertedEntry` @~**2460** (returns the wire entry; add `fp` + `source`/`sourceEncoding`).
- `Capture.readSource` (Phase 4) — extend for base64 (SRC-1).
- `Transport.safeEncode` / `sanitizeJsonValue` (0.4.18) — keep as the safety net.
- Dirty sets: `Live.dirtyUpsert` (Instance→true), `Live.dirtyRemoved` (id→true).
- No plugin-side fingerprint today (only fetched the daemon's via `/live/fingerprint`). FP-1 is **new**.

---

## 5A — Daemon `/tick` + `/tick/bulk/*` (legacy kept; protocol still 1)

1. **`POST /studio-stud/tick`** (new handler, `http.rs`). Body = design §4.1: `placeId, sessionMode,
   baseRevision, serviceFingerprints{}, ops{upserted[],removed[]}, bulkRef`. Add `?placeId=` to the URL
   for cheap worker routing (5B). Behaviour:
   - **Empty-tick short-circuit:** if `ops` empty AND `bulkRef` null AND `serviceFingerprints` match
     stored → return `{ok, revision, instanceCount, driftServices:[], request:null, applyScripts:[]}`
     **without acquiring the writer** (read-only in-memory/quick read). Critical for 0.5s cadence.
   - Else, in the place's writer lane: reuse `apply_delta_tx` for `ops` (FP-1 storage, task 3); if
     `bulkRef` set, commit the staged bulk via `materialize` into the place; compute `driftServices`
     by comparing request `serviceFingerprints` to stored `service_fingerprints`; record `sessionMode`;
     return the response shape (with `request` = AI-queued job placeholder, `applyScripts` = `[]`).
   - `sessionMode=="play"` → keepalive: record mode, answer drift/request, **ignore ops** (design §4.3).
   - **Tests (HTTP):** (a) empty tick, matching fp → `driftServices:[]`, revision unchanged, no writer
     acquired; (b) tick with `ops.upserted` → revision++ and the right service fp updated; (c) tick with
     a deliberately wrong `serviceFingerprints` entry → that service in `driftServices`; (d) `play` tick
     with ops → ops ignored, revision unchanged.

2. **`POST /studio-stud/tick/bulk/{start,chunk,complete}`** — thin aliases over the existing chunked
   capture machinery (`http.rs` 248–336 internals). `complete` stages a syncId; the next `/tick` with
   `bulkRef=syncId` commits it via `materialize`.
   - **Test (HTTP):** start→chunk→complete a baseline payload, then `/tick {bulkRef}` → revision=1,
     `service_fingerprints` populated from the bulk's per-instance fps.

3. **FP-1 storage (daemon).**
   - Add `fingerprint` column to `instances` (TEXT hex or BLOB). `insert_instance` reads the entry's
     `fp` and stores it (no hashing). On upsert via `apply_delta_tx`: XOR out the old stored fp (if the
     row existed) and XOR in the new `fp`; on remove: read stored fp, XOR out. Route to the service
     accumulator by `service_of(path)`.
   - **Replace** `fingerprint_instance`/`canonical_instance_value` in the live path with the stored fp.
     Keep the functions only if still used elsewhere; otherwise delete (or `#[allow(dead_code)]` + TODO
     offline-integrity). `live_state.fingerprint` (global) = XOR of service fps.
   - Migration: clean break (protocol v2) — a fresh baseline repopulates fps; no in-place migration of
     old rows needed (the next connect re-baselines).
   - **Tests:** XOR invariant `XOR(service fps) == global fp` holds after a tick; daemon's stored
     service fp after applying ops **equals** the fp the plugin would send next tick (parity by
     construction — assert the round-trip: feed ops with fps, read back service_fingerprints, compare).

4. **SRC-1 decode (daemon).** `insert_instance` source handling: if `sourceEncoding=="base64"`,
   base64-decode `source` → raw bytes; `source_hash = sha256_hex(raw)` (NO newline-normalize);
   store raw + `source_encoding="base64"`. Else (`"utf8"`/absent) → `sha256_hex(normalize_newlines(src))`
   as today. Add `source_encoding` column to `script_sources`.
   - **Tests:** base64 round-trip (CRLF-free binary → decoded bytes + raw-bytes hash stored, encoding
     marked); utf8 path unchanged.

> **5B note (separable):** per-place writer-lane (1 writer thread/place + shared pool of 3) is a
> correctness/perf nicety; since the plugin is sequential per place and the conn registry already
> serializes per-place writes, the existing 4-worker pool is safe meanwhile. Land 5A on the existing
> pool first; do 5B as its own step. **5B:** dispatcher routes `POST /tick(/bulk)?placeId=` to a lazily
> created, idle-evicted per-place writer thread (bounded channel, arrival order); all else → shared
> pool (default 3, configurable). Replace `cli.rs:940–968`. Test: interleaved same-place ticks apply in
> order (revision strictly increments, no `revision_mismatch`); cross-place ticks run in parallel;
> `concurrent_pings_while_serve_is_running` still passes.

---

## 5C — Plugin fingerprints + base64 source

1. **Per-instance hash.** `Live.hashInstance(entry) -> hex` — a **fast non-crypto 128-bit hash**
   (FNV-1a recommended; crypto not needed — daemon is hash-agnostic, this is drift detection) over a
   canonical string of the entry's **synced** fields: `className, name, parentId, path, depth,
   siblingIndex, childCount, duplicateSiblingName, properties (key-sorted), attributes (key-sorted),
   tags`. **Exclude `source`/`sourceEncoding`** (fingerprint stays source-isolated, per Phase 4). The
   canonical string only needs to be self-consistent within the plugin.
   - **Test (SelfTest):** same entry → same hash; reorder a property table → same hash (sorted);
     change one property → different hash; two distinct entries → different hashes.

2. **Incremental per-service accumulators.** `Live.instFp[id]=hex`, `Live.serviceFp[service]=XOR`.
   On dirty-flush build of an entry: compute newHash; XOR out `instFp[id]` (if present) from its
   service, XOR in newHash, store. On remove: XOR out + clear. `service` = first path segment.
   - **Test (SelfTest):** add A,B to Workspace → serviceFp == hash(A) XOR hash(B); remove A → ==
     hash(B); re-add A → back to A XOR B (XOR self-inverse).

3. **Entry carries its fp.** `buildUpsertedEntry` adds `fp = Live.hashInstance(entry)` (compute after
   the entry table is built, before return). The same value feeds the incremental accumulator (task 2).

4. **Base64 source (SRC-1).** Extend `Capture.readSource`: read `inst.Source`; if `utf8.len(src)~=nil`
   → return `src,"utf8"` else `base64encode(src),"base64"`. `buildUpsertedEntry`/baseline set
   `entry.source` + `entry.sourceEncoding`. Add a small Luau base64 encoder (`Capture.base64`).
   - **Test (SelfTest):** utf8 source → encoding "utf8", text unchanged; a string with invalid bytes
     → encoding "base64", and base64-decoding it (test helper) reproduces the original bytes.

## 5D — Plugin single tick loop

1. **Replace the 3 loops** (2879/2903/3135) with **one fixed-interval tick loop** (default 0.5s,
   runtime setting reusing the debounce setting plumbing). Each beat:
   - If `not Session.isEdit()` → send keepalive tick (`sessionMode="play"`, no ops) and continue.
   - Build packet: `placeId, sessionMode, baseRevision=Live.currentRevision, serviceFingerprints` (from
     `Live.serviceFp`), and inline `ops{upserted,removed}` from the dirty sets — UNLESS the JSON
     exceeds the inline threshold (~256KB), then spill via `/tick/bulk/*` and set `bulkRef`.
   - POST `/tick`; on `ok`: set `currentRevision=response.revision`; clear **only** the dirty entries
     that were included (no-data-loss: never clear flags set during the in-flight tick); handle
     `driftServices` (task 2) and `request`/`applyScripts` (apply-list reserved; log for now).
   - On `revision_mismatch`: adopt daemon revision, keep dirty, retry next beat.
   - **Tests (SelfTest):** pure `buildTickBody(dirtyUpsert, dirtyRemoved, serviceFp, rev, mode)` shape
     test; `classifyPayload(bytes)` → inline vs bulk at the threshold.

2. **Drift recovery.** On `driftServices` non-empty: coalesced **re-walk of only those services**
   (yielding, reuse the Phase-4 yielding walk), recompute their instances' fps + accumulators, spill
   the re-walked subtree via `/tick/bulk` → next tick commits. **No-data-loss invariant** (design §6):
   never clear dirty flags during recovery; re-walk reads current live state.
   - **Test (SelfTest):** pure recovery-state helper — given driftServices, the dirty set is preserved
     across a simulated recovery; only listed services are scheduled for re-walk.

3. **Baseline = first tick.** On connect, the daemon reports no stored state → the plugin sends the
   whole tree (over threshold → `/tick/bulk`). Remove the separate startup-capture path
   (`startupConnectAndCapture`/`syncFn`) in favor of the tick loop's baseline.

## 5E — Cutover (breaking)

1. **Delete** the 5 legacy endpoint groups in `http.rs` (capture/*, live/delta, live/fingerprint,
   live/verify/*). Old paths → 404. **Test:** each old path returns 404; `/ping` reports protocol 2.
2. **Bump** `PROTOCOL_VERSION` and `MIN_PLUGIN_PROTOCOL_VERSION` → **2** (`util.rs`). The mutual
   handshake surfaces "out of date" if only one side upgrades.
3. **Delete dead plugin code**: `Live.flushDirty`, `Live.sendVerify`, the verify snapshot path, the
   old poll/debounce/verify loops, `/live/fingerprint` usage.

---

## ✅ PHASE 5 GATE (folds deferred "Option A")
- `cargo test` green incl. all new HTTP/FP/base64 tests; **XOR invariant** intact; old endpoints 404.
- Plugin SelfTest green incl. hashInstance, incremental serviceFp, base64 round-trip, buildTickBody,
  drift-recovery helper.
- **Studio soak (user gate):** fresh connect → baseline via `/tick/bulk` → edit storm (deltas via
  `/tick`, < 50 ms) → **empty ticks are cheap** (no writer acquired) → **no periodic full
  re-baselines** (contrast pre-rework: deltas should dominate; bulk only on connect/drift). Force drift
  (edit during a simulated stall) → only the drifted service re-walks, no lost edits.
- **Deferred Option-A checks land here:** (1) `script-sources`/`script-source` debug CLI works against
  live storage (the spawned-task fix) → verify `script_sources` populated + hashes match the projection
  (now incl. a base64-encoded entry); (2) live Source edit ships a delta and updates stored source/hash.

## Version
Bump to **0.4.19** (or higher) via `scripts\bump-version.ps1` on the cutover push (plugin + daemon move
together at protocol v2).

## Out of scope (still deferred)
- Real play/pause logic (seam only — `sessionMode` rides every tick).
- `applyScripts` write channel (shape only — empty list).
- Defaults skip, Merkle drift escalation, parallel-hash burst, larger reader pool (all profile-gated).
