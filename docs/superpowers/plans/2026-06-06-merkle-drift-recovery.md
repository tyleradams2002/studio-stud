# Merkle Drift Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make drift recovery ship a *minimal* delta (only the instances that actually diverged) instead of re-baselining the whole tree — plus a small yield fix so full baselines never freeze Studio.

**Architecture:** Two staged deliverables on top of the existing plugin-authoritative fingerprints. **Phase 1 (surgical recovery)** keeps the per-service drift *detection* but, on drift, exchanges per-instance fingerprints for the drifted service and ships only the differing instances as a normal delta (no `materialize`, no full re-upload). **Phase 2 (Merkle)** adds a per-instance *subtree* fingerprint maintained on both sides (XOR-Merkle up the parent chain) plus a descent endpoint, so recovery localizes to the changed subtree *without* walking the whole drifted service. Phase 2 is gated on soak data and only pays off when a large service drifts often.

**Tech Stack:** Rust daemon (`rusqlite`/SQLite WAL, `tiny_http`), Luau Studio plugin. Fingerprints are 32-byte (64-hex) XOR accumulators; recovery ships through the existing `/tick` `ops` (delta) path.

---

## Background & key facts (verified 2026-06-06)

The tick protocol is plugin-authoritative for fingerprints (decision FP-1): the plugin computes each instance's hash; the daemon stores it and XORs it into per-service accumulators; the daemon never recomputes a hash. Current recovery (Phase 5 "Fix A") is: **any drift → full-tree `materialize` re-baseline** (`Live.triggerDriftRecovery → Live.triggerFullBaseline`). That is correct and wipe-free but re-uploads the entire tree on every drift event.

**Existing surface this plan builds on:**

Plugin (`plugin/StudioStud.plugin.lua`):
- `Live.instFp[id]` = 64-char hex (the instance's *self* fingerprint).
- `Live.serviceFpBytes[service]` = `byte[32]` (XOR of `instFp` for that service = the service-level Merkle node already).
- `Live.parentByInst[Instance] = Instance` (last-known parent).
- `Live.hashInstance(entry) -> hex64`; `Live.serviceOf(path) -> string`.
- `Live.applyFpUpsert(id, entry, oldPath)`, `Live.applyFpRemove(id, path)`, `Live.resetFingerprints()`.
- Local byte helpers: `fpZeroBytes()`, `fpHexToBytes(hex)`, `fpBytesToHex(bytes)`, `fpXorBytes(target, source)`.
- `Live.buildBaselineSnapshot(reason)`, `Live.collectOpsFromDirty()` (depth-sorted, capped), `Live.runTick(mode)` (drift branch calls `Live.triggerDriftRecovery(drift)`), `Live.uploadTickBulk`, `instanceIdByRef[inst] = id`.

Daemon:
- `instances` table has `parent_id` and `fingerprint` (self fp) columns (`src/capture.rs` `insert_instance`).
- `service_fingerprints(capture_id, service_name, fingerprint, instance_count)` table; built during ingest (`src/capture.rs` ~350–405) and maintained in `apply_delta_tx` via `xor_service_fp` (`src/live.rs`).
- `read_stored_fp(conn, capture_id, id) -> Option<[u8;32]>`, `fp_digest_from_entry(inst)`, `service_of(path)`.
- `compute_drift_services(conn, capture_id, request_fps) -> Vec<String>` (`src/tick.rs`).
- `/studio-stud/tick` handler (`src/http.rs`); ops applied via `apply_delta_tx` (`src/live.rs`).

**Design decisions locked for this plan:**
- **M1 — XOR-Merkle.** `subtreeFp[node] = XOR of selfFp(d)` over all `d` in `subtree(node)` (node included). XOR is associative/commutative → a leaf change propagates as a single XOR delta up the ancestor chain (O(depth)); it also makes the existing service fp *already equal* the service node's subtree fp. (Trade-off vs hash-Merkle: XOR can't see a change that exactly XOR-cancels another — negligible at 256 bits; reordering is still caught because `selfFp` includes `path`/`siblingIndex`.)
- **M2 — Steady-state tick is unchanged.** The plugin keeps sending per-service fps each tick; detection is identical. Merkle only adds a *descent on drift*. No hot-path cost.
- **M3 — Recovery always ships a normal delta** through the existing `/tick` `ops` path (never `materialize` a partial tree). `materialize` stays reserved for the connect/`no_baseline` full baseline only.
- **M4 — Daemon stores per-instance fps already; descent reads them.** Phase 1 reads the `fingerprint` column; Phase 2 adds a `subtree_fingerprint` column.
- **M5 — Processing order is depth-ascending** (parents before children), which `collectOpsFromDirty` already does — required for correct subtree-fp maintenance under reparent.
- **M6 — Fallback.** If surgical/Merkle recovery fails or can't converge in a bounded number of rounds, fall back to `Live.triggerFullBaseline` (today's behavior). Recovery must never be worse than a full re-baseline.

---

## File structure

- `plugin/StudioStud.plugin.lua` — all plugin changes (yield fix, surgical-recovery diff, descent driver, subtree-fp maintenance, SelfTest).
- `src/tick.rs` — recovery endpoints (`/tick/fps`, `/tick/merkle/children`), request parsing, response shapes.
- `src/http.rs` — route the new endpoints; they are reads (shared pool, not writer-lane).
- `src/capture.rs` — `subtree_fingerprint` maintenance (ingest + helpers); query helpers for children fps.
- `src/live.rs` — maintain `subtree_fingerprint` inside `apply_delta_tx` (up the `parent_id` chain).
- `src/storage.rs` — schema column add (`subtree_fingerprint`).
- `tests/tick_http.rs` (+ a new `tests/merkle_recovery.rs`) — daemon HTTP/integration tests.

---

# PHASE 0 — Yield fix (Q1)

### Task 1: Yield the full-baseline fingerprint rebuild

The walk inside `Capture.buildSnapshot` already yields, but `Live.buildBaselineSnapshot`'s fp-rebuild loop hashes every instance in one burst (runs on every full baseline: connect, drift, undo). Add a yield mirroring `Live.initFingerprintsFromWalk`.

**Files:** Modify `plugin/StudioStud.plugin.lua` (`Live.buildBaselineSnapshot`).

- [ ] **Step 1 — apply the change.** Replace the loop body:

```lua
function Live.buildBaselineSnapshot(reason)
	Live.resetFingerprints()
	local snapshot = Capture.buildSnapshot({ reason = reason or "tick-baseline" })
	local processed = 0
	for _, entry in ipairs(snapshot.instances) do
		entry.fp = Live.hashInstance(entry)
		Live.applyFpUpsert(entry.id, entry, nil)
		processed += 1
		if Capture.shouldYield(processed, BASELINE_YIELD_EVERY) then
			task.wait()
		end
	end
	return snapshot
end
```

- [ ] **Step 2 — syntax check.** Run:
  `"/c/Users/tyler/.rokit/tool-storage/lune-org/lune/0.10.4/lune.exe" run <tmp luau.compile script>`
  Expected: `COMPILE OK`.

- [ ] **Step 3 — SelfTest assertion (add to the JSON-safety/Phase-5 SelfTest block).** Assert the snapshot still builds and the global fp equals the XOR of service fps (sanity that the loop ran):

```lua
local snap = live.buildBaselineSnapshot("selftest")
SelfTest.assert("baseline snapshot has instances", #snap.instances > 0, failures)
```

- [ ] **Step 4 — Studio check (manual, folds into the gate):** capture a large place → no multi-second freeze during baseline.

- [ ] **Step 5 — Commit.**

```bash
git add plugin/StudioStud.plugin.lua
git commit -m "fix(plugin): yield the full-baseline fingerprint rebuild loop"
```

---

# PHASE 1 — Surgical recovery (per-instance fp exchange → delta)

Goal: on drift in service X, ship only the instances that differ — without `materialize` and without re-uploading the whole service's *entries* (only fps are exchanged to find the diff; only differing instances are re-read and shipped).

### Task 2: Daemon endpoint — per-service instance fps

**Files:** `src/tick.rs` (new `fn fps_for_services`), `src/http.rs` (route), `tests/merkle_recovery.rs` (new).

- [ ] **Step 1 — failing test.** New `tests/merkle_recovery.rs`:

```rust
// Baseline a place with Workspace/Part(p1) and ServerScriptService/Script(s1).
// POST /studio-stud/tick/fps?placeId=... { "services": ["Workspace"] }
// -> { ok:true, fps: { "p1": "<hex64>", "ws": "<hex64>" } } containing every instance whose
//    service_of(path) == "Workspace" (id -> stored fingerprint), and NOT s1.
#[test]
fn tick_fps_returns_instance_fps_for_requested_services() { /* ... */ }
```

Run: `cargo test --test merkle_recovery tick_fps_returns_instance_fps_for_requested_services`
Expected: FAIL (route/handler missing).

- [ ] **Step 2 — implement `fps_for_services`** in `src/tick.rs`:

```rust
pub(crate) fn fps_for_services(
    storage_root: Option<PathBuf>,
    project_key: &str,
    place: Option<&str>,
    services: &[String],
    registry: &ConnRegistry,
) -> Result<Value> {
    let storage = Storage::new(storage_root, project_key)?;
    let place_storage = resolve_place(&storage, place)?;
    registry.with_reader(&place_storage.db_path, |conn| {
        let Some(live) = read_live_state(conn)? else {
            return Ok(json!({ "ok": false, "error": "no_baseline" }));
        };
        let want: std::collections::BTreeSet<&str> = services.iter().map(String::as_str).collect();
        let mut stmt = conn.prepare(
            "SELECT instance_id, path, fingerprint FROM instances WHERE capture_id = ?",
        )?;
        let mut fps = serde_json::Map::new();
        let rows = stmt.query_map([&live.capture_id], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, Option<String>>(2)?))
        })?;
        for row in rows {
            let (id, path, fp) = row?;
            if want.contains(crate::live::service_of(&path)) {
                if let Some(fp) = fp { fps.insert(id, Value::String(fp)); }
            }
        }
        Ok(json!({ "ok": true, "fps": Value::Object(fps) }))
    })
}
```

(If `service_of` is private to `live.rs`, re-export it `pub(crate)`.) Parse the request `{ services: [..] }` with a small `parse_fps_request` (mirror `parse_tick_request`'s `serviceFingerprints` parsing).

- [ ] **Step 3 — route** in `src/http.rs` `handle_daemon_request` match (it is a read → shared pool, NOT a writer-lane path; do not add it to `routes_to_writer_lane`):

```rust
(tiny_http::Method::Post, "/studio-stud/tick/fps") => {
    let payload = read_request_json(&mut request)?;
    let services = parse_fps_request(&payload);
    let place = payload.get("placeId").and_then(Value::as_str);
    fps_for_services(storage_root.clone(), project_key, place, &services, &config.registry_conns)?
}
```

- [ ] **Step 4 — run test.** Expected: PASS.

- [ ] **Step 5 — Commit.** `git commit -m "feat(daemon): /tick/fps returns per-instance fps for services"`

### Task 3: Plugin — diff daemon fps against `instFp`, build a delta

**Files:** `plugin/StudioStud.plugin.lua` (new `Live.diffServiceFps`, `Live.collectServiceEntries`).

- [ ] **Step 1 — implement `Live.diffServiceFps(daemonFps, services)`** (pure, SelfTestable). Given `daemonFps` (`{id=hex}`) and the set of drifted `services`, return `{ upsertIds = {id,...}, removedIds = {id,...} }`:

```lua
-- daemonFps: { [id] = hex }  (what the daemon currently has for the drifted services)
-- returns ids to upsert (plugin has, differs or daemon-missing) and ids to remove (daemon has, plugin lost)
function Live.diffServiceFps(daemonFps, serviceSet)
	local upsertIds, removedIds = {}, {}
	-- plugin-side current view, restricted to the drifted services
	for id, mine in pairs(Live.instFp) do
		local svc = Live.serviceOfId(id) -- path lookup via pathByRef/instanceIdByRef
		if svc and serviceSet[svc] then
			if daemonFps[id] ~= mine then
				table.insert(upsertIds, id) -- changed or daemon-missing
			end
		end
	end
	for id, _ in pairs(daemonFps) do
		if Live.instFp[id] == nil then
			table.insert(removedIds, id) -- daemon has it, plugin no longer does
		end
	end
	return { upsertIds = upsertIds, removedIds = removedIds }
end
```

Add `Live.serviceOfId(id)` helper (resolve the instance's path → `serviceOf`). Maintain a reverse map `Live.instById[id] = Instance` (populate in `registerInstance`/walk; clear in `unregisterInstance`) so the upsert path can rebuild entries.

- [ ] **Step 2 — SelfTest** for `diffServiceFps`: given a known `instFp` + a `daemonFps` table, assert it reports the changed id as upsert, the plugin-removed id as remove, the matching id as neither.

- [ ] **Step 3 — `Live.collectServiceEntries(upsertIds, removedIds)`**: build entries for `upsertIds` via `buildUpsertedEntry(instById[id])` (skip if the instance is gone → add to removed), feed through the existing capped `Live.collectOpsFromEntries` so it respects `TICK_INLINE_THRESHOLD` and updates accumulators. Return `(upserted, removed, stamps)`.

- [ ] **Step 4 — Commit.** `git commit -m "feat(plugin): diff daemon fps to build a surgical recovery delta"`

### Task 4: Plugin — wire drift → surgical recovery (replace full re-baseline)

**Files:** `plugin/StudioStud.plugin.lua` (`Live.triggerDriftRecovery`, `Live.runTick` drift branch).

- [ ] **Step 1 — implement `Live.triggerDriftRecovery(driftServices)`** to run surgically, with the M6 fallback:

```lua
function Live.triggerDriftRecovery(driftServices)
	if Live.recoveryInProgress or Live.baselineInProgress or Live.pendingBulkRef or not Live.liveRunning then
		return false
	end
	if not driftServices or #driftServices == 0 then return false end
	Live.recoveryInProgress = true
	task.spawn(function()
		local serviceSet = {}
		for _, s in ipairs(driftServices) do serviceSet[s] = true end
		local ok, resp = ctx.transport.requestJson(
			"POST", "/studio-stud/tick/fps?" .. Live.tickQuerySuffix(),
			{ placeId = game.PlaceId, services = driftServices }
		)
		if not ok or not resp or resp.ok ~= true or type(resp.fps) ~= "table" then
			Live.recoveryInProgress = false
			Live.triggerFullBaseline("drift-fallback") -- M6 fallback
			return
		end
		local diff = Live.diffServiceFps(resp.fps, serviceSet)
		-- queue the diff onto the dirty sets; the normal capped tick loop ships it as a delta
		for _, id in ipairs(diff.upsertIds) do
			local inst = Live.instById[id]
			if inst then Live.markDirtyUpsert(inst) end
		end
		for _, id in ipairs(diff.removedIds) do
			Live.dirtyRemoved[id] = true
			Live.removedStamp[id] = (Live.removedStamp[id] or 0) + 1
		end
		Live.recoveryInProgress = false
	end)
	return true
end
```

- [ ] **Step 2 — confirm the `runTick` drift branch** already calls `Live.triggerDriftRecovery(drift)` (it does). No change needed beyond the new body.

- [ ] **Step 3 — SelfTest**: pure check that, given a `diff` with one upsert id and one removed id, the corresponding `dirtyUpsert`/`dirtyRemoved` entries are set and others are untouched (no-data-loss: pre-existing dirty entries preserved).

- [ ] **Step 4 — syntax check (lune `COMPILE OK`).**

- [ ] **Step 5 — Commit.** `git commit -m "feat(plugin): surgical drift recovery via fp diff (delta), full-baseline fallback"`

### Task 5: Daemon test — surgical recovery preserves other services & re-syncs

**Files:** `tests/merkle_recovery.rs`.

- [ ] **Step 1 — test.** Baseline services A and B. Simulate drift on A only: mutate A's stored data so its service fp diverges from a tick's reported fp. Drive: `/tick/fps {services:[A]}` → diff → a `/tick` with the resulting `ops`. Assert: A re-syncs (its service fp matches), **B's instances and fingerprint are untouched**, instance_count is correct (no wipe), revision advanced by deltas (not reset to 0 by a materialize).

Run: `cargo test --test merkle_recovery`. Expected: PASS.

- [ ] **Step 2 — Commit.** `git commit -m "test: surgical recovery re-syncs drifted service without wiping others"`

> **Phase 1 gate:** `cargo test` green; SelfTest green; drift recovery now ships a delta scoped to changed instances; full-baseline only on `no_baseline` or the M6 fallback. This is the high-value/low-cost deliverable. **Stop here unless the soak shows drift is frequent on a large service.**

---

# PHASE 2 — Merkle subtree fingerprints + descent

Only needed if Phase 1's "walk/diff the whole drifted service" is itself too heavy (a giant service like Workspace drifting often). Phase 2 lets recovery descend to the changed *subtree* without exchanging fps for the entire service.

### Task 6: Daemon schema + ingest maintenance for `subtree_fingerprint`

**Files:** `src/storage.rs` (column), `src/capture.rs` (ingest), `tests/merkle_recovery.rs`.

- [ ] **Step 1 — add column** in `src/storage.rs` schema/migration (mirror how `fingerprint`/`source_encoding` were added):
  `ensure_column(conn, "instances", "subtree_fingerprint", "TEXT")?;`

- [ ] **Step 2 — failing test.** After ingesting a small tree (root → A → {A1, A2}), assert `subtree_fingerprint(A) == selfFp(A) XOR subtree_fingerprint(A1) XOR subtree_fingerprint(A2)` and `subtree_fingerprint(root) == XOR of all selfFps`. Run → FAIL.

- [ ] **Step 3 — compute on ingest.** In the ingest path (`src/capture.rs`, where `fingerprint_acc` + `service_fingerprints` are built ~350–405): after all rows are inserted with their `fingerprint` (selfFp), compute `subtree_fingerprint` bottom-up. Implementation: build `children: HashMap<parent_id, Vec<id>>` and `self_fp: HashMap<id, [u8;32]>` from the inserted rows, then for each node compute `subtree = self XOR (XOR of children subtree)` via post-order over the parent map; `UPDATE instances SET subtree_fingerprint = ? WHERE ...`. (Roots = rows whose `parent_id` is null or not present in the capture.)

```rust
fn compute_subtree_fps(tx: &Transaction<'_>, capture_id: &str) -> Result<()> {
    // load (id, parent_id, fingerprint)
    // children: parent_id -> [id]; self: id -> [u8;32] (parse_fp_hex)
    // post-order DFS from roots; subtree[id] = self[id] xor fold(children, subtree)
    // UPDATE instances SET subtree_fingerprint = hex(subtree[id]) per id (prepare_cached)
    Ok(())
}
```

- [ ] **Step 4 — run test → PASS. Commit.** `git commit -m "feat(daemon): subtree_fingerprint column + ingest computation"`

### Task 7: Daemon — maintain `subtree_fingerprint` on delta (up the parent chain)

**Files:** `src/live.rs` (`apply_delta_tx`), `src/capture.rs` (helper), `tests/merkle_recovery.rs`.

- [ ] **Step 1 — failing test.** Baseline a tree; apply a delta that changes one deep leaf's selfFp; assert the leaf's, each ancestor's, and the root's `subtree_fingerprint` all changed by exactly the leaf's `(old XOR new)` delta, and untouched siblings/ancestph-unrelated nodes are unchanged. Run → FAIL.

- [ ] **Step 2 — implement** an up-chain XOR helper and call it in `apply_delta_tx` wherever the self fp is XORed today (next to `xor_service_fp`):

```rust
fn xor_subtree_up(tx: &Transaction<'_>, capture_id: &str, start_id: &str, delta: &[u8;32]) -> Result<()> {
    let mut cur = Some(start_id.to_string());
    let mut guard = 0;
    while let Some(id) = cur {
        let row: Option<(Option<String>, Option<String>)> = tx.query_row(
            "SELECT subtree_fingerprint, parent_id FROM instances WHERE capture_id=? AND instance_id=?",
            params![capture_id, id], |r| Ok((r.get(0)?, r.get(1)?))).optional()?;
        let Some((stf, parent_id)) = row else { break };
        let mut acc = stf.as_deref().map(parse_fp_hex).transpose()?.unwrap_or([0u8;32]);
        for i in 0..32 { acc[i] ^= delta[i]; }
        tx.execute("UPDATE instances SET subtree_fingerprint=? WHERE capture_id=? AND instance_id=?",
            params![hex_bytes(&acc), capture_id, id])?;
        cur = parent_id;
        guard += 1; if guard > 4096 { break; } // cycle guard
    }
    Ok(())
}
```

  - On **upsert**: `delta = old_self XOR new_self` (old from `read_stored_fp` before the row update; new from `fp_digest_from_entry`); call `xor_subtree_up(new_id, delta)`. On **reparent** (old parent != new), additionally move the node's *subtree* aggregate: `xor_subtree_up(old_parent_id, subtree_of(id))` to remove and `xor_subtree_up(new_parent_id, subtree_of(id))` to add — BUT order matters; see M5. For the daemon, the simplest correct sequence per delta item (items arrive depth-sorted from the plugin): compute the node's pre-update `subtree_fingerprint`, XOR it out of the OLD parent chain, update the row + self-delta into the node, then XOR the (post) subtree into the NEW parent chain.
  - On **remove**: `xor_subtree_up(parent_id, subtree_of(removed))` to remove its aggregate, then delete rows.

- [ ] **Step 3 — run test → PASS.** Add a reparent test (move a subtree across services; assert both old and new ancestor chains + roots are consistent and equal a from-scratch `compute_subtree_fps`). Commit.

### Task 8: Daemon — descent endpoint (children fps for a node)

**Files:** `src/tick.rs` (`fn merkle_children`), `src/http.rs` (route), `tests/merkle_recovery.rs`.

- [ ] **Step 1 — failing test.** `POST /tick/merkle/children { placeId, parentId | service }` → `{ ok:true, node: {id, selfFp, subtreeFp}, children: [ {id, selfFp, subtreeFp}, ... ] }`. For `service` (top), `node` is the service root row and `children` are its direct children. Run → FAIL.

- [ ] **Step 2 — implement** `merkle_children` (a reader): resolve the node row (by `parentId`, or by service name → the service-root instance), return its `fingerprint`/`subtree_fingerprint`, and `SELECT instance_id, fingerprint, subtree_fingerprint FROM instances WHERE capture_id=? AND parent_id=?`.

- [ ] **Step 3 — route** in `http.rs` (read → shared pool). Run test → PASS. Commit.

### Task 9: Plugin — maintain `subtreeFpBytes` incrementally

**Files:** `plugin/StudioStud.plugin.lua` (`Live.applyFpUpsert`/`applyFpRemove`, new `Live.subtreeFpBytes`, `Live.parentIdOf`, `Live.xorSubtreeUp`).

- [ ] **Step 1 — add state:** `Live.subtreeFpBytes = {}` (`[id]=byte[32]`), `Live.parentIdOf = {}` (`[id]=parentId|nil`). Reset both in `Live.resetFingerprints`.

- [ ] **Step 2 — `Live.xorSubtreeUp(startId, deltaBytes)`** — walk `parentIdOf` from `startId` up to root, XOR `deltaBytes` into each `subtreeFpBytes[ancestor]` (create as zero if absent). Cycle guard.

- [ ] **Step 3 — extend `applyFpUpsert(id, entry, oldPath)`** (keep the existing per-service XOR for back-compat/Phase-1 detection; ADD subtree maintenance). Pseudocode (M5 depth-sorted order guarantees parents are processed first):

```lua
local oldSelf = Live.instFp[id]                      -- may be nil (new)
local newSelf = entry.fp
local oldParent = Live.parentIdOf[id]
local newParent = entry.parentId
if oldSelf and oldParent ~= newParent then
	-- reparent: move this node's whole aggregate from old chain to new chain
	local agg = Live.subtreeFpBytes[id] or fpZeroBytes()
	Live.xorSubtreeUp(oldParent, agg)                 -- remove aggregate from OLD ancestors
	Live.parentIdOf[id] = newParent
	Live.xorSubtreeUp(newParent, agg)                 -- add aggregate to NEW ancestors
else
	Live.parentIdOf[id] = newParent
end
-- self-fp delta into this node + all ancestors (subtreeFp includes self)
local delta = fpZeroBytes()
if oldSelf then fpXorBytes(delta, fpHexToBytes(oldSelf)) end
fpXorBytes(delta, fpHexToBytes(newSelf))
Live.xorSubtreeUp(id, delta)                          -- node + ancestors
Live.instFp[id] = newSelf
```

  (`xorSubtreeUp(id, ...)` starts AT `id`, so the node's own `subtreeFpBytes` updates too.)

- [ ] **Step 4 — extend `applyFpRemove(id, path)`**: `Live.xorSubtreeUp(Live.parentIdOf[id], Live.subtreeFpBytes[id] or fpZeroBytes())` (remove aggregate from ancestors), then clear `subtreeFpBytes[id]`, `parentIdOf[id]`, `instFp[id]`.

- [ ] **Step 5 — SelfTest (the critical invariants):**
  - Build A→{A1,A2}: `subtreeFpBytes[A] == selfFp(A) XOR selfFp(A1) XOR selfFp(A2)`.
  - Change A1's selfFp: A and root change by exactly A1's delta; A2 unchanged.
  - Remove A2: A/root drop A2's contribution.
  - Reparent A1 from A to B: A's chain loses A1's aggregate, B's gains it; root unchanged (XOR moved within tree). Then assert `subtreeFpBytes[root] == XOR of all current selfFps` (the global invariant) after each op.

- [ ] **Step 6 — lune `COMPILE OK`; Commit.** `git commit -m "feat(plugin): incremental subtree fingerprints (XOR-Merkle up parent chain)"`

### Task 10: Plugin — descent driver + wire Merkle recovery

**Files:** `plugin/StudioStud.plugin.lua` (`Live.descendDrift`, `Live.triggerDriftRecovery`).

- [ ] **Step 1 — `Live.descendDrift(driftServices)`** (orchestration; bounded rounds, M6 fallback). For each drifted service, BFS using `/tick/merkle/children`:

```
queue = drifted service nodes
diffUpserts, diffRemoves = {}, {}
rounds = 0
while queue not empty and rounds < MAX_ROUNDS:
  node = pop(queue); rounds += 1
  resp = POST /tick/merkle/children { node }      -- daemon's children {id, selfFp, subtreeFp}
  mine = { childId -> {selfFp=instFp[childId], subtreeFp=subtreeFpBytes[childId]} } from live children of node
  -- node's own self changed?
  if resp.node.selfFp ~= instFp[node]: diffUpserts += node
  for each daemon child dc:
     mc = mine[dc.id]
     if mc == nil: diffRemoves += dc.id                     -- plugin removed it
     elseif mc.subtreeFp != dc.subtreeFp: push dc.id        -- descend
  for each live child lc not in daemon's set: diffUpserts += whole subtree of lc   -- plugin added it
if rounds >= MAX_ROUNDS: return false  -- give up → caller falls back to full baseline
queue diffUpserts/diffRemoves onto dirty sets (same as Phase 1 Task 4 Step 1)
return true
```

  (Compare `subtreeFp` as hex strings; convert `subtreeFpBytes` via `fpBytesToHex`.)

- [ ] **Step 2 — switch `triggerDriftRecovery`** to try `Live.descendDrift(driftServices)`; on `false` (gave up / request failed) call `Live.triggerFullBaseline("drift-fallback")`. Keep `recoveryInProgress` guard.

- [ ] **Step 3 — SelfTest** for the pure diff-merge step (given simulated daemon children responses, the right ids are queued; dirty preserved). Full descent is exercised in the Studio gate.

- [ ] **Step 4 — lune `COMPILE OK`; Commit.** `git commit -m "feat(plugin): Merkle descent drift recovery with full-baseline fallback"`

> **Phase 2 gate:** `cargo test` green; SelfTest green (subtree invariants + diff merge). Studio soak: force localized drift in a large service → recovery descends and ships a small delta touching only the changed subtree; other subtrees and services untouched; if descent can't converge it falls back to a full baseline (no regression).

---

## Rollout / sequencing
- **Task 1 (yield)** lands now (independent, tiny) — fold into the current Phase-5 branch or its own.
- **Phase 1** is the recommended drift-recovery upgrade; build it when the soak shows full re-baselines firing often enough to matter.
- **Phase 2** is gated on Phase 1 proving insufficient (a giant service drifting often). It is the heaviest piece (continuous subtree maintenance incl. reparent) — do not build speculatively. Decide from drift telemetry: frequency, which service, and changed-subtree size.

## Out of scope
- Hash-Merkle (order-sensitive) — XOR-Merkle (M1) is sufficient because `selfFp` already encodes path/sibling order.
- Replacing the `service_fingerprints` table with `subtree_fingerprint` of service-root rows (a possible later cleanup; keep both for now).
- Changing steady-state tick traffic (M2 — unchanged).

---

## Self-review

**Spec coverage:** Q1 yield fix → Task 1. "Smaller deltas on drift" → Phase 1 (surgical fp-diff delta) + Phase 2 (Merkle descent). Both ship via the existing delta path (M3, no partial `materialize` → no wipe). Fallback to full baseline preserved (M6). Detection unchanged (M2). ✓

**Placeholder scan:** Core algorithms (yield loop, `fps_for_services`, `xor_subtree_up`, `xorSubtreeUp`, `applyFpUpsert` subtree extension, `descendDrift`) are shown in code. Daemon `compute_subtree_fps` and the descent orchestration are specified with concrete signatures + the exact XOR rules; an executing engineer fills in the loop bodies from the given recurrences (acceptable for a forward-looking, soak-gated plan — flagged, not vague). Tests state exact assertions. ✓

**Type/name consistency:** Plugin uses `Live.instFp` (hex), `Live.subtreeFpBytes` (byte[32]), `Live.parentIdOf`, `Live.instById`, `fpXorBytes/fpHexToBytes/fpBytesToHex/fpZeroBytes`, `Live.serviceOf`. Daemon uses `subtree_fingerprint` column, `parse_fp_hex`, `hex_bytes`, `read_stored_fp`, `service_of`, `fp_digest_from_entry`. Endpoints: `/tick/fps`, `/tick/merkle/children` (both reads, shared pool, not writer-lane). Consistent across tasks. ✓
