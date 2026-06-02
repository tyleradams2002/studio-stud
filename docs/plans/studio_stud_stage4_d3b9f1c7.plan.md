---
name: Studio Stud Platform — Stage 4 (Repo index + read-only project diff / Rojo Phase 1)
overview: Add a read-only repo-index + Rojo-v7 desired-projection + desired-vs-actual diff engine to the daemon, completely independent of any Studio mutation. Ships four things later stages reuse — (1) a Rojo v7 project parser for default.project.json with faithful $path/$className/$properties/$ignoreUnknownInstances semantics, (2) a hardened desired-projection sub-component (Luau scripts + folders + init collapsing) as a lightweight reflection-validated tree (rbx_reflection_database; full WeakDom + rbx_xml/rbx_binary deferred to Stage 7), flattened to normalized-path-keyed entries, (3) a deterministic structural diff engine that joins the desired projection against the live SQLite DB (read-only, joined on normalize_query_path, actual side never deduped on path_norm) and classifies each path by ownership-aware risk (matched / classMismatch / missingInStudio / extraInStudio / studioOwned / unsupported), and (4) an in-memory repo index (path/size/mtime/hash/role) plus a policy-readiness report. No Studio mutation, no FS->Studio apply, no source-content sync (capture stores no script Source — deferred to Stage 5's per-file base ledger + in-plugin CAS). Proven by projection-parity fixtures adapted from Rojo, ownership-boundary fixtures, and a large bounded-diff fixture, all in cargo test from this stage forward.
todos: []
isProject: false
---

# Studio Stud Platform — Stage 4 Execution Plan (Repo index + read-only project diff / Rojo Phase 1)

Status: **READY TO EXECUTE** (post–technical-review revision). Source of truth: `docs/studio-stud-platform-design.md` §5.1 (desired vs actual +
diff engine + projection fidelity + rbx-dom directive), §5.1.1 (file scope: Luau + folders first), §5.6/§5.7
(single live DB per place + AI-first bounded output), §6 (live state model — the "actual" side the diff reads),
§7 (Stage 4 = Roadmap Phase 1 mapping), §9 (read-only/no-mutation safety), §10 (perf/determinism), §11
(Stage 4 deliverables + exit gate), and Appendix A (module split: `project.rs`, `diff.rs`). This plan executes
the design; it does not re-litigate it.

Stage 4 is a **net-additive, read-only** stage. It adds two Rust modules (`project.rs`, `diff.rs`), **one
new crate dependency** (`rbx_reflection_database` — reflection only; full `WeakDom` + `rbx_xml`/`rbx_binary`
deferred to Stage 7), and CLI subcommands. It **mutates nothing**:
no Studio writes, no repo file writes, no SQLite schema change, no new HTTP route. The diff reads the live DB
through the existing read-only handle (`open_db_readonly`, from the reliability-fix pass) and reads repo files
from disk. The first consumer of the *projection* output (the per-file source hashes / base ledger) is Stage 5;
Stage 4 only reports.

Scope is exactly the Stage 4 deliverables and nothing more. Do **NOT** introduce any Stage 5+ surface: no file
watcher, no patch planner (`sync.rs`), no plugin apply endpoints, no hash-guarded applies, no per-file base
ledger persistence, no FS->Studio mutation, no multi-developer concurrency / CAS / 3-way merge / `flctl sync`,
no `.rbxmx`/`.rbxm`/`.model.json`/`.meta.json`/`.json`/`.txt`/`.csv` projection (those are Stage 7 parity), no
Boat panel. Source-content "this script changed" classification is explicitly OUT (the live DB stores no
script `Source` — verified §2); Stage 4 classifies **structure + class + ownership**, and records the desired
source hash for Stage 5 to consume.

---

## 0. Locked decisions (do not revisit)

0. **READ-ONLY, ZERO MUTATION (hard guardrail, §9).** Stage 4 never writes a file, never mutates Studio, never
   changes the SQLite schema, and adds no HTTP route. The diff opens the live DB via `open_db_readonly`
   (READ_ONLY + `PRAGMA query_only=ON`, already in `util.rs`) and reads repo files. A reviewer grepping the new
   modules must find no `atomic_write`, no `init_schema`, no `conn.execute("INSERT…")`, no
   `handle_daemon_request` route addition, no `ChangeHistoryService`. The Stage 3 `write::safety` toolkit is
   used ONLY for its pure functions (`normalize_newlines`, `sha256_hex`, `parse_luau`, `unified_diff`) — never
   `atomic_write`.

1. **GENERIC ONLY — zero game/boat knowledge (Non-Goals §65-67).** Nothing in `project.rs`/`diff.rs` knows the
   word "boat", a game schema, or any Example Project concept. The projection is driven entirely by
   `default.project.json` + Rojo v7 rules + the repo file tree. The existing `CRITICAL_NAMES`/`KEYWORDS` in
   `util.rs` belong to `analyze`/`query`, NOT to the diff — do not reuse them here.

2. **STRUCTURAL diff, not source-content diff (verified constraint — the single most important scoping call).**
   The live capture stores **no script `Source`** — `CLASS_PROPERTIES` in the plugin captures only
   `{ "Enabled", "Disabled", "LinkedSource" }` for `Script`/`LocalScript`/`ModuleScript` (verified §2). The DB
   therefore cannot tell whether a script's body differs from the repo. Stage 4 consequently classifies on
   **presence + className + parent/hierarchy + ownership**, NOT on source equality. The desired source hash IS
   computed per projected script (`sha256_hex(normalize_newlines(file_bytes))`) and emitted in the projection /
   diff payload so Stage 5 can seed the per-file base ledger, but it is NOT compared against the DB (there is
   nothing to compare it to). "safe script update" detection (design §5.1) is a Stage 5 apply-time concern via
   the in-plugin content CAS + base ledger (design §6.2/Appendix F/G), NOT a Stage 4 DB diff. **Do NOT add
   `Source` to capture** — that perturbs capture/live, bloats the DB and every delta, and breaks the golden
   suite; it is explicitly rejected here.

3. **OWNERSHIP BOUNDARY is the core correctness requirement (exit gate: "correct repo-owned vs Studio-owned
   reporting").** Apply Rojo v7's exact `$ignoreUnknownInstances` default rule: a node **with `$path`** defaults
   to `false` (Rojo manages/would-delete unknown children) unless the project explicitly sets it; a node
   **without `$path`** (pure organizational tree node) defaults to `true` (leaves unknown alone); an explicit
   `$ignoreUnknownInstances` in the project file always wins. It is **per-node**, not inherited — every
   projected node carries its own effective `ignoreUnknownInstances`. In ExampleProject every `$path` service root
   sets `$ignoreUnknownInstances:true` explicitly, but their **directory-projected descendant folders**
   (e.g. `ServerScriptService/Core`) have no flag and default to `false`. Therefore: a Studio-only instance
   directly under a service root is `studioOwned` (ignored), but a Studio-only instance under a repo-projected
   folder is `extraInStudio` (a delete *candidate*, reported only — Stage 4 never deletes). Getting this rule
   right is the whole point of the stage.

4. **Projection fidelity is its own hardened sub-component with a Rojo-derived fixture corpus (§5.1).** The
   desired projection must faithfully reproduce: `$path` directory expansion; `$className`/`$properties`/`$id`
   tree nodes; `$ignoreUnknownInstances`; `init.luau`/`init.server.luau`/`init.client.luau` collapsing a
   directory into a Script/LocalScript/ModuleScript; `.server.luau`→`Script`, `.client.luau`→`LocalScript`,
   `.luau`/`.lua`→`ModuleScript`; `globIgnorePaths` (ExampleProject ignores `**/*.spec.luau`); and deterministic
   sibling ordering. Borrow/adapt Rojo's own projection semantics into a committed fixture corpus. A subtle
   projection bug silently corrupts the desired side of every downstream diff, so the parser/projection gets
   its own unit + golden tests independent of the diff.

5. **Reflection from rbx-dom; lightweight desired tree this stage; full WeakDom deferred to Stage 7.** The
   design directive (§5.1) is "build on the rbx-dom crate family rather than **hand-rolling reflection and model
   serialization**." Stage 4 honors that by taking reflection from `rbx_reflection_database` (REQUIRED — it
   powers `infer_class_name`'s `ClassTag::Service` check AND class-name validation, §3.2) and **deferring**
   `rbx_xml`/`rbx_binary` (`.rbxmx`/`.rbxm`) to Stage 7. It does **NOT** build a real `rbx_dom_weak::WeakDom`
   this stage: a `WeakDom` requires typed `Variant` properties, but typed-`$properties` conversion is itself
   deferred to Stage 7 — so a Stage-4 WeakDom would degenerate to `{class, name, children}` (properties parked
   in the side-table regardless), buying nothing while importing Variant-typing friction. Build a **lightweight
   `DesiredInstance` tree** instead, reflection-validate every `className` (default-derived or from
   `$className`; unknown ⇒ projection error/warning, never silent), then flatten. Do NOT add `rbx_dom_weak`/
   `rbx_types` this stage (no `WeakDom` to build ⇒ they would be unused deps; add them in Stage 7 alongside the
   `WeakDom`). Do NOT hand-roll reflection; do NOT add `rbx_xml`/`rbx_binary`.

6. **Diff join key = `normalize_query_path`, and the actual side is NEVER deduped on `path_norm` (verified
   §2 — corrected).** The capture builds `instances.path` by appending `[siblingIndex]` to **every** segment
   unconditionally (`plugin … ("%s[%d]"):format(inst.Name, siblingIndex)`, verified `StudioStud.plugin.lua`
   ~L1604) — it is NOT "only duplicate disambiguation." `instances.path_norm` is
   `normalize_query_path(path)` (lowercased, `/`-folded, **all `[n]` stripped** — `util.rs:233`). Therefore
   `path_norm` is **non-unique**: duplicate-named Studio siblings (`Part[1]`,`Part[2]`) both normalize to
   `…/part`. Consequences for the diff:
   - **Desired side** keys are `normalize_query_path(studio_path)` and ARE unique (Rojo forbids duplicate child
     names — a collision is a projection error, §3.2). The projection builds `studio_path` as service-root name
     + `/` + child names with **NO `[n]` suffixing** (the join strips `[n]` anyway; reproducing it is wrong and
     pointless). Lowercase/separator-fold only.
   - **Actual side** MUST be keyed by a **unique** identifier (`instance_id`, or the case-folded full `path`
     which preserves `[n]`), and the desired lookup is computed **per actual row** via
     `normalize_query_path(path)`. **Do NOT load actual into a `BTreeMap<path_norm, …>`** — that silently
     drops duplicate-named siblings, undercounts `studioOwned`/`extraInStudio`, and hides a real divergence
     (repo expects one `Core/DataManager`, Studio has two). Multiplicity divergence itself (count mismatch for
     the same normalized key) is NOT classified this stage (Stage 5+), but every actual row MUST be counted and
     classified — never collapsed.
   - Invariant test: `sum(five DB category counts) == live instance_count` (`unsupported` is repo-index-only,
     excluded); a duplicate-sibling fixture asserts at most one `matched` per desired key and excess rows ⇒
     `extraInStudio`.

7. **Deterministic, bounded, AI-first output (§5.7/§10).** Every command emits compact JSON with stable,
   sorted keys; the diff is bounded (`returned`/`total`/`limit`/`truncated` per category, capped sample
   arrays), never a full dump of hundreds of scripts. `--markdown` is human-only. Same `(repo, DB)` ⇒
   byte-identical JSON (deterministic ordering everywhere: sort entries by `studioPath`, sort categories by a
   fixed order). The diff against the full Example Project repo must stay bounded and fast.

8. **Repo index is in-memory this stage (no persistence, preserves read-only purity).** `project index`
   computes `{ path, size, mtime, hash, role, studioPath?, projected }` per file in-memory and emits bounded
   JSON. A persistent/cached index (mtime-skip per §10) is a **perf follow-up, NOT built here** — adding a
   SQLite index table would be a schema change (violates decision 0) and is unnecessary for correctness. The
   in-memory index is deterministic and recomputed per invocation.

9. **Testability without Studio is mandatory (mirror Stage 3 decision 9).** Every guarantee (projection
   parity, ownership classification, diff boundedness, join fidelity, determinism) MUST run from `cargo test`
   against committed fixtures — a fixture repo tree + a fixture live-DB (ingested from a committed raw snapshot
   via the existing `ingest` path) — with NO live Studio and NO running daemon. CLI subcommands drive everything
   via `--repo-root` + `--storage-root` (+ `<PLACE>`).

10. **No new HTTP route, no plugin change (isolation).** The diff is a local CLI read over local files + the
    local DB; the plugin is not involved. `http.rs`, the plugin `.lua`, the protocol version, and `ServeConfig`
    are untouched. (Exposing diff over HTTP for automation is a possible future step, not Stage 4.)

11. **Reuse the Stage 3 toolkit, do not duplicate it.** Source hashing = `write::safety::sha256_hex` +
    `normalize_newlines`; optional projected-Luau syntax validation = `write::safety::parse_luau` (a projection
    *warning*, not a hard failure — a repo can legitimately contain a script the daemon's pinned `full_moon`
    can't parse; surface it, don't crash). Any diff text uses `write::safety::unified_diff`. Do NOT re-implement
    these in `project.rs`/`diff.rs`.

12. This plan is saved under `.cursor/plans/` matching the existing `*_<hex>.plan.md` convention.

---

## 1. Hard guardrails / definition of done

- **Read-only, zero mutation (decision 0).** No file write, no Studio mutation, no schema change, no HTTP
  route; the diff uses `open_db_readonly`; a grep of the new modules for `atomic_write`/`init_schema`/`INSERT`/
  route registration returns nothing.
- **Generic only (decision 1).** No game/boat term in `project.rs`/`diff.rs`; `CRITICAL_NAMES`/`KEYWORDS` not
  referenced.
- **Projection parity (decision 4).** A committed Rojo-derived fixture corpus proves `$path` expansion, init
  collapsing, `.server`/`.client` suffix mapping, `$className`/`$properties` tree nodes, `globIgnorePaths`, and
  deterministic ordering. Projection has its own goldens independent of the diff.
- **Ownership correctness (decision 3).** Fixture tests prove: a Studio-only child of a `$ignoreUnknownInstances:
  true` root ⇒ `studioOwned` (not a delete candidate); a Studio-only child of a default-false directory-folder ⇒
  `extraInStudio`; an explicit `$ignoreUnknownInstances:false` override flips a tree node to owned. The
  per-node default-by-`$path` rule is unit-tested directly.
- **Structural diff only (decision 2).** No code path reads a `Source` column (it does not exist); the diff
  classifies on presence/class/hierarchy/ownership; the desired source hash is emitted but never compared.
- **Bounded, deterministic, AI-first (decision 7).** The diff against the full repo + a large fixture stays
  bounded (counts + capped samples + `truncated`); two runs are byte-identical.
- **Join fidelity (decision 6).** Actual loaded as `Vec` (never deduped on `path_norm`); multiplicity rule
  (§3.5.1): at most one `matched`/`classMismatch` per desired key; `sum(five DB category counts) ==
  instance_count`.
- **Reflection adopted, DOM/serialization deferred (decision 5).** `rbx_reflection_database` added; every class
  name validated against reflection; lightweight desired tree (no `WeakDom` this stage); `rbx_dom_weak`/
  `rbx_types`/`rbx_xml`/`rbx_binary` NOT added (Stage 7).
- **Isolation.** Capture/live/query/write goldens + the live-convergence + write-safety suites stay
  byte-identical; existing routes/aliases/404 unchanged; no Cargo dep removed.
- **Reuse the toolkit (decision 11).** Hashing/parse/diff come from `write::safety`; not re-implemented.

---

## 2. Current state (verified facts, do not re-discover)

- **Daemon modules** (after Stages 0-3 + reliability fixes): `tools/studio_stud/src/{lib,util,storage,capture,
  output,http,analyze,query,cli,bench,live,policy,write,stage3_cli}.rs` + `src/write/{file,safety}.rs`. **No
  `project.rs`, no `diff.rs` yet** — Stage 4 creates both and adds `pub mod project; pub mod diff;` to
  `lib.rs`. (Appendix A also lists a future `sync.rs` — NOT this stage.)
- **Cargo deps** (`Cargo.toml`, crate version `0.3.1`, edition 2024): `anyhow, chrono, clap(derive), dirs,
  flate2, full_moon(luau), globset, rusqlite(bundled), serde, serde_json, sha2="0.11", similar, tiny_http,
  uuid(v4)`. **No rbx-dom crates.** Stage 4 adds `rbx_reflection_database` (pin latest via `cargo add`;
  reflection only, decision 5). Do NOT add `rbx_dom_weak`/`rbx_types` (lightweight tree this stage) nor
  `rbx_xml`/`rbx_binary` — all Stage 7.
- **Capture instance shape** (`capture.rs`, the "actual" side): each DB instance row has
  `instance_id, parent_id, path, path_norm, display_path, name, class_name, depth, child_count, sibling_index,
  duplicate_sibling_name, property_json` (+ `instance_properties`/`instance_attributes`/`instance_tags`). The
  canonical value (`canonical_instance_value`) is `{ attributes, childCount, className, depth,
  duplicateSiblingName, id, name, parentId, path, properties, siblingIndex, tags }`. **No `Source` /
  script body anywhere** — `CLASS_PROPERTIES` (plugin) is `Script={Enabled,Disabled,LinkedSource}`,
  `LocalScript={Enabled,Disabled,LinkedSource}`, `ModuleScript={LinkedSource}` (verified line ~250). This is
  why decision 2 holds.
- **Live DB read access** (`util.rs`): `open_db_readonly(path)` (READ_ONLY + `busy_timeout(60s)` +
  `query_only=ON`, NO WAL pragma) — the handle the diff MUST use. `STALE_DB_SCHEMA_MSG` is the
  actionable error for a pre-normalization DB. `normalize_query_path` (lowercases, `/`-normalizes `.`,`\`,`/`,
  strips numeric `[n]`) is the diff join-key normalizer. `path_root(path)` returns the first segment
  (service root) sans `[...]`. `hex_bytes` exists.
- **Capture path convention (decision 6, verified):** the plugin builds `instances.path` with `[siblingIndex]`
  on **every** segment (`Name[siblingIndex]`, not duplicate-only). `path_norm = normalize_query_path(path)`
  strips all `[n]` and lowercases — therefore **non-unique** for duplicate-named siblings. The diff MUST NOT
  dedup actual rows on `path_norm` (see §3.5.1).
- **Storage / place resolution** (`storage.rs`): `Storage::new(storage_root, project_key)` →
  `%LOCALAPPDATA%/StudioStud/<project_key>/places/<safe place key>/syncs.db`; `resolve_place(storage, place)`
  resolves an explicit `<PLACE>` or falls back to `active_place` then most-recent `live_state.updated_at_utc`.
  `read_live_state(conn)` returns the single `live_state` row (one live DB per place, §5.6); the live capture
  rows live under `instances WHERE capture_id = live.capture_id`. The diff reads that current capture
  partition. **No schema change this stage.**
- **default.project.json** (repo root): `name:"ExampleProject"`, `globIgnorePaths:["**/*.spec.luau"]`, `tree` =
  `DataModel` with: `HttpService($properties)`, `ReplicatedFirst($path:src/ReplicatedFirst, ignore:true)`,
  `ServerScriptService($path:src/Server, ignore:true)`, `ReplicatedStorage($path:src/Shared, ignore:true)`,
  `StarterPlayer(ignore:true){ StarterPlayerScripts($path:src/Client, ignore:true) }`,
  `StarterGui($path:src/StarterGui, ignore:true)`, `StarterPack(ignore:true)`,
  `Workspace/Lighting/SoundService/ServerStorage(ignore:true, no $path)`. So every `$path` root is
  `ignore:true` (its direct unknown children are Studio-owned), but their directory-projected descendant
  folders default to `ignore:false` (decision 3).
- **CLI** (`cli.rs`): `Commands` enum dispatched via a big `match`; `CommonArgs{project_key(default
  "ExampleProject"), storage_root}` flattened into read commands; user-facing commands are NOT `hide`. Policy
  commands take a `--repo-root` (`policy::resolve_repo_root`, which finds `.studio-stud/policy.json`, else
  `default.project.json`/`.git` ancestor). Stage 4 adds a `Project` command group with the SAME `--repo-root`
  resolution + `CommonArgs` (for `--storage-root`/`<PLACE>` on `diff`).
- **Policy** (`policy.rs`): `resolve_repo_root(Option<&Path>)`, `load_policy`/`load_compiled_policy`,
  `CompiledPolicy` (allow + header globsets), `explain_path`. The committed `.studio-stud/policy.json` has
  `allowedWritePaths: []` (Stage 5/8 broaden it). The Stage 4 **policy-readiness report** reuses
  `load_compiled_policy` + the allow globset to report which projected source paths WOULD be writable when
  Stage 5 sync lands — read-only, no enforcement.
- **Tests** (`tests/`): `golden_outputs.rs` (CLI golden harness: `run_cli(args, storage_root)` via
  `CARGO_BIN_EXE_studio-stud`, `normalize_output`/`normalize_json` with `TIMESTAMP`/`DAEMON_STATE`
  placeholders, goldens under `tests/golden/`, fixture `tests/fixtures/baseline_capture.json` ingested via
  `ingest`); `live_convergence.rs` (`run_cli` + `run_cli_allow_fail`); `write_safety.rs`/`write_http.rs`;
  `http_reliability.rs`. **Stage 4 adds `tests/project_diff.rs` + `tests/fixtures/project/` (a fixture repo
  tree) + reuses/adds a fixture raw snapshot + `tests/golden/project_*.txt`.** The `golden_outputs.rs`
  fixture `baseline_capture.json` is the Example Place A place (placeId `100000000000001`) — reuse it as the
  "actual" side where convenient.
- **Build/verify**: `pwsh tools/studio_stud/build-local.ps1` (clean build → `bin/studio-stud.exe`),
  `cargo test`, `cargo clippy --all-targets`.

---

## 3. Design (project parser + repo index + projection + diff)

### 3.0 Rojo v7 source parity map (port these, do not improvise)

The projection sub-component (decision 4) must be a faithful port of Rojo v7's snapshot middleware for the
Luau + folder subset. Pin to `rojo-rbx/rojo@master` and mirror these exact files/rules (verified against
source):

- **Project model** — `src/project.rs` (`Project`, `ProjectNode`). Confirms the load-bearing rules Stage 4
  depends on:
  - `$ignoreUnknownInstances` default (decision 3): **"If unset: `$path` not set ⇒ `true`; `$path` set ⇒
    `false`."** Explicit always wins. (`ProjectNode::ignore_unknown_instances` doc + the
    `snapshot_project_node` block at the bottom that sets `metadata.ignore_unknown_instances`.)
  - `$path` is a `PathNode` = `Required(String)` OR `Optional({ "optional": String })`. An **optional** path
    that does not resolve ⇒ the node is **skipped** (projection returns `None` for it), NOT an error. A
    **required** path that does not resolve ⇒ hard error.
  - `$className` MUST be set if `$path` is not; `$className` CANNOT be set if `$path` resolves to a non-Folder.
  - `$attributes` exists alongside `$properties` (carry both; typed conversion is Stage 7).
  - `globIgnorePaths` are globs **relative to the project folder**; `.project.jsonc` + JSONC (comments/trailing
    commas) are supported (ExampleProject uses plain `.json` — JSONC is a nice-to-have, not required for MVP).
  - `DEFAULT_PROJECT_NAMES = ["default.project.json", "default.project.jsonc"]`.
- **Snapshot dispatch + init priority + sync rules** — `src/snapshot_middleware/mod.rs`:
  - `get_dir_middleware` init priority (order matters): a `default.project.json[c]` in the dir ⇒ nested
    **Project**; else first match of `init.luau`, `init.lua`, `init.server.luau`, `init.server.lua`,
    `init.client.luau`, `init.client.lua`, `init.csv`; else plain **Dir** (Folder).
  - `default_sync_rules()` extension→middleware order: `*.server.lua[u]`→ServerScript, `*.client.lua[u]`→
    ClientScript, `*.plugin.lua[u]`→PluginScript, `*.{lua,luau}`→ModuleScript, `*.project.json[c]`→Project,
    `*.model.json[c]`→JsonModel, `*.json[c]`→Json (excl. `*.meta.json[c]`), `*.toml`→Toml, `*.csv`→Csv,
    `*.txt`→Text, `*.rbxmx`→Rbxmx, `*.rbxm`→Rbxm, `*.{yml,yaml}`→Yaml. **Stage 4 implements ONLY the script +
    project + dir rules; everything else (`model.json`/`json`/`toml`/`csv`/`txt`/`rbxmx`/`rbxm`/`yaml`/
    `meta.json`) is `FileRole::Unsupported`, not projected (Stage 7).**
- **Class-name resolution + service inference** — `src/snapshot_middleware/project.rs` (`snapshot_project_node`
  + `infer_class_name`). Port BOTH verbatim (§3.2).
- **Script class mapping** — `src/snapshot_middleware/lua.rs` (`snapshot_lua` `ScriptType`→class) +
  `src/snapshot_middleware/util.rs` (`emit_legacy_scripts_default() == Some(true)`) (§3.4).

Lift Rojo's own middleware unit tests (the `#[cfg(test)] mod test` in `snapshot_middleware/project.rs`:
`project_from_folder`, `project_with_children`, `project_with_path_to_txt`, `project_with_path_to_project`,
`project_path_property_overrides`, etc.) into the projection-parity corpus (decision 4), translated to the
flattened-projection assertions Stage 4 uses.

### 3.1 Module layout (`project.rs` + `diff.rs`, Appendix A)

Mirror the `write.rs` + `write/{file,safety}.rs` submodule pattern:

```
src/project.rs            // pub mod; re-exports; ProjectError; public entry fns
src/project/manifest.rs   // parse default.project.json -> ProjectNode tree (Rojo v7)
src/project/index.rs      // scan repo files -> RepoIndex (path/size/mtime/hash/role)
src/project/projection.rs // ProjectNode + RepoIndex -> lightweight DesiredInstance tree -> flattened map
src/diff.rs               // DesiredInstance map  vs  live DB  -> ProjectDiff (ownership-aware)
```

`lib.rs`: add `pub mod project;` and `pub mod diff;` (after `pub mod write;`). All new public items are
`pub(crate)` unless a test needs `pub`.

### 3.2 Rojo v7 manifest parse (`project/manifest.rs`)

Parse `<repo_root>/default.project.json` (strict `serde_json`) into a recursive node tree. A node's keys are
either reserved (`$`-prefixed) or child instance names.

```rust
pub(crate) struct ProjectManifest {
    pub name: String,
    pub glob_ignore_paths: Vec<String>,   // globIgnorePaths
    pub emit_legacy_scripts: Option<bool>, // emitLegacyScripts (None => default true per Rojo util.rs)
    pub tree: ProjectNode,
}
pub(crate) struct ProjectNode {
    pub class_name: Option<String>,        // $className (None => inferred: see rules)
    pub path: Option<PathNode>,            // $path: Required(PathBuf) | Optional(PathBuf) (Rojo PathNode, §3.0)
    pub properties: serde_json::Map<String, Value>, // $properties (carried, typed in Stage 7; class-validated now)
    pub attributes: serde_json::Map<String, Value>, // $attributes (carried; typed/diffed in Stage 7)
    pub ignore_unknown: Option<bool>,      // explicit $ignoreUnknownInstances (None => default-by-$path, decision 3)
    pub id: Option<String>,                // $id (carried; not load-bearing for diff)
    pub children: BTreeMap<String, ProjectNode>, // non-$ keys, name-keyed; iterate sorted for determinism
}
// PathNode mirrors Rojo: serde-untagged Required(String) | Optional({ "optional": String }).
// Optional + unresolved => node skipped (projection None); Required + unresolved => error (§3.2).
pub(crate) enum PathNode { Required(PathBuf), Optional(PathBuf) }
```

Rules (Rojo v7 parity, the subset Stage 4 needs):
- Root node `class_name` defaults to `DataModel` if absent.
- A node with `$path` pointing at a **directory** is expanded by `project/projection.rs` (§3.4).
- A node with `$path` pointing at a **file** maps that file to the node by extension (script rules §3.4).
- A node with `$path` pointing at a **nested `*.project.json`**: parse it as a sub-manifest and splice its
  `tree` under this node (parity item). ExampleProject has none — implement the common dir/file case fully; for a
  nested project file, parse-and-splice if straightforward, else emit a `unsupported` projection warning
  (do NOT crash). Keep this minimal.
- `$ignoreUnknownInstances` effective value (decision 3): `explicit if present, else (path.is_some() ? false :
  true)`. Compute and store this per projected node in projection (§3.4), not just on the manifest node.
- `class_name` resolution — port Rojo's exact matrix from `snapshot_project_node` over
  `(node.$className, class_name_from_path, class_name_from_inference, node.$path)` (first match wins):
  1. `($className, None, None, _)` ⇒ `$className`.
  2. `(None, path, None, _)` ⇒ `path` class (from resolving `$path`).
  3. `(None, None, inference, _)` ⇒ `inference` (from `infer_class_name`).
  4. `($className, None, inference, _)` ⇒ `$className` (explicit beats inference).
  5. `(None, path, inference, _)` ⇒ if `path == "Folder"` use `inference`, else `path`.
  6. `($className, path, _, _)` ⇒ if `path == "Folder"` use `$className`, else **ERROR** ("$className and $path
     both set, but $path is not a Folder"). **This is the ExampleProject case:** each service root sets
     `$className:"ServerScriptService"` etc. AND `$path:"src/..."` (a dir ⇒ `class_name_from_path=="Folder"`)
     ⇒ uses `$className`. The projection MUST implement this arm or it would error on the real project.
  7. `(_, None, _, Some(Optional path))` ⇒ return `None` (skip the node — optional path absent).
  8. `(_, None, _, Some(Required path))` ⇒ ERROR (required `$path` didn't resolve to a known file type).
  9. `(None, None, None, None)` ⇒ ERROR (node has no class/path and isn't an inferable service).
- `infer_class_name(name, parent_class)` — port verbatim: parent `DataModel` + `name` is a class tagged
  `ClassTag::Service` in `rbx_reflection_database` ⇒ `name` (services like `ServerScriptService`,
  `ReplicatedStorage`, `Workspace`, `Lighting`, `SoundService`, `ServerStorage`, `StarterGui`, `StarterPack`,
  `HttpService`); parent `StarterPlayer` + name ∈ {`StarterPlayerScripts`,`StarterCharacterScripts`} ⇒ `name`;
  parent `Workspace` + name `Terrain` ⇒ `name`; else `None`. This is why `rbx_reflection_database` is a genuine
  dependency, not cosmetic (decision 5). Validate every resolved class against `rbx_reflection_database`;
  unknown ⇒ projection error for that node (reported; projection continues for siblings).
- **Children merge:** a `$path`-dir node's children come from BOTH the directory expansion AND the node's
  explicit child entries (`node.children`), merged. Rojo/syncback require unique child names; on a name
  collision, record a projection error (do not silently drop).
- **`$properties`/`$attributes`:** carried verbatim onto the node (overriding any `$path`-derived property of
  the same name); class-validated, but NOT compared by the structural diff this stage (Stage 7 types + compares
  them via typed `Variant` conversion).

Errors: a missing/malformed `default.project.json` ⇒ a structured `ProjectError` surfaced as `{ ok:false,
error, detail }` + nonzero CLI exit (this is a real failure, not a "block"; the daemon-write structured-block
contract is a Stage 3 concept — Stage 4 read commands use ordinary `Result`/nonzero-exit like `analyze`/`query`).

### 3.3 Repo index (`project/index.rs`)

Walk the repo file tree once (deterministic, sorted), producing an in-memory index. Scope the walk to the
directories referenced by `$path` in the manifest (plus the manifest file itself) — do NOT walk the entire repo
(skip `.git`, `target/`, `node_modules`, `.cursor/`, etc.). Honor `globIgnorePaths` (skip `**/*.spec.luau`).

```rust
pub(crate) struct RepoIndexEntry {
    pub repo_path: String,   // repo-relative, forward-slash
    pub size: u64,
    pub mtime_utc: String,   // RFC3339; NORMALIZED to "MTIME" in golden tests
    pub hash: String,        // sha256_hex(normalize_newlines(bytes)) for text; sha256_hex(raw) for binary
    pub role: FileRole,      // see below
    pub studio_path: Option<String>, // set during projection join; None if not projected
    pub projected: bool,
}
pub(crate) enum FileRole {
    ServerScript,   // *.server.luau / *.server.lua
    ClientScript,   // *.client.luau / *.client.lua
    ModuleScript,   // *.luau / *.lua (not .server/.client/.spec, not init*)
    InitScript,     // init.luau / init.server.luau / init.client.luau (collapses parent dir)
    Folder,         // a directory under a $path root
    ProjectFile,    // default.project.json / nested *.project.json
    Unsupported,    // .rbxmx/.rbxm/.model.json/.meta.json/.json/.toml/.txt/.csv/etc (Stage 7 parity)
}
```

`mtime` is recorded per the deliverable but is NOT part of any hash, join, or diff decision (it is display-only
and golden-normalized) — this keeps the index deterministic across checkouts.

### 3.4 Desired projection (`project/projection.rs`) — lightweight tree, reflection-validated, flattened

Build a lightweight `DesiredInstance` tree from the manifest + repo index (decision 5 — NOT a `WeakDom` this
stage), reflection-validate each class, then flatten. Projection rules (the fidelity sub-component, decision 4):

- **Root handling:** the manifest root is the `DataModel` node — it is NOT itself emitted as a keyed instance.
  Projection starts at its children (the service nodes). Each projected **service root** (e.g.
  `ServerScriptService`, `ReplicatedStorage`, `StarterPlayer`) MUST appear in `by_key` (its own normalized key)
  so the diff's ownership walk can resolve "nearest desired ancestor is a projected service root" (§3.5). This
  matches the capture, whose top path segment is the service (`ServerScriptService[1]`), never `game`/`DataModel`.
- **Tree nodes**: each `ProjectNode` becomes a `DesiredInstance` with its resolved class name and a `NodeMeta
  { ignore_unknown: bool, source_repo_path: Option<String>, source_hash: Option<String>, parse_ok: Option<bool> }`.
  `$properties`/`$attributes` are carried on the node (class-validated, not diffed this stage).
- **`$path` → directory** expansion (port `get_dir_middleware` + `snapshot_lua_init`, §3.0): a directory's
  own instance is decided by init priority (first match): a `default.project.json[c]` inside ⇒ **nested
  Project** (parse + splice; rare, ExampleProject has none in subdirs — if encountered and non-trivial, emit a
  `unsupported` projection warning, do not crash); else `init.luau`/`init.lua` ⇒ the directory collapses to a
  **ModuleScript** named after the directory; `init.server.luau`/`init.server.lua` ⇒ **Script**;
  `init.client.luau`/`init.client.lua` ⇒ **LocalScript** (className per the emitLegacyScripts note below);
  `init.csv` ⇒ Unsupported (Stage 7); else the directory is a plain **Folder**. **Collapse constraint
  (Rojo `snapshot_lua_init`):** an `init.*` only collapses if the directory would otherwise be a `Folder`; if
  the dir resolves to a non-Folder, that is a projection error. The collapsed/Folder instance records
  `source_repo_path` (the init file, when collapsed) + `source_hash`. Remaining directory entries become its
  children, recursing.
  - File children (non-`init`, honoring `default_sync_rules` order, §3.0):
    `*.server.lua[u]` ⇒ `Script` named `<basename − .server>`; `*.client.lua[u]` ⇒ `LocalScript` named
    `<basename − .client>`; `*.{lua,luau}` ⇒ `ModuleScript` named `<basename>` (NOT `.server`/`.client`/
    `.plugin`, NOT `init*`). `*.plugin.lua[u]` ⇒ `FileRole::Unsupported` (PluginScript is in the rule set but
    unused by ExampleProject `src/`; not projected this stage — Stage 7 if ever needed).
  - A subdirectory ⇒ recurse (Folder by default, `ignore_unknown=false`, OR collapsed by its own `init`).
  - `globIgnorePaths` match (ExampleProject: `**/*.spec.luau`) ⇒ skipped (matched relative to the project folder).
  - Any other file extension (`*.model.json`/`*.json`/`*.toml`/`*.csv`/`*.txt`/`*.rbxmx`/`*.rbxm`/`*.{yml,yaml}`/
    `*.meta.json`) ⇒ `FileRole::Unsupported`, NOT projected (Stage 7), recorded in the index as
    `projected=false` and surfaced by the diff `unsupported` category (§3.5).
- **emitLegacyScripts (className nuance — `lua.rs`/`util.rs`):** ExampleProject does NOT set `emitLegacyScripts`,
  so the default `emit_legacy_scripts_default() == Some(true)` applies ⇒ `.server.*`→`Script`,
  `.client.*`→`LocalScript`, `.{lua,luau}`→`ModuleScript` (the simple, expected mapping). Implement the
  default-`true` (legacy) mapping; honor an explicit `emitLegacyScripts:false` if present (then `.client.*` ⇒
  `Script` with `RunContext=Client`, `.server.*` ⇒ `Script` with `RunContext=Server`) — but for the structural
  diff only the **className** matters (`Script` vs `LocalScript`), so the RunContext property is carried, not
  diffed. Capture stores no `Source` (decision 2), so the script body is never compared regardless.
- **`$path` → file** ⇒ map that single file to the node by the extension rules above.
- Each projected script instance records `source_repo_path` + `source_hash =
  sha256_hex(normalize_newlines(bytes))` (decision 11). Optionally run `parse_luau` and record a
  `parse_ok: bool` projection warning (NON-fatal, decision 11).
- **Flatten**: walk the desired tree depth-first in deterministic sibling order, building a
  `BTreeMap<String /*normalize_query_path(studio_path)*/, DesiredInstance>` plus retaining the display
  `studio_path`. The `studio_path` is built from the service-root name down (decision 6) with **NO `[n]`
  suffixing** — the join key is `normalize_query_path(studio_path)`, which strips `[n]` anyway. Desired keys are
  unique; a normalized-key collision between two desired instances (duplicate Rojo child names, or two names
  that fold to the same key) is a **projection error** (§3.2), not a silent overwrite. `DesiredInstance {
  studio_path, normalized_key, class_name, ignore_unknown, source_repo_path?, source_hash?, parse_ok? }`.

```rust
pub(crate) struct DesiredProjection {
    pub by_key: BTreeMap<String, DesiredInstance>, // key = normalize_query_path(studio_path)
    pub errors: Vec<ProjectionError>,              // unknown class, nested-project-unsupported, etc.
    pub warnings: Vec<ProjectionWarning>,          // parse failures, skipped unsupported files
}
```

Determinism: sort directory entries and node children before building; the BTreeMap key-orders the flatten.

### 3.5 Diff engine (`diff.rs`) — desired vs actual, ownership-aware

Inputs: the `DesiredProjection.by_key` and the live DB's current capture rows (read-only). Load EVERY actual
row into a `Vec<ActualInstance{ instance_id, path, class_name, key: normalize_query_path(path) }>` (one entry
per row — keyed/deduped by NOTHING; see decision 6) via:
`SELECT instance_id, path, path_norm, class_name FROM instances WHERE capture_id = ?1` using `open_db_readonly`
+ `read_live_state` for the `capture_id` (error with `STALE_DB_SCHEMA_MSG` if `path_norm` is NULL / no
baseline). Compute the set of actual keys for desired-presence checks; classify each actual row individually so
duplicate-named siblings are never dropped (decision 6 invariant: `sum(category counts) == live instance_count`).

Classification (join on the normalized key; first matching rule wins):

| Category | Condition | Stage-5 meaning |
| --- | --- | --- |
| `matched` | key in both; same `class_name` (exact — Roblox class names are case-sensitive) | present; source compared at apply time (Stage 5), NOT here |
| `classMismatch` | key in both; `class_name` differs | type change — surfaced, never auto-resolved |
| `missingInStudio` | key in desired only | Stage 5 would CREATE (with `source_hash`) |
| `extraInStudio` | key in actual only; nearest **desired** ancestor exists and that ancestor's `ignore_unknown == false` | delete *candidate* inside a repo-owned subtree (reported only) |
| `studioOwned` | key in actual only; nearest desired ancestor has `ignore_unknown == true`, OR no desired ancestor under a projected root | Studio-managed — correctly ignored |
| `unsupported` | repo-index entry with `role=Unsupported` under a `$path` root | Stage 7 parity (not projected) |

#### 3.5.1 Classification algorithm (implement exactly — no guessing)

The diff MUST classify **every actual DB row exactly once** and satisfy `sum(all six category counts) ==
live instance_count` (decision 6). `unsupported` counts repo-index files only (not DB rows) and is excluded
from that invariant.

**Phase 1 — load actual (never dedup):**
```rust
// One Vec entry per DB row; NEVER BTreeMap<path_norm, _>
struct ActualRow { instance_id, path, class_name, key: normalize_query_path(path) }
let actual_rows: Vec<ActualRow> = /* SELECT … WHERE capture_id = ?1 */;
let mut unconsumed: HashSet<instance_id> = all instance_ids;
```

**Phase 2 — desired presence + multiplicity (keys can repeat on actual, not on desired):**
Group unconsumed actual rows by `key`. For each `(key, desired)` in `DesiredProjection.by_key` (sorted for
determinism):
1. Let `rows = actual_rows grouped by key` (may be empty, one, or many).
2. **No rows** ⇒ `missingInStudio` (+1 to summary; may appear in bounded `items`).
3. **Rows exist** ⇒ consume at most **one** row for pairing:
   - Pick the **first** row (stable sort by `path` ascending) whose `class_name` **exactly equals**
     `desired.class_name` ⇒ classify that row `matched`; remove from `unconsumed`.
   - Else pick the **first** row (same sort) ⇒ classify `classMismatch` (desired vs actual class); remove from
     `unconsumed`.
   - **All remaining rows** with the same `key` stay in `unconsumed` — they are excess Studio instances and
     MUST NOT be silently folded into `matched`. (Fixture: repo has one `Core/DataManager`, Studio has two ⇒
     one `matched`, one `extraInStudio`.)

**Phase 3 — actual-only rows (each unconsumed row, stable sort by `path`):**
For each row still in `unconsumed` (normalized key absent from desired, OR excess duplicate of a desired key):
1. Walk normalized-key prefixes longest→shortest; first prefix ∈ `by_key` ⇒ nearest desired ancestor.
2. Ancestor `ignore_unknown == true` ⇒ `studioOwned`.
3. Ancestor `ignore_unknown == false` ⇒ `extraInStudio` (apply collapse-root rule below for `items`).
4. No ancestor prefix ∈ `by_key` (e.g. `Workspace/*`, `Lighting/*`) ⇒ `studioOwned`.

**Phase 4 — `unsupported` (repo index only):** count `RepoIndexEntry` where `role == Unsupported &&
projected == false` under a `$path` root; does not consume DB rows.

**`extraInStudio` collapse-root rule (bounded `items`):** an `extraInStudio` row appears in `items` iff its
immediate normalized parent prefix is a **desired key** (the attachment point to repo-owned structure). Rows
whose parent prefix is another `extraInStudio` row are counted in `total` only.

**`--under <studioPath>`:** normalize the filter arg with `normalize_query_path` before prefix-matching so
`ServerScriptService/Systems` matches capture rows regardless of `[n]` suffixes on segments.

**Headline ownership examples (decision 3 — must match Phase 3):** service roots ARE in `by_key` (§3.4), so a
direct child of a projected `ignore:true` service root ⇒ nearest ancestor is that root ⇒ `studioOwned`; a
child of a directory-projected default-`false` folder ⇒ nearest ancestor is that folder ⇒ `extraInStudio`.
ExampleProject: Studio-only under `ServerScriptService` ⇒ `studioOwned`; Studio-only under
`ServerScriptService/Core` ⇒ `extraInStudio`.

Output (`ProjectDiff`, AI-first bounded, decision 7):

```jsonc
{
  "ok": true,
  "place": "100000000000001",
  "summary": { "matched": N, "classMismatch": N, "missingInStudio": N,
               "extraInStudio": N, "studioOwned": N, "unsupported": N },
  "projectionErrors": N, "projectionWarnings": N,
  "categories": {
    "classMismatch":  { "total": N, "returned": k, "limit": L, "truncated": bool, "items": [ {studioPath, desiredClass, actualClass} ] },
    "missingInStudio":{ "total": N, "returned": k, "limit": L, "truncated": bool, "items": [ {studioPath, class, sourceRepoPath?, sourceHash?} ] },
    "extraInStudio":  { "total": N, "returned": k, "limit": L, "truncated": bool, "items": [ {studioPath, actualClass, ownerRoot} ] }
  },
  "policyReadiness": { "syncedPathsAllowed": k, "syncedPathsBlocked": j, "blockedSamples": [ {sourceRepoPath, reason} ] }
}
```
- `matched`/`studioOwned`/`unsupported` are summarized by COUNT only by default (they are the bulk and not
  actionable); `--verbose` may add bounded sample arrays for them. The actionable categories
  (`classMismatch`/`missingInStudio`/`extraInStudio`) carry bounded `items` (default `--limit 25`, same as
  `query`). `truncated:true` ⇒ raise `--limit` or narrow with `--under <studioPath>`.
- `policyReadiness`: for each projected script's `source_repo_path`, test it against the compiled allow globset
  (`load_compiled_policy`); report counts + a bounded sample of blocked paths. Reason mapping (pin for golden
  stability): **`noPolicy`** when no `.studio-stud/policy.json` is found by `resolve_repo_root`;
  **`pathNotAllowed`** when a policy file exists but the path is outside its allow globset. With the committed
  `allowedWritePaths:[]` (policy file present, empty allow), every synced path is blocked with
  `pathNotAllowed`. This is the read-only "will Stage 5 sync be allowed to write these?" pre-flight.

### 3.6 CLI surface (read-only, user-facing — NOT hidden)

Add `Commands::Project { #[command(subcommand)] action: ProjectAction, --repo-root, #[command(flatten)] common }`:

- `studio-stud project index [--repo-root <p>] [--full] [--markdown]` — emit the repo index. Default: counts by
  `role` + projected/unprojected totals; `--full` adds the bounded entry list (sorted by `repo_path`). mtime is
  display-only.
- `studio-stud project projection [--repo-root <p>] [--full] [--markdown]` — emit the flattened desired
  projection (counts by class; `--full` = bounded sorted `DesiredInstance` list incl. `source_hash`) +
  projection errors/warnings. This is the projection-fidelity inspection surface and the source of the
  projection golden.
- `studio-stud project diff <PLACE> [--repo-root <p>] [--under <studioPath>] [--limit N] [--markdown]
  [--verbose]` — the §3.5 diff against the live DB. Read-only; `open_db_readonly`. `<PLACE>` resolves via
  `resolve_place` (explicit, else active/most-recent, like `analyze`/`query`).
- `studio-stud project check [--repo-root <p>] [--markdown]` — projection validity + policy-readiness report
  WITHOUT a DB (manifest parses, all classes resolve, no projection errors, which projected paths are
  policy-allowed). Nonzero exit if the manifest is missing/malformed or projection has errors (a CI gate, like
  `policy check`).

All emit compact JSON by default; `--markdown` human-only; deterministic ordering throughout.

---

## 4. Workstream breakdown (dependency order)

Build + `cargo test` + `cargo clippy --all-targets` green after each. Commit per workstream.

### Workstream A — Dependencies + manifest parser (`project/manifest.rs`)
A1. `Cargo.toml`: `cargo add rbx_reflection_database` (REQUIRED; pin resolved latest). `rbx_reflection` is a
   transitive dep of it (for `ClassTag`); add it explicitly only if the `ClassTag::Service` enum isn't
   re-exported. Do NOT add `rbx_dom_weak`/`rbx_types` (lightweight tree, decision 5 — add them only in Stage 7
   when a real `WeakDom` is built). Do NOT add `rbx_xml`/`rbx_binary`. Compile/assert EXIT-A gate (locks the
   pinned reflection API surface): `rbx_reflection_database::get()` returns the bundled DB; `classes.get("Folder")`
   resolves; a known service (`classes.get("ServerScriptService")`) has `ClassTag::Service`; an unknown class
   (`classes.get("NotARealClass")`) is `None`.
A2. Create `src/project.rs` (+ `src/project/manifest.rs`); `pub mod project;` in `lib.rs`. Implement
   `ProjectManifest`/`ProjectNode` (§3.2), `parse_manifest(repo_root) -> Result<ProjectManifest>`, the
   effective-`ignore_unknown` rule, class resolution + reflection validation, and `ProjectError`.
A3. Unit tests (manifest):
   - parse ExampleProject `default.project.json` (copy into a fixture or read the real one via `--repo-root`):
     `name=="ExampleProject"`, `globIgnorePaths==["**/*.spec.luau"]`, every `$path` root present with
     `ignore_unknown==Some(true)`, `Workspace`/`Lighting` have `ignore_unknown==Some(true)` + no `$path`.
   - `effective_ignore_unknown`: `$path` + no explicit ⇒ false; no `$path` + no explicit ⇒ true; explicit
     wins both ways.
   - class resolution: `$className` honored; **arm 6 (ExampleProject shape):** `$className` + `$path`-to-dir ⇒
     uses `$className` not `Folder`; dir-with-init ⇒ script class; dir-without-init ⇒ `Folder`; unknown
     `$className` ⇒ projection error.
   - `emit_legacy_scripts`: absent ⇒ default `true` (`.client.*` ⇒ `LocalScript`).
   - pure tree node: `HttpService` with `$properties` only (no `$path`) projects as a service with
     `ignore_unknown == true` (default no-`$path`).

**Exit A:** `rbx_reflection_database` resolves + EXIT-A reflection gate green; manifest parses with correct
ownership defaults + class resolution.

### Workstream B — Repo index (`project/index.rs`)
B1. Implement `RepoIndexEntry`/`FileRole` (§3.3), `build_index(manifest, repo_root) -> RepoIndex`: scoped walk
   of `$path` dirs (sorted, deterministic), `globIgnorePaths` honored, role classification by extension/name,
   `hash = sha256_hex(normalize_newlines(bytes))` for text roles (raw for `Unsupported` binary), mtime captured
   display-only.
B2. Unit tests: a fixture repo tree (built in `tests/fixtures/project/`, see D) classifies roles correctly;
   `*.spec.luau` is excluded; an `init.server.luau` is `InitScript`; a `.rbxmx`/`.json` is `Unsupported`; hashes
   are stable across CRLF/LF (normalize_newlines).

**Exit B:** deterministic role-classified index honoring `globIgnorePaths`; stable hashes.

### Workstream C — Projection (`project/projection.rs`)
C1. Implement the lightweight desired-tree build + flatten (§3.4): DataModel-root skip with service roots
   emitted into `by_key`, init collapsing, `.server`/`.client`/`.luau` mapping, nested subfolders, `$properties`
   carry, per-node `NodeMeta{ignore_unknown, source_repo_path, source_hash, parse_ok}`, reflection-validated
   classes, deterministic flatten to `DesiredProjection.by_key` keyed on `normalize_query_path(studio_path)`
   (NO `[n]` suffixing — decision 6; a normalized-key collision between two desired nodes is a projection error).
C2. `project index` / `project projection` / `project check` CLI (§3.6) + dispatch arm. `project check` exits
   nonzero on manifest/projection errors.
C3. Tests (projection fidelity — its own goldens, decision 4):
   - **Init collapse:** a fixture dir `Systems/FishingSystem/{init.luau, Helper.luau}` ⇒
     `ServerScriptService/Systems/FishingSystem` is a `ModuleScript` with child `…/FishingSystem/Helper`.
   - **Suffix mapping:** `main.server.luau` ⇒ `Script` "main"; `Foo.client.luau` ⇒ `LocalScript` "Foo";
     `Bar.luau` ⇒ `ModuleScript` "Bar"; repeat with `.lua` extensions for parity.
   - **Service-root arm 6:** fixture project with `$className:"ServerScriptService"` + `$path:"src/Server"`
     (dir) ⇒ root class is `ServerScriptService`, not `Folder`; descendants default `ignore_unknown:false`.
   - **globIgnore:** `X.spec.luau` is absent from the projection.
   - **$className/$properties tree node:** a fixture project node with `$className:"Configuration"` +
     `$properties` projects that class (reflection-validated), `$properties` carried.
   - **Determinism / golden:** `project projection --full` against the fixture repo ⇒ byte-identical golden
     (`tests/golden/project_projection_fixture.txt`, mtime/timestamp normalized).
   - **Adapted Rojo parity:** at least 3-4 cases lifted from Rojo's projection semantics (init kinds,
     `$path`-to-file, default-Folder tree node, `$ignoreUnknownInstances` default rule) to lock parity.

**Exit C:** projection reproduces Rojo Luau+folder semantics; `index`/`projection`/`check` work; projection
golden stable.

### Workstream D — Diff engine (`diff.rs`) + `project diff` + the large fixture
D1. Implement `ProjectDiff` (§3.5 + §3.5.1): load actual as `Vec<ActualRow>` (NEVER `BTreeMap<path_norm, _>`),
   run the four-phase classification algorithm (multiplicity rule: at most one `matched`/`classMismatch` per
   desired key; excess actual rows ⇒ actual-only path), `STALE_DB_SCHEMA_MSG` on missing baseline / NULL
   `path_norm`, `extraInStudio` collapse-root filtering for bounded `items`, `policyReadiness` via
   `load_compiled_policy`. Assert `sum(five DB category counts) == live instance_count` in tests. `project diff
   <PLACE>` CLI + dispatch arm.
D2. **Permanent fixtures + tests — `tests/project_diff.rs` + `tests/fixtures/project/`:**
   - A committed **fixture repo tree** under `tests/fixtures/project/repo/` (`default.project.json` mapping
     `ServerScriptService`→`server/` with `$ignoreUnknownInstances:true`, plus a default-false nested folder)
     and `server/{main.server.luau, Core/init.luau, Core/DataManager.luau, Systems/Combat.luau, X.spec.luau}`.
   - A committed **fixture raw snapshot** `tests/fixtures/project/actual.json` (capture shape) ingested via the
     existing `ingest` CLI into a temp `--storage-root`, representing the matching Studio place — deliberately
     containing: all repo-projected instances (⇒ `matched`); one with a different class (⇒ `classMismatch`);
     a Studio-only child directly under `ServerScriptService` (⇒ `studioOwned`, ignore:true root); a Studio-only
     child under the default-false nested folder (⇒ `extraInStudio`); a `Workspace/*` instance (⇒ `studioOwned`,
     unprojected root); a **duplicate-named sibling pair** in Studio under a repo-owned folder where the repo
     projects exactly ONE such name (e.g. repo has `Core/DataManager`, Studio has `DataManager` twice ⇒ one
     `matched`, the second `extraInStudio`) to exercise the non-dedup join (decision 6); and OMITTING one repo
     script (⇒ `missingInStudio`).
   - Assertions: `summary` counts exact; **count invariant `sum(matched+classMismatch+missingInStudio+
     extraInStudio+studioOwned) == live instance_count`** (`unsupported` excluded — repo files only); `missingInStudio` item carries
     `sourceHash`; `extraInStudio` item names the owner root; the `studioOwned` Studio-only-under-ignore:true
     child is NOT in `extraInStudio` (the ownership-boundary proof); **multiplicity:** repo-single vs
     Studio-duplicate under same key ⇒ exactly one `matched`, the excess row `extraInStudio` (§3.5.1); `classMismatch` lists desired+actual class; **determinism** (two `project diff` runs
     byte-identical); `--under` narrows correctly; an oversized category sets `truncated:true` with
     `returned <= limit`.
   - **Boundedness at scale:** generate (in-test, programmatically) a fixture with hundreds of projected scripts
     + hundreds of differences and assert the diff JSON stays bounded (counts + capped samples; no full dump).
   - **Stale/no-baseline DB:** `project diff` against an empty/old storage ⇒ `STALE_DB_SCHEMA_MSG`, nonzero exit.
D3. **Isolation regression:** the `golden_outputs` + `live_convergence` + `write_safety`/`write_http` +
   `http_reliability` suites stay byte-identical (no schema/route/dep-removal perturbation).

**Exit D:** ownership-aware structural diff correct + bounded + deterministic; large fixture stays bounded; all
prior suites unchanged.

### Workstream E — Docs + rule + repo map
E1. `docs/studio-stud.md`: add a "Project diff (Stage 4)" section — `project index|projection|diff|check`, the
   six diff categories + the ownership rule (decision 3), the structural-not-source caveat (decision 2, point at
   Stage 5 for source sync), the bounded-output contract, and that it is READ-ONLY.
E2. `.cursor/rules/studio-stud.mdc`: add the `project` subcommands under a "Project diff" subsection with the
   one-line note that the diff is structural/read-only and ownership-aware (so the AI uses `project diff` for
   "what does the repo expect vs the live place", and knows it does NOT detect changed script bodies — that is
   Stage 5). `docs/repo-map.md` auto-regenerates via the hook (run `/repo-map` if `project.rs`/`diff.rs` aren't
   picked up).

**Exit E:** docs + rule describe the read-only project diff + ownership semantics; repo map current.

---

## 5. Execution order (for Composer)
1. Workstream A (`rbx_reflection_database` + manifest parser + EXIT-A reflection gate).
2. Workstream B (repo index).
3. Workstream C (projection + `index`/`projection`/`check` CLI + projection goldens).
4. Workstream D (diff engine + `project diff` + permanent fixtures + isolation regression).
5. Workstream E (docs + rule + repo map).
6. Final verification (§7/§8).

Commit per workstream. After each: `pwsh tools/studio_stud/build-local.ps1` + `cargo test` +
`cargo clippy --all-targets` clean. No plugin load needed (no plugin change this stage).

---

## 6. Resolved sub-decisions (all locked)

Locked in §0:
- **Structural diff only; do NOT capture Source** (decision 2). Source sync = Stage 5 base ledger + in-plugin CAS.
- **Reflection (`rbx_reflection_database`) now; lightweight desired tree; `WeakDom`/`rbx_xml`/`rbx_binary`
  deferred to Stage 7** (decision 5).
- **In-memory repo index; no SQLite index table** (decision 8).
- **No HTTP route; CLI-only read** (decision 10).
- **Ownership = Rojo per-node default-by-`$path` rule, explicit wins** (decision 3).
- **Join on `normalize_query_path`; actual side never deduped on `path_norm`** (decision 6).
- **`matched`/`studioOwned` sample exposure:** default count-only; `--verbose` adds bounded samples (locked).

Open sub-questions: **none** — all sub-decisions locked above.

---

## 7. Test contract (what proves the stage)
- **Projection parity (its own goldens):** init-collapse (3 kinds), `.server`/`.client`/`.luau` mapping,
  `$path`-to-file, default-`Folder` tree node, `$className`/`$properties` node, `globIgnorePaths` exclusion,
  adapted-Rojo cases; `project projection --full` byte-identical golden.
- **Ownership correctness:** Studio-only child under `$ignoreUnknownInstances:true` root ⇒ `studioOwned` (NOT
  `extraInStudio`); Studio-only child under a default-false directory-folder ⇒ `extraInStudio`; explicit
  `$ignoreUnknownInstances:false` override flips a tree node; `effective_ignore_unknown` unit-tested directly.
- **Structural diff categories:** `matched`/`classMismatch`/`missingInStudio`/`extraInStudio`/`studioOwned`/
  `unsupported` each exercised against the fixture place; `missingInStudio` carries `sourceHash`; no code reads a
  (non-existent) Source column.
- **Join fidelity + multiplicity (decision 6, §3.5.1):** actual loaded as `Vec` (never `BTreeMap<path_norm,_>`);
  at most one `matched`/`classMismatch` per desired key; excess duplicate-named Studio siblings ⇒ `extraInStudio`;
  `sum(five DB category counts) == instance_count`; `--under` uses `normalize_query_path`.
- **Boundedness + determinism:** large fixture (hundreds of diffs) stays bounded (counts + capped samples +
  `truncated`); two `project diff` runs byte-identical; `--under` narrows.
- **Policy readiness:** projected paths tested against the compiled allow globset; with the committed
  `allowedWritePaths:[]` and policy file present, all synced paths report `pathNotAllowed` (golden-stable).
- **Stale DB:** `project diff` against no-baseline storage ⇒ `STALE_DB_SCHEMA_MSG`, nonzero exit.
- **Read-only / isolation:** no file/Studio/schema/route mutation; `golden_outputs` + `live_convergence` +
  `write_safety`/`write_http` + `http_reliability` suites byte-identical; no dep removed.
- **Reflection adopted:** EXIT-A reflection gate green (`classes.get("Folder")` resolves; a service has
  `ClassTag::Service`; an unknown class is `None`); `rbx_dom_weak`/`rbx_types`/`rbx_xml`/`rbx_binary` absent.

---

## 8. Tests Tyler runs (single-person, required for exit)

### 8.1 Automated (from `tools/studio_stud/`)
```powershell
pwsh tools/studio_stud/build-local.ps1     # clean build -> bin/studio-stud.exe
cargo test                                  # all unit + golden + project_diff + UNCHANGED prior suites green
cargo clippy --all-targets                  # no new warnings
```
Must be green, in particular: `project_diff` (all six categories + ownership boundary + multiplicity +
boundedness + determinism + stale-DB + count invariant), the projection goldens + parity cases, the EXIT-A
reflection gate, and the UNCHANGED
`golden_outputs` / `live_convergence` / `write_safety` / `write_http` / `http_reliability` suites.

### 8.2 CLI smoke (no Studio, no daemon — against the real repo + an existing place DB)
```powershell
# projection / index / check (no DB needed)
.\bin\studio-stud.exe project check                                   # ok:true, exit 0 (manifest + projection valid)
.\bin\studio-stud.exe project index                                  # role counts; --full for entries
.\bin\studio-stud.exe project projection --full | ConvertFrom-Json   # flattened desired instances + source hashes
# diff against a captured place (uses the live DB; ensure a capture exists, e.g. ExamplePlaceA)
.\bin\studio-stud.exe project diff 100000000000001                   # summary + bounded actionable categories
.\bin\studio-stud.exe project diff 100000000000001 --under ServerScriptService/Systems --limit 50
```
Expect: `summary.studioOwned` is large (Workspace/Lighting/etc. + Studio-managed children under ignore:true
roots) and is NOT flooding `extraInStudio`; `missingInStudio` lists repo scripts not yet in the captured place;
`policyReadiness` reports every synced path as `pathNotAllowed` under the committed empty
`allowedWritePaths` (policy file present at `.studio-stud/policy.json`).

---

## 9. Exit gate checklist (all must be true)
- [ ] **Read-only:** no file/Studio write, no schema change, no HTTP route; diff uses `open_db_readonly`; grep of
      `project.rs`/`diff.rs` finds no `atomic_write`/`init_schema`/`INSERT`/route/`ChangeHistoryService`.
- [ ] **Generic only:** no game/boat term, no `CRITICAL_NAMES`/`KEYWORDS` in `project.rs`/`diff.rs`.
- [ ] **Reflection adopted, DOM/serialization deferred:** `rbx_reflection_database` added; classes
      reflection-validated; lightweight desired tree (no `WeakDom`); `rbx_dom_weak`/`rbx_types`/`rbx_xml`/
      `rbx_binary` NOT added; EXIT-A reflection gate green.
- [ ] **Manifest parser:** parses `default.project.json` (Rojo v7 subset) with correct per-node
      `effective_ignore_unknown` (default-by-`$path`, explicit wins) + class resolution.
- [ ] **Projection fidelity:** init collapsing (3 kinds), `.server`/`.client`/`.luau` mapping, `$path`-to-file,
      default-`Folder` node, `$className`/`$properties` node, `globIgnorePaths`; deterministic flatten; own golden.
- [ ] **Structural diff (decision 2):** six ownership-aware categories; no Source comparison; `missingInStudio`
      carries `sourceHash` for Stage 5; join on `normalize_query_path`; actual never deduped on `path_norm`
      (duplicate-sibling multiplicity + `sum(five DB counts)==instance_count`).
- [ ] **Ownership correctness:** Studio-only under ignore:true ⇒ `studioOwned`; under default-false folder ⇒
      `extraInStudio`; explicit `false` override flips; the boundary is the headline test.
- [ ] **Bounded + deterministic (§5.7/§10):** large fixture bounded (counts + capped samples + `truncated`);
      two runs byte-identical; `--under` narrows.
- [ ] **Policy readiness:** projected paths tested against the compiled allow globset (read-only pre-flight).
- [ ] **CLI:** `project index|projection|diff|check` work; `project check` exits nonzero on manifest/projection
      errors; `project diff` errors with `STALE_DB_SCHEMA_MSG` on no baseline.
- [ ] **Isolation:** capture/live/query/write goldens + live-convergence + http-reliability suites byte-identical;
      routes/aliases/404 unchanged; no dep removed.
- [ ] **Reuse:** hashing/parse/diff-text from `write::safety`, not re-implemented.
- [ ] **Docs/rule/map:** `docs/studio-stud.md` + `.cursor/rules/studio-stud.mdc` describe the read-only,
      structural, ownership-aware project diff; repo map current.
- [ ] `cargo test` + `cargo clippy` green; `build-local.ps1` clean.
- [ ] No Stage 5+ surface introduced.

---

## 10. Risks & mitigations
- **Projection infidelity silently corrupts every diff (design §5.1, the top risk).** A wrong init-collapse,
  suffix, or ordering rule poisons the desired side. Mitigation: projection is a hardened sub-component with its
  own unit + golden tests + adapted-Rojo parity cases, tested INDEPENDENTLY of the diff (Workstream C) before
  the diff consumes it.
- **Ownership rule wrong ⇒ false "delete candidates" against Studio-managed content (correctness-critical).**
  Misapplying the per-node `$ignoreUnknownInstances` default would flag legitimate Studio content as
  `extraInStudio`. Mitigation: implement Rojo's exact default-by-`$path` rule (decision 3), unit-test
  `effective_ignore_unknown` directly, and make the ignore:true-root-vs-default-false-folder boundary the
  headline fixture assertion.
- **Trying to diff script source with no Source in the DB (the trap).** The DB has no script body (verified).
  Mitigation: decision 2 — structural-only diff; record `source_hash` for Stage 5; do NOT add Source to capture
  (would perturb capture/live + bloat the DB + break goldens). Document that "changed script" detection is
  Stage 5.
- **Join-key / multiplicity bugs (decision 6).** Deduping actual on `path_norm`, reproducing `[n]` in desired
  paths, or classifying every duplicate-named sibling as `matched` silently corrupts counts and ownership.
  Mitigation: §3.5.1 four-phase algorithm; `Vec` load; at-most-one pairing per desired key; count invariant in
  every diff test; duplicate-sibling fixture.
- **Join-key drift between projection paths and capture paths.** Different separators would desync the join.
  Mitigation: join on `normalize_query_path`; desired `studio_path` without `[n]`; `--under` normalizes filter.
- **rbx-dom API/version drift (decision 5).** `rbx_reflection_database`'s API evolves. Mitigation:
  pin via `cargo add`; an EXIT-A compile+lookup gate locks the surface; keep usage minimal (reflection lookup +
  class lookup) and defer `$properties` typing + `rbx_xml`/`rbx_binary` to Stage 7.
- **Unbounded diff output on a large place (§5.7/§10).** Hundreds of differences could flood AI context.
  Mitigation: count-only for the bulk categories, bounded `items` (default `--limit 25`) for actionable ones,
  `extraInStudio` subtree collapse, `truncated` + `--under`, and a programmatic large-fixture boundedness test.
- **Walking the whole repo (perf / picking up junk).** Mitigation: scope the index walk to `$path` dirs +
  `globIgnorePaths`; skip `.git`/`target`/`node_modules`/`.cursor`.
- **Perturbing capture/live/query/write isolation.** Mitigation: new modules + new CLI only; no schema, no
  route, no dep removal; the UNCHANGED prior goldens + suites guard against drift.
- **Scope creep into Stage 5-8.** Forbidden in scope/§0: no watcher/patch planner/`sync.rs`, no plugin apply,
  no hash-guarded applies, no base-ledger persistence, no CAS/merge/`flctl`, no model-file projection, no boat.

---

## 11. Out of scope (defer to later stages)
File watcher → patch set, plugin apply endpoints (Folder/Script/Source/Delete/Move), hash-guarded applies,
per-file base ledger persistence, source-content "changed script" detection, post-apply verification (Stage 5);
multi-developer / Team Create concurrency, in-plugin content CAS, deterministic 3-way merge, transient claims,
`flctl sync explain|status|resolve`, post-write convergence (Stage 6 + Final Verification); `.rbxmx`/`.rbxm`/
`.model.json`/`.meta.json`/`.json`/`.toml`/`.txt`/`.csv` projection, `rbx_xml`/`rbx_binary`, typed `$properties`
Variant conversion, `build` + `sourcemap`, controlled two-way reconcile (Stage 7); Boat Configurator panel
(Stage 8). Persistent/cached repo index, exposing the diff over HTTP, and enforcement of
`maxPatchItems`/`maxDeleteCount`/`ownedPaths`/`ownedServices`/`lease`/`unsupportedFeatureBehavior` are also
deferred — Stage 4 reads policy for the readiness report only.

---

## 12. Technical-review revision log (applied)

Independent adversarial review (`/review-plan`) identified the items below. All are incorporated in this
revision; implementers should treat §3.5.1 as authoritative where it supersedes earlier prose.

| # | Severity | Finding | Resolution in this plan |
|---|----------|---------|-------------------------|
| 1 | **Blocker** | Actual side keyed on `path_norm` silently drops duplicate-named Studio siblings (`normalize_query_path` strips `[n]`; plugin adds `[n]` to every segment) | Decision 6 rewritten; §3.5.1 Phase 1 loads `Vec<ActualRow>`; explicit NEVER `BTreeMap<path_norm,_>`; count invariant + fixture |
| 2 | **Major** | Plan mischaracterized `[n]` as duplicate-only disambiguation; instructed projection to reproduce `[n]` | Corrected in §2, decision 6, §3.4 flatten: desired `studio_path` has NO `[n]`; join strips them anyway |
| 3 | **Major** | `WeakDom` self-contradictory for Stage 4 (typed Variant deferred to Stage 7) | Decision 5 locked to lightweight tree + `rbx_reflection_database` only; `rbx_dom_weak`/`rbx_types` deferred to Stage 7 |
| 4 | **Major** | Multiplicity rule unspecified: multiple actual rows per desired key would all `matched` | §3.5.1 Phase 2: at most one `matched`/`classMismatch` per desired key; excess ⇒ actual-only (`extraInStudio`) |
| 5 | Minor | `extraInStudio` collapse-root rule under-specified | §3.5.1 Phase 3 + Phase 4 collapse-root rule |
| 6 | Minor | DataModel root emission implicit | §3.4 root handling: skip DataModel; service roots in `by_key` |
| 7 | Minor | Case-insensitive class compare | §3.5 table: exact class match |
| 8 | Minor | `*.plugin.lua` role ambiguous | Locked to `FileRole::Unsupported` |
| 9 | Minor | `policyReadiness` reason mapping unstable | Pinned `noPolicy` vs `pathNotAllowed`; ExampleProject golden expects `pathNotAllowed` |
| 10 | Minor | `emitLegacyScripts` not on manifest struct | Added `emit_legacy_scripts: Option<bool>` to `ProjectManifest` |
| 11 | Minor | `--under` filter vs capture `[n]` segments | §3.5.1: normalize filter arg with `normalize_query_path` |
| 12 | Optional | Open sub-questions left ambiguity | All locked; verbose samples default count-only |
