---
name: Studio Stud Platform — Stage 3 (Generic write/reconcile primitive + policy + token)
overview: Add a deterministic, policy-gated, allowlisted Studio→FS file-write primitive to the daemon, completely independent of any boat/game logic. Ships three things that later stages reuse verbatim — (1) a reusable write-safety toolkit (Luau parse via full-moon, unified-diff generator via similar, atomic temp+replace, sha256 hash compare, newline normalization), (2) the policy layer (.studio-stud/policy.json loader + glob allowlist + caps + `studio-stud policy init|check|explain`), and (3) the HTTP write namespace `/studio-stud/write/{validate,preview,apply}` plus an auto-issued write token with a localhost handshake. Proven by a PERMANENT fixture + golden/integration test that runs in every later stage so the early-built endpoint cannot bit-rot. No write consumer is wired in this stage (boat is Stage 8); the toolkit is consumed by Stages 4-5.
todos: []
isProject: false
---

# Studio Stud Platform — Stage 3 Execution Plan (Generic write/reconcile primitive + policy + token)

Status: READY TO EXECUTE. Source of truth: `docs/studio-stud-platform-design.md` §5.2 (write/reconcile
protocol), §5.3 (policy file), §5.5 (Decision D1/Option A — boat renders finished Luau, daemon writes
generically), §7 (Stage 3 mapping), §9 (security/safety), §10 (perf/determinism), §11 (Stage 3 deliverables
+ exit gate), §14 (D3 token handshake, D5 full-moon), and Appendix B (policy.json schema), C (write protocol
shapes), H (write-token handshake). This plan executes the design; it does not re-litigate it.

Stage 3 is a **net-additive** stage: it adds a new HTTP namespace, two new Rust modules (`policy.rs`,
`write.rs`), a token, and CLI subcommands, but it changes **nothing** in the capture/live/query paths. The
write apply path has **no workflow consumer in this stage** — the first real consumers are Stage 4-5
(reuse the toolkit to validate synced/projected Luau) and Stage 8 (boat config persistence). The endpoint is
therefore proven by a permanent fixture + golden/integration test, NOT by a feature.

Scope is exactly the Stage 3 deliverables and nothing more. Do **NOT** introduce any Stage 4+ surface: no
repo index, no `default.project.json` Rojo parsing, no `rbx-dom`, no desired projection, no `project diff`,
no FS→Studio apply / plugin apply endpoints, no per-file base ledger, no multi-developer concurrency / CAS /
3-way merge / `flctl sync`, no Boat Configurator panel. The write primitive built here is **one file at a
time, client-supplied finished text** (Option A); multi-op patches and the patch caps
(`maxPatchItems`/`maxDeleteCount`) are parsed-and-stored only, enforced in Stages 4-6.

---

## 0. Locked decisions (do not revisit)

0. **GENERIC ONLY — zero game/boat knowledge in the daemon (hard guardrail, Non-Goals §65-67).** Nothing in
   `policy.rs`/`write.rs`/`http.rs` knows the word "boat", the boat schema, or any game concept. The write
   primitive takes `{ path, content }` where `content` is **finished text the client already rendered**
   (Option A / D1). The daemon validates generically (allowlist, size, header marker, UTF-8, optional Luau
   parse) and writes atomically. This is the single most important invariant of the stage — a reviewer
   grepping the new modules for game terms must find none.

1. **Fail closed — and a failing CHECK is a structured BLOCK, never a 503 (review BLOCKER-fix).** Every write
   path defaults to DENY. No policy file ⇒ block (`noPolicy`). Path not in the allowlist / escapes the repo
   root ⇒ block. A write is allowed only when *every* gate explicitly passes. **Critically:** internal errors
   inside the gate pipeline (policy IO error, `globset` build error, `canonicalize` failure, etc.) MUST be
   caught and converted to a structured block (`blockedReason:"internalError"` with a compact `detail`),
   NOT `?`-propagated. The current route mapper turns any `Err` into HTTP **503** and the CLI into an
   unstructured nonzero exit — which would make a real error path bypass the structured-block contract. So
   `write::file`/`policy::check_path` return a `WriteOutcome`/`Option<BlockedReason>` and never bubble an
   `anyhow::Err` out of the gate logic (reserve `Err`/503 for genuine framework failures only). Model the
   gates so the type system prevents an internal `Err` from reaching the write step.

2. **Client supplies finished content (Option A, D1/§5.5).** The daemon never generates file bodies. It does
   not template, does not know schemas. `write/apply` receives the complete intended file text and persists
   it. (Daemon-owned generation is explicitly future-only, D6 — not built here.)

3. **Determinism contract — write decision on RAW bytes, hashes on NORMALIZED bytes (review MAJOR-fix).**
   Same `(path, content)` ⇒ byte-identical file on disk. Normalize line endings to `\n` (LF); CRLF and
   lone-CR collapse to LF. Content is otherwise written exactly as supplied (no trailing-newline insertion,
   no trimming, no reformatting). We ALWAYS write the LF-normalized bytes, so after any apply the on-disk file
   IS the normalized content. Two distinct quantities (do not conflate — this was the bug):
   - **Physical write decision (`changed`)** = `raw_on_disk_bytes != normalized_proposed_bytes` (byte-exact).
     This means a file that is logically identical but stored as CRLF on disk IS rewritten to LF (so
     byte-identity holds), while a file already byte-equal to the normalized target is a true no-op (skip the
     write, preserve mtime). `changed` reports "the file on disk was/would be modified."
   - **`hashBefore`/`hashAfter`** = sha256 over NORMALIZED bytes (`hashBefore` = normalized current on-disk
     bytes or `""` if absent; `hashAfter` = normalized proposed = the bytes we write). These are
     newline-insensitive and are the CAS basis (decision below + §3.2). So `hashBefore == hashAfter` with
     `changed:true` is a legal, expected combination (a CRLF→LF-only rewrite).
   - Repo hygiene: add `.gitattributes` (`*.luau text eol=lf`; `tests/fixtures/write/** -text`) so checkouts
     don't re-mangle EOLs under a dev's `core.autocrlf` and undo the normalization on the next commit. There
     is no `.gitattributes` today; the determinism guarantee depends on adding one (Workstream A).
   Document this split in code + docs.

4. **Atomic or nothing.** Render in memory → validate → write a temp file in the **same directory** as the
   target (same filesystem ⇒ atomic rename) → `fs::rename` over the target. On ANY validation failure no temp
   is created; on a mid-write failure the temp is removed and the original file is untouched. Never a partial
   file. (Use a fresh `write::safety::atomic_write`, §3.3, reusing the temp-write-rename *pattern*; the dead
   `storage.rs::atomic_write_json` is DELETED — its `with_extension` temp naming would clobber a `.luau`
   target. See §2/A2.)

5. **The reusable write-safety toolkit is a first-class deliverable, separate from the write endpoint
   (§11/§7).** Split into: (a) `write::safety` — `parse_luau`, `unified_diff`, `atomic_write`, `sha256_hex`,
   `normalize_newlines`; and (b) `write::file` — the policy-gated Studio→FS apply that composes the toolkit
   with `policy.rs`. Stages 4-5 consume `write::safety` directly to validate projected/synced Luau before it
   touches the live place; Stage 8 consumes `write::file`. Keep the toolkit free of policy so it is reusable.

6. **`policy.json` is COMMITTED and team-shared; the write token is NOT (D3/§6/§9).** The policy is
   project-layer trust shared between developers (Stage 6 needs both devs on the same policy), so it lives at
   repo `.studio-stud/policy.json` and is committed (do NOT gitignore it). The token is a per-daemon local
   convenience credential stored under the storage root (`%LOCALAPPDATA%/StudioStud/write.token`), outside
   the repo — never committed, never in chat.

7. **Token gates HTTP writes only; it is NOT the real safety mechanism (Appendix H honesty note).** A
   localhost handshake mainly prevents accidental cross-talk from other local tools; any local process could
   call it. The REAL protection is allowlist + policy + place-id + (later) hash guard. So: `/write/*` over
   HTTP requires the token; the **CLI** (`write-*` hidden subcommands, run by the trusted local user) does
   NOT require a token and calls the same `write::file` functions directly. Token-check lives in `http.rs`,
   never inside the toolkit — so the toolkit stays reusable and CLI-testable without HTTP.

8. **Single-file, client-text writes only this stage.** `write/{validate,preview,apply}` operate on ONE
   file. The patch-level caps `maxPatchItems`/`maxDeleteCount` and `ownedPaths`/`ownedServices`/`lease` are
   PARSED and stored from policy but NOT enforced here (no multi-op patch exists yet); they are enforced in
   Stages 4-6. `maxPatchBytes` (single-file size cap), `allowedWritePaths`, `requireGeneratedHeaderPaths`,
   and `allowedPlaceIds` ARE enforced now. Document which fields are live vs reserved.

9. **Testability without Studio is mandatory (mirror Stage 2 decision 8).** Every correctness guarantee
   (allowlist enforcement, caps, atomic write, determinism, diff, Luau-parse rejection, hash CAS, policy
   parse) MUST be runnable from `cargo test` against fixtures with NO live Studio and NO running daemon, via
   hidden CLI subcommands (`write-validate`/`write-preview`/`write-apply`/`policy …`) driving the toolkit
   against `--repo-root` + `--storage-root`. The daemon HTTP layer gets a thin smoke test for token
   enforcement + route wiring only.

10. **Plugin handshake is minimal and consumer-free this stage, but REQUIRED (D3).** Implement the daemon
    token + `GET /studio-stud/write/token` endpoint fully (needed + testable). On the plugin side, add ONLY a
    transport helper (`Transport.fetchWriteToken()` + cache in plugin settings + `Transport.requestJsonAuthed`
    that attaches the token header) plus a self-test — **no write UI, no write calls**. The first plugin write
    consumer is Stage 8. Rationale for doing it now (not deferring): D3 lists it as a Stage 3 deliverable, it
    is cheap + self-testable, and Stage 6 `flctl`/CAS will need authed writes — building the primitive once,
    here, avoids re-opening the transport layer later. Workstream E is REQUIRED, not optional.

11. **`policy explain` is a path/place/size/header-required/glob pre-flight; content-dependent gates are
    reported as "checked at write time."** Without file content, `explain` cannot evaluate the
    `headerMissing`/`parseError`/`hashMismatch` gates, so it reports `allowed` against the
    content-independent gates (path allowlist, traversal/escape, place, size cap) and flags
    `headerRequired:true|false` + a note that header presence + Luau parse are enforced at `validate`/`apply`.
    This is the right contract for an AI/human "can I write here?" pre-flight; we do NOT make `explain` take
    content.

12. **Unified diff = `similar` line-based, `context_radius(3)`.** Standard, AI-bounded, deterministic. No
    tighter/looser radius; line-based (not char/word) for stable, reviewable hunks.

13. This plan is saved under `.cursor/plans/` matching the existing `*_<hex>.plan.md` convention.

---

## 1. Hard guardrails / definition of done

- **No game logic in the daemon (decision 0).** A grep of `policy.rs`/`write.rs`/`http.rs` write routes for
  any game/boat term returns nothing. The write primitive is `{path, content}` in, structured result out.
- **Fail-closed everywhere (decision 1).** Negative tests prove every out-of-policy attempt is blocked with a
  structured `blockedReason` + (CLI) nonzero exit; no path, no missing-policy, no oversize, no header-missing,
  no malformed-Luau, no hash-mismatch write ever lands.
- **Deterministic, atomic, no data loss (decisions 3-4).** Same input ⇒ byte-identical file (golden); a
  failed write leaves the original intact and no temp behind; a no-op write (`changed:false`) does not rewrite
  the file (preserves mtime, avoids needless churn).
- **Capture/live/query untouched.** All existing routes/aliases + the 404 fallback unchanged; `cargo test`
  goldens for `analyze_*`/`query_*`/`status_json`/`doctor_json` and the live convergence suite stay green
  byte-for-byte. The write additions are isolated behind new routes/modules.
- **Permanent anti-bit-rot test (§7/§11).** `tests/write_safety.rs` + `tests/fixtures/write/*` +
  `tests/golden/write_*` exercise the full validate→preview→apply lifecycle and every block reason, and run
  in `cargo test` from this stage forward.
- **Toolkit reusable by Stages 4-5 (decision 5).** `write::safety` has no policy/HTTP dependency and a public
  (crate) API the diff/sync stages can call.
- **AI-first output discipline (§5.7).** Write responses are compact JSON with stable fields
  (`ok`, `blocked`, `blockedReason`, `changed`, `diff`, `bytes`, `hashBefore`, `hashAfter`); diffs are
  bounded/compact; never echo a full file body unless explicitly requested. `policy explain` is the
  read-only AI/human "would this write be allowed and why" surface.
- **No Luau register-pressure / connection regressions in the plugin** (`.cursor/rules/luau-files.mdc`) from
  the required minimal plugin handshake (decision 10).

---

## 2. Current state (verified facts, do not re-discover)

- **Daemon modules** (after Stages 0-2): `tools/studio_stud/src/{lib,util,storage,capture,output,http,
  analyze,query,cli,bench,live}.rs`. **No `write.rs`, no `policy.rs` yet** — Stage 3 creates both and adds
  `pub mod write; pub mod policy;` to `lib.rs`.
- **Cargo deps** (`Cargo.toml`): `anyhow, chrono, clap(derive), dirs, flate2, rusqlite(bundled), serde,
  serde_json, sha2="0.11", tiny_http, uuid="1.23.2"`. **No `full-moon`, no diff crate, no glob crate.** Stage 3
  adds `full-moon` (with the `luau` feature — REQUIRED, §3.4), `similar` (unified diff), and `globset`
  (allowlist glob matching), and **adds the `["v4"]` feature to `uuid`** (currently featureless + unused —
  `Uuid::new_v4` will NOT compile without it; review BLOCKER). `sha2 = "0.11"` is already used by
  `capture.rs` (`Sha256::new()/update()/finalize()` + `hex_bytes`) — the toolkit's `sha256_hex` copies that
  exact pattern (the 0.11 Digest API is a non-issue, already proven in-tree).
- **HTTP today** (`http.rs`): `handle_daemon_request(request, state: Arc<Mutex<DaemonState>>, storage_root:
  Option<PathBuf>, project_key: &str)`. Routes are ping/manifest/capture(request|start|body|chunk|complete|
  status) + legacy aliases (`/request-sync`, `/live-sync/*`) + `live/{delta,fingerprint,verify/*}`. Status
  mapping after the route closure: `ok:false`→404, the protocol-too-old marker→426, `Err`→503, else 200.
  **This is the pattern Stage 3 mirrors for token failure → 401** (a sentinel error string special-cased like
  the 426 case). `DaemonState{pending_requests,active_request_id,uploads,verify_uploads,completions}` has no
  token field. `daemon_json(method,path,body)` is the CLI→daemon client. `read_request_json` exists.
- **CLI today** (`cli.rs`): `Cli{command}`, `Commands` enum with `Status/Doctor/Ingest/Analyze/Query/Capture/
  Serve/Daemon/Bench/LiveDelta/LiveVerify/LiveDump`. `CommonArgs{project_key(default "ExampleProject"),
  storage_root: Option<PathBuf>}` flattened into most commands. Hidden subcommands use `#[command(hide =
  true)]` (`Bench`, `LiveDelta`, etc.). `cmd_serve(host,port,common)` binds tiny_http, builds
  `Arc<Mutex<DaemonState::default()>>`, loops `handle_daemon_request(...)`. Dispatch is a big `match`.
- **Storage** (`storage.rs`): `Storage{root,project_key}`; `Storage::new(storage_root, project_key)` resolves
  root to `--storage-root` or `dirs::data_local_dir()/APP_NAME` (`APP_NAME="StudioStud"`). `atomic_write_json`
  exists but is `#[allow(dead_code)]` with **NO callers** (verified) and uses the buggy-to-generalize
  `path.with_extension("json.tmp")` (replaces a real extension). So the toolkit's `atomic_write` is a fresh
  generic impl (§3.3); `atomic_write_json` can be **deleted** rather than kept-delegating (removing it also
  clears the dead-code allow). WAL `open_db`, `safe_key`, `init_schema` (unchanged this stage — no new tables).
- **Util** (`util.rs`): `DEFAULT_HOST="127.0.0.1"`, `DEFAULT_PORT=31878`, `DEFAULT_PROJECT_KEY="ExampleProject"`,
  `PROTOCOL_VERSION=1`, `MIN_PLUGIN_PROTOCOL_VERSION=1`, `make_id`, `now_utc`, `hex_bytes`, `safe_key`,
  `split_url`/`required_query`. **`hex_bytes` + `sha2::Sha256` are the hashing primitives** (live.rs already
  uses sha256 over canonical values — reuse the same approach for file hashing).
- **Tests** (`tests/`): `golden_outputs.rs` (CLI golden harness: `run_cli(args, storage_root)` via
  `CARGO_BIN_EXE_studio-stud`, `normalize_output`/`normalize_json`, golden files under `tests/golden/`);
  `live_convergence.rs` (CLI driver pattern: `run_cli` + `run_cli_allow_fail` for nonzero-exit assertions,
  temp storage per test, fixtures under `tests/fixtures/live/`). **NOTE:** the existing `run_cli`/
  `run_cli_allow_fail` UNCONDITIONALLY append `--storage-root` (`live_convergence.rs:27-56`); the new
  `policy`/`write-*` CLIs take `--repo-root`, so Stage 3 adds a sibling harness helper that appends
  `--repo-root` (or those subcommands also flatten `CommonArgs` so both flags are accepted). **Stage 3 adds
  `tests/write_safety.rs` + `tests/fixtures/write/` + `tests/golden/write_*.txt`.**
- **Plugin** (`StudioStud.plugin.lua`): `PROTOCOL_VERSION=1`; `SETTINGS = {daemonUrl, welcomeVersion,
  liveCaptureEnabled, debounceMs, debugLogging, panelEnabled}`; `Settings.getString/setString` wrap
  `plugin:GetSetting/SetSetting`; `Transport.requestJson(method,path,body,timeout)` and `Transport.requestBody`
  exist and set `Content-Type: application/json`. **Stage 3 (required, decision 10) adds a `writeToken`
  settings key + `Transport.fetchWriteToken()` + `Transport.requestJsonAuthed`.**
- **.gitignore**: only `tools/studio_stud/target/` + `bin/*` are ignored. `.studio-stud/` is NOT ignored —
  so `.studio-stud/policy.json` will be committed by default (decision 6, intended). The token never lives
  in the repo.

---

## 3. Policy model + write protocol + toolkit (the design)

### 3.1 `.studio-stud/policy.json` schema (Appendix B) — `policy.rs`

Committed, repo-relative, strict JSON. `policy init` GENERATES it (so we control the format — strict JSON, no
comments; the Appendix B jsonc is illustrative only). Loader uses strict `serde_json`.

```rust
#[derive(Deserialize, Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Policy {
    pub version: u32,                                   // == 1; reject unknown major
    #[serde(default)] pub allowed_place_ids: Vec<i64>,  // [] = no place restriction
    #[serde(default)] pub allowed_write_paths: Vec<String>,        // repo-relative globs (ENFORCED)
    #[serde(default)] pub require_generated_header_paths: Vec<String>, // globs needing the marker (ENFORCED)
    #[serde(default = "default_max_patch_bytes")] pub max_patch_bytes: u64,  // single-file cap (ENFORCED)
    #[serde(default)] pub max_patch_items: Option<usize>,   // RESERVED (Stage 4-6)
    #[serde(default)] pub max_delete_count: Option<usize>,  // RESERVED (Stage 5-6)
    #[serde(default)] pub owned_paths: Vec<String>,         // RESERVED (Stage 6, off by default)
    #[serde(default)] pub owned_services: Vec<String>,      // RESERVED (Stage 5-6)
    #[serde(default)] pub live_capture_scope: Option<Vec<String>>, // RESERVED (Stage 2 perf hatch, unused)
    #[serde(default = "default_unsupported")] pub unsupported_feature_behavior: String, // RESERVED (Stage 7)
    #[serde(default)] pub lease: Option<serde_json::Value>, // RESERVED (Stage 6)
}
```
- `load_policy(repo_root) -> Result<Option<Policy>>`: reads `<repo_root>/.studio-stud/policy.json`; `Ok(None)`
  if absent (callers fail closed ⇒ `noPolicy`); `Err` on malformed JSON or unsupported `version`.
- `Policy::validate()`: `version == 1`; every glob in `allowed_write_paths` + `require_generated_header_paths`
  compiles under `globset`; `max_patch_bytes > 0`. Returns a structured error list.
- `Policy::compiled() -> CompiledPolicy`: build `globset::GlobSet` for allow + header sets once (cache per
  load). Match against the **repo-relative, forward-slash-normalized** candidate path.

### 3.2 Write protocol shapes (Appendix C) — `write.rs`

- Routes (HTTP): `POST /studio-stud/write/{validate|preview|apply}`; handshake `GET /studio-stud/write/token`.
- Request (JSON): `{ token?, path, content, expectedHash?, generatedBy?, placeId? }`
  - `token`: HTTP only. May be supplied as the `X-StudioStud-Token` **header** (preferred) OR this body
    field; the header takes precedence (§3.6). The CLI supplies neither (decision 7).
  - `path`: repo-relative (forward or backslash; normalized to `/`). Absolute / drive-relative / rooted /
    `..`-traversal / escaping paths ⇒ `pathNotAllowed` (Windows rules in §3.8).
  - `content`: finished file text (UTF-8 string from JSON; bytes from `--content-file` on the CLI).
  - `expectedHash`: optional CAS — sha256 hex of the file's CURRENT **normalized** bytes the client based its
    edit on. If present and `!= hashBefore` ⇒ `hashMismatch` (apply only).
  - `generatedBy`: free-form provenance string, echoed in the response, not load-bearing.
  - `placeId`: optional, **client-supplied this stage** (no live-place source until a consumer exists); if
    present AND `allowed_place_ids` non-empty AND not contained ⇒ `placeMismatch`. Absent ⇒ no place gate.
- **Response (JSON, stable fields):** `{ ok, blocked, blockedReason?, detail?, changed, diff, bytes,
  hashBefore, hashAfter, generatedBy?, path }`.
  - **`ok`/`blocked` contract (review MINOR-fix — make it consistent):** a successful, non-blocked op is
    `{ ok:true, blocked:false }`; **every** block (token, policy, validation, internal) is
    `{ ok:false, blocked:true, blockedReason, detail? }`. No `ok:true, blocked:true` asymmetry. This extends
    Appendix C (which has no `blocked` field) with a redundant convenience bool; a block staying `ok:false`
    matches Appendix C's `blockedReason?` and the daemon's `ok:false == not-success` convention. `blocked` is
    purely a fast boolean for AI/plugin consumers.
  - `validate`: runs all gates, NO diff/write ⇒ `{ ok, blocked, blockedReason?, path }`.
  - `preview`: gates + diff vs current file ⇒ adds `changed, diff, bytes, hashBefore, hashAfter`. NO write.
  - `apply`: gates + CAS + atomic write ⇒ same fields; physically writes iff `changed` (= raw on-disk bytes
    differ from normalized proposed bytes, decision 3); no-op skips the write + preserves mtime. `bytes` =
    byte length of the normalized content.
- **HTTP status mapping (write routes only; review MAJOR-fix — the generic `ok:false→404` mapper does NOT
  do this):** the write route handler's status is determined by an explicit branch added BEFORE the generic
  `ok:false→404` rule, keyed on `blockedReason` (NOT on `error`, so it does not "mirror" the 426 branch which
  keys on `error`):
  - `blockedReason == "tokenInvalid"` ⇒ **401**.
  - `blockedReason == "badRequest"` (malformed JSON / missing required field) ⇒ **400** (today malformed JSON
    is an `Err`⇒503; this must be caught and mapped explicitly).
  - any other `blockedReason` (policy/validation/internal blocks, incl. `internalError`) ⇒ **200** with the
    structured `{ ok:false, blocked:true, blockedReason }` body (reachable + parseable; distinct from a true
    framework 503). `HttpService:RequestAsync` and `daemon_json` both decode the JSON body on non-2xx too, so
    401/400 bodies remain parseable.
  - no `blockedReason` ⇒ existing logic (426 marker, else `ok:false→404`, else 200).
- **Block reasons** (Appendix C set + fail-closed additions, decisions 1/3/7):
  `tokenInvalid` (401), `badRequest` (400), `noPolicy`, `pathNotAllowed` (traversal/escape + not-in-allowlist),
  `placeMismatch`, `invalidUtf8`, `oversize`, `headerMissing`, `parseError`, `hashMismatch`, `internalError`.
- **Deterministic gate ORDER (first failure wins; document in code; UTF-8 precedes size — review MAJOR-fix
  since `normalize_newlines` requires a valid UTF-8 string):**
  1. `tokenInvalid` — HTTP only, in `http.rs` before calling the toolkit (CLI skips, decision 7).
  2. `badRequest` — HTTP only: malformed JSON body or missing `path`/`content`.
  3. `noPolicy` — no policy file (after repo-root resolution; resolution failure ⇒ `internalError`).
  4. `pathNotAllowed` — `/`-normalize; reject `..`/absolute/drive-relative/rooted (§3.8); canonicalize parent
     and assert within the canonical repo root (canonicalize failure ⇒ block, NOT 503 — decision 1); then
     require a glob match in `allowed_write_paths`.
  5. `placeMismatch` — if `placeId` given and not in a non-empty `allowed_place_ids`.
  6. `invalidUtf8` — content bytes are not valid UTF-8 (guards the CLI `--content-file` byte path; an HTTP
     JSON string is already UTF-8). Must run BEFORE any newline-normalization.
  7. `oversize` — normalized content byte length `> max_patch_bytes`.
  8. `headerMissing` — path matches `require_generated_header_paths` but the normalized content lacks the
     marker in its first 3 lines (§3.5).
  9. `parseError` — path ends `.luau`/`.lua` and `full-moon` fails to parse the normalized content (§3.4).
  - Then (preview/apply): compute `hashBefore` (normalized current file, or `""` if absent), normalized
    proposed bytes, `hashAfter` (normalized proposed), and `changed = raw_on_disk_bytes !=
    normalized_proposed_bytes` (decision 3). Apply only: `hashMismatch` if `expectedHash` present and
    `!= hashBefore`, else atomic-write the normalized bytes iff `changed`.

### 3.3 The reusable write-safety toolkit (`write::safety`, decision 5)

Policy-free, HTTP-free, crate-public so Stages 4-5 call it directly:
- `normalize_newlines(&str) -> String` — CRLF/CR → LF.
- `sha256_hex(&[u8]) -> String` — `sha2::Sha256` + `hex_bytes` (reuse util).
- `unified_diff(old: &str, new: &str, path: &str) -> String` — `similar::TextDiff::from_lines` →
  `.unified_diff().context_radius(3).header(&old_label, &new_label)`. Deterministic. Empty string when equal.
- `atomic_write(abs_path: &Path, bytes: &[u8]) -> Result<()>` — temp file in the SAME dir as the target
  (same filesystem ⇒ atomic rename, no cross-device issue), write, flush, `fs::rename`; remove temp on error.
  **Temp name (review MINOR):** `<file_name>.<pid>-<nanos>-<counter>.tmp` (process id + monotonic nanos + a
  per-process atomic counter) to avoid same-millisecond collisions without needing a random crate; append the
  full target file name (not `with_extension`, which would clobber `.luau`). Fresh impl — do NOT reuse
  `atomic_write_json`'s `with_extension` pattern.
- `parse_luau(source: &str) -> Result<(), String>` — `full_moon::parse(source)` (luau feature). On error
  return a COMPACT single-line message (first error's message + position), never the whole error dump.

### 3.4 `full-moon` (D5) — Luau parse safety net

- Add `full-moon = { version = "<latest>", features = ["luau"] }` (confirm exact latest via `cargo add
  full-moon --features luau`). The **`luau` feature is mandatory**: without it, valid Luau (type annotations
  `local x: number`, `--!strict`, compound assignment, `continue`, string interpolation) fails to parse and
  every real repo file would false-positive `parseError`. Add a unit test that parses a `--!strict`
  type-annotated snippet to lock the feature in.
- Only `.luau`/`.lua` paths are parse-checked; other extensions skip the parse gate (still allowlist/size/
  header gated). The parse check NEVER executes code — it only confirms syntax.

### 3.5 Generated-header marker (`requireGeneratedHeader`, §5.3)

- Constant `AUTO_GENERATED_MARKER = "-- AUTO-GENERATED"`. A path matching `require_generated_header_paths`
  must contain a line whose trimmed text STARTS WITH the marker within the first 3 lines of the normalized
  content; else `headerMissing`. (This is the generic guard that a hand-edit didn't replace a generated file
  with un-marked content; the boat config in Stage 8 will carry this header.)

### 3.6 Token + handshake (D3, Appendix H) — `http.rs` + storage

- **Entropy (review BLOCKER-fix):** `uuid = "1.23.2"` is currently a featureless, unused dep — `Uuid::new_v4`
  WILL NOT COMPILE without `features = ["v4"]` (which pulls `getrandom`), and there is no `rand`/`getrandom`
  direct dep for the "32 hex" fallback. So Workstream A1 MUST add `uuid = { version = "1.23.2", features =
  ["v4"] }` (explicit, do not rely on transitive feature unification). The token is then
  `Uuid::new_v4().to_string()` (hyphenated).
- Daemon generates the token ONCE at `cmd_serve` startup; persist to `<storage.root>/write.token` (default
  `%LOCALAPPDATA%/StudioStud/write.token`) via the toolkit's `atomic_write`; reuse an existing token file if
  present and non-empty (stable across restarts so the plugin's cached token keeps working). Hold the token in
  a `ServeConfig` (see Workstream D1) passed into `handle_daemon_request`.
- `GET /studio-stud/write/token` ⇒ `{ ok:true, token }` (localhost, unauthenticated — it ISSUES the token;
  Appendix H honesty note: protection is allowlist/policy/hash, not the token).
- **Token transport — accept BOTH header and body, header precedence (review MAJOR-fix; Appendix C puts it in
  the body, Workstream E uses a header — the daemon must accept either or the plugin's authed request always
  401s):** `/write/{validate,preview,apply}` read the token from the `X-StudioStud-Token` header first, else
  the body `token` field. Compare to the daemon token; missing/mismatch ⇒ `{ ok:false, blocked:true,
  blockedReason:"tokenInvalid" }`.
- **401 mapping (review MAJOR-fix):** the existing 426 branch keys on the `error` field, so a payload carrying
  `blockedReason` (not `error`) would fall through to `ok:false→404`. The write-route status branch (added in
  §3.2 / Workstream D2) therefore keys on `blockedReason == "tokenInvalid"` ⇒ 401, placed BEFORE the generic
  `ok:false→404` rule. Likewise malformed JSON must be caught and mapped to `badRequest` ⇒ 400 (today it is an
  `Err`⇒503).

### 3.7 Repo-root resolution

The daemon + write CLI must resolve the repo root to (a) find `.studio-stud/policy.json` and (b) resolve
`allowed_write_paths` to absolute targets. Resolution order (provide `--repo-root` override for tests):
1. Explicit `--repo-root`.
2. Nearest ancestor of cwd containing `.studio-stud/policy.json`.
3. Nearest ancestor of cwd containing `default.project.json` (repo root per repo-navigation rule) or `.git`.
4. Resolution failure ⇒ `internalError` block (writes fail closed); never write.
Store the resolved repo root in `ServeConfig` for the daemon; pass per-command for the CLI. `--repo-root` is
the deterministic override every test uses (avoids a stray nested `.studio-stud/policy.json` selecting a wrong
root; canonicalize-within-root then still prevents escape from whatever root is chosen).

### 3.8 Path-safety rules (Windows-correct — review MINOR-fix)

`Path::is_absolute()` is **false** on Windows for drive-relative `C:foo` and root-relative `\foo` / `/foo`,
and `PathBuf::join` with a drive-prefixed or rooted component silently REPLACES part of the base — so an
"is_absolute" pre-check alone is not sufficient. The canonicalize-parent backstop does the real work. Exact
algorithm for `pathNotAllowed`:
1. Reject empty, then `/`-normalize the input (`\` → `/`).
2. Reject if any segment is `..` or `.`; reject if the path is absolute OR drive-relative (`^[A-Za-z]:`) OR
   rooted (`^[\\/]`) OR a verbatim/UNC prefix (`\\?\`, `\\`). (String-level checks, before any join.)
3. `abs = repo_root.join(rel)`. Canonicalize `abs.parent()` (the file itself may not exist yet) AND the repo
   root; assert the canonical parent is inside the canonical repo root. **Any canonicalize failure ⇒ block**
   (`internalError`/`pathNotAllowed`), never `?`→503 (decision 1). Canonicalizing both sides collapses
   symlinks, `\\?\` verbatim, and Windows case-insensitivity so the containment check is robust.
4. **Not-yet-existing parent dir:** if `abs.parent()` does not exist, BLOCK this stage (we do not create
   nested dirs). Documented latent limitation: Stage 5/8 that needs nested creation must create the dir
   *before* canonicalize without reopening a traversal window (handle there, not here).
Only after path safety passes do we glob-match against `allowed_write_paths` (on the `/`-normalized rel path).

---

## 4. Workstream breakdown (dependency order)

Build + `cargo test` + `cargo clippy` green after each. Commit per workstream. Daemon-first; the (required,
decision 10) minimal plugin handshake is last and isolated.

### Workstream A — Dependencies + write-safety toolkit (`write::safety`)
A1. `Cargo.toml`: add `full-moon` (features `["luau"]`), `similar`, `globset`; **add `["v4"]` to the existing
   `uuid`** (BLOCKER fix — `Uuid::new_v4` needs it). Pin to latest resolved versions via `cargo add`; make
   "`full_moon::parse` compiles + parses `--!strict` typed Luau" an EXIT-A gate, not advisory (confirm the
   exact `parse` signature/return for the pinned version — `parse(&str) -> Result<Ast, Vec<full_moon::Error>>`
   vs a `parse_fallible` variant). Add `.gitattributes` (`*.luau text eol=lf`; `tests/fixtures/write/** -text`)
   so EOL normalization survives checkout (decision 3).
A2. Create `tools/studio_stud/src/write.rs`; `pub mod write;` in `lib.rs`. Add the `safety` submodule (or
   keep flat with clearly-named fns): `normalize_newlines`, `sha256_hex` (copy `capture.rs`'s `Sha256` +
   `hex_bytes` pattern), `unified_diff`, `atomic_write` (fresh impl, §3.3), `parse_luau` (§3.3-3.4). **Delete
   the dead, no-caller `storage.rs::atomic_write_json`** (do NOT generalize its `with_extension` temp naming).
A3. Unit tests in `write.rs`:
   - `normalize_newlines`: CRLF + lone CR → LF; idempotent.
   - `sha256_hex`: known vector; equal for equal normalized inputs.
   - `unified_diff`: equal inputs → empty; a one-line change → stable hunk (golden-able); deterministic
     across runs.
   - `atomic_write`: writes bytes; overwrites atomically; **no temp left on success**; simulated failure
     leaves original intact + no temp (e.g. write to a dir path).
   - `parse_luau`: a `--!strict` type-annotated + string-interpolation snippet PARSES (locks the luau
     feature); a clearly malformed snippet returns a compact error.

**Exit A:** toolkit compiles, unit tests green, no policy/HTTP dependency in the toolkit; deps resolve.

### Workstream B — Policy layer (`policy.rs`) + `policy` CLI
B1. Create `tools/studio_stud/src/policy.rs`; `pub mod policy;` in `lib.rs`. Implement `Policy` (§3.1),
   `load_policy`, `Policy::validate`, `Policy::compiled` (globset), `repo_root` resolution (§3.7), and
   `Policy::check_path(rel_path, content, place_id) -> Option<BlockedReason>` implementing gates 4-9 of §3.2
   (the path/place/UTF-8/size/header/parse gates, given content) — reused by both CLI and HTTP. (Gates 1-2 are
   HTTP-only; gate 3 `noPolicy` is handled by `load_policy` returning `None`.)
B2. CLI subcommands (NOT hidden — these are user-facing per §5.3/Appendix B):
   - `studio-stud policy init [--repo-root <p>] [--force]` — write a default `.studio-stud/policy.json` if
     absent (refuse overwrite without `--force`). Default: `version:1`, `allowedPlaceIds:[100000000000001,
     100000000000003]` (Example Place A, Example Place B — from the studio-stud rule), a MINIMAL `allowedWritePaths`
     (least privilege — Stage 5/8 broaden it; see Workstream F), `maxPatchBytes:1048576`, the reserved fields
     at safe defaults. Output `{ ok, path, created }`.
   - `studio-stud policy check [--repo-root <p>]` — load + `validate`; print `{ ok, valid, errors:[...],
     path }`; **nonzero exit** if invalid/missing (CI gate).
   - `studio-stud policy explain --path <rel> [--place <id>] [--repo-root <p>]` — read-only "would a write to
     `<path>` be allowed and why": report `{ path, allowed, matchedAllowGlob?, headerRequired, sizeCap,
     placeAllowed, reason? }`. The AI/human pre-flight surface (§5.7). No content needed (header/parse gates
     noted as "checked at write time").
   - Add a `Commands::Policy { #[command(subcommand)] action: PolicyAction, ... }` enum + dispatch arm.
B3. Unit + CLI tests:
   - `policy.rs` units: parse a full Appendix-B-shaped policy; reject `version:2`; reject a bad glob; default
     fields fill; `check_path` returns the right `BlockedReason` for: not-allowlisted, traversal (`../x`),
     absolute path, oversize, header-missing, malformed-luau, and `None` for a clean allowlisted path.
   - CLI: `policy init` into a temp repo-root creates a file that `policy check` accepts; `policy check` on a
     malformed file exits nonzero; `policy explain` returns `allowed:true` for an allowlisted path and
     `allowed:false` + reason for a forbidden one.

**Exit B:** policy load/validate/check_path correct; `policy init|check|explain` work against `--repo-root`;
fail-closed on missing/invalid policy.

### Workstream C — Write file primitive (`write::file`) + hidden CLI + permanent fixture/golden test
C1. `write.rs`: implement `validate(repo_root, policy, req, mode) -> WriteOutcome` (§3.2) composing
   `policy::check_path` (gates) + the toolkit (normalize/hash/diff/atomic). Modes: `Validate|Preview|Apply`.
   Path safety per §3.8 (the Windows-correct algorithm; canonicalize failure ⇒ block, never `?`→503 per
   decision 1). Apply: `hashMismatch` CAS, then `atomic_write` (normalized bytes) iff `changed`
   (`changed = raw_on_disk != normalized_proposed`, decision 3). All internal errors caught → `internalError`
   block; the gate functions never return `anyhow::Err` to the caller.
C2. Hidden CLI (`hide = true`, decision 9), driving `write::file` directly (NO token):
   - `write-validate --repo-root <p> --path <rel> --content-file <f> [--place <id>]`
   - `write-preview  --repo-root <p> --path <rel> --content-file <f>`
   - `write-apply    --repo-root <p> --path <rel> --content-file <f> [--expected-hash <h>] [--generated-by <s>]`
   Each prints the `WriteOutcome` JSON; a block ⇒ print JSON + **exit nonzero** (per §5.3 "risky ops ⇒
   nonzero exit + structured reason"). Content read from a file so byte-exact/large/non-UTF8 inputs are
   testable.
C3. **PERMANENT fixture + golden/integration test (§7/§11) — `tests/write_safety.rs` + `tests/fixtures/write/`:**
   Fixtures (committed, reviewable, NO game content). **Newline-variant inputs are written PROGRAMMATICALLY by
   the test (review MAJOR-fix), NOT committed** — with `tests/fixtures/write/** -text` in `.gitattributes` and
   the bytes authored in-test, EOLs are deterministic regardless of `core.autocrlf`. Committed fixtures:
   - `policy.json` — allows `synced/**/*.luau`, requires the header on `generated/*.luau`, `maxPatchBytes`
     small enough to trigger oversize with a big input.
   - `target_clean.luau` — a valid `--!strict` Luau body (round-trip target content; `-text` so it stays LF).
   - `target_malformed.luau` — syntactically broken Luau (drives `parseError`).
   - `target_generated_with_header.luau` / `target_generated_no_header.luau` (drive header gate).
   - `golden/write_apply_outcome.txt`, `golden/write_preview_diff.txt` — normalized expected outcomes/diff.
   The test builds a TEMP repo-root (copy `policy.json` to `<tmp>/.studio-stud/policy.json`), then asserts:
   - **Happy path:** `write-apply` an allowlisted `synced/foo.luau` ⇒ `ok:true, blocked:false, changed:true`;
     file bytes == normalized content (golden); `hashAfter` correct. Second identical apply ⇒ `changed:false`,
     file mtime unchanged (true no-op skip).
   - **CRLF→LF determinism (review MAJOR — the test that fails today):** pre-seed the target on disk with
     CRLF bytes whose NORMALIZED content equals the proposed content; apply ⇒ `hashBefore == hashAfter` BUT
     `changed:true`, and the on-disk bytes become LF (byte-identical to the normalized content).
   - **Determinism:** two applies of the same content to a fresh temp ⇒ byte-identical files + identical
     `hashAfter`.
   - **Preview no-write:** `write-preview` returns a stable unified diff (golden) and does NOT create/modify
     the file.
   - **Allowlist:** apply to `forbidden/bar.luau` ⇒ `pathNotAllowed`, nonzero exit, no file written.
   - **Windows traversal matrix (review):** `..\escape.luau`, an absolute path, drive-relative `C:foo.luau`,
     rooted `\foo.luau`, `\\?\C:\x.luau`, a UNC path, and (where constructible) a symlinked parent ⇒ each
     `pathNotAllowed`/block, nothing written outside the temp root.
   - **Oversize:** content > `maxPatchBytes` ⇒ `oversize`.
   - **Header:** generated path without the marker ⇒ `headerMissing`; with the marker ⇒ allowed.
   - **Parse:** `target_malformed.luau` to an allowlisted `.luau` path ⇒ `parseError`, nothing written.
   - **CAS:** `write-apply --expected-hash <wrong>` ⇒ `hashMismatch`, file untouched; with the correct
     `hashBefore` ⇒ applies.
   - **No-policy:** temp root with NO `.studio-stud/policy.json` ⇒ `noPolicy`, nothing written.
   - **Internal-error block (review MAJOR):** make `policy.json` unreadable / an `allowed_write_paths` glob
     invalid ⇒ structured `internalError` block + nonzero CLI exit (NEVER an unstructured 503/panic).
   - **Atomic failure:** (best-effort) a write whose rename target is unwritable leaves the original intact
     and no `*.tmp` behind.

**Exit C:** `write::file` validate/preview/apply correct; every block reason proven; permanent fixture/golden
test green; the toolkit + policy compose end-to-end with NO Studio and NO daemon.

### Workstream D — HTTP wiring + token (daemon)
D1. `http.rs`: introduce a small `ServeConfig { storage_root: Option<PathBuf>, project_key: String,
   repo_root: Option<PathBuf>, write_token: String }` (or extend the existing param list minimally) threaded
   from `cmd_serve` into `handle_daemon_request`. Generate/persist the token in `cmd_serve` (§3.6).
D2. Add routes (keep ALL existing routes/aliases + 404 unchanged):
   - `GET /studio-stud/write/token` ⇒ `{ ok, token }`.
   - `POST /studio-stud/write/{validate,preview,apply}`: read the token (header `X-StudioStud-Token` first,
     else body `token`; §3.6), parse JSON (malformed ⇒ `badRequest`), `load_policy(repo_root)` (fail-closed
     `noPolicy`; resolution error ⇒ `internalError`), call `write::file::validate(..., mode)`, return the
     `WriteOutcome`. Every block is `{ ok:false, blocked:true, blockedReason }` (§3.2). **Status mapper
     (review MAJOR — it must NOT mirror the 426 branch, which keys on `error`; key on `blockedReason`):** add
     a write-route branch BEFORE the generic `ok:false→404`: `blockedReason=="tokenInvalid"`→401,
     `blockedReason=="badRequest"`→400, any other `blockedReason` (policy/validation/`internalError`)→200
     (structured + reachable), else fall through to existing logic. Reserve a true `Err`→503 for framework
     failures only.
D3. `cli.rs::cmd_serve`: resolve repo root (§3.7) + token, build `ServeConfig`, pass through. Print the
   resolved repo root + "write token issued" (NOT the token value) on startup.
D4. HTTP smoke tests (`tests/write_http.rs` or extend `write_safety.rs`): start `serve` on an ephemeral port
   (reuse Stage-2-style serve-smoke if present, else `Command` + a chosen free port), then:
   - `GET /write/token` returns a token; **token matrix** on `POST /write/validate` with an allowlisted path:
     header-only ⇒ 200 `blocked:false`; body-only ⇒ 200 (body fallback); both ⇒ 200; neither ⇒ **401
     `tokenInvalid`**. Malformed JSON body ⇒ **400 `badRequest`** (not 503). A policy block (e.g. forbidden
     path) ⇒ **200** `{ok:false, blocked:true, blockedReason}`.
   - A capture round-trip (`/capture/*`) still ingests byte-identically AFTER the write routes are added
     (proves the additions didn't perturb capture). If the serve-smoke is flaky, keep HTTP coverage to the
     token matrix + status codes + route-reachability and rely on Workstream C for write correctness.

**Exit D:** write endpoints reachable; token issued + enforced (401 without it); policy fail-closed over HTTP;
capture/live/query routes + goldens unchanged.

### Workstream E — Plugin write-token handshake (MINIMAL, consumer-free; decision 10 — REQUIRED)
E1. `SETTINGS.writeToken = "StudioStudWriteToken"`. `Transport.fetchWriteToken()` — `GET /write/token`, cache
   via `Settings.setString`; called once on connect (alongside the existing ping). `Transport.requestJsonAuthed`
   — like `requestJson` but adds the `X-StudioStud-Token` header (the daemon reads this header first, §3.6),
   and on a 401 re-fetches the token once then retries before failing. This is the only Stage-3 write surface
   in the plugin; it must round-trip against the daemon's header-first token check (tested in D4 + the
   self-test).
E2. NO write UI, NO write calls this stage. Extend `_G.StudioStud.RunSelfTest` (Stage 1 §8) with a check that
   `fetchWriteToken` caches a non-empty token and `requestJsonAuthed` attaches the header (mock/inspect the
   request table). Re-check Luau register pressure (`.cursor/rules/luau-files.mdc`) after editing the large
   plugin file.

**Exit E:** plugin caches the write token and can issue an authed request; self-test PASS; no UI/consumer; no
register-pressure or connection regressions.

### Workstream F — Repo policy file + docs + rule update
F1. Run `studio-stud policy init` at the ExampleProject repo root and COMMIT the resulting `.studio-stud/
   policy.json` (decision 6). Keep `allowedWritePaths` MINIMAL (least privilege) — broadened in Stage 5
   (synced Luau globs) and Stage 8 (`src/Shared/Constants/BoatAuthoringConfig.luau` +
   `requireGeneratedHeaderPaths`). Confirm `policy check` passes (a CI gate from now on).
F2. `docs/studio-stud.md`: add a "Write protocol" section — the `/write/*` endpoints + token handshake, the
   policy file + `policy init|check|explain`, the block-reason table, the determinism/atomicity contract, and
   the honesty note that the token is convenience (real protection = allowlist/policy/hash). Note there is NO
   write consumer yet (Stage 8 boat / Stage 5 sync are the consumers).
F3. `.cursor/rules/studio-stud.mdc`: add the `policy` subcommands + a one-line note that `/write/*` is
   token-gated and policy-allowlisted (so the AI uses `policy explain` before assuming a write is possible).
   `docs/repo-map.md` auto-regenerates via the hook (run `/repo-map` if `write.rs`/`policy.rs` aren't picked
   up).

**Exit F:** committed minimal `.studio-stud/policy.json` that `policy check` accepts; docs + rule updated;
repo map current.

---

## 5. Execution order (for Composer)
1. Workstream A (deps + toolkit — foundation Stages 4-5 also need).
2. Workstream B (policy layer + `policy` CLI).
3. Workstream C (write file primitive + hidden CLI + PERMANENT fixture/golden test — the anti-bit-rot proof).
4. Workstream D (HTTP wiring + token + 401 enforcement + capture regression).
5. Workstream E (minimal plugin handshake — REQUIRED).
6. Workstream F (committed repo policy + docs + rule).
7. Final verification (§7/§8).

Commit per workstream. After each daemon workstream: `pwsh tools/studio_stud/build-local.ps1` + `cargo test`
+ `cargo clippy --all-targets` clean. After the plugin workstream: load in Studio, no Output errors,
`RunSelfTest` PASS.

---

## 6. Resolved sub-decisions (locked — no confirmation needed)
All previously-open sub-decisions are RESOLVED in §0 (decisions 10-12); recorded here for traceability:
- **Plugin handshake: include the minimal daemon+plugin handshake NOW** (decision 10). Workstream E is
  required. Rationale: D3 deliverable, cheap + self-testable, and Stage 6 authed writes reuse it.
- **`policy explain`: content-independent pre-flight** (decision 11). Reports path/place/size/glob +
  `headerRequired`; header-presence + Luau parse + CAS are noted as enforced at write time. `explain` does
  not take content.
- **Unified diff: `similar`, line-based, `context_radius(3)`** (decision 12).

---

## 7. Test contract (what proves the stage)
- **Determinism:** same `(path, content)` ⇒ byte-identical file + identical `hashAfter` (golden +
  two-run assertion); a pre-existing CRLF file is rewritten to LF (`hashBefore==hashAfter`, `changed:true`,
  on-disk bytes become LF — the case the no-op-on-raw-bytes fix makes pass).
- **Atomicity / no data loss:** failed write leaves the original intact, no `*.tmp` left; no-op apply does not
  rewrite (mtime preserved).
- **Fail-closed allowlist + caps:** every block reason (`noPolicy`, `pathNotAllowed` incl. the Windows
  traversal matrix, `placeMismatch`, `invalidUtf8`, `oversize`, `headerMissing`, `parseError`, `hashMismatch`,
  `internalError`, HTTP-only `tokenInvalid`/`badRequest`) is exercised and writes nothing; CLI exits nonzero
  on block; an internal error (unreadable policy / bad glob) becomes a structured `internalError` block, never
  a 503/panic.
- **Luau parse net:** valid `--!strict` typed Luau parses (luau feature locked — an EXIT-A compile+parse
  gate); malformed Luau ⇒ `parseError`.
- **Token transport:** header-only, body-only, both, and neither → resolve to 200/401 per the header-first
  contract (§3.6).
- **Toolkit reusability:** `write::safety` unit-tested in isolation with no policy/HTTP.
- **Isolation:** capture/live/query goldens + live-convergence suite stay byte-identical; HTTP capture
  round-trip regression green after route additions.
- **Anti-bit-rot:** `tests/write_safety.rs` + `tests/fixtures/write/*` + `tests/golden/write_*` are permanent
  and run in `cargo test` from Stage 3 onward (the design's explicit requirement so the early-built endpoint
  cannot rot before its Stage 5/8 consumers arrive).

---

## 8. Tests Tyler runs (single-person, required for exit)

### 8.1 Automated (from `tools/studio_stud/`)
```powershell
pwsh tools/studio_stud/build-local.ps1     # clean build → bin/studio-stud.exe
cargo test                                  # all unit + golden + live + write tests green
cargo clippy --all-targets                  # no new warnings
```
Must be green, in particular: `write_safety` (all block reasons incl. `internalError` + the Windows traversal
matrix + CRLF→LF determinism + atomicity + CAS), `write.rs`/`policy.rs` units, the luau-feature compile+parse
gate, the HTTP token matrix (header/body/both/neither → 200/401) + `badRequest`→400 + capture regression, and
the UNCHANGED `golden_outputs` + `live_convergence` suites.

### 8.2 CLI smoke (no Studio, no daemon)
```powershell
# policy lifecycle
.\bin\studio-stud.exe policy init  --repo-root .tmp/repo
.\bin\studio-stud.exe policy check --repo-root .tmp/repo                      # ok:true, exit 0
.\bin\studio-stud.exe policy explain --path synced/foo.luau --repo-root .tmp/repo    # allowed:true
.\bin\studio-stud.exe policy explain --path secrets/x.luau  --repo-root .tmp/repo    # allowed:false + reason
# write lifecycle (hidden subcommands)
.\bin\studio-stud.exe write-validate --repo-root .tmp/repo --path synced/foo.luau --content-file good.luau
.\bin\studio-stud.exe write-preview  --repo-root .tmp/repo --path synced/foo.luau --content-file good.luau   # diff, no write
.\bin\studio-stud.exe write-apply    --repo-root .tmp/repo --path synced/foo.luau --content-file good.luau   # changed:true
.\bin\studio-stud.exe write-apply    --repo-root .tmp/repo --path synced/foo.luau --content-file good.luau   # changed:false (no-op)
.\bin\studio-stud.exe write-apply    --repo-root .tmp/repo --path ../escape.luau  --content-file good.luau   # pathNotAllowed, exit≠0
.\bin\studio-stud.exe write-apply    --repo-root .tmp/repo --path synced/bad.luau --content-file malformed.luau  # parseError, exit≠0
```

### 8.3 Daemon HTTP smoke (token)
```powershell
# in one terminal:  .\bin\studio-stud.exe serve --repo-root <repo>
curl http://127.0.0.1:31878/studio-stud/write/token                          # { ok, token }
# POST /write/validate with header  X-StudioStud-Token: <token> + allowlisted path → ok:true, blocked:false
# POST /write/validate with body    {"token":"<token>", ...}                       → ok:true (body fallback)
# POST /write/apply    with NO token (neither header nor body)                     → HTTP 401 tokenInvalid
# POST /write/apply    with malformed JSON body                                    → HTTP 400 badRequest
```

### 8.4 Plugin self-test (required)
`_G.StudioStud.RunSelfTest()` ⇒ PASS, including: `fetchWriteToken` caches a non-empty token;
`requestJsonAuthed` attaches the token header; state fully restored; no Output errors.

---

## 9. Exit gate checklist (all must be true)
- [ ] **Generic only:** no game/boat term in `policy.rs`/`write.rs`/`http.rs` write routes; write primitive is
      `{path, content}` in, structured result out (Option A).
- [ ] **Toolkit shipped + reusable:** `write::safety` (`normalize_newlines`, `sha256_hex`, `unified_diff`,
      `atomic_write`, `parse_luau`) is policy/HTTP-free and unit-tested; the dead `storage.rs::atomic_write_json`
      is deleted and replaced by a fresh `atomic_write` (§3.3).
- [ ] **full-moon (luau feature) parse gate:** `uuid` gains `["v4"]`; `full_moon::parse` compiles + parses
      `--!strict` typed Luau (EXIT-A gate, not advisory); malformed ⇒ `parseError`; a unit test locks the
      feature; `.gitattributes` added (`*.luau text eol=lf`, `tests/fixtures/write/** -text`).
- [ ] **Policy layer:** `.studio-stud/policy.json` loader + `validate` + globset allowlist + `check_path`;
      `policy init|check|explain` work; fail-closed on missing/invalid (`noPolicy`, nonzero exit).
- [ ] **Write endpoints:** `/studio-stud/write/{validate,preview,apply}` + `GET /write/token`; validate=no
      write, preview=diff-only, apply=atomic; every block is `{ok:false, blocked:true, blockedReason}`; CLI
      blocks exit nonzero; HTTP policy/internal-block=200, token-fail=401, malformed body=400 (NOT 503);
      internal errors → structured `internalError` block, never `?`→503; gate order has UTF-8 before size.
- [ ] **Token transport:** daemon accepts `X-StudioStud-Token` header (precedence) AND body `token`; the
      header/body/both/neither matrix resolves correctly; the 401 mapper branch keys on
      `blockedReason=="tokenInvalid"` BEFORE the generic `ok:false→404`.
- [ ] **Determinism + atomicity:** same input ⇒ byte-identical file (golden); write decision on raw-vs-
      normalized so a CRLF file is rewritten to LF; no-op apply (raw==normalized) doesn't rewrite (mtime kept);
      failed write leaves original intact + no temp; CAS (`expectedHash`, normalized) blocks a stale overwrite.
- [ ] **Path safety (Windows):** `..`/absolute/drive-relative/rooted/verbatim/UNC rejected; canonicalize both
      parent + repo root and assert containment; canonicalize failure / non-existent parent ⇒ block; traversal
      matrix test green.
- [ ] **Token:** auto-issued at `serve`, persisted under storage root (NEVER in repo), required for HTTP
      writes only; CLI writes need no token; honesty note documented.
- [ ] **Permanent anti-bit-rot test:** `tests/write_safety.rs` + fixtures + goldens run in `cargo test` and
      cover the full lifecycle + every block reason; no boat code involved.
- [ ] **Isolation:** capture/live/query goldens + live-convergence suite byte-identical; capture HTTP
      round-trip regression green; existing routes/aliases/404 unchanged.
- [ ] **Committed minimal `.studio-stud/policy.json`** that `policy check` accepts (least privilege);
      `docs/studio-stud.md` + `.cursor/rules/studio-stud.mdc` updated; repo map current.
- [ ] **Plugin handshake (required):** caches the write token + authed request helper + self-test PASS; no
      write UI; no register/connection regressions.
- [ ] `cargo test` + `cargo clippy` green; `build-local.ps1` clean.
- [ ] No Stage 4+ surface introduced.

---

## 10. Risks & mitigations
- **full-moon feature/version/API drift (D5).** Wrong/missing `luau` feature ⇒ every real Luau file
  false-fails `parseError`; and `parse`'s signature/return differs across versions (`Result<Ast, Vec<Error>>`
  vs a `parse_fallible` variant). Mitigation: mandatory `luau` feature + an EXIT-A compile+parse gate on
  `--!strict` typed Luau that locks both the feature AND the confirmed `parse` API; pin the version via
  `cargo add`. Parse-check only `.luau`/`.lua`; never other extensions.
- **Glob semantics (`**`).** Hand-rolled or weak globbing mis-matches allowlist paths. Mitigation: use
  `globset` (ripgrep-grade `**`), normalize candidates to repo-relative forward-slash before matching, unit
  tests for `src/**/*.luau` vs `src/x.luau` vs `other/x.luau`.
- **Path traversal / escape (security, §9; Windows-specific — review MINOR).** A crafted `path` writing
  outside the repo would be catastrophic, and `Path::is_absolute()` misses drive-relative `C:foo` / rooted
  `\foo`. Mitigation: the §3.8 algorithm — `/`-normalize → reject `..`/`.`/absolute/drive-relative/rooted/
  verbatim/UNC string forms → canonicalize BOTH parent and repo root → assert containment → canonicalize
  failure or non-existent parent ⇒ block (never 503). Covered by the §8 Windows traversal-matrix test
  (`C:foo\x`, `\x`, `..\x`, `\\?\C:\x`, UNC, symlinked parent), not just `../escape`.
- **Non-atomic / partial writes (trust bar, §9).** Mitigation: temp-in-same-dir + `fs::rename`; remove temp on
  error; test that a failed write leaves the original intact and no temp behind; no-op skip avoids needless
  rewrites.
- **Determinism drift (CRLF, encoding) — and the no-op trap (review MAJOR).** Windows CRLF could make "same
  content" hash differently, AND a no-op skip computed over normalized bytes would leave a pre-existing CRLF
  file un-normalized on disk. Mitigation: `normalize_newlines` before hash/diff; hashes over normalized bytes;
  but the WRITE decision (`changed`) is raw-on-disk vs normalized-proposed so a CRLF file IS rewritten to LF;
  add `.gitattributes` so commits don't re-mangle EOLs; CRLF→LF apply test + two-run byte-identity test.
- **Token over an unauthenticated GET (§9/Appendix H).** Any local process can fetch it. Accepted by design:
  the token is convenience; real protection is allowlist + policy + place-id + (Stage 6) hash guard. Document
  the honesty note; never log/echo the token value.
- **Fail-open regressions / `?`→503 leak (review BLOCKER).** Idiomatic `?`/`anyhow` propagation would turn an
  internal error into HTTP 503 (or an unstructured nonzero CLI exit), bypassing the structured-block contract;
  a future refactor could also let an error path fall through to a write. Mitigation: gate fns return
  `Option<BlockedReason>`/`WriteOutcome` and convert internal errors to `internalError` (never bubble `Err`
  into the write step); the gate order is explicit + tested; negative tests assert NOTHING is written for
  every block reason (incl. the `internalError` unreadable-policy / bad-glob case); the default branch of any
  match returns a block.
- **Perturbing the capture/live path (isolation).** Mitigation: write additions are new modules + new routes;
  the existing 404 fallback + capture round-trip regression + UNCHANGED goldens guard against drift; no
  changes to `capture.rs`/`live.rs`/`query.rs`/`analyze.rs`/`storage.rs` schema.
- **Plugin register pressure (Workstream E, required).** Adding transport helpers to the large plugin file
  can hit the Luau 200-local limit. Mitigation: keep helpers inside the `Transport` table; re-check lints +
  register pressure after the edit (`.cursor/rules/luau-files.mdc`).
- **Scope creep into Stage 4-8.** Explicitly forbidden in §0: no repo index/projection/diff, no FS→Studio
  apply, no multi-op patch enforcement (`maxPatchItems`/`maxDeleteCount`/`ownedPaths`/`lease` parsed-only), no
  CAS/merge/`flctl`, no boat panel.

---

## 11. Out of scope (defer to later stages)
Repo index / `default.project.json` Rojo v7 parsing / `rbx-dom` / desired projection / read-only `project
diff` (Stage 4, reuses `write::safety`); file watcher → patch set, plugin apply endpoints (Folder/Script/
Source/Delete/Move), hash-guarded applies, per-file base ledger (Stage 5); multi-developer / Team Create
concurrency, continuous bidirectional mirror, in-plugin content CAS, deterministic 3-way merge, transient
claims, `flctl sync explain|status|resolve`, post-write convergence (Stage 6 + Final Verification); other file
types / `build` / `sourcemap` / controlled two-way reconcile (Stage 7); Boat Configurator panel + boat config
generation in Luau + the `BoatDatabase` merge contract + the Python-oracle generation parity golden tests
(Stage 8). Enforcement of `maxPatchItems`/`maxDeleteCount`/`ownedPaths`/`ownedServices`/`lease`/
`unsupportedFeatureBehavior` is deferred (Stages 4-7) — Stage 3 parses and stores them only.
