---
name: Studio Stud Platform — Stage 2 (Live incremental capture + single live DB per place)
overview: Migrate storage from the multi-capture pointer model (latest.json/previous.json + Comparison report) to ONE always-current live SQLite DB per place, add an event-driven incremental delta protocol (/studio-stud/live/*) keyed by stable session instance IDs (GetDebugId), wire Studio signal listeners + debounce in the plugin, apply deltas as single transactions in the daemon, and guarantee no data loss via a fingerprinted, layered drift backstop that converges the delta-built DB byte-for-byte with a fresh full capture WITHOUT an intervening verify. Activates the inert Stage 1 live-capture/debounce settings.
todos: []
isProject: false
---

# Studio Stud Platform — Stage 2 Execution Plan (Live incremental capture + single live DB per place)

Status: READY TO EXECUTE (revised after technical review — see §0 decision 0). Source of truth:
`docs/studio-stud-platform-design.md` §5.6 (single live DB), §5.7 (AI-first output), §6 / §6.1 / §6.3
(live state model + deltas + drift + fingerprint), §11 (Stage 2), §14 (D4, D7), Appendix D (live protocol
shapes), Appendix E (single-live-DB schema). This plan executes the design; it does not re-litigate it.

This is the largest stage so far: it touches the daemon storage model, adds a new HTTP namespace, and adds
live signal machinery to the plugin. Do it in the workstream order below; each workstream ends with a green
build + tests so regressions stay bisectable.

Scope is exactly the Stage 2 deliverables and nothing more. Do **NOT** introduce any Stage 3+ surface: no
`/studio-stud/write/*`, no `.studio-stud/policy.json`, no write token / handshake, no `full-moon`, no
`rbx-dom`, no repo index / Rojo projection, no FS→Studio apply, no multi-developer concurrency / `flctl
sync` / CAS / 3-way merge / per-file base ledger, no Boat Configurator panel. Multi-developer / Team Create
concerns (replicated-edit capture, claims, conflict surfacing) are **Stage 6** — Stage 2 is
single-developer live capture only.

---

## 0. Locked decisions (do not revisit)

0. **GATING DECISION — deltas converge ALONE (no intervening verify).** The correctness contract is that
   the delta-built live DB converges byte-identical to a fresh full capture **without** running a
   `/live/verify` first. Verify is only the no-data-loss backstop for missed signals, not a required step
   to reach convergence. This is what forces the delta op + neighbor-dirtying design in decision 1b and §4.1,
   and it is what the design's no-data-loss bar (§6/§6.3) and "deltas measurably cheaper" goal both imply.
   The structural convergence test in §8.1/B3 (add a child, remove one of two duplicate-named siblings,
   reparent a subtree → dump must equal a fresh full ingest, no verify between) is the proof and is
   REQUIRED to pass.

1. **Stable session instance IDs via `GetDebugId(0)` (load-bearing).** Today the snapshot `id` is an
   ordinal `("%s:%06d"):format(inst.ClassName, ordinal)` (plugin line ~1161). Ordinals are
   **position-dependent**: inserting/removing any earlier instance shifts every later id, so they are NOT
   delta-safe and cannot converge. Stage 2 switches the capture id to `inst:GetDebugId(0)` (a string unique
   per instance and **stable for the instance's lifetime within a Studio session**, including across a
   re-walk and across reparents). A fresh full re-walk in the same session assigns the **same** ids, so the
   delta-built DB and a fresh full capture are comparable byte-for-byte.
   - The Rust side treats `id` as an opaque string, so this change does **not** break the existing frozen
     fixture/goldens (they keep ordinal ids and still ingest).
   - **Confirm before relying on it** (Workstream D + risks): `GetDebugId` is available at plugin security
     (the plugin runs at plugin security; command-bar/plugins can call it), returns a non-empty unique
     string, and is stable across a re-walk and a reparent within one session. This is verified by a
     dedicated self-test (Workstream E, M4) — NOT just the manual pass. Note: `GetDebugId` differs per
     Team-Create client; that only matters in Stage 6 and is out of scope here.

1b. **One `upserted` op carrying FULL structural entries (replaces split added/changed).** Because
   `childCount` (on the parent), `siblingIndex` / `duplicateSiblingName` / `path` segment (on same-name
   siblings) are **neighbor-dependent** in `collectBaseInstances`, a structural change must re-emit the full
   row for every affected instance, not just the one that was added/removed. The delta therefore carries
   `{ upserted: [<full instance entry>], removed: [<id>] }` where each upserted entry has the SAME fields a
   baseline row has (id, parentId, path, name, className, depth, childCount, siblingIndex,
   duplicateSiblingName, properties, attributes, tags). The daemon upsert reuses `ingest_sqlite`'s
   per-instance write logic verbatim. (There is no separate `changed` op — a property-only change is just an
   upsert of that one instance's full current row.)
   - **`path` cascades — the rename/move trap (load-bearing for decision 0).** A node's `path` segment is
     `Name[siblingIndex]`, so changing a node's **`Name`** or **`Parent`** changes the `path` of that node
     AND of **every descendant** (and the sibling-group fields at the old and new parent). Crucially, `Name`
     is NOT in `CLASS_PROPERTIES`, and an **intra-root** reparent (the node stays under the same captured
     root) fires NO `Descendant*` signal for the descendants — so neither is covered by the structural
     signals alone. Therefore the plugin MUST additionally track `Name` and ancestry per instance and, on
     such a change, re-emit upserts for the node + its **entire subtree** + the affected sibling groups at
     both the old and new parent (D3). Rename and intra-root move are first-class convergence cases, not
     edge cases.

2. **Full capture == live baseline (one ingest model).** The existing chunked upload
   (`/studio-stud/capture/{start,body,chunk,complete}`) IS the baseline/full capture; on `complete` it now
   **replaces the current live state** in the single live DB. CLI `studio-stud capture` triggers a full
   baseline exactly as today. Do **not** add a separate `/studio-stud/live/baseline` endpoint.

3. **Single live DB per place; retire the pointer + Comparison model (D7).** Drop `latest.json` /
   `previous.json`, `Pointer`, `promote_pointers`, `prune_old_captures`, `prune_sqlite_captures`,
   `retained_capture_ids`, `previous_capture_for_place`, the `syncs/<captureId>/` per-capture dirs, and the
   `ReportView::Comparison` / `comparison_json` / `render_comparison` path. Add a `live_state` table (single
   row). WAL is already on (`init_schema` ~line 291) — keep it. Retain exactly ONE raw snapshot per place
   for cold-start/debug (`<place_dir>/baseline.json.gz`), replaced on each baseline; no history.

4. **D7 sub-question — no delta journal in Stage 2.** The live DB is the always-current truth; change
   reporting comes from the diff engine in later stages. Do NOT build a `delta_journal` ring now.

5. **D4 — full coverage, with a measured listener budget + documented fallback.** Live capture mirrors the
   FULL DataModel (no narrowing). Property coverage is the curated `CLASS_PROPERTIES` set (live is never
   *worse* than today). The plugin's PRIMARY path is per-instance `GetPropertyChangedSignal` on the curated
   set plus structural/attribute/tag/selection/waypoint signals (decision 5 detail in §5 D3). BUT the design
   says this is the benchmarked, fallback-able choice — so Stage 2 has a **measurement gate** (Workstream D
   exit): record the connection count and the baseline→signals-connected wall-clock time on a realistic
   place (Example Place A). If connection count or connect time is unacceptable (budget below), fall back to
   the documented coarse mode: connect ONLY structural (`DescendantAdded/Removing`) + `Selection` +
   `ChangeHistoryService` waypoint signals, and cover property changes via targeted rescans of dirty/selected
   instances on the debounce flush. Correctness is identical either way because of the drift verify.
   - **Budget (soft, record actuals):** baseline→connected under ~2 s and under ~50k live connections on
     Example Place A. If exceeded, ship coarse mode by default and note it.
   - `liveCaptureScope` (policy) is NOT implemented in Stage 2 (no policy file until Stage 3); default is
     full coverage = all captured roots.

6. **Trust model for live endpoints: localhost, unauthenticated.** `/studio-stud/live/*` touches only the
   local DB, never the repo, so it is NOT token-gated (tokens arrive in Stage 3). Same trust model as
   `/capture/*` today.

7. **Activate the inert Stage 1 settings.** `liveCaptureEnabled` (default true) now gates whether the plugin
   connects live signals; `debounceMs` (default 300) now controls the dirty-set flush timer. No settings
   migration — the keys already persist (Stage 1 §A2).

8. **Testability without Studio is mandatory.** Every correctness guarantee (convergence, no-data-loss,
   delta application, drift detection) MUST be runnable from `cargo test` against fixtures with NO live
   Studio, via hidden CLI subcommands driving the daemon-side live engine against `--storage-root`. Studio
   is only needed for the manual end-to-end pass in §10 and the GetDebugId/listener self-tests in Workstream E.

9. This plan is saved under `.cursor/plans/` matching the existing `*_<hex>.plan.md` convention.

---

## 1. Hard guardrails / definition of done

- **No data loss + deltas converge alone (trust bar).** For any sequence of edits — including add, remove,
  reparent, and duplicate-sibling churn — the delta-built live DB converges to a fresh full capture,
  byte-identical (modulo the volatile fields in §7), with NO intervening verify. The drift verify is the
  net for *missed signals*, not a crutch for an incomplete delta protocol.
- **Deltas measurably cheaper than full captures.** The honest, primary win is Studio-walk-side (no full
  re-walk) + transport-side (no full re-upload); the daemon-side bench must also not regress (decision via
  incremental `class_counts`; see M3/§5 F).
- **AI-first output discipline preserved (§5.7).** `analyze`/`query` still emit bounded compact JSON with
  `returned`/`total`/`limit`/`truncated`, stable ids, hashes/counts not raw bodies. No always-on AI
  behavior, no per-delta AI notification, no new tokened surface. Silent to AI until a query runs.
- **Reads never block on an in-flight delta** (WAL, single writer = daemon). Indexed columns unchanged.
- **Plugin shell stays generic.** All live machinery lives inside the Capture/Query panel build (or a
  panel-local `Live` sub-table), pinned to the build instance like the Stage 1 poll loop. No project words.
- **No connection leaks; no Luau register-pressure regression** (`.cursor/rules/luau-files.mdc`). Re-check
  after the plugin workstream.
- **Reconnect re-baselines correctly.** On (re)connect the plugin runs one full baseline that fully replaces
  live state; stale state from a prior session never lingers.

---

## 2. Current state (verified facts, do not re-discover)

- **Daemon modules** (Stage 0 split): `tools/studio_stud/src/{lib,util,storage,capture,output,http,analyze,
  query,cli,bench}.rs`. No `live.rs` yet. Stage 2 creates `live.rs`.
- **`serde_json` has NO `preserve_order`** (`Cargo.toml`): `Value::Object` is a `BTreeMap`, so serializing a
  `Value` emits **sorted keys deterministically**. This is the canonicalization primitive for the
  fingerprint (§3.3) — round-tripping `property_json`/attributes through `serde_json::Value` normalizes key
  order for free.
- **Storage today** (`storage.rs`): `PlaceStorage` has `latest_path`/`previous_path`; instance tables
  partitioned by `capture_id`; `init_schema` (~line 288) sets `PRAGMA journal_mode = WAL`; pointer model via
  `Pointer`/`promote_pointers`/`prune_*`/`read_pointer`; `resolve_place` (no-arg) scans for `latest.json`;
  `latest_capture_for_place`/`previous_capture_for_place`/`capture_by_id` → `CaptureMeta`.
- **Capture/ingest today** (`capture.rs`): `materialize_snapshot` writes `syncs/<id>/raw.json.gz` +
  `metadata.json`, `ingest_sqlite` (full delete-then-insert per `capture_id`; recomputes
  `class_counts`/`keyword_hits`/`critical_presence`/`findings` via `FindingState`), promote_pointers, prune.
  `capture_meta` derives capture_id from `sync.syncId` or timestamp+hash. Snapshot `id` is opaque Rust-side.
- **HTTP today** (`http.rs`): `DaemonState{pending_requests,active_request_id,uploads,completions}`; routes
  ping/manifest/capture(request|start|body|chunk|complete|status) + legacy aliases (`/request-sync`,
  `/live-sync/*` — Stage 0 §2: do not drop any alias); `complete_daemon_upload`→`materialize_snapshot`; 404
  fallback. `daemon_json` is the CLI→daemon client. `UploadState{body,chunks}` has no `kind`.
- **Read/analyze today**: `analyze.rs` resolves latest+previous, renders `context|comparison|findings|
  critical`, emits `captureId`. `query.rs` resolves `latest.capture_id`, all read SQL `WHERE capture_id = ?`.
  `output.rs::pointer_compact_json` formats pointers for `status`. `cli.rs::cmd_status` reads pointers.
- **Plugin today** (`tools/studio_stud/plugin/StudioStud.plugin.lua`, single composed file from Stage 1):
  `CapturePanel.build` (~line 923) holds the verbatim snapshot builder (`Capture.serialize*`,
  `getPropertyNames`, `readProperties/Attributes/Tags`, `getRootEntries`, `collectBaseInstances` with the
  ordinal id at ~line 1161, `buildSnapshot`), `syncFn` (chunked upload), `statusFn`, the build-instance-
  pinned 2s poll loop (~line 1382, `running` upvalue + post-`task.wait` guard), `destroy` sets running=false.
  Settings `liveCaptureEnabled`(default true)/`debounceMs`(default 300) exist+persist but are INERT.
- **Tests** (`tests/golden_outputs.rs`): ingests `tests/fixtures/baseline_capture.json`; golden cases incl.
  `analyze_comparison`; `normalize_json` blanks `generatedAtUtc`/`createdAtUtc`/`daemon`. Plus a `bench
  --json` shape test.
- **Constants** (`util.rs`): `MAX_CHUNK_BYTES=900_000`, `SCHEMA_VERSION=1`, `PROTOCOL_VERSION=1`,
  `MIN_PLUGIN_PROTOCOL_VERSION=1`, `make_id`, `now_utc`, `hex_bytes`.

---

## 3. Target storage model (single live DB per place)

One DB per place (`<place_dir>/syncs.db`), WAL, single writer (daemon). The current state lives in the
existing instance tables under a **single current `capture_id`** (keep the column to avoid rewriting all
read SQL); `live_state` is the authority for which id is current + the live metadata.

### 3.1 New `live_state` table (add in `init_schema`)
```sql
CREATE TABLE IF NOT EXISTS live_state (
    id INTEGER PRIMARY KEY CHECK (id = 1),   -- singleton row
    capture_id TEXT NOT NULL,                -- current/live capture id (== baseline id)
    place_id TEXT NOT NULL,
    place_key TEXT NOT NULL,
    place_name TEXT NOT NULL,
    game_id INTEGER,
    revision INTEGER NOT NULL,               -- 0 on baseline (reset); +1 per applied delta; bumped by verify-correction
    baseline_at_utc TEXT NOT NULL,
    updated_at_utc TEXT NOT NULL,
    baseline_hash TEXT NOT NULL,             -- raw_sha256 of the baseline snapshot
    fingerprint TEXT NOT NULL,               -- order-independent content hash of current state (§3.3)
    instance_count INTEGER NOT NULL
);
```
- Bump `SCHEMA_VERSION` → `2` (in `util.rs` + the `meta` insert). `init_schema` stays idempotent/additive
  (`CREATE TABLE IF NOT EXISTS` + `ensure_column`); it tolerates a pre-Stage-2 DB by creating `live_state`
  if missing. A discovered-but-un-baselined DB (no `live_state` row) is handled per m3 (friendly error).

### 3.2 Baseline (full capture) write path — replaces `materialize_snapshot` behavior
1. Open `syncs.db`, `init_schema`.
2. In ONE transaction: **unconditionally `DELETE FROM` every instance/aggregate/findings table** (one place
   per DB, so no `WHERE capture_id` needed — this guarantees a fresh `capture_id` can't orphan old rows),
   then insert the new snapshot's rows under a fresh `capture_id`. Reuse `ingest_sqlite`'s row/aggregate/
   findings logic; extract a reusable `ingest_rows(tx, snapshot, capture_id)` and an
   `upsert_instance(tx, capture_id, entry)` so deltas/verify reuse the exact write + aggregate logic.
   `upsert_instance` MUST delete-then-insert ALL per-id rows for that instance — `instances`,
   `instance_properties`, `instance_attributes`, `instance_tags`, AND the per-id `keyword_hits` row
   (keyword match depends on path/name/class, so a stale hit must not survive an upsert).
3. Compute `fingerprint` (§3.3) over the inserted state via `fingerprint_state(conn, capture_id)`.
4. Upsert the singleton `live_state` row (`revision = 0`).
5. Write the single retained raw snapshot to `<place_dir>/baseline.json.gz` (replace).
6. Remove pointer/staging/per-capture-dir/prune machinery entirely.

### 3.3 Content fingerprint (`fingerprint`) — ONE canonicalization, always from DB rows
A stable, order-independent hash of the whole current state so drift checks are O(1) in the common case
(§6.3). It MUST be computed identically on baseline, after each delta, and for a verify snapshot, so they
compare equal. To eliminate representation drift (review M1):

- **Single source of truth = DB rows.** `fingerprint_state(conn, capture_id)` reads each instance and its
  property/attribute/tag rows and builds a canonical `serde_json::Value` per instance with a FIXED field
  order: `{ id, parentId, path, name, className, depth, childCount, siblingIndex, duplicateSiblingName,
  properties, attributes, tags }`. `properties`/`attributes` are reconstructed as `Value::Object` (BTreeMap
  ⇒ sorted keys; §2); each property value is the parsed `value_json` (so number/string formatting matches
  whatever serde_json produced at ingest); `tags` is a sorted array. Exclude derived columns
  (`search_text`, `*_norm`, `property_json` blob).
- `instance_hash = sha256(serde_json::to_string(canonical_value))` (32 bytes).
- **Order-independent fold:** XOR the 32-byte digests of all instances together, then `hex_bytes`. XOR is
  commutative/associative ⇒ row-order-independent. (Distinct instances never collide to zero because each
  canonical value embeds the unique `id` ⇒ distinct digests; review's duplicate-XOR concern does not apply.)
- **Verify computes via the same function:** `/live/verify` ingests the submitted snapshot into a **staging
  capture_id** (temp rows) and calls `fingerprint_state` on it, so baseline/delta/verify can never diverge
  in representation (review M1).
- **Incremental maintenance on delta:** before mutating a row, re-read it and `fingerprint_instance` it to
  get the OLD digest to XOR-out; after writing the new row, XOR-in the new digest. Removed ⇒ XOR-out only;
  upserted ⇒ XOR-out old (if present) then XOR-in new. Store the rolling 32-byte accumulator (hex) in
  `live_state.fingerprint`. A baseline recomputes from scratch.

---

## 4. Live protocol (new `/studio-stud/live/*`)

Add to `handle_daemon_request` (keep all existing capture routes + aliases verbatim; unknown still 404s).

### 4.1 `POST /studio-stud/live/delta`
```jsonc
{
  "placeId": "100000000000001",
  "baseRevision": 42,
  "ops": {
    "upserted": [ { "id": "...", "parentId": "...", "path": "...", "name": "...", "className": "...",
                    "depth": 3, "childCount": 0, "siblingIndex": 1, "duplicateSiblingName": false,
                    "properties": {}, "attributes": {}, "tags": [] } ],
    "removed": [ "id1", "id2" ]
  }
}
```
Daemon (`live.rs::apply_delta`):
- Open DB, `init_schema`, read `live_state`. No row ⇒ `{ ok:false, error:"no_baseline" }`.
- **Revision guard:** `baseRevision` present and `!= live_state.revision` ⇒
  `{ ok:false, error:"revision_mismatch", revision:<current> }` (plugin re-baselines). (Single-dev recovery,
  NOT the Stage-6 CAS.)
- In ONE transaction (rollback on any error ⇒ DB + revision unchanged):
  - For each `removed` id: re-read + XOR-out its fingerprint, then delete the instance + its property/
    attribute/tag/keyword rows.
  - For each `upserted` entry: XOR-out old digest if the id exists, delete-then-insert the instance +
    property/attribute/tag rows via the shared `upsert_instance`, XOR-in the new digest.
  - **Aggregate maintenance:**
    - `class_counts`: update **incrementally** (±1 per class for removed/added; on a class change for an
      existing id, −1 old class +1 new) — cheap and keeps the daemon-side delta genuinely cheaper (M3).
    - `keyword_hits`: per-id; handled inside `upsert_instance` (delete-then-insert the id's row) and by the
      `removed` delete path — NOT a global recompute.
    - `critical_presence`: these are 8 **GLOBAL** booleans derived from `path_blob.contains(critical)` over
      ALL instances (`capture.rs` ~lines 328–337). They CANNOT be maintained "per touched id" — a delete can
      only be resolved against the whole path set, so a stale `present:true` would survive. **Recompute all 8
      globally each delta** (cheap: 8 substring checks over current paths) — group with `findings`, not with
      the per-id aggregates.
    - `findings`: recompute from the current rows (depends on cross-instance state like duplicate siblings).
      This is the one O(current-state) part — **document that findings (and the 8 critical_presence checks)
      are the O(n) cost**; acceptable, since the headline win is Studio/transport-side.
- Bump `revision`, set `updated_at_utc`, update `instance_count` + `fingerprint`.
- Respond `{ ok:true, revision:<new>, fingerprint:<hex>, instanceCount:<n> }`.
- Send deltas as a single JSON body; only if a delta exceeds `MAX_CHUNK_BYTES` (rare) fall back to the
  dedicated verify-style chunk routes (§4.2) with a delta marker — but the common path is one POST.

### 4.2 `/studio-stud/live/verify/{start,body,chunk,complete}` (drift backstop, full) — DEDICATED routes
Do NOT overload the capture completer (review M6). Add a parallel chunked-upload family mirroring
`/capture/*` but routed to `verify_drift`:
- `POST /studio-stud/live/verify/start` → `{ ok, syncId, maxChunkBytes }` (own upload slot).
- `POST /studio-stud/live/verify/body?syncId=` and `/chunk?syncId=&index=` → store bytes.
- `POST /studio-stud/live/verify/complete` → assemble, decode, `verify_drift`.

`live.rs::verify_drift(snapshot)`:
- Ingest the submitted snapshot into a **staging capture_id**; compute its `fingerprint_state`. If it equals
  `live_state.fingerprint` ⇒ drop staging, respond `{ ok:true, drift:[], corrected:0, revision:<unchanged> }`
  (O(1)-ish happy path; the plugin usually avoids even uploading via §4.3).
- On mismatch: row-level diff staging-vs-current ⇒ diverging ids = `drift`. **Correct** by promoting staging
  to the authoritative current state (it is a fresh full capture = ground truth). Do the ingest-to-staging →
  diff → promote **in one transaction**: on promotion, **delete the old current `capture_id` partition
  entirely** (unconditional `DELETE FROM`, same orphan-avoidance as baseline m3), repoint `live_state` to the
  staging `capture_id`, recompute aggregates + fingerprint, bump `revision`. Respond `{ ok:true,
  drift:[ids...], corrected:<n>, revision:<new> }`. Never leave the DB diverged or half-promoted. (Staging
  rows live under a different `capture_id`, so they never pollute reads — which always filter by the current
  id — until the atomic swap completes.)

### 4.3 `GET /studio-stud/live/fingerprint`
Cheap pre-check: `{ ok:true, revision, fingerprint, instanceCount }` from `live_state`. The plugin computes
the same fingerprint over the live tree and, on mismatch, triggers a full `/live/verify/*`.

> Endpoint summary: add `live/delta` (POST), `live/verify/{start,body,chunk,complete}`, `live/fingerprint`
> (GET). No `live/baseline` (baseline reuses `/capture/*`, decision 2). The capture completer is untouched.

---

## 5. Workstream breakdown (dependency order)

Build + `cargo test` green after each. Commit per workstream.

### Workstream A — Storage migration to single live DB (daemon, no deltas yet)
A1. `storage.rs`: add `live_state` to `init_schema`; bump `SCHEMA_VERSION`→2. Add `LiveState` struct +
   `read_live_state`/`write_live_state` (upsert singleton). Remove `Pointer`, `latest_path`/`previous_path`,
   `promote_pointers`, `prune_old_captures`, `prune_sqlite_captures`, `retained_capture_ids`, `read_pointer`,
   `previous_capture_for_place`. Add `<place_dir>/baseline.json.gz` as the single raw path. Change
   `resolve_place` (no-arg) to discover places by presence of `syncs.db` (or a `live_state` row), not
   `latest.json`. Repurpose `latest_capture_for_place` → `current_state(conn) -> Result<LiveState>`.
A2. `capture.rs`: rewrite `materialize_snapshot` to §3.2 (unconditional table clear + fresh-id full ingest,
   fingerprint, `live_state` revision 0, write `baseline.json.gz`, no staging/pointer/prune). Extract
   `ingest_rows`/`upsert_instance` for reuse. Add `fingerprint_state`/`fingerprint_instance` (§3.3) here or
   in `live.rs` and share.
A3. `analyze.rs` + `cli.rs`: remove `ReportView::Comparison`, `comparison_json`, `render_comparison`,
   `previous` plumbing. Resolve only the current `LiveState`. Keep `context`/`findings`/`critical`/`focus`
   shapes unchanged (still emit `captureId` from `live_state.capture_id`). **Do NOT add `revision` to the
   analyze payload** (would churn the golden unless normalized) — leave analyze output byte-identical.
A4. `query.rs`: replace `latest_capture_for_place` with the current-state resolver; keep all `WHERE
   capture_id = ?` (now always the single current id). No shape change.
A5. `output.rs` + `cli.rs::cmd_status`: replace `pointer_compact_json` with `live_state_compact_json`
   (placeId/placeKey/captureId/revision/updatedAtUtc/instanceCount). `status` lists each place's
   `live_state`. `--paths` shows `db` + `baseline.json.gz`.
A6. **Goldens (corrected scope — review m1):**
   - Delete the `analyze_comparison` golden case + `tests/golden/analyze_comparison.txt`.
   - Regenerate ONLY `status_json` (pointer→live_state shape changed). Add `revision` to `normalize_json` if
     it appears and is volatile (a single baseline ingest gives revision 0, so it is deterministic — only
     normalize if needed).
   - **`analyze_context_findings_critical` and all `query_*` goldens MUST stay byte-identical** (captureId
     derives unchanged from the fixture's `sync.syncId`; `query_*` carry no capture_id). Treat ANY diff in
     these as a real regression, not an expected churn — assert equality as a guard.
   - Unit tests: `live_state` round-trip; fingerprint determinism (same snapshot → same hash; shuffle the
     instances array → identical hash); baseline replace (second baseline fully replaces; instance_count
     correct; zero leftover rows).

**Exit A:** `cargo test` green; capture/ingest/analyze/query/status work on the single live DB; Comparison
gone; only `status_json` regenerated; no pointer files written.

### Workstream B — Live delta engine (daemon) + hidden CLI drivers
B1. Create `tools/studio_stud/src/live.rs`; `mod live;` in `lib.rs`. Implement `apply_delta` (§4.1),
   `verify_drift` (§4.2), and the shared fingerprint helpers. Single-transaction apply; revision guard;
   incremental fingerprint + incremental `class_counts`.
B2. Hidden CLI (`hide = true`, like `bench`) against `--storage-root` (decision 8):
   - `live-delta --raw <delta.json> [--place <id>]` → `apply_delta`, prints `{ok,revision,...}`.
   - `live-verify --raw <fullsnapshot.json>` → `verify_drift`, prints `{ok,drift,corrected,...}`.
   - `live-dump <place>` → canonical deterministic JSON of current state. **Shape (review o1):** two top-level
     blocks — `meta` (capture_id, baseline_hash, revision, timestamps; the volatile §7 fields) and `state`
     (sorted instances with sorted props/attrs/tags) + `fingerprint`. Convergence comparison = equality of
     `state` + `fingerprint` only; `meta` is ignored. (Baseline is drivable via existing `ingest`.)
B3. `tests/live_convergence.rs`:
   - **Structural convergence (THE gate, decision 0):** `ingest baseline.json` → one or more `live-delta`s
     covering every neighbor-dependent + path-cascade case: (a) adds a child (parent childCount changes), (b)
     removes one of two duplicate-named siblings (survivor's duplicateSiblingName/siblingIndex/path change),
     (c) reparents a subtree OUT of/into a root (remove+add), (d) **renames a node that HAS descendants**
     (path cascades to the whole subtree + old/new sibling groups), (e) **intra-root moves a subtree** (node
     stays under the same root — no `Descendant*` signal; descendants' paths cascade). Then `live-dump`;
     separately `ingest full_after.json` → `live-dump`; assert `state` + `fingerprint` equal **with NO verify
     between**. Since these deltas are what the daemon receives, the test encodes the delta payloads the
     PLUGIN would emit for (a)–(e) — so a wrong daemon apply OR a wrong delta shape fails here. Build
     `full_after` by applying the same ops in-test (or assert a guard that fixture == baseline+deltas) so the
     fixture can't silently drift (review m7).
     - The plugin-side correctness of *producing* those (d)/(e) delta payloads (Name + AncestryChanged
       handling, subtree dirtying) is additionally covered by the Workstream E self-tests, since it can't be
       exercised from the daemon CLI alone.
   - **No-data-loss / drift recovery:** baseline → a delta that deliberately OMITS one change (missed signal)
     → `live-verify full_after.json` ⇒ `drift` non-empty, `corrected>0`; subsequent `live-dump` == fresh full
     ingest.
   - **Revision guard:** stale `baseRevision` ⇒ `revision_mismatch`.
   - **Fingerprint fast path:** `live-verify` with the current state ⇒ `drift:[]`, `corrected:0`, revision
     unchanged.
   - **Fingerprint cross-representation:** baseline fingerprint == verify fingerprint of the same snapshot ==
     incremental fingerprint after a no-op-equivalent upsert round-trip (review M1).
   - **Transactional rollback:** a delta with a malformed op leaves DB + revision unchanged.
B4. Fixtures `tests/fixtures/live/`: small deterministic `baseline.json` (fixed string ids incl. a parent
   with two duplicate-named children and a movable subtree), `delta_*.json`, `full_after.json`, +
   `README.md` documenting their relationship. Hand-authored, fixed ids, reviewable.

**Exit B:** all B3 tests green (the structural-convergence test passes WITHOUT a verify); `live.rs` unit
tests for XOR-fold and per-id upsert/delete/aggregate pass.

### Workstream C — HTTP wiring for live endpoints (daemon)
C1. `http.rs`: add `(Post, "/studio-stud/live/delta")` (reads JSON → `apply_delta`); the dedicated
   `(Post, "/studio-stud/live/verify/{start,body,chunk,complete}")` family (own upload slots, mirrors
   `/capture/*` but routes to `verify_drift` — do NOT touch `complete_daemon_upload`); and
   `(Get, "/studio-stud/live/fingerprint")`. Keep ALL existing routes/aliases + the 404 fallback unchanged.
C2. **Regression test (required):** a capture round-trip via `/capture/*` still ingests byte-identically
   after the HTTP additions (proves the dedicated verify routes didn't perturb the capture path). Optionally
   a `serve`-on-ephemeral-port smoke test that POSTs a delta and asserts the live DB updated; if heavy/flaky,
   rely on the B3 CLI tests for correctness and keep HTTP coverage to the capture regression + a delta smoke.

**Exit C:** live endpoints reachable; manifest/protocol unchanged; capture round-trip regression green.

### Workstream D — Plugin: stable ids, signal listeners, dirty set, debounce, delta emit
D1. **Stable ids + living map.** Change the id assignment in `collectBaseInstances` (~line 1161) to
   `inst:GetDebugId(0)`. Keep `instanceIdByRef`/`pathByRef` as **session-living** maps owned by the panel
   build: baseline populates; `DescendantAdded` adds; `DescendantRemoving` removes (clear the entries to
   avoid unbounded growth — review m4). `InstanceRef` serialization (~line 1031) keeps using
   `instanceIdByRef`.
D2. **`Live` sub-table** in the build holding: `dirtyUpsert` (`{[Instance]=true}`), `dirtyRemoved`
   (`{[id]=true}`), per-instance connection registry `{[Instance]={conns...}}`, the debounce timer, the slow
   verify timer, a `currentRevision`, and a `liveRunning` flag owned by the build.
D3. **Connect signals (full coverage; budget per decision 5):** after a successful baseline, for each
   captured root connect `DescendantAdded`/`DescendantRemoving`; per instance (baseline + on add) connect:
   `GetPropertyChangedSignal(prop)` for each name from `Capture.getPropertyNames(inst)`; **`GetPropertyChangedSignal(inst, "Name")`
   ALWAYS** (Name is NOT in `CLASS_PROPERTIES` — decision 1b); **`inst.AncestryChanged`** (catches intra-root
   reparents that fire no `Descendant*` signal — it fires on the moved node AND each descendant, giving an
   automatic subtree fan-out for moves); `AttributeChanged`; and CollectionService tag signals. Plus
   `Selection.SelectionChanged` (targeted) and the non-deprecated `ChangeHistoryService` waypoint signal
   (review m5 — pin to the current API: `OnUndo`/`OnRedo` and the waypoint-recorded signal if present; there
   is no public "any property changed" signal, so bulk paste is covered by `DescendantAdded` + the verify
   net). Record the connection count + connect time for the measurement gate; if over budget, ship the
   documented coarse mode (decision 5).
   - **Neighbor-dirtying (decision 1b, the convergence fix). The living map (`pathByRef` + a parent map)
     records each instance's last-known parent so the OLD sibling group is recoverable on a move.**
     - `DescendantAdded(child)` ⇒ dirty `child` (and register its listeners), `child.Parent` (childCount),
       and `child.Parent`'s children sharing `child.Name` (siblingIndex/duplicate/path).
     - `DescendantRemoving(child)` ⇒ add `child`'s id (and its descendants' ids, from the living map) to
       `dirtyRemoved`; dirty `child.Parent` and the surviving same-name siblings; disconnect + drop the
       subtree's listeners/map entries.
     - **`Name` change of X** ⇒ dirty X + **X's ENTIRE subtree** (path cascade — descendants' paths change)
       + the parent's children sharing the OLD name and the NEW name (from the living map vs live).
     - **`AncestryChanged` of X (intra-root move)** ⇒ dirty X (AncestryChanged also fires per descendant, so
       the subtree self-dirties) + the NEW parent's same-name sibling group + the OLD parent's same-name
       sibling group and childCount (old parent looked up from the living map BEFORE updating it). Update the
       living parent map after handling.
   - In all cases, structural fields for dirtied instances are recomputed from the LIVE tree at flush (D4),
     not from cached values, so childCount/siblingIndex/duplicate/path/parentId/depth are always correct.
D4. **Debounce + flush (interval = `Settings.getNumber(debounceMs, 300)`):** on flush, build
   `{ upserted, removed }`:
   - **Precedence + dead-instance handling (review M5):** an id in both sets ⇒ removed wins. For each
     `dirtyUpsert` instance, before reading, verify it is still parented under a captured root and alive
     (`inst.Parent ~= nil` and reachable); if not, drop it from upserted and add its id to removed. Read the
     full current row (`Capture.readProperties/readAttributes/readTags` + structural fields recomputed from
     the LIVE tree at flush, not from cached maps — review m4): `path`, `parentId`, `siblingIndex`, `depth`,
     `childCount`, `duplicateSiblingName`.
   - POST `/studio-stud/live/delta` with `baseRevision = currentRevision`; on success adopt the returned
     `revision` and clear flushed sets; on `revision_mismatch`/`no_baseline` ⇒ full re-baseline.
D5. **Periodic drift verify (catch-all):** a slow timer (~30–60 s, and on reconnect/waypoint) computes the
   plugin-side fingerprint over the live tree, GETs `/live/fingerprint`; on mismatch sends a full
   `/live/verify/*`. **Adopt the `revision` from delta, verify, AND fingerprint responses** so a verify
   correction doesn't trigger a re-baseline storm on the next delta (review m2).
D6. **Lifecycle & settings (decision 7):** `liveCaptureEnabled` gates D3–D5 (off ⇒ exactly Stage 1
   request-poll behavior). On connect/reconnect: run one full baseline (existing `syncFn`), THEN connect
   signals. `destroy` sets `liveRunning=false`, disconnects EVERY per-instance + root + selection + waypoint
   connection, stops both timers, clears all maps — zero leaks. The 2s request poll stays (live + request
   coexist; `studio-stud capture` is still a manual full re-baseline). Keep all live machinery in the `Live`
   sub-table / functions (Luau 200-local limit); re-check after this workstream.
   - **Graceful degradation (review m6):** if the daemon returns 404 for `/live/*` (older daemon), fall back
     to the request poll instead of erroring.
D7. **Protocol version:** live is purely ADDITIVE to the capture contract, so keep `PROTOCOL_VERSION = 1` in
   both `util.rs` and the plugin. Only bump (both + `MIN_PLUGIN_PROTOCOL_VERSION`) if you change an existing
   message shape; state the decision in the commit.

**Exit D:** with `serve` up + plugin loaded, Live capture ON triggers a baseline then live deltas on edits
(incl. add/remove/reparent/duplicate-sibling); `studio-stud analyze/query` reflects edits without a manual
`capture`; connection count + connect time recorded; teardown leaks no connections.

### Workstream E — Plugin self-test extension (in-Studio determinism)
Extend `_G.StudioStud.RunSelfTest` (Stage 1 §8) with checks needing no daemon; snapshot/restore state and
print PASS/FAIL:
- **GetDebugId stability (review M4):** build a throwaway subtree; walk it twice ⇒ identical `GetDebugId(0)`
  ids per instance; reparent a node ⇒ its id is unchanged. (Proves decision 1's load-bearing assumption.)
- **Neighbor-dirtying:** simulate add/remove of a duplicate-named child ⇒ parent + same-name siblings are in
  `dirtyUpsert`.
- **Rename + move subtree dirtying (covers NEW-1 / decision 1b path cascade):** build a node with a couple
  of descendants; (i) rename the node ⇒ the node + its ENTIRE subtree + old/new same-name sibling groups are
  in `dirtyUpsert`; (ii) intra-root reparent the node ⇒ the node + subtree (via AncestryChanged) + old parent
  (childCount/siblings) + new parent (siblings) are dirtied, and the emitted upsert entries carry the
  recomputed cascaded `path`s.
- **Dirty-set precedence + dead instance:** mark an instance upsert then `Destroy` it before flush ⇒ it ends
  up in `removed`, no error thrown reading a dead instance.
- **Coalescing:** N marks on one id ⇒ one upserted entry.
- **Connection bookkeeping:** register listeners for a throwaway Folder, `Destroy` it ⇒ connections dropped,
  map entry removed; after teardown the per-instance connection table is empty.
- **Debounce/verify timers single-instance after teardown→re-init.**
- **Settings gate:** `liveCaptureEnabled=false` ⇒ no signal connections created.

**Exit E:** `RunSelfTest()` PASS incl. live checks; fully restores state.

### Workstream F — Benchmark + docs (honest perf claim)
F1. Extend the hidden `bench` (e.g. `bench --baseline <full.json> --delta <delta.json> --json`) to report
   daemon-side `apply_delta` vs full `materialize_snapshot`/`ingest` on a **realistic large fixture** so the
   "cheaper" claim is meaningful. Make `apply_delta` cheaper via incremental `class_counts` (M3); the bench
   output must explicitly note findings recompute is O(n) and that the PRIMARY win is Studio-walk +
   transport-side (not measured here). Add a `bench --json` shape assertion for the new fields.
F2. Update `docs/studio-stud.md`: add a "Live capture" section (how live mode works, settings, `/live/*`
   endpoints, drift backstop, the listener mode + measured connection count/time) and record delta-vs-full
   bench numbers next to the Stage 0 baseline. Note Stage 2 is single-developer (multi-dev = Stage 6).
F3. **Update `.cursor/rules/studio-stud.mdc` (review m6):** it currently lists `--report comparison` as valid
   and shows it in examples — remove `comparison` from the valid report views and its example so the rule
   doesn't document a removed option. `docs/repo-map.md` auto-regenerates via the hook (run `/repo-map` if
   `live.rs` isn't picked up).

**Exit F:** bench reports delta < full on a realistic fixture with the honesty note; docs + the studio-stud
rule updated.

---

## 6. Execution order (for Composer)
1. Workstream A (storage migration — biggest blast radius; regenerate ONLY `status_json`).
2. Workstream B (live engine + hidden CLI + convergence/no-data-loss tests — provable without Studio).
3. Workstream C (HTTP wiring + capture-regression test).
4. Workstream D (plugin live machinery + measurement gate).
5. Workstream E (self-test extension, incl. GetDebugId stability).
6. Workstream F (bench + docs + rule update).
7. Final verification (§9/§10).

Commit per workstream. After each daemon workstream: `pwsh tools/studio_stud/build-local.ps1` + `cargo test`
+ `cargo clippy` clean. After plugin workstreams: load in Studio, no Output errors, `RunSelfTest` PASS.

---

## 7. Convergence comparison contract (what "byte-identical" excludes)
`live-dump` segregates volatile meta into a `meta` block; the convergence assertion compares only the
`state` block + `fingerprint`. The `meta`/excluded fields are: `capture_id`, `baseline_hash`, `revision`,
`baseline_at_utc`, `updated_at_utc`. Derived columns (`*_norm`, `search_text`, `property_json` blob) are not
emitted into `state` (they recompute deterministically and are reconstructed for the fingerprint). Everything
in `state` — each instance's `id` (GetDebugId-stable in-session; fixed strings in fixtures), `parentId`,
`path`, `name`, `className`, `depth`, `childCount`, `siblingIndex`, `duplicateSiblingName`, and sorted
`properties`/`attributes`/`tags` — MUST be identical, AND `fingerprint` MUST be equal. Fingerprint equality
is the primary gate; the `state` diff is the diagnostic. **This equality must hold with NO intervening
verify** (decision 0).

---

## 8. Tests Tyler runs (single-person, required for exit)

### 8.1 Automated (from `tools/studio_stud/`)
```powershell
pwsh tools/studio_stud/build-local.ps1     # clean build → bin/studio-stud.exe
cargo test                                  # all unit + golden + live convergence tests green
cargo clippy --all-targets                  # no new warnings
```
Must be green, in particular:
- `live_convergence::structural_convergence` — the decision-0 gate (add child + remove duplicate sibling +
  reparent converges with NO verify).
- `live_convergence` no-data-loss/drift recovery, revision guard, fingerprint fast path,
  cross-representation fingerprint, transactional rollback.
- `golden_outputs` with `analyze_comparison` removed; **`analyze_context_findings_critical` + `query_*`
  unchanged** (regression guard); `status_json` regenerated.
- `live.rs`/`storage.rs` unit tests; `bench --json` shape.

### 8.2 Daemon CLI smoke (no Studio)
```powershell
.\bin\studio-stud.exe ingest --raw tools/studio_stud/tests/fixtures/live/baseline.json --storage-root .tmp/live
.\bin\studio-stud.exe live-delta --raw tools/studio_stud/tests/fixtures/live/delta_struct.json --storage-root .tmp/live
.\bin\studio-stud.exe live-dump <PLACE> --storage-root .tmp/live
.\bin\studio-stud.exe ingest --raw tools/studio_stud/tests/fixtures/live/full_after.json --storage-root .tmp/live2
.\bin\studio-stud.exe live-dump <PLACE> --storage-root .tmp/live2     # state+fingerprint must match (no verify)
.\bin\studio-stud.exe analyze <PLACE> --report context --storage-root .tmp/live
.\bin\studio-stud.exe analyze <PLACE> --report comparison --storage-root .tmp/live   # must ERROR (removed)
.\bin\studio-stud.exe live-verify --raw tools/studio_stud/tests/fixtures/live/full_after.json --storage-root .tmp/live  # drift:[], corrected:0
.\bin\studio-stud.exe status --storage-root .tmp/live                 # shows live_state, not pointers
```

### 8.3 Manual Studio end-to-end (live)
1. `studio-stud serve`; open Example Place A with the plugin loaded.
2. Settings overlay: Live capture = ON, Debounce = 300.
3. Connect/reconnect ⇒ a baseline runs (status → connected). Note the recorded connection count + connect
   time (measurement gate).
4. Edit in Studio: move a Part, **rename a FOLDER that contains children** (path cascade), **add a Folder,
   delete a Part, add a second child with the same name as an existing one, reparent a model to another
   folder under the same root** (intra-root move). Within ~1 s, `studio-stud analyze/query` reflects each
   edit WITHOUT running `studio-stud capture` — and the parent's child count, the renamed/reindexed siblings,
   AND the `path` of the renamed/moved folder's descendants are all correct (the structural + path-cascade
   cases B1/NEW-1 were about). Confirm descendant paths update (e.g. `query --under <renamed folder>`).
5. Bulk op: undo/redo + paste a small model ⇒ still converges (spot-check via `query`; let periodic verify
   run).
6. Toggle Live capture OFF ⇒ reverts to Stage 1 (only manual `capture` updates); ON ⇒ re-baseline works.
7. `_G.StudioStud.RunSelfTest()` ⇒ PASS (incl. GetDebugId stability + live checks). Then fire one
   `studio-stud capture` and confirm it still ingests (no leaked/dead loops or connections).

### 8.4 Perf
```powershell
.\bin\studio-stud.exe bench --baseline tools/studio_stud/tests/fixtures/live/full_after.json --delta tools/studio_stud/tests/fixtures/live/delta_struct.json --json
```
Confirm delta apply median < full ingest median (with the honesty note that Studio-walk/transport is the
primary, unmeasured win).

---

## 9. Exit gate checklist (all must be true)
- [ ] Single live DB per place: `live_state` is authority; pointers/promotion/pruning + per-capture dirs
      gone; one `baseline.json.gz` retained.
- [ ] Comparison fully removed (code + golden); `analyze_context_*`/`query_*` goldens UNCHANGED; only
      `status_json` regenerated.
- [ ] `/studio-stud/live/delta`, dedicated `/live/verify/*`, `/live/fingerprint` implemented; capture
      completer untouched; all existing routes/aliases + 404 unchanged; capture round-trip regression green.
- [ ] Delta op is `{upserted, removed}` with full structural entries; daemon upsert (incl. per-id
      `keyword_hits`) reuses `ingest_sqlite` logic; single-transaction, revision-guarded; incremental
      fingerprint + incremental `class_counts`; `critical_presence` recomputed globally each delta; findings
      recompute documented as the O(n) cost; bad op rolls back (DB + revision unchanged).
- [ ] **Deltas converge ALONE (no verify):** the structural-convergence test covering add child, remove
      duplicate sibling, reparent (in/out of root), **rename-with-descendants (path cascade)**, and
      **intra-root move** passes byte-identical to a fresh full capture; fingerprints equal.
- [ ] No data loss: the drift verify recovers an injected missed change and re-converges (test + manual);
      verify promotion is atomic and deletes the old partition.
- [ ] Plugin: GetDebugId stable ids (self-test proven); living id + parent map; full-coverage signals with
      neighbor-dirtying INCLUDING always-tracked `Name` + `AncestryChanged` and subtree/old-+new-sibling
      dirtying on rename/move; dirty-set precedence + dead-instance handling; debounce uses `debounceMs`;
      baseline-on-connect; periodic fingerprint verify adopting revision from all responses;
      `liveCaptureEnabled` gates live mode; 404 fallback to request poll; zero leaked connections; connection
      count/connect time recorded against the budget.
- [ ] AI-first discipline intact; no per-delta AI notification; no new tokened surface.
- [ ] Deltas measurably cheaper daemon-side (incremental class_counts) with the honest transport-side note;
      numbers recorded in `docs/studio-stud.md`; `.cursor/rules/studio-stud.mdc` no longer lists
      `--report comparison`.
- [ ] `cargo test` + `cargo clippy` green; `build-local.ps1` clean; `RunSelfTest()` PASS.
- [ ] No Stage 3+ surface introduced.

---

## 10. Risks & mitigations
- **GetDebugId stability (load-bearing).** Misuse (rebuilt map per delta, non-zero scope, or instability)
  targets wrong rows. Mitigation: living session map maintained by Descendant signals; the dedicated
  GetDebugId self-test (Workstream E, M4) proves stability across re-walk + reparent BEFORE trusting it;
  drift verify is the net. Confirm via Roblox docs:
  https://create.roblox.com/docs/reference/engine/classes/Instance#GetDebugId
- **Structural convergence (the redesigned core).** Neighbor-dependent fields (childCount/siblingIndex/
  duplicate/path) must be re-emitted via full upserts of the affected parent + sibling group; AND **`path`
  cascades to the whole subtree on rename or intra-root move**, neither of which fires a `Descendant*` or
  curated-property signal — the easy-to-miss hole. Mitigation: decision 1b + D3 always-track `Name` +
  `AncestryChanged` + subtree/old-&-new-sibling dirtying; the decision-0 structural-convergence test that
  runs WITHOUT a verify and explicitly includes rename-with-descendants + intra-root move; plus the
  Workstream E plugin self-test for subtree dirtying (the daemon CLI can't exercise the plugin's delta
  production). If it can't pass without a verify, the protocol is wrong, not the test.
- **Global-vs-per-id aggregates.** `critical_presence` (8 global booleans over all paths) cannot be
  maintained per touched id — a delete/rename would leave a stale `present`. Mitigation: recompute the 8
  globally each delta (cheap), grouped with findings; `keyword_hits` stays per-id inside `upsert_instance`.
- **Fingerprint representation drift.** Mitigation: ONE `fingerprint_state` over DB rows used by baseline +
  delta + verify (verify ingests to staging first); serde_json BTreeMap gives sorted keys for free; the
  cross-representation test guards it.
- **Storage migration blast radius** (pointer removal across storage/capture/analyze/query/output/cli).
  Mitigation: Workstream A first, isolated, with the corrected goldens scope + unit tests before delta work;
  commit per area.
- **Plugin connection leaks / register pressure / listener scale.** Mitigation: strict `destroy`; self-test
  asserts empty connection table after teardown; `Live` sub-table; the measurement gate + documented coarse
  fallback (decision 5) if per-instance listeners are too heavy.
- **Signal blind spots (no global property-changed signal).** Mitigation: layered drift backstop (continuous
  deltas + waypoint rescan + periodic full verify + fingerprint fast path) — correctness never depends on
  perfect coverage; verify is authoritative.
- **Debounce/coalescing dropping the last edit / dead instances.** Mitigation: re-check running flag after
  the timer wait (Stage 1 pattern); precedence (removed wins) + still-parented check at flush; verify net.
- **Re-baseline storm after a verify correction.** Mitigation: plugin adopts `revision` from delta, verify,
  and fingerprint responses (m2).
- **Daemon-side delta not actually cheaper.** Mitigation: incremental `class_counts`; document findings as the
  O(n) part; bench a realistic large fixture; state the primary win is transport/walk-side.
- **Goldens churn hiding a regression.** Mitigation: only `status_json` is allowed to change; assert
  `analyze_context_*`/`query_*` unchanged as a guard.
- **Scope creep into Stage 3/6.** Explicitly forbidden in §0; live endpoints stay unauthenticated/local-DB-
  only; no CAS/claims/merge.

---

## 11. Out of scope (defer to later stages)
`/studio-stud/write/*`, `.studio-stud/policy.json`, write token + handshake, `full-moon` (Stage 3); repo
index / Rojo v7 projection / `rbx-dom` / read-only project diff (Stage 4); FS→Studio apply endpoints,
hash-guarded applies, per-file base ledger (Stage 5); multi-developer / Team Create concurrency,
bidirectional mirror, content CAS, 3-way merge, transient claims, `flctl sync explain|status|resolve`,
replicated-edit conflict surfacing (Stage 6 + Final Verification); Rojo format parity / build / sourcemap /
controlled two-way reconcile (Stage 7); the Boat Configurator panel rebuild (Stage 8). A bounded
`delta_journal` history ring is explicitly deferred (decision 4).
```
