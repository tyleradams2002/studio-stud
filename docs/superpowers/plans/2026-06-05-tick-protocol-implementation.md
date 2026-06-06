# Tick-Protocol Core Sync Redesign — Implementation Plan

> **For Composer 2.5 (Cursor):** Execute this plan **phase by phase**. Each phase is independently
> shippable and ends with a **PHASE GATE** — a concrete command whose output must match before you
> move to the next phase. Steps use checkbox (`- [ ]`) syntax. Follow TDD: write the test, watch it
> fail, implement minimally, watch it pass, commit. **Do not start a phase until the previous
> phase's gate is green.**

**Goal:** Replace the 5-traffic-form live-sync core with a single fixed-interval `/tick` packet, and
remove the implementation waste underneath it (per-row inserts, per-request DB connections,
full-table fingerprint rescans) — making capture/sync faster, lighter on the Studio editor, and
simpler. Design source of truth: [`docs/tick-protocol-redesign-design.md`](../../tick-protocol-redesign-design.md) (decisions D1–D15).

**Architecture:** A Rust daemon (`tiny_http` + SQLite/WAL) mirrors the Roblox Studio DataModel.
The plugin (Luau) detects edits via one `inst.Changed` signal per instance and ships them in one
periodic `POST /tick`; the daemon applies them in batched transactions and maintains per-service XOR
fingerprints for drift detection. Reflection metadata (`rbx_reflection_database`) drives the
property allow-list, versioned per `place.db`.

**Tech Stack:** Rust 2024 (`rusqlite` bundled, `tiny_http`, `sha2`, `flate2`, `serde_json`,
`rbx_reflection` + `rbx_reflection_database`, `ureq`), Luau (Roblox Studio plugin). Tests: Rust
in-crate `#[cfg(test)]` unit tests + integration tests that spawn the `studio-stud` binary
(CLI subcommands and raw HTTP), per the existing pattern in `tests/`.

---

## How this plan is structured (read first)

**Test styles available in this repo** (confirmed from `tests/`):
- **In-crate unit tests** — `#[cfg(test)] mod tests { use super::*; ... }` inside a `src/*.rs` file.
  These can reach `pub(crate)` / private items. Use for pure helpers and DB-level logic.
- **Integration via CLI subprocess** — `tests/live_convergence.rs` runs
  `Command::new(env!("CARGO_BIN_EXE_studio-stud"))` with `--storage-root <tmp>` and parses stdout
  JSON (subcommands: `ingest --raw <file>`, `live-delta --raw <file> --place <id>`,
  `live-dump <place>`, `live-verify --raw <file>`).
- **Integration via HTTP** — `tests/http_reliability.rs` / `tests/capture_complete.rs` spawn
  `serve` on an ephemeral port + temp storage-root and hit it over a raw `TcpStream`.

**Plugin (Luau) testing reality:** the plugin runs inside Roblox Studio and cannot run in CI.
- **Pure logic** (e.g. `Session.decide`) is unit-tested in the plugin's in-file `SelfTest`
  (truth-table pattern around `plugin/StudioStud.plugin.lua:31-47`). Add cases there.
- **Behavior** is verified by a **manual Studio checklist** PLUS **daemon-side assertions** — the
  daemon integration tests + the `daemon.log` telemetry (Phase 1) are the objective signal that the
  plugin did the right thing. Every plugin task below lists both.

**Phase calibration:** Phase 1 (daemon core) is written as full TDD steps. Phases 2–6 are specified
to **task + test + gate** granularity — each task names exact files, the precise change contract,
the real test/assertion that gates it, and run commands. Because later phases consume interfaces
built in earlier phases, **expand the current phase's tasks to step level just before executing it**
(the interfaces it depends on will then be concrete in the code). This is deliberate — over-coding
unbuilt phases against guessed interfaces would make the plan inaccurate.

**Commit discipline:** one commit per task (or per green test). Branch off `development`.

---

## File map (what changes, and why)

**Daemon (Rust):**
- `src/util.rs` — `open_db` pragmas (D5); add `cache_size`, `mmap_size`, `temp_store`.
- `src/storage.rs` — `init_schema`: add `service_fingerprints` table (D4), `script_sources` table
  (§9 seam #1), `meta.reflection_version` row (D14); helpers to read/write them.
- `src/capture.rs` — `ingest_rows` / `insert_instance`: prepared-statement batching (D5); per-service
  fingerprint accumulation (D4); script-Source ingest helper (seam #1).
- `src/live.rs` — `apply_delta_tx`: route per-instance XOR into per-service accumulators (D4).
- `src/conn_registry.rs` *(new)* — per-place persistent writer+reader connections (D10).
- `src/telemetry.rs` *(new)* — pure formatters for size/timing summaries (Q2); emitted via `obs`.
- `src/cli.rs` — wire the registry into `cmd_serve`; new debug subcommand `live-services <place>`;
  reflection subcommands (Phase 2); worker-lane routing (Phase 5).
- `src/http.rs` — `/tick` + `/tick/bulk/*` handlers, drift response, `applyScripts` seam (Phase 5);
  remove legacy endpoints (Phase 5).
- `src/reflection.rs` *(new)* — allow-list generation from `rbx_reflection_database`, runtime-fetch,
  version compare (Phase 2).
- `src/obs.rs` — (unchanged API; reused for telemetry emission).

**Plugin (Luau) — `plugin/StudioStud.plugin.lua`:**
- Detection collapse → one `inst.Changed` (Phase 3).
- Yielding baseline walk + batch-`pcall` + Source capture (Phase 4).
- Single `/tick` loop, per-service fingerprints, drift recovery, graceful drain, remove debounce
  slider (Phase 5).

**Protocol:** `PROTOCOL_VERSION` / `MIN_PLUGIN_PROTOCOL_VERSION` in `src/util.rs` + the plugin's
`PROTOCOL_VERSION` → 2 (Phase 5).

---

# PHASE 1 — Daemon Core Performance (no protocol change)

**Decisions:** D5, D10, D4 (daemon-side fingerprint), Q2 telemetry, §9 seams.
**Why first:** kills the measured 25 s `capture/complete` and per-request connection churn **without
touching the wire** — the existing plugin + endpoints keep working, so it's shippable and safe to
verify against today's protocol.
**Net effect target:** `capture/complete` p50 drops from ~25 s to **< 1 s** for the same snapshot;
`live/delta` p50 from ~0.8 s to **< 50 ms**.

### Task 1.1 — SQLite pragmas for throughput

**Files:**
- Modify: `src/util.rs` (`open_db`, ~lines 145-155)
- Test: `src/util.rs` (in-crate `#[cfg(test)] mod tests`)

- [ ] **Step 1: Write the failing test**

In `src/util.rs`, add (or extend) the in-crate test module:

```rust
#[cfg(test)]
mod pragma_tests {
    use super::*;

    #[test]
    fn open_db_sets_performance_pragmas() {
        let dir = std::env::temp_dir().join(format!("ss_pragma_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("t.db");
        let conn = open_db(&db).expect("open");

        let journal: String = conn
            .query_row("PRAGMA journal_mode", [], |r| r.get(0)).unwrap();
        assert_eq!(journal.to_lowercase(), "wal");

        let cache: i64 = conn.query_row("PRAGMA cache_size", [], |r| r.get(0)).unwrap();
        assert!(cache <= -16000, "expected >=16MB page cache, got {cache}");

        let mmap: i64 = conn.query_row("PRAGMA mmap_size", [], |r| r.get(0)).unwrap();
        assert!(mmap >= 268_435_456, "expected mmap >=256MB, got {mmap}");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test --lib pragma_tests::open_db_sets_performance_pragmas`
Expected: FAIL on the `cache_size` / `mmap_size` assertion (defaults are -2000 / 0).

- [ ] **Step 3: Implement**

In `open_db`, extend the `execute_batch` to add the pragmas (keep WAL/synchronous/foreign_keys):

```rust
conn.execute_batch(
    "PRAGMA journal_mode = WAL;
     PRAGMA synchronous = NORMAL;
     PRAGMA foreign_keys = ON;
     PRAGMA cache_size = -65536;   -- 64 MB page cache (negative = KB)
     PRAGMA mmap_size = 268435456; -- 256 MB memory-mapped I/O
     PRAGMA temp_store = MEMORY;",
)?;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cargo test --lib pragma_tests::open_db_sets_performance_pragmas`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/util.rs
git commit -m "perf(daemon): add cache_size/mmap_size/temp_store pragmas to open_db"
```

### Task 1.2 — Batch ingest with prepared statements (the 25 s killer)

`Transaction::execute` re-prepares its SQL on every call; with ~80k calls for a 10k-instance place
that dominates `capture/complete`. `prepare_cached` prepares each distinct SQL once and reuses it.

**Files:**
- Modify: `src/capture.rs` — `ingest_rows` (275-357) and `insert_instance` (393-497)
- Test: `tests/live_convergence.rs` (CLI integration — correctness regression)

- [ ] **Step 0: Surface `fingerprint` in the ingest output**

`cmd_ingest` (src/cli.rs:901) prints `materialize_snapshot`'s JSON, which today returns
`{ ok, captureId, placeId, placeKey, instances, revision, stored }` — **no `fingerprint`**. The
value already exists as `live_state.fingerprint` inside `materialize_snapshot` (src/capture.rs:~92).
Add it to the returned `json!({...})`:

```rust
// in materialize_snapshot's final Ok(json!({ ... }))
"fingerprint": live_state.fingerprint,
```

(Confirmed fixture: `tests/fixtures/live/baseline.json` has `place.placeId == "999001"` and
instances shaped `{id, parentId, path, name, className, depth, childCount, siblingIndex,
duplicateSiblingName, properties, attributes, tags}`.)

- [ ] **Step 1: Write the guarding test**

The refactor must not change behavior — same rows, same fingerprint. In `tests/live_convergence.rs`:

```rust
#[test]
fn ingest_baseline_is_deterministic_and_complete() {
    let storage = temp_storage("ingest_det");
    let out = run_cli(&["ingest", "--raw", fixture("baseline.json").to_str().unwrap()], &storage);
    assert_eq!(out.get("ok").and_then(Value::as_bool), Some(true));
    let count = out.get("instances").and_then(Value::as_i64).expect("instances");
    assert!(count > 0);
    let fp1 = out.get("fingerprint").and_then(Value::as_str).map(str::to_string);
    assert!(fp1.is_some(), "ingest must surface fingerprint (Step 0)");

    // Re-ingest must produce the identical fingerprint (determinism).
    let out2 = run_cli(&["ingest", "--raw", fixture("baseline.json").to_str().unwrap()], &storage);
    let fp2 = out2.get("fingerprint").and_then(Value::as_str).map(str::to_string);
    assert_eq!(fp1, fp2, "fingerprint must be stable across identical ingests");
}
```

- [ ] **Step 2: Run to verify it passes on current code** (this is a guard, not red-first)

Run: `cargo test --test live_convergence ingest_baseline_is_deterministic_and_complete`
Expected: PASS (establishes the invariant the refactor must preserve).

- [ ] **Step 3: Refactor `insert_instance` to `prepare_cached`**

Replace each `tx.execute("INSERT ...", params![...])?` in `insert_instance` with the cached form,
e.g. the main instance insert:

```rust
tx.prepare_cached(
    "INSERT INTO instances (
        capture_id, instance_id, parent_id, path, path_norm, display_path, display_path_norm,
        name, class_name, search_text, depth, child_count, sibling_index,
        duplicate_sibling_name, property_json
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
)?
.execute(params![
    capture_id, id, parent_id, path, path_norm, display_path, display_path_norm,
    name, class_name, search_text, depth, child_count, sibling_index,
    duplicate as i64, serde_json::to_string(&properties)?,
])?;
```

Do the same for the `instance_attributes`, `instance_tags`, and `keyword_hits` inserts in
`insert_instance`, and the `class_counts` insert in `ingest_rows`. (Same SQL string each iteration →
cached once.)

- [ ] **Step 4: Run the regression test + full suite**

Run: `cargo test --test live_convergence` then `cargo test`
Expected: PASS (identical fingerprints/counts; nothing else broke).

- [ ] **Step 5: Commit**

```bash
git add src/capture.rs tests/live_convergence.rs
git commit -m "perf(daemon): reuse prepared statements in ingest_rows/insert_instance"
```

### Task 1.3 — Per-service fingerprint table + invariant

Adds `service_fingerprints` (D4) maintained incrementally, with the invariant
**XOR(all service fingerprints) == global fingerprint**. This is what `/tick` drift detection (Phase 5)
will consume; here we build + maintain + test it.

**Files:**
- Modify: `src/storage.rs` (`init_schema`) — add the table
- Modify: `src/capture.rs` (`ingest_rows`) — accumulate per-service during the instance loop
- Modify: `src/live.rs` (`apply_delta_tx`) — route XOR per service
- Add: `src/capture.rs` — `pub(crate) fn service_of(path: &str) -> &str` (first path segment)
- Add: `src/cli.rs` — debug subcommand `live-services <place>` printing rows + global fp
- Test: `src/capture.rs` in-crate (`service_of`) + `tests/live_convergence.rs` (invariant)

- [ ] **Step 1: Write the failing unit test for `service_of`**

```rust
#[cfg(test)]
mod service_tests {
    use super::*;
    #[test]
    fn service_of_returns_first_segment() {
        assert_eq!(service_of("Workspace/Model/Part"), "Workspace");
        assert_eq!(service_of("ServerScriptService/Init"), "ServerScriptService");
        assert_eq!(service_of("Workspace"), "Workspace");
        assert_eq!(service_of(""), "");
    }
}
```

Run: `cargo test --lib service_tests` → FAIL (`service_of` undefined).

- [ ] **Step 2: Implement `service_of`**

```rust
pub(crate) fn service_of(path: &str) -> &str {
    match path.split_once('/') {
        Some((head, _)) => head,
        None => path,
    }
}
```

Run: `cargo test --lib service_tests` → PASS.

- [ ] **Step 3: Add the table to `init_schema`**

Add inside the `execute_batch` schema string in `src/storage.rs`:

```sql
CREATE TABLE IF NOT EXISTS service_fingerprints (
    capture_id TEXT NOT NULL,
    service_name TEXT NOT NULL,
    fingerprint TEXT NOT NULL,
    instance_count INTEGER NOT NULL,
    PRIMARY KEY (capture_id, service_name)
);
```

- [ ] **Step 4: Accumulate per-service in `ingest_rows`**

In the instance loop, alongside `fingerprint_acc`, keep a `BTreeMap<String, [u8;32]>` and a
`BTreeMap<String, i64>` keyed by `service_of(&path)`, XOR each instance digest into its service's
accumulator and increment its count. After the loop, write one `service_fingerprints` row per
service (use `prepare_cached`). Keep the existing global `fingerprint_acc` return value.

- [ ] **Step 5: Route per-service XOR in `apply_delta_tx`**

For each removed/upserted instance, look up its `path` (removed: `SELECT path` before delete;
upserted: `str_field(inst, "path")`), compute its service via `service_of`, and XOR the same digest
you already XOR into the global `acc` into that service's row (read-modify-write the
`service_fingerprints` row in the same tx, adjusting `instance_count`). Add a private
`fn xor_service(tx, capture_id, service, digest, count_delta)`.

- [ ] **Step 6: Add `live-services` debug subcommand**

In `src/cli.rs`, add a subcommand that opens the place DB and prints:
```json
{ "ok": true, "global": "<hex>", "services": { "Workspace": {"fingerprint":"<hex>","count":N}, ... },
  "xorOfServices": "<hex>" }
```
where `global` is `live_state.fingerprint` and `xorOfServices` is the XOR of all
`service_fingerprints.fingerprint` values (parsed from hex, folded).

- [ ] **Step 7: Write the invariant integration test**

In `tests/live_convergence.rs`:

```rust
#[test]
fn service_fingerprints_xor_to_global() {
    let storage = temp_storage("svc_fp");
    run_cli(&["ingest", "--raw", fixture("baseline.json").to_str().unwrap()], &storage);
    let dump = run_cli(&["live-services", "999001"], &storage); // place id per fixture
    let global = dump.get("global").and_then(Value::as_str).unwrap();
    let xored = dump.get("xorOfServices").and_then(Value::as_str).unwrap();
    assert_eq!(global, xored, "XOR of per-service fingerprints must equal the global fingerprint");

    // Apply a delta and re-check the invariant holds.
    run_cli(&["live-delta", "--raw", fixture("delta_struct.json").to_str().unwrap(),
              "--place", "999001"], &storage);
    let dump2 = run_cli(&["live-services", "999001"], &storage);
    assert_eq!(dump2.get("global").and_then(Value::as_str),
               dump2.get("xorOfServices").and_then(Value::as_str));
}
```

> Confirm the fixture's place id (the agent reported `live-delta ... --place 999001`); adjust if the
> baseline fixture uses a different `placeId`.

Run: `cargo test --test live_convergence service_fingerprints_xor_to_global` → PASS.

- [ ] **Step 8: Commit**

```bash
git add src/storage.rs src/capture.rs src/live.rs src/cli.rs tests/live_convergence.rs
git commit -m "feat(daemon): maintain per-service XOR fingerprints (XOR == global invariant)"
```

### Task 1.4 — Persistent per-place connection registry (D10)

Today `materialize_snapshot` and `apply_delta` call `open_db()` per request (file open + pragma
replay + WAL recovery every time). Introduce a registry that keeps a persistent **writer** connection
(behind a `Mutex`) and **reader** connection(s) per place, lazily opened and idle-evicted.

**Files:**
- Add: `src/conn_registry.rs`
- Modify: `src/lib.rs` (`pub mod conn_registry;`)
- Modify: `src/capture.rs`, `src/live.rs` — accept/use a writer handle instead of `open_db`
- Modify: `src/cli.rs` / `src/http.rs` — construct the registry once and thread it through `ServeConfig`
- Test: `src/conn_registry.rs` in-crate + `tests/live_convergence.rs` regression (must stay green)

- [ ] **Step 1:** Write the registry contract test (in-crate): opening place "A" twice returns a
  handle to the **same** underlying connection (e.g. a write to a temp table on the first handle is
  visible on the second); evicting "A" then re-opening yields a fresh connection. Run → FAIL.
- [ ] **Step 2:** Implement `ConnRegistry { inner: Mutex<HashMap<String, PlaceHandle>> }` with
  `with_writer(place_key, |conn| -> Result<T>)` (locks that place's writer `Mutex<Connection>`),
  `reader(place_key) -> Arc<Connection>` (WAL read connection), lazy open via `open_db` + `init_schema`
  on first use, and `evict_idle(now)` / `last_used` tracking. Run in-crate test → PASS.
- [ ] **Step 3:** Thread the registry through `ServeConfig` (add `pub registry_conns: Arc<ConnRegistry>`),
  construct it in `cmd_serve`, and change `materialize_snapshot` / `apply_delta` to use
  `registry.with_writer(place_key, |conn| ...)` instead of `open_db`. Keep `materialize_snapshot`'s
  CLI path (which has no registry) working by constructing a one-shot registry there.
- [ ] **Step 4:** Run `cargo test` (the CLI + HTTP integration tests are the regression gate — they
  must all still pass). Expected: PASS.
- [ ] **Step 5:** Commit `feat(daemon): persistent per-place connection registry (writer+reader)`.

### Task 1.5 — Per-phase telemetry (Q2)

**Files:**
- Add: `src/telemetry.rs` (pure formatters) + `src/lib.rs` (`pub mod telemetry;`)
- Modify: `src/capture.rs`, `src/live.rs` — emit a summary via `obs::event("telemetry", &...)`
- Test: `src/telemetry.rs` in-crate (pure formatter)

- [ ] **Step 1:** Failing unit test: `format_ingest(instance_count=1234, bytes=98765, ms=420)` →
  a deterministic string like `"ingest n=1234 bytes=98765 ms=420 (78µs/inst)"`. Run → FAIL.
- [ ] **Step 2:** Implement the pure formatter(s) for ingest, delta, and bulk (counts, bytes, ms,
  derived per-item). Run → PASS.
- [ ] **Step 3:** Emit them: wrap `ingest_rows` and `apply_delta` with `Instant::now()` timing and
  `obs::event("telemetry", &telemetry::format_ingest(...))`. (No assertion on the log; the formatter
  is the unit under test, emission is observed manually.)
- [ ] **Step 4:** `cargo test` → PASS. Commit `feat(daemon): per-phase ingest/delta telemetry`.

### Task 1.6 — Write-readiness seams (schema reservations)

**Files:**
- Modify: `src/storage.rs` (`init_schema`) — add `script_sources` + `meta.reflection_version`
- Add: `src/storage.rs` — `pub(crate) fn upsert_script_source(...)` + `read_reflection_version` /
  `write_reflection_version` helpers (unused until Phases 2/4)
- Test: `src/storage.rs` in-crate (schema presence + helper round-trip)

- [ ] **Step 1:** Failing test: open a temp DB, `init_schema`, assert `script_sources` table exists
  (`SELECT name FROM sqlite_master WHERE type='table' AND name='script_sources'` returns 1 row), and
  `write_reflection_version(&conn, "0.659")` then `read_reflection_version(&conn)` round-trips. Run → FAIL.
- [ ] **Step 2:** Add to `init_schema`:
  ```sql
  CREATE TABLE IF NOT EXISTS script_sources (
      capture_id TEXT NOT NULL, instance_id TEXT NOT NULL,
      source_text TEXT NOT NULL, source_hash TEXT NOT NULL,
      last_synced_hash TEXT, PRIMARY KEY (capture_id, instance_id)
  );
  ```
  Implement `read/write_reflection_version` over the existing `meta` table (key `reflection_version`)
  and a no-op-for-now `upsert_script_source`. Run → PASS.
- [ ] **Step 3:** Commit `feat(daemon): reserve script_sources table + reflection_version meta (seams)`.

### ✅ PHASE 1 GATE

- [ ] `cargo test` — **all** unit + integration tests pass.
- [ ] `cargo clippy --all-targets -- -D warnings` — clean.
- [ ] **Manual perf check:** run `studio-stud serve --storage-root <tmp> --verbose`, capture a real
  place from Studio (or `cargo run -- ingest --raw <a large fixture>`), and confirm in `daemon.log`
  that the `telemetry` line for ingest shows **ms < 1000** for a place that previously took seconds,
  and that `capture/complete` (HTTP path) returns well under a second. Record the before/after in the
  commit message of the gate.
- [ ] Tag: `git commit --allow-empty -m "checkpoint: Phase 1 daemon core complete (gate green)"`.

---

# PHASE 2 — Reflection allow-list + versioning (daemon)

**Decisions:** D9, D14, D15. **No protocol change** (daemon-internal + a new read-only endpoint the
plugin will consume in Phase 3).

**Tasks (expand to steps before executing):**

1. **`src/reflection.rs` — generate the curated allow-list from `rbx_reflection_database`.**
   - Walk every class + superclass chain; for each property keep it if it's readable from a plugin
     (`Scriptability` allows read) and serializable, drop `Deprecated`/`Hidden`; tag `readOnly` when
     not writable. Output `BTreeMap<String /*class*/, Vec<PropEntry{name, read_only}>>`.
   - **Test (in-crate):** assert known truths from the bundled DB — e.g. `BasePart` curated set
     contains `Transparency` (writable, `read_only=false`) and `Size`, and that a known read-only
     like `ClassName` is absent or tagged `read_only=true`. (Pin to stable, long-lived properties.)
   - **Gate:** `cargo test --lib reflection`.

2. **Runtime-fetch the dump for a target version (with bundled fallback).**
   - `fn fetch_dump_for_version(version: &str) -> Result<ApiDump>` using `ureq`; on any failure,
     fall back to `rbx_reflection_database::get()` (the bundled DB).
   - **Test:** unit-test the fallback path deterministically (inject a failing fetcher → returns the
     bundled DB, no panic). Do **not** hit the network in CI.
   - **Gate:** `cargo test --lib reflection::fetch`.

3. **Version compare + `meta.reflection_version` flow (D15).**
   - `fn needs_update(db_version: Option<&str>, studio_version: &str) -> bool` (absent or differs).
   - On connect (the existing ping/heartbeat handler, until `/tick` exists): if `needs_update`,
     regenerate the allow-list, and **write `meta.reflection_version` only after success** (atomic);
     on failure, log `obs::event("reflection", "update failed: ...")` and keep the old version.
   - **Test (in-crate):** `needs_update(None, "0.659") == true`, `needs_update(Some("0.659"),"0.659")
     == false`, `needs_update(Some("0.658"),"0.659") == true`.
   - **Gate:** `cargo test --lib reflection::version`.

4. **`GET /studio-stud/allowlist` endpoint** returning `{ version, classes: { Class: [{name,readOnly}] } }`.
   - **Test (HTTP integration):** spawn `serve`, GET the endpoint, assert `BasePart` includes
     `Transparency`. (Pattern: `tests/http_reliability.rs`.)
   - **Gate:** `cargo test --test http_reliability allowlist`.

### ✅ PHASE 2 GATE
`cargo test` green; `GET /studio-stud/allowlist` returns a non-empty class map and a version string;
ingest still writes `meta.reflection_version`. Manual: hit `/studio-stud/allowlist` with curl and eyeball `BasePart`.

---

# PHASE 3 — Plugin detection collapse (Luau)

**Decisions:** D2, D9 (consume allow-list + probe). **Plugin-only**, no wire change yet.

**Tasks:**

1. **Fetch the allow-list on connect** and store it as the curated filter (replacing the static
   `CLASS_PROPERTIES` at `plugin/StudioStud.plugin.lua:220`). Keep the static table as offline
   fallback.
   - **Test:** add a `SelfTest` case asserting the curated-set lookup is O(1) membership and that a
     known property (`Transparency` on a Part) is present after load.
   - **Manual:** connect; confirm the plugin logs the loaded allow-list version.

2. **Collapse `registerInstance` (≈2109) to ~3 connections:** one `inst.Changed` (filter via the
   curated set), keep `AncestryChanged` + `AttributeChanged`, special-case `ValueBase` →
   `GetPropertyChangedSignal("Value")`. Remove the per-property `GetPropertyChangedSignal` loop
   (2165-2176).
   - **Test (SelfTest):** a pure helper `shouldMarkDirty(className, propName, curatedSet)` →
     truth-table cases (curated prop → true; uncurated → false; ValueBase "Value" → true). Add to
     SelfTest following the `Session.decide` pattern.
   - **Manual Studio checklist:** with live mode on, change a Part's Position → it syncs (delta
     fires); change an uncurated property → no delta; an IntValue's `Value` change → syncs.
   - **Daemon-side assertion:** during the manual run, `daemon.log` shows `live-delta APPLY` for the
     curated change and **no** delta for the uncurated one.

3. **Gap-discovery probe (D9):** when `inst.Changed` fires with a name not in the curated set,
   enqueue `(className, propName)` for the next report to the daemon (dedup in a set).
   - **Test (SelfTest):** the probe set records unknown names and dedups.
   - **Manual:** trigger a known-uncurated-but-real property; confirm the daemon logs a
     "candidate property" line (daemon side handles add/persist — wire the daemon validation here or
     defer the daemon add to Phase 5's tick channel; for Phase 3 just confirm the probe **collects**).

### ✅ PHASE 3 GATE
SelfTest passes (run the plugin's SelfTest in Studio). Manual checklist green. Connection-count
sanity: log the number of signal connections created for a known subtree before/after — expect ~7×
fewer. Daemon log confirms deltas still fire for curated changes only.

---

# PHASE 4 — Non-blocking baseline + Source capture (Luau)

**Decisions:** D6, §9 seam #1.

**Tasks:**

1. **Yield the baseline walk** (the synchronous walk ~1687-1740): process instances in batches and
   `task.wait()` every **500** (configurable). Pull the count into a named constant `YIELD_EVERY = 500`.
   - **Test (SelfTest):** a pure `function shouldYield(processedCount, yieldEvery)` returns true at
     multiples of `yieldEvery`. Add truth-table cases.
   - **Manual:** capture a large place (10k+ instances) → the Studio window stays responsive (no
     multi-second freeze); a progress indicator updates.

2. **Optimistic batch-`pcall`** for property reads: one `pcall` reading all curated props for an
   instance, falling back to per-property `pcall` only on error (replaces the per-property `pcall`
   pattern ~1599-1627).
   - **Test (SelfTest):** a pure `readProps` wrapper test using a fake instance table (success path
     returns all; a throwing prop triggers the per-prop fallback and still returns the rest).
   - **Manual:** capture still records all curated props (spot-check a Part in `live-dump`).

3. **Capture script `Source`** for `Script`/`LocalScript`/`ModuleScript` (today only
   `Enabled`/`Disabled`/`LinkedSource`, line 341). Add `Source` to the captured payload + a
   normalized-newline sha256 computed the same way as the projection
   (`normalize_newlines` + `sha256_hex`, `src/write/safety.rs`).
   - **Daemon side:** `materialize`/`ingest` writes Source into `script_sources` (the Phase 1 seam) —
     wire `upsert_script_source` into `insert_instance` when the instance is a script class.
   - **Test (CLI integration):** ingest a fixture containing a ModuleScript with `Source`; a new
     `live-dump`/`live-services`-style check (or a `script-source <place> <path>` debug command)
     returns the stored text + a hash equal to the projection's hash for the same bytes.
   - **Gate add:** `cargo test --test live_convergence script_source_round_trip`.

### ✅ PHASE 4 GATE
SelfTest green; manual large-place capture is non-freezing; `script_sources` is populated and its
hash matches the projection hash for identical bytes (the cross-check that makes future repo↔Studio
reconciliation a map-join). `cargo test` green.

---

# PHASE 5 — The `/tick` protocol cutover (both sides)

**Decisions:** D1, D3, D4 (plugin drift), D7, D11/D13 (writer-lane), §9 seam #3 (`applyScripts`),
play/pause graceful drain. **This is the breaking change** — land plugin + daemon together; bump
protocol; delete legacy endpoints.

**Daemon tasks:**

1. **`POST /studio-stud/tick`** handler: parse the packet (D1 schema in design §4.1), apply `ops` via
   the Phase-1 batched delta path inside the place's writer lane, compare the packet's
   `serviceFingerprints` to stored `service_fingerprints` → build `driftServices`, fold in
   `sessionMode` (record), `request` inbox, and the reserved empty `applyScripts`. **Empty-tick
   short-circuit:** if `ops` empty and fingerprints match, return without acquiring the writer.
   - **Test (HTTP integration):** a keepalive tick (empty ops, matching fp) returns
     `driftServices: []` and does not bump revision; a tick with `ops.upserted` bumps revision and
     updates the right service fingerprint; a tick with a deliberately wrong `serviceFingerprints`
     entry returns that service in `driftServices`.

2. **`POST /studio-stud/tick/bulk/{start,chunk,complete}`** — reuse the existing chunked-upload
   machinery (`capture/start|chunk|complete` internals) under the new paths; the next `/tick` with
   `bulkRef` commits it via `materialize` into the place.
   - **Test (HTTP):** start→chunk→complete a baseline-sized payload, then a `/tick` with `bulkRef`
     sets revision=1 and populates `service_fingerprints`.

3. **Worker-lane routing (D11/D13):** route requests by `placeId` to a per-place writer thread
   (borrowed from a fixed pool of `1 + 3`); reads/keepalives go to the shared pool. Replace the
   single mpsc/4-worker block in `cmd_serve` (860-898).
   - **Test (HTTP):** `concurrent_pings_while_serve_is_running`-style test still passes; add a test
     that interleaved ticks for the same place apply in order (revision strictly increments, no
     `revision_mismatch` under sequential client sends).

4. **Delete legacy endpoints** (`/capture/request`, `/capture/start|body|chunk|complete`,
   `/live/delta`, `/live/fingerprint`, `/live/verify/*`) and **bump** `PROTOCOL_VERSION`/
   `MIN_PLUGIN_PROTOCOL_VERSION` to `2` in `src/util.rs`.
   - **Test:** old endpoints now return 404; `/ping` reports protocol 2.

**Plugin tasks:**

5. **Replace the three loops** (poll 2865, debounce 2608, verify 2629) with **one fixed-interval tick
   loop** (default **0.5 s**, runtime setting). Build the packet (sessionMode, baseRevision,
   per-service fingerprints, inline `ops` or `bulkRef` spill above the inline threshold), POST `/tick`,
   apply the response (revision, `driftServices`, `request`).
   - **Test (SelfTest):** pure `buildTickBody(dirtyUpsert, dirtyRemoved, fingerprints, rev)` shape
     test; `classifyPayload(bytes)` → inline vs bulk at the threshold.

6. **Per-service fingerprints (plugin side)** maintained as instances are registered/changed; **drift
   recovery** = coalesced re-walk of `driftServices` only (yielding) → bulk spill; **no-data-loss
   invariant** (don't clear dirty flags during recovery — design §6).
   - **Test (SelfTest):** pure recovery-state-machine helper (given driftServices, dirty set is
     preserved across recovery).
   - **Manual:** force drift (edit during a simulated stall) → only the drifted service re-walks, no
     lost edits (verify via `live-services`).

7. **Graceful drain on entering play** (finish the one in-flight op, then keepalive-only) and **remove
   the sync-debounce slider** from the plugin UI.
   - **Manual:** start a capture, hit Play mid-upload → the upload completes, then only keepalive
     ticks flow (`sessionMode:"play"`); Stop → fingerprint short-circuit resumes instantly.

### ✅ PHASE 5 GATE
`cargo test` green (new `/tick` + bulk + routing tests; legacy-404 tests). Plugin SelfTest green.
**Full manual loop:** fresh connect → baseline via `/tick/bulk` → edit storm (deltas via `/tick`) →
induce drift (recovers one service) → Play/Stop (drain + resume). `daemon.log` telemetry shows: most
ticks empty/cheap, deltas < 50 ms, **no** periodic full re-baselines (contrast the pre-rework log:
44 baselines / 12 verifies / 85 deltas → expect deltas to dominate, bulk only on connect/drift).

---

# PHASE 6 — Verify & soak

**Tasks:**
1. **Update `tests/http_reliability.rs` + `tests/live_convergence.rs`** for protocol v2 (new
   endpoints, removed legacy). Add: large-place capture timing assertion (sanity, generous bound),
   drift-injection convergence, play↔edit transition, daemon-restart-mid-session reconnect.
2. **Soak script** (`scripts/validate-live-capture.ps1` exists — extend it) driving a long edit
   session and asserting the daemon log shows no constant-bulk pattern.
3. **Update docs:** mark the design doc Status → Implemented; note the measured before/after.

### ✅ PHASE 6 GATE
Full `cargo test` green; soak run shows delta-dominated traffic and stable revision growth; design
doc updated with real measured numbers (capture/complete, delta p50, idle traffic).

---

## Self-review (author checklist — done)

- **Spec coverage:** D1 (P5), D2 (P3), D3 (P5 + UI removal), D4 (P1 daemon fp + P5 plugin drift),
  D5 (P1.1/1.2/1.4), D6 (P4), D7 (P5.4), D8 (full-mirror — preserved, no task needed), D9 (P2 + P3
  probe), D10 (P1.4), D11/D13 (P5.3), D12 (multi-reader — P1.4 reader handles + P5.3), D14/D15 (P2),
  §9 seams (P1.6 schema, P4 Source, P5 applyScripts), Q2 telemetry (P1.5). All mapped.
- **Test reality:** plugin behavior is gated by SelfTest (pure logic) + manual Studio checklist +
  daemon-side log/integration assertions, because Luau can't run in CI — called out explicitly per
  task rather than faked.
- **Verified against the code (no open assumptions in Phase 1):** fixture `placeId` is `999001`
  (`tests/fixtures/live/baseline.json`); `cmd_ingest` (src/cli.rs:901) prints `materialize_snapshot`'s
  JSON which lacks `fingerprint`, so Task 1.2 Step 0 adds it (the value already exists in
  `live_state.fingerprint`). The instance payload shape used in tests matches the fixture.

---

_Plan derived from `docs/tick-protocol-redesign-design.md` (D1–D15), grounded in the current daemon
internals (util/storage/capture/live/cli/http/obs) and the existing CLI+HTTP integration test
patterns. Phase 1 is execution-ready; expand Phases 2–6 to step level just before executing each._
