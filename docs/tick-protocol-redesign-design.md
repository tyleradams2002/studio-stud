# Studio Stud — Core Sync Redesign (the `/tick` protocol)

**Status:** Design — **complete and ready for review.** 15 decisions (D1–D15) locked via grill sessions 2026-06-05, log-validated. Not yet implemented; the only remaining open items are measure-during-implementation tuning values (§11).
**Scope:** The live communication core between the Studio plugin and the Rust daemon.
**Goal:** Make the core *faster*, *lighter on the editor*, and *simpler* — collapse five
overlapping traffic forms into one heartbeat packet, and remove the implementation waste
underneath it. Get the core strong before building anything else on top.

---

## 1. Why

The current live system works, but it has accreted complexity and per-operation waste.
Pain (confirmed, all three felt simultaneously): **steady-state editor drag**, a **freeze on
initial Capture**, and **daemon-side slowness**. Notably *not* scale-bound — it's heavy even
on normal-sized places, which points at constant per-operation overhead, not big-N scaling.

**Design scale target:** worst case **~100k instances** (typical 5–15k). This makes
non-blocking capture, batched writes, and incremental fingerprinting *mandatory*, not optional.

### Root causes (measured from the code)

| Symptom | Root cause | Location |
|---|---|---|
| Steady-state drag | ~20 signal connections **per instance** (one `GetPropertyChangedSignal` per curated property) → ~2,000,000 live connections at 100k | `registerInstance` [plugin:2109](../plugin/StudioStud.plugin.lua) |
| Capture freeze | Baseline walk is fully **synchronous** — no `task.wait()` yields; UI thread blocks for the whole walk. Plus ~10–20 `pcall`s/instance and creating all those connections. | walk ~[plugin:1687](../plugin/StudioStud.plugin.lua) |
| Too many traffic forms | 5 transport types at 4 cadences: 3s heartbeat poll, debounced `/live/delta`, 45s `/fingerprint`, 180s blind full `/verify`, 3-phase baseline | `src/http.rs` dispatch |
| Daemon slowness | New SQLite connection **per request**; **per-row** INSERTs (~80k execs for 10k place); statements re-prepared each row; **full-table fingerprint rescan** on verify | `open_db` [src/util.rs:145](../src/util.rs), `ingest_rows` [src/capture.rs:275](../src/capture.rs), `fingerprint_state` [src/capture.rs:603](../src/capture.rs) |

The design (baseline + event-deltas + fingerprint) was always sound. The problem is the
*number of mechanisms* layered on it and the *naïveté* of the hot paths beneath it.

---

## 2. The two axes (don't fuse them)

Every decision below sits on one of two independent axes:

- **Detection** — how the plugin *notices* a change (signal connections). Lives in the plugin.
- **Transport** — how noticed changes are *shipped* (the wire). The `/tick` packet.

The packet ships the dirty set; the detection layer *fills* it. They are complementary —
optimizing one does not remove the need for the other.

---

## 3. Locked decisions

| # | Decision | Choice | Rationale |
|---|---|---|---|
| D1 | Transport model | **One periodic `/tick` POST** carries everything: sessionMode, baseRevision, per-service fingerprints, accumulated ops; response carries ack/revision/drift/pending-request | Collapses 5 traffic forms → 1. This is the spine. |
| D2 | Change detection | **Collapse per-property signals → one `inst.Changed` per instance**, filter to curated props in the handler; keep `AncestryChanged` + `AttributeChanged`; special-case `ValueBase` | ~20 → ~3 connections/instance (~7× cut). Attacks both steady-state drag and freeze. |
| D3 | Tick cadence | **Fixed interval, default 0.5s**, stored as a runtime setting. Safe from day one because the whole rework ships as one release (daemon batching makes deltas <50ms, so no backpressure). **Remove the sync-debounce slider from the plugin UI** (no UI control for now; future-exposable). | Simplicity/predictability; the log shows the debounce is moot once writes are fast. |
| D4 | Drift recovery | **Per-root-service fingerprints**; mismatch re-baselines only the drifted service | Localizes drift cheaply (one XOR accumulator per root); avoids full-tree freeze and Merkle complexity. |
| D5 | Daemon core | **Persistent per-place connections** (writer+reader split, see D10) — no per-request open; pragmas set once; `prepare_cached`; batched single-transaction writes; incremental per-service fingerprint; **empty ticks short-circuit before any DB work** | Removes per-request connection churn + per-row prep. SQLite single-writer is inherent, not a bottleneck once batched. |
| D6 | Baseline | **Non-blocking**: yielding walk (`task.wait` every ~500 instances — default, tunable), optimistic batch-`pcall` per instance with per-property fallback | A 100k synchronous walk is an unacceptable freeze; rebaseline-on-drift must also be non-blocking. |
| D7 | Rollout | **Clean break, protocol v2**: add `/tick`, delete the 5 legacy endpoints, bump `MIN_PLUGIN_PROTOCOL_VERSION` | We control both sides + have a version handshake. One protocol, no dead code — this is what actually delivers the simplification. |
| D8 | Read-mirror scope | **Full mirror** — keep capturing all curated properties incl. geometry | AI must reason about positions/sizes, not just code. The perf rework (yielding/batching/incremental) is therefore mandatory, not optional. |
| D9 | Property allow-list | **Generate `CLASS_PROPERTIES` from Roblox's API dump** (filter to scriptable+serializable; read-only kept but tagged `readOnly`) — sourced per D14 (runtime-fetched for the current version, bundled fallback) — + log uncurated names that fire via `inst.Changed` as a gap-discovery probe. | Ends hand-curation drift; makes the curated subset *informed*; the probe finds real-world gaps without expensive reflection. |
| D10 | Connection lifecycle | **Per-place connection registry**: lazily open on first tick, idle-evict (~5 min) + small LRU cap; **dedicated writer + reader connection per place** (WAL = 1 writer + N readers) | Multiple/serial places handled cleanly + in parallel (independent DB files); reader split stops a long AI read from blocking ticks. |
| D11 | Worker routing/ordering | **Acceptor routes by `placeId` + request type:** writes → that place's borrowed writer thread (serial, in arrival order); reads + cheap in-memory (keepalive, ping) → the shared remainder. Sizing per D13. | One writer thread per place = guaranteed ordering + zero contention → worker desync impossible. SQLite single-writer is a hard limit. Heartbeat keepalive is cheap/in-memory so the shared pool answers it promptly — no dedicated heartbeat thread. |
| D12 | Reader concurrency | **Multiple concurrent readers allowed** (moved out of deferred), served from the shared pool via per-place reader connections. AI reads are directed + short, so concurrent reads under WAL snapshot isolation are safe and cheap. | User-endorsed; only risk (long read pinning WAL growth) doesn't apply to short directed queries. |
| D13 | Pool / worker model | **1 dedicated writer thread per active place + a small fixed shared pool (default 3, configurable)** for reads + cheap in-memory work. A thread is **not** a core — idle threads cost ~nothing and don't steal cores from Studio; the daemon is idle almost all the time, so size for concurrency need, not core count. 3 shared threads amply cover a solo dev's keepalives + 1-2 reads. Routing by `placeId` → `(projectKey, placeId)` key (fallback for unsaved `PlaceId=0`). | Right-sized for the real workload; SQLite single-writer ⇒ 1 writer/place is the max useful. A future parallel-hashing burst (deferred) can fan out to a transient core-sized set without enlarging the steady pool. |
| D14 | Reflection versioning | **Runtime-fetch** the API dump for the current Studio version from an external source (Roblox CDN / Client-Tracker) — **decoupled from daemon releases** — with a **bundled baseline as offline fallback**. Reflection version stored **inside each `place.db` (`meta.reflection_version`)** — the DB is the thing being versioned, already per-machine, and per-place versioning is *more* correct (each place's data can be at a different version). No separate state file. Trigger = plugin-reported Roblox version ≠ DB's stored version (absent on a fresh DB = mismatch). | User wants reflection updates independent of shipping a new daemon; storing the version with the data it describes is the cleanest source of truth. |
| D15 | Reflection update flow | On connect, if `meta.reflection_version` ≠ Studio version: fetch dump → regenerate whitelist → inform plugin of new props → **write new version into `meta` ONLY on full success** (atomic); on failure log + report "property update failed" + keep old version (retry next launch) + proceed with existing whitelist. Then run initial sync. **No DB migration** — properties are a JSON blob, so a new property is just another captured key; the full initial sync backfills every instance in one pass. | Fail-safe + atomic; the JSON-blob storage collapses "update db" into "re-capture." |

---

## 4. Target architecture

### 4.1 The `/tick` packet

```
Plugin → daemon  (every fixed interval, default 0.5s)
POST /studio-stud/tick
{
  "placeId":   "<id>",
  "sessionMode": "edit" | "play",
  "baseRevision": <int>,                 // plugin's current revision
  "serviceFingerprints": {               // per captured root service
    "Workspace": "<hex>",
    "ServerScriptService": "<hex>",
    ...
  },
  "ops": {                               // accumulated since last tick (small payloads only)
    "upserted": [ <full instance entry>, ... ],
    "removed":  [ "<instanceId>", ... ]
  },
  "bulkRef": "<syncId>" | null           // set instead of ops when payload spilled to chunks
}

daemon → plugin  (the response — this is the only "downstream" channel)
{
  "ok": true,
  "revision": <int>,                     // new revision after applying ops
  "instanceCount": <int>,
  "driftServices": [ "Workspace", ... ], // services whose fingerprint disagreed (usually [])
  "request": <AI-queued job> | null,     // e.g. {"reason":"rebaseline"} — was /capture/request
  "applyScripts": [                      // downstream write channel (reserved; empty until write is built)
    { "studioPath": "...", "newSource": "...", "expectedPriorHash": "..." }
  ]
}
```

One packet replaces: the 3s heartbeat poll, `/live/delta`, the 45s `/fingerprint` probe,
the 180s blind `/verify`, and the session-mode query param. **Drift detection is free on
every beat** — the plugin's `serviceFingerprints` are compared to the daemon's stored ones.

### 4.2 Baseline is no longer a separate protocol

Baseline = "the first tick after connect, where the daemon reports no stored state, so the
plugin sends the whole tree." A full tree (or any payload over the inline threshold) does not
fit in one POST body, so it **spills** to a chunked sub-upload referenced by `bulkRef`:

```
POST /studio-stud/tick/bulk/start   → { syncId, maxChunkBytes }
POST /studio-stud/tick/bulk/chunk   (×N)
POST /studio-stud/tick/bulk/complete
... then the next /tick carries  "bulkRef": syncId  to commit it.
```

This is the *one* place multi-phase remains, and it's now a **sized fallback of the tick**,
not a parallel concept. Inline threshold (tunable): ~256 KB JSON / a few hundred instances.
Below it → inline `ops`; above it → `bulkRef`.

### 4.3 Session gating (unchanged intent, simpler surface)

`sessionMode` rides every tick. During play, the tick is a pure keepalive: the daemon
records mode, answers drift/request, and **ignores any ops**. Edit→play tears down live
connections (no dirty accrues); play→edit does the smart catch-up via the per-service
fingerprints already in the tick.

**Reserved seam — play/pause:** the full play-pause logic is **not built yet** (it pairs with the
future write/edit feature — the reason to pause is "don't sync into a running game you might
write to"). But the seam is already here: `sessionMode` on every tick + the PLAY state. When the
real play-pause is built it's a *thin layer that just sets `sessionMode`* — **zero** protocol or
daemon changes needed. (Same pattern as the `applyScripts` write seam.)

**Graceful drain on entering play (not a hard cutoff):** because the plugin sends one op at a time,
at most ONE operation is in flight when Play starts. Let that op (e.g. a bulk's remaining chunks +
commit) **finish and commit**, then switch to keepalive-only. The in-flight bulk already read the
edit tree (pre-play), so finishing it captures legitimate edit state and leaves a clean revision;
a hard cutoff would strand half-staged chunks and force a full re-baseline on return. After a clean
drain, returning to edit hits the fingerprint short-circuit and resumes instantly.

**In active play, the ONLY traffic is the keepalive tick** (carrying `sessionMode:"play"`). No
deltas (edit tree is frozen — you're in the separate play DataModel), no drift checks, no bulk. The
heartbeat is both the keepalive and the play-vs-edit signal.

---

## 5. Detection layer (plugin)

`registerInstance` changes from ~20 connections to ~3:

```
inst.Changed:Connect(prop -> if curatedSet[prop] then dirtyUpsert[inst]=true end)  -- 1
inst.AncestryChanged:Connect(...)                                                  -- 1 (path/sibling logic kept)
inst.AttributeChanged:Connect(...)                                                 -- 1
```

- **`ValueBase` special-case:** IntValue/StringValue/BoolValue/etc. fire `.Changed` with the
  *value*, not the property name. For those classes, fall back to
  `GetPropertyChangedSignal("Value")`. Small fixed list.
- `DescendantAdded`/`DescendantRemoving` on captured roots stay as-is (structural changes).
- The curated property allow-list (`CLASS_PROPERTIES`, generated per D9) is reused as the in-handler filter.

This cuts connection count ~7×, cuts connection *creation* cost during baseline ~7× (helping
the freeze), and cuts per-change dispatch overhead.

**Lazy read-on-tick (no round-trip, no multi-tick delay):** the handler only sets
`dirtyUpsert[inst]=true` — it does **not** read the value at fire-time. The plugin already holds
the value locally (it owns the DataModel); `buildUpsertedEntry` reads the instance's current
values fresh on the next tick. So a change ships in **≤1 tick (≤1s)**, and rapid edits to the same
instance coalesce into one read of the final value. The only +1-tick round-trips are
*daemon-initiated* (drift recovery, AI-requested capture), never the property path.

**Gap-discovery probe (D9):** when `inst.Changed` fires with a property name *not* in the curated
set, log/telemeter it — that surfaces real-world properties we aren't capturing without any
reflection scan. The daemon validates each via the reflection DB (real + capturable + not
deny-listed → add to the curated set & persist; read-but-not-write → add **tagged `readOnly`** so
the AI knows it's display-only; not a real property → reject).

**Properties vs attributes (the allow-list only governs *properties*):** the reflection-DB /
allow-list machinery is for **built-in class properties** only. **Attributes** (`SetAttribute`) —
Roblox's actual "custom property" mechanism — are dynamic and open-ended, so we capture **all** of
them wholesale (no whitelist) and track them via `AttributeChanged`. So user-defined/custom data
needs no discovery — it's an attribute and is captured immediately. Reflection DB = engine schema
(per-Roblox-version, **not** pulled from the game); **runtime-fetched** for the current Studio
version with a bundled fallback, and each `place.db` records the version it was built against in
`meta.reflection_version` (see D14/D15).

---

## 6. Consistency layer — per-service fingerprints

- Maintain one XOR fingerprint accumulator **per captured root service**, on both sides.
- An instance's service = first segment of its captured path; the daemon routes each
  instance's hash to the right accumulator on upsert/remove (incremental XOR — never rescan).
- Daemon storage: a **`service_fingerprints(capture_id, service_name, fingerprint, instance_count)`
  table** (resolved over a JSON blob on `live_state` — a table writes only the changed row per
  tick and is queryable, vs a full read-modify-write of a blob every tick), updated inside the
  same tick transaction.
- On each tick the plugin sends its per-service fingerprints; the daemon returns
  `driftServices` as an **array** for any mismatch. The plugin recovers **all** drifted services
  in **one coalesced pass** (re-walk each yielding → single bulk spill → daemon replaces those
  services' rows + recomputes those accumulators), not N round-trips. Many services drifting at
  once naturally approaches a full re-baseline — correct behavior for that rare case.
- **Drift telemetry:** count drift events per service. This is the signal that tells us whether a
  single huge service drifts often enough to justify building Merkle (the deferred escalation).

Drift should be **rare** (the Changed-collapse covers all curated props + structure +
attributes), so this path is a safety net, not a hot path.

**No-data-loss invariant (recovery races):** if an edit lands while a drift re-walk is in
flight, nothing is lost. The rules: (1) dirty flags are **never cleared except by a committed
upsert/delta of that instance** — recovery keeps accumulating them; (2) the re-walk reads the
**current** live state, so edits before/during the walk are captured; (3) any edit landing after
the walk read an instance but before commit stays flagged and ships as a delta against the new
post-recovery revision; (4) the `baseRevision` guard serializes ordering. Worst case is a ≤1-tick
*delay*, never a loss.

---

## 7. Daemon core

- **Per-place connection registry** (D10): `placeKey → { writer: Mutex<Conn>, readers: [Conn] }`,
  lazily opened on first tick, kept warm, **idle-evicted** (~5 min no ticks) with a small LRU cap
  (~8). Pragmas (`WAL`, `synchronous=NORMAL`, `foreign_keys=ON`, plus add `cache_size` and
  `mmap_size`) set **once** at open. Multiple places = independent DB files → true parallelism, no
  cross-place lock.
- **Writer/reader split per place** (D10/D12): writes (ticks/ingest) go through the writer; AI
  `query`/`analyze`/`context` reads go through separate reader connection(s). WAL allows 1 writer
  + N readers, so a long AI read never blocks ticks (and vice versa). **Multiple concurrent readers
  are in scope** (D12); only a *larger/dynamic* reader pool stays deferred until measured.
- **`prepare_cached`** for all INSERT/UPDATE/SELECT in the ingest + delta paths → statements
  prepared once, reused.
- **Batched writes:** the whole tick (all upserts + removes) applies in **one transaction**.
  Baseline ingest reuses cached prepared statements rather than re-preparing per row.
- **Incremental fingerprint:** per-service accumulators updated by XOR on each tick. The
  full-table `fingerprint_state` rescan is **deleted** from the hot path (kept only as an
  offline integrity-check tool, if at all).
- **Empty-tick short-circuit:** a keepalive tick (no ops, fingerprints match) returns
  *without acquiring the writer* — it only reads in-memory `DaemonState`. Critical: at a fixed
  0.5s cadence most ticks are empty, so they must cost ~nothing.
- **Worker model (D11/D13):** **1 dedicated writer thread per active place + a small fixed shared
  pool (default 3, configurable)** for reads + cheap in-memory work. The writer owns its place's
  writer connection and processes that place's writes **in arrival order** (guaranteed ordering,
  zero contention, worker-desync impossible). **A thread is not a core** — idle threads cost ~nothing
  and don't steal cores from Studio; the daemon is idle almost all the time, so size for concurrency
  need, not core count. Do **not** parallelize a single place's writes (SQLite single-writer — extra
  threads just queue). Cross-place = fully parallel (independent files). Every message carries
  `placeId` → routed by `(projectKey, placeId)` (fallback for unsaved `PlaceId=0`). A future
  parallel-hashing burst (deferred) can fan out to a transient core-sized set without enlarging the
  steady pool.
- **Latent worker uses (deferred, profile-gated):** parallel SHA-256 hashing of the snapshot
  during baseline ingest (the *write* stays single-threaded, but hashing/parsing can fan out), and
  background maintenance (WAL checkpoint, incremental vacuum). Build only if profiling shows ingest
  is CPU-bound.

---

## 8. Protocol v2 / clean break

**Added:** `POST /tick`, `POST /tick/bulk/{start,chunk,complete}`.
**Removed:** `/capture/request`, `/capture/start|body|chunk|complete` (folded into `/tick/bulk`),
`/live/delta`, `/live/fingerprint`, `/live/verify/*`.
**Kept (unchanged, out of scope):** `/ping`/manifest, `/write/*`, `/context*`, `/addons/*`, `/admin/shutdown`.

Bump `PROTOCOL_VERSION` → 2 and `MIN_PLUGIN_PROTOCOL_VERSION` → 2. The existing mutual
handshake surfaces "daemon/plugin out of date" cleanly when only one side is upgraded.

---

## 9. Write-readiness — repo ↔ Studio script sync (design now, build later)

The IDE→Studio write side is **not being built now**, but the `/tick` rework must leave clean
seams so it slots in without re-surgery. The model is a **three-way reconciliation**, two parts
of which already exist:

- **Desired state** = repo `.luau` files + `default.project.json`, projected on demand via
  `build_projection()` → `DesiredProjection` ([src/project/projection.rs:69](../src/project/projection.rs)).
  Already does Rojo file conventions (`.server.luau`→Script, `init.luau` collapse, folders,
  glob-ignore) and computes per-script normalized-newline sha256 + Luau parse check. **Exists.**
- **Actual state** = the Studio DataModel mirrored in SQLite. **Exists** (this rework).
- **Reconciler** = diff desired vs actual → emit script writes. **Not built.**

**Key correction to the mental model:** there are *not* two DB writers. The daemon is the **sole**
DB writer; the DB is the actual-state mirror. The "two sources of truth" are Studio (authoritative
for geometry/properties/Studio-edited scripts) and the repo (authoritative for code). SQLite is
the right tool for the mirror; **no second DB is needed**; desired state stays as files + a cheap
on-demand projection.

**The asymmetry (confirmed):** from the IDE, only **Luau `Source`** (+ folder structure from
`default.project.json`) ever flows into Studio. Parts/CFrames/properties are authored only in
Studio and are read-only from the AI's side. `.rbxmx`/JSON/etc. are already `Unsupported (Stage 7)`
and deferred. The `/tick` is the one channel for both directions: changes flow **up** in the
packet; pending script writes flow **down** in the response.

### Four seams to bake into this rework

1. **Capture script `Source`** into the mirror (today only `Enabled`/`Disabled`/`LinkedSource`
   are captured — [plugin:341](../plugin/StudioStud.plugin.lua)). Store the text **and** a
   normalized-newline sha256 computed with the **same** function the projection uses
   ([projection.rs:429](../src/project/projection.rs)) so desired/actual hashes compare directly.
2. **Key instances by `normalize_query_path`** — the same normalization the projection uses
   ([projection.rs:347](../src/project/projection.rs)) — so reconcile = map-join on the key.
3. **Tick response carries a downstream apply-list** — shape it now (`{ studioPath, newSource,
   expectedPriorHash }` entries), even if empty. Generalize today's `request` field into
   "pending Studio mutations."
4. **Store a last-synced hash per script** so the future reconciler can tell which side changed
   (repo-edited vs Studio-edited) and detect conflicts (the write-half hash-guard).

### Deferred write-side decisions (not now)

- **Conflict policy** when both sides edited a script (repo-wins / Studio-wins / block-and-flag).
  The last-synced-hash seam makes any policy implementable later.
- **Studio→repo write-back** of Studio-edited script Source into files.
- Model/`.rbxmx`/data-file sync (Stage 7).

---

## 10. Deferred — documented, NOT built (escape hatches w/ triggers)

These are the *more-complex siblings* of choices we made. Build only if the trigger fires.

| Item | Trigger to build it |
|---|---|
| **Property-level delta diffing** (#1 to revisit) | Mass-edit bandwidth is a measured problem (e.g. nudging 5k parts re-sends ~17 props each). gzip + bulk keep it *correct* today, just not byte-optimal. Closest call of the three. |
| **Merkle / hierarchical fingerprints** | Per-service **drift telemetry** shows a single large service drifts often, making per-service rebaseline recurring. |
| **Larger / dynamic reader pool** | Read latency persists even with the D12 readers served from the shared pool (default 3) — i.e. many concurrent heavy reads. |
| **Parallel ingest hashing / decompress** | Telemetry (Q2) shows baseline ingest is CPU-bound after batching. All daemon-side, per-item independent → **spin up a transient worker set sized to cores** (`min(cores−reserved, work)`) for the hashing/decompress burst, then tear it down and do the serial write — the steady 3-thread pool stays small. Plugin walk can NOT parallelize (Luau single-threaded) — only yields. |

---

## 11. Open questions (resolve during implementation)

1. **Inline threshold** (tunable, not derived) — the size cutoff for inline `ops` vs `bulkRef`
   spill. Must be big enough that ordinary deltas always inline (avoid bulk-path overhead) and
   small enough to not drop MBs into one JSON parse on the 0.5s hot path. ~256 KB sits between "a
   few instances" (~KBs) and the 900 KB hard chunk cap. **Measure and tune.**
2. **Yield granularity** — instances processed per `task.wait()` in the walk. **Default 500** (every
   1 = no freeze but ~27 min for 100k; never = full freeze; ~500–1000 = no perceptible hitch,
   completes in seconds). Tune from 500 with telemetry.
3. ~~Fixed interval default~~ **RESOLVED: 0.5s** default, stored as a **runtime setting** (plumbed
   through, not hardcoded) so a future plugin UI can change it live.
4. ~~Per-service table vs JSON column~~ **RESOLVED: table** (`service_fingerprints`) — writes only
   the changed row per tick, queryable; beats a full read-modify-write of a JSON blob each tick.
5. **`Changed` coverage audit** — before trusting `inst.Changed` over per-property signals, spot-
   check a few classes during impl to confirm it fires with the right property name and misses
   nothing (the `ValueBase` value-not-name case is the known exception, special-cased). Pairs with
   the D9 gap-discovery probe.
6. **Script Source storage** — full text + hash in the DB (recommended; scripts are few) vs hash-only with on-demand text fetch. Affects baseline/delta payload size.

---

## 12. Rough sequencing

**Provisional ordering — to be finalized before execution.** Each phase independently shippable
behind the v2 protocol bump (all land together at cutover).

1. **Daemon core** (no protocol change yet): per-place writer/reader connections + worker model
   (D10–D13), `prepare_cached`, batched ingest, incremental per-service fingerprint, pragmas, and
   reflection-versioning + allow-list generation (D9/D14/D15, `meta.reflection_version`). Verify
   against existing endpoints + tests.
   *Write-readiness seams land here too:* key instances by `normalize_query_path`; add the
   `service_fingerprints` storage; reserve the script Source columns (text + last-synced hash).
2. **Detection collapse** (plugin-local): `inst.Changed` + `ValueBase` special-case. Verify
   live deltas still fire correctly; measure connection-count drop.
3. **Non-blocking baseline** (plugin-local): yielding walk + optimistic batch-`pcall`. Measure freeze.
   *Add script `Source` capture (text + normalized-newline sha256) here* — the serialization path
   is already being rewritten, so it's the cheap moment to close the no-Source-captured gap.
4. **`/tick` protocol** (both sides, the cutover): add `/tick` + `/tick/bulk`, per-service drift
   in the response, fold session-mode + request-inbox in. Delete the 5 legacy endpoints. Bump protocol.
5. **Verify & soak**: large-place capture, edit storm, drift injection, play↔edit transitions,
   daemon restart mid-session. Update `tests/` (http_reliability, live_convergence) for v2.

---

_Decisions D1–D15 locked 2026-06-05 across multiple grill sessions; log-validated against a real
42h daemon.log. See project memory `tick-protocol-redesign`. The only open items are the §11
measure-during-implementation tuning values._
