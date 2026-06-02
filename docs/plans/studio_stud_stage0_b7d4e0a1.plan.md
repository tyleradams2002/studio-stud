---
name: ""
overview: ""
todos: []
isProject: false
---

# Studio Stud Platform — Stage 0 Execution Plan (Foundations, Cleanup, Benchmarks)

Status: READY TO EXECUTE. Source of truth: `docs/studio-stud-platform-design.md` §11 (Stage 0) and
Appendix A. This plan is the authoritative, implementation-level breakdown for Composer; it does not
re-litigate the design, it executes it.

Scope is exactly the three Stage 0 workstreams and nothing more. Do NOT introduce any Stage 1+ surface
(no tab host, no `/studio-stud/live/*` delta protocol, no `/studio-stud/write/*`, no policy file, no
`rbx-dom`, no `full-moon`, no future-stage module stubs). Per the locked decisions below, future-stage
modules are created in their own stage, not now.

---

## 0. Locked decisions (do not revisit)

1. **Per-stage modules.** Create ONLY modules that hold real existing code. Do NOT scaffold empty
   `live.rs` / `write.rs` / `project.rs` / `diff.rs` / `sync.rs` — each lands in its own stage.
2. **Built-in benchmark.** No `criterion`, no new crate dependency. Timing is a `std::time::Instant`
   harness exposed as a hidden `bench` subcommand (details in Workstream C). Fits the local, zero-token
   dev-space CI model (design §2 "Repository / publish boundary").
3. **Update the stale connector header** in `src/Shared/Constants/BoatAuthoringConfig.luau` to record
   that the generator was retired in Stage 0 (the file itself is kept as static data).
4. This plan is saved under `.cursor/plans/` matching the existing `*_<hex>.plan.md` convention.

## 1. Hard guardrails / definition of done

- **Zero behavior change to `capture`, `analyze`, `query`, `status`, `doctor`, `serve`, `ingest`.**
  The refactor is mechanical relocation only. Public CLI surface, stdout bytes, HTTP routes, JSON
  response shapes, and SQLite schema are all byte/shape-identical to pre-Stage-0.
- **Golden-gated.** Output goldens are captured BEFORE any code moves (Workstream B0) and are the
  contract the split must not break.
- **Every step is independently revertable via git.** Boat files are untracked; the lib split and bench
  are additive.
- **No clippy regressions; `cargo build` (via `build-local.ps1`) clean.**

## 2. Current state (verified facts, do not re-discover)

- All daemon code is in one file: `tools/studio_stud/src/main.rs` — **2,909 lines / ~105 KB**, binary
  crate only (no `lib.rs`). Edition 2024. Deps: `anyhow, chrono, clap(derive), dirs, flate2,
  rusqlite(bundled), serde, serde_json, sha2, tiny_http, uuid`.
- **No tests, no `tests/`, no fixtures, no benches** exist under `tools/studio_stud/`.
- Build: `tools/studio_stud/build-local.ps1` runs `cargo build` then copies
  `target/debug/studio-stud.exe` → `bin/studio-stud.exe`. `.gitignore` tracks only
  `bin/studio-stud.exe`.
- Boat tooling to remove is **untracked** (`git status` shows `??`):
  `tools/plugin/BoatConfigurator.plugin.lua`, `tools/boat_plugin_connector.py`. Plus the gitignored
  local token `tools/.boat_plugin_connector.token` and its `.gitignore` line (line 5). Port **31912**
  appears ONLY inside those two files (verified by repo-wide grep).
- Keep as static data: `src/Shared/Constants/BoatAuthoringConfig.luau` (untracked) and
  `src/Shared/Constants/BoatDatabase.luau` (modified). No `src/**` runtime code references the
  connector/port/plugin — they are dev-only tools, so removal cannot affect game load.
- `docs/studio-stud.md` does NOT reference the connector (only unrelated `BoatSpawnPoints` query
  examples). `docs/repo-map.md` auto-regenerates and needs no manual edit.

### Existing daemon HTTP routes (must be preserved verbatim in `http.rs`)

`handle_daemon_request` (`main.rs:926`) routes these. Note the legacy aliases — they are the CAPTURE
upload path, NOT the future Stage 2 live-delta path. Do not rename, drop, or collapse any alias.

| Method | Path(s) |
| --- | --- |
| GET | `/ping`, `/studio-stud/ping`, `/studio-stud/manifest` |
| GET | `/request-sync`, `/studio-stud/capture/request` |
| GET | `/studio-stud/capture/status` (`?requestId=`) |
| POST | `/request-sync`, `/studio-stud/capture/request` |
| POST | `/live-sync/start`, `/studio-stud/capture/start` |
| POST | `/live-sync/body`, `/studio-stud/capture/body` (`?syncId=`) |
| POST | `/live-sync/chunk`, `/studio-stud/capture/chunk` (`?syncId=&index=`) |
| POST | `/live-sync/complete`, `/studio-stud/capture/complete` |
| fallback | `{ "ok": false, "error": "not_found" }` → HTTP 404 |

Protocol constants stay fixed: `PROTOCOL_VERSION = 1`, `MIN_PLUGIN_PROTOCOL_VERSION = 1`,
`MAX_CHUNK_BYTES = 900_000`, `SCHEMA_VERSION = 1`.

---

## 3. Execution order (for Composer)

Do the workstreams in this order; A is independent and lowest-risk, B0 must precede any code movement.

1. **A** — remove boat tooling + header edit (independent, trivially reversible).
2. **B0** — capture golden baselines from the CURRENT binary (before touching `main.rs`).
3. **C-fixtures** — land the fixture snapshot(s) (shared by goldens and bench).
4. **B1** — introduce `lib.rs` + thin `main.rs` shim (no logic change).
5. **B2** — module split, compiling and re-running goldens after each module is extracted.
6. **C-harness** — add the `bench` subcommand + record baseline numbers + doc.
7. Final exit-gate verification (§7).

---

## 4. Workstream A — Remove unused boat tooling

### A1. Delete files
- Delete `tools/plugin/BoatConfigurator.plugin.lua`.
- Delete `tools/boat_plugin_connector.py`.
- Delete `tools/.boat_plugin_connector.token` if present (gitignored local file).
- If `tools/plugin/` is now empty (it only contained the boat plugin), remove the empty directory.

### A2. `.gitignore`
- Remove line 5: `tools/.boat_plugin_connector.token`. Leave all other entries untouched.

### A3. Update stale header (locked decision 3)
In `src/Shared/Constants/BoatAuthoringConfig.luau`, the top comment currently reads
`-- AUTO-GENERATED by tools/boat_plugin_connector.py (Boat Configurator plugin).` and line ~64 references
"the local connector". Replace the generator attribution with a note that the connector was retired in
Stage 0 of the Studio Stud platform rebuild and that this file is retained as static data, regenerated by
the rebuilt Boat Configurator panel in Stage 8. Do not change any data/table values — comment text only.

### A4. Verify (exit criteria for A)
- Repo-wide grep for `31912`, `boat_plugin_connector`, `BoatConfigurator`, `FishersLifeBoatConnector`
  returns matches ONLY in `docs/studio-stud-platform-design.md` (and `docs/repo-map.md` until it
  regenerates). No hit in `src/**` or `tools/**`.
- Confirm no `src/**` code path requires the removed tooling (dev-only; nothing imports it).
- `BoatAuthoringConfig.luau` + `BoatDatabase.luau` still parse and load (game boots; their merge
  contract is unchanged).

---

## 5. Workstream B — Testable daemon + `main.rs` split (the risky part)

### B0. Golden baselines FIRST (gate for the whole split)

Build the current binary unchanged, then freeze deterministic outputs as goldens. These run against the
fixture DB from Workstream C (build the fixture first if not already present), NOT against live Studio, so
they are reproducible.

1. `pwsh tools/studio_stud/build-local.ps1` → produces `bin/studio-stud.exe`.
2. Create `tools/studio_stud/tests/fixtures/` with a frozen raw snapshot (see §6 C1).
3. Ingest the fixture into a throwaway storage root and capture stdout for the read commands:
   - `studio-stud ingest --raw <fixture> --storage-root <tmp>`
   - `studio-stud analyze <placeKey> --report context --report findings --report critical --storage-root <tmp>`
   - `studio-stud analyze <placeKey> --report comparison --storage-root <tmp>`
   - `studio-stud query <placeKey> --class Part --limit 25 --storage-root <tmp>`
   - `studio-stud query <placeKey> --name BoatSpawnPoints --storage-root <tmp>`
   - `studio-stud query <placeKey> --tree Workspace/BoatSpawnPoints --depth 1 --storage-root <tmp>`
   - `studio-stud query <placeKey> --detail Workspace/BoatSpawnPoints --props Position,Size --storage-root <tmp>`
   - `studio-stud status --storage-root <tmp>` and `--markdown`
   - `studio-stud doctor --storage-root <tmp>`
   - one `--markdown` variant of `analyze` to lock the markdown renderers.
4. Save each stdout verbatim under `tools/studio_stud/tests/golden/<name>.txt`. Normalize only known
   nondeterministic fields if any leak in (timestamps, absolute paths, capture UUIDs) — prefer pointing
   `--storage-root` at a temp dir and using a fixture with fixed IDs so normalization is unnecessary.
   If normalization is required, do it identically in B0 and in the assertion harness.

These goldens are committed and become integration tests in B2/§6.

### B1. Introduce `lib.rs` + thin `main.rs`

Currently everything is private in a binary crate, so `cargo test` and `tests/` integration tests cannot
reach any code. Add a library target:

- New `tools/studio_stud/src/lib.rs` declaring the modules and exposing a single entry point, e.g.
  `pub fn run() -> anyhow::Result<()>` (parses `Cli` and dispatches), plus `pub` re-exports needed by
  integration tests (at minimum the command handlers or a `run_with_args(args: impl IntoIterator<...>)`).
- `main.rs` shrinks to:
  ```rust
  fn main() -> anyhow::Result<()> { studio_stud::run() }
  ```
- `Cargo.toml`: add a `[lib]` (default `src/lib.rs`) alongside the existing binary. Crate name stays
  `studio-stud`; the lib path is `studio_stud`. No dependency or version changes.

This is a pure restructure — no logic edits. Build + goldens must pass before B2.

### B2. Module split

Split `main.rs`'s contents into modules under `src/`. **Deviation from design Appendix A (documented and
intentional):** Appendix A lists `output.rs` but provides no home for the substantial query engine or the
analyze view-builders. Folding both into `output.rs` would make it large and contradict its stated
"compact JSON / markdown" role. Therefore add `analyze.rs` and `query.rs` and keep `output.rs` for shared
compact-output primitives. Also add `util.rs` for cross-cutting constants/helpers/types. This is a
superset of Appendix A for the read layer only; it introduces NO new behavior and no future-stage code.

#### Recommended Stage 0 module layout (existing code only)

| Module | Items to move (current `main.rs` line refs; lines shift as you go) |
| --- | --- |
| `util.rs` | Constants `APP_NAME, DEFAULT_PROJECT_KEY, DEFAULT_HOST, DEFAULT_PORT, MAX_CHUNK_BYTES, SCHEMA_VERSION, PROTOCOL_VERSION, MIN_PLUGIN_PROTOCOL_VERSION, KEYWORDS, CRITICAL_NAMES` (21–50); pure helpers `make_id` (1304), `now_utc` (1438), `value_to_string` (1430), `str_field` (1798), `opt_str_field` (1802), `matches_keyword` (1806), `build_search_text` (1813), `path_root` (1897), `looks_like_invisible_helper` (1906), `safe_key` (1277), `display_path` (643), `percent_decode` (1214), `split_url` (1204), `required_query` (1238); shared types `Finding` (245), `DoctorCheck` (254) + constructors `pass`/`warn`/`fail` (619/627/635). |
| `storage.rs` | `Storage` (202) + `impl Storage` (1246), `PlaceStorage` (208), `Pointer` (193), `CaptureMeta` (217); `find_studio_stud_dir` (494), `init_schema` (1442), `ensure_column` (1559), `backfill_normalized_columns` (1571), `read_pointer` (2160), `atomic_write_json` (2164), `promote_pointers` (2060), `prune_old_captures` (2078), `retained_capture_ids` (2104), `prune_sqlite_captures` (2117), `resolve_place` (2171), `latest_capture_for_place` (2192), `previous_capture_for_place` (2198), `capture_by_id` (2208), `remove_if_exists` (612). |
| `capture.rs` | `materialize_snapshot` (730), `ingest_sqlite` (1616), `capture_meta` (1367), `decode_raw_snapshot` (1289), `encode_gzip_json` (1298), `inject_sync_metadata` (1164); findings: `FindingState` (1825), `update_findings` (1834), `insert_findings` (1924), `add_finding` (2008), `add_finding_count` (2044). |
| `http.rs` | `DaemonState` (237), `UploadState` (231); `handle_daemon_request` (926) with the verbatim route table (§2), `complete_daemon_upload` (1095), `assemble_upload` (1142), `read_request_bytes` (1177), `read_request_json` (1183), `respond_json` (1191), `manifest_json` (1351), `daemon_json` (1314). |
| `analyze.rs` | `cmd_analyze` (783); view builders `context_json` (2231), `findings_json` (2242), `critical_json` (2271), `comparison_json` (2284), `focus_json` (2337), `recommended_queries` (2360); renderers `render_context` (2382), `render_comparison` (2419), `render_findings` (2473), `render_critical` (2480), `render_focus` (2487). |
| `query.rs` | `cmd_query` (850); `QueryFilters` (2499) + `impl` (2512), `UnderScope` (2507), `QueryOutputOptions` (2523), `DetailSelector` (2528) + `impl` (2534), `BulkQuerySpec` (2573); `parse_prop_list` (2563), `query_find` (2596), `run_query_request` (2613), `query_bulk` (2650), `read_bulk_query_input` (2702). |
| `output.rs` | Shared compact-output primitives used across read commands: `pointer_compact_json` (435) and any small JSON/markdown formatting helpers that `analyze.rs`/`query.rs`/`status` share. Keep this module thin. |
| `cli.rs` | `Cli` (55), `Commands` (61), `CommonArgs` (177), `ReportView` (185); dispatch `match` (from `main` 260–339); thin command handlers `cmd_status` (374), `cmd_doctor` (341), `doctor_checks` (447) + `storage_check` (530)/`sqlite_check` (551)/`server_manifest_check` (578), `cmd_capture` (647), `cmd_serve` (694), `cmd_ingest` (721). (`doctor_*`/`server_manifest_check` may instead live in `http.rs`/`storage.rs` next to what they probe — Composer's call, compiler-guided.) |

Notes:
- Exact `pub` vs `pub(crate)` boundaries are mechanical and compiler-driven — make items `pub(crate)`
  where another module needs them; keep everything else private. Do not over-export.
- Move imports per module; remove now-unused `use` from each file. The big `use std::{...}` block (1–19)
  is split per module needs.
- `cmd_serve` spins the `tiny_http` server and calls `handle_daemon_request` — `cli.rs` depends on
  `http.rs`. Keep the threading/`Arc<Mutex<DaemonState>>` wiring exactly as-is.

#### B2 working method (keeps the build green)

Extract ONE module at a time, in dependency order: `util` → `storage` → `capture` → `output` → `http` →
`analyze` → `query` → `cli`. After EACH extraction: `cargo build`, `cargo test`, and re-run the B0
golden commands to confirm byte-identical output. Commit per module so any regression is bisectable.

---

## 6. Workstream C — Built-in timing/benchmark harness + documented baseline

### C1. Fixture snapshot
- Add `tools/studio_stud/tests/fixtures/baseline_capture.json` (or `.json.gz`, matching what
  `decode_raw_snapshot` accepts): a real, sanitized capture snapshot with **fixed, deterministic** IDs,
  place key, and timestamps so goldens and bench are reproducible. Prefer a real Fisher's Life capture
  trimmed/sanitized over a synthetic one for realism; optionally add a second larger synthetic fixture to
  stress ingest. Document how it was produced in a short header/README note in `tests/fixtures/`.

### C2. `bench` subcommand (hidden)
Add a hidden clap subcommand: `studio-stud bench --raw <fixture> [--iterations N] [--json]`.

- Measures ONLY the Rust-side daemon pipeline stages that exist today (design §10 list, minus the
  Luau/HTTP stages that aren't measurable here — state that explicitly in output):
  - `decode` — `decode_raw_snapshot` (gzip/utf-8 decode)
  - `parse` — `serde_json::from_str` to `Value`
  - `capture_meta` — `capture_meta`
  - `ingest` — `ingest_sqlite` into a fresh temp SQLite DB (schema init included or timed separately)
- Runs `--iterations` (default e.g. 20), reports per-stage min/median/max/mean in milliseconds plus the
  fixture's instance count and raw byte size. Uses `std::time::Instant`. No new dependency.
- `--json` emits a compact stable JSON object (sorted keys) so it can be diffed/tracked; default is a
  short human table. Honesty line in output: "capture walk + HTTP transfer are plugin/Luau-side and not
  measured here."
- Implement in a new `bench.rs` module (Stage-0-appropriate: it benchmarks existing code only) wired
  into `cli.rs` dispatch. Keep it `hide = true` like the `Daemon` alias.

### C3. Document the baseline
- Record measured numbers for the fixture in `docs/studio-stud.md` (new short "Benchmarks / capture cost"
  section) — this closes the design's open "exact latency is unmeasured today" note (§6) and gives Stage 2
  a baseline to prove deltas are cheaper. Include: machine note, fixture instance count, raw bytes, and
  the per-stage medians. State clearly these are daemon-side ingest timings only.

---

## 7. Testing strategy & exit gate

### Unit tests (`#[cfg(test)]` per module)
- `util`: `safe_key`, `percent_decode`, `split_url`, `path_root`, `matches_keyword`, `build_search_text`,
  `make_id` prefix shape.
- `capture`: gzip round-trip (`encode_gzip_json` → `decode_raw_snapshot`), `capture_meta` instance count +
  sha256 over a fixture, findings classification (`update_findings`/`insert_findings`) on a small input.
- `storage`: `init_schema` on an in-memory/temp DB creates expected tables + `SCHEMA_VERSION`;
  `ensure_column`/`backfill_normalized_columns` idempotent; `resolve_place` path math.
- `query`: `parse_prop_list`, `DetailSelector` parsing, `BulkQuerySpec` parse from `read_bulk_query_input`.

### Integration / golden tests (`tests/`)
- Replay `tests/fixtures/baseline_capture.json` through `ingest`, then assert each read command's stdout
  is byte-identical to the committed `tests/golden/*.txt`. Drive via the `lib.rs` entry
  (`run_with_args`) or by shelling the built binary with a temp `--storage-root`.
- A permanent golden for `bench --json` shape (NOT exact timings — assert keys/structure only).

### Manual verification
- `pwsh tools/studio_stud/build-local.ps1` clean.
- Optional live smoke: `serve` + a real Studio capture still ingests and `query`/`analyze` work
  (dogfood per design §12). Not required for exit if goldens pass, but recommended once.

### Exit gate checklist (all must be true)
- [ ] Boat tooling removed; grep clean (§4 A4); `BoatAuthoringConfig.luau` header updated; game loads.
- [ ] `main.rs` is a thin shim; code lives in `lib.rs` + modules; no future-stage modules created.
- [ ] `cargo build` + `cargo clippy` clean; `cargo test` green (unit + golden).
- [ ] Every read command's output byte-identical to pre-split goldens.
- [ ] `bench` produces stable per-stage numbers; baseline recorded in `docs/studio-stud.md`.
- [ ] HTTP route table + protocol constants + SQLite schema unchanged.

---

## 8. Risks & mitigations

- **Cross-cutting helper tangle during the split** is the main risk over ~2,900 lines. Mitigated by:
  B0 goldens captured first; one-module-at-a-time extraction with build+test+golden after each; per-module
  commits for bisectability.
- **Hidden nondeterminism in goldens** (timestamps, UUIDs, absolute paths). Mitigated by a fixture with
  fixed IDs + temp `--storage-root`; apply identical normalization in B0 and the harness if any leaks.
- **`lib.rs` is a design-implied prerequisite not spelled out in Appendix A** — flagged explicitly here so
  it's an intentional, reviewed change, not a surprise. It unlocks all later-stage testing.
- **Accidental scope creep into Stage 1+** — explicitly forbidden in §0; `bench.rs` is the only new module
  beyond the read-layer split, and it benchmarks existing code only.

## 9. Out of scope (defer to later stages)
Tab host / plugin shell (Stage 1); live deltas & single-live-DB migration / WAL / dropping
`latest_path`/`previous_path` & `Comparison` (Stage 2); `/studio-stud/write/*`, policy, token, `full-moon`
(Stage 3); repo index / projection / `rbx-dom` (Stage 4+); the Boat Configurator rebuild (Stage 8).
Removing the `Comparison` report is explicitly a Stage 2 change — in Stage 0 it stays and is golden-tested.