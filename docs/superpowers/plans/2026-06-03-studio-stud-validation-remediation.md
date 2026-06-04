# Studio Stud — Validation Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve the 15 findings from the 2026-06-03 in-Studio validation (dev v0.4.9), grouped into 6 verified root-cause clusters, so the dev Fishers Life place captures, streams live deltas (including deletes), updates, and re-baselines correctly on a trustworthy install.

**Architecture:** Three subsystems are touched — the Rust daemon/CLI (`studio-stud`), the Rust setup/installer crate (`studio-stud-setup`), and the Luau Studio plugin (`plugin/StudioStud.plugin.lua`). Work is sequenced so the two *prerequisite* clusters land first: **observability** (so the live-delta bug is diagnosable at all) and **install integrity** (so re-testing happens on a clean install). The remaining clusters — live deletes, capture/DB performance, config self-heal, and CLI papercuts — follow.

**Tech Stack:** Rust (edition 2024, workspace crates `.` and `setup`), clap 4.6 (derive), rusqlite 0.40 (bundled SQLite, WAL), serde/serde_json, chrono, tiny_http; Luau (Roblox Studio plugin); PowerShell 5.1 (install/launcher scripts).

**Source of findings:** `docs/validation-report-2026-06-03.md`. Every cluster below was root-caused against live source before this plan was written; where the report's *suspected* cause was refuted, the corrected cause is stated.

---

## Cluster → Finding → Phase map

| Cluster | Findings | Phase | Severity |
|---|---|---|---|
| E — Observability (keystone) | F-OBS | Phase 1 | P2 |
| A — Split-brain install | F-1, F-2, F-3 (partial) | Phase 2 | P1 |
| C — Deletes not live | F-I / Call-out 1 | Phase 3 | P2 |
| D — Capture/DB performance | F-H, F-J | Phase 4 | P2 |
| B — Config self-heal + channel | F-3, F-G / Call-out 2 | Phase 5 | P1/P2 |
| F — CLI papercuts | F-A, F-B, F-K, minor | Phase 6 | P3 |

**Out of scope (per maintainer decision):** Stage 7/8 atomic-write workflow (not built yet); the end-to-end "dev push → `updateAvailable:true`" round-trip (needs a real CI dev publish to verify).

---

## File Structure (what each task creates/modifies)

**New files**
- `src/obs.rs` — daemon observability module: timestamped event/timing logging to stderr + a rotating `logs/daemon.log` under the storage root; `--profile` timing spans. (Phase 1)
- `setup/src/legacy_cleanup.rs` — pure, unit-testable detection + removal of legacy installs (system32 shims/bundle, sibling-repo shims, duplicate binaries) with an elevation shim for system32. (Phase 2)
- `tests/policy_place_ids.rs` — integration test for string-or-int `allowedPlaceIds`. (Phase 6)

**Modified files**
- `src/lib.rs` — register `mod obs;`. (Phase 1)
- `src/cli.rs` — wire `obs` init into `serve`; add `--profile` flag; make top-level `--version` work (F-A). (Phase 1, 6)
- `src/http.rs` — instrument capture/complete + live delta with timing; make `/capture/complete` ack-then-finalize-async (F-H). (Phase 1, 4)
- `src/live.rs` — route the existing `revision_mismatch`/`delta applied` diagnostics through `obs`. (Phase 1)
- `src/util.rs` — add compaction/`auto_vacuum` PRAGMA on DB open (D). (Phase 4)
- `src/capture.rs` — stop double-storing properties and/or `VACUUM` after rebuild; incremental re-baseline guard (D). (Phase 4)
- `src/policy.rs` — canonicalize `--repo-root` against CWD (F-B); string-or-int `allowedPlaceIds` deserializer (F-K). (Phase 6)
- `scripts/launcher.ps1` — converge on the canonical `%LOCALAPPDATA%\Programs\StudioStud\bin\studio-stud.exe` daemon path (A). (Phase 2)
- `src/setup_core/install.rs` — install *primitives* in the main lib (`install_path_shim`, `migrate_legacy_repo`, `default_install_root`); keep idempotent (A). (Phase 2)
- `setup/src/install_flow.rs` — install/update *orchestration* in the setup crate (`run_install_headless`/`run_update_headless`); invoke legacy cleanup before laying the install (A). (Phase 2)
- `setup/src/update_apply.rs` — either true hot-swap re-exec or an honest "restart required" message (F-2). (Phase 2)
- `setup/src/main.rs` — `update --check` honors `version.json` channel + `--channel` override (F-G); add `cleanup-legacy`/`repair` subcommand (A). (Phase 2, 5)
- `src/setup_core/config.rs` — populate `installRoot`/`pluginsDir`/`channel`/`versions` on install; self-heal on serve start; reconcile with `version.json` (B). (Phase 5)
- `plugin/StudioStud.plugin.lua` — capture/complete timeout + the live-delete fix once diagnosed (C, D). (Phase 3, 4)

---

## Executor orientation (read first)

- **Tool-agnostic:** this plan is executable by any capable coding agent. If the `superpowers` plugin is available (e.g. Cursor with third-party skills enabled), the sub-skills in the header structure execution; if not, the per-task test→implement→verify→commit structure stands on its own.
- **Two-crate workspace** (`Cargo.toml` members `.` and `setup`). Know which crate you're in:
  - Main lib `studio_stud` (`src/…`): the daemon/CLI **and** the install *primitives* under `src/setup_core/` (`install.rs`, `config.rs`, `registry.rs`).
  - Setup binary `studio-stud-setup` (`setup/src/…`): the installer/updater *orchestration* (`install_flow.rs`, `update_apply.rs`, `main.rs`). The setup crate depends on the main lib, **not** vice-versa — so a main-lib file cannot call a setup-crate function. Place shared cleanup logic (Task 2.2) in the setup crate, where its callers are.
- **Line numbers are navigation hints, not contracts.** They were captured at planning time and may have drifted. Always locate the real edit site by *symbol name* (`git grep -n "fn run_install_headless"`), then apply the change.

## Conventions for this plan

- **Rust tasks are TDD:** write a failing `#[cfg(test)]` test (or a `tests/*.rs` integration test), run it red, implement, run it green, commit. Build the whole workspace with `cargo build` and run `cargo test` before each commit.
- **Luau plugin tasks have no in-repo test harness:** verification is the in-Studio repro from the runbook. Each such task states the exact repro and the expected observable result. Do NOT claim a plugin task is done without running the repro in Studio.
- **Installer/PowerShell tasks** are verified by `cargo test` on the pure Rust cleanup logic **plus** a manual check on the live (corrupted) test machine — the maintainer chose to use that machine as the cleanup test case.
- **Commit after every task.** Branch off `development` (current branch). Do not push or merge unless the maintainer asks.
- Run all `cargo` commands from the repo root `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud`.

---

# Phase 1 — Observability (Cluster E / F-OBS) — KEYSTONE

**Why first:** The daemon already logs the live-delta reject/apply decisions via `eprintln!` ([src/live.rs:124,149](../../../src/live.rs#L124)) but nothing surfaces them — no log file, no timing, only a startup banner ([src/cli.rs:791-801](../../../src/cli.rs#L791)). Phase 3 (the delete bug) is undiagnosable until this lands. This phase is also cheap and self-contained.

**Root cause (confirmed):** No logging crate in `Cargo.toml`; daemon emits only the banner + scattered `eprintln!`; no per-request/timing/error log and no log file in the storage root.

### Task 1.1: Create the `obs` logging module

**Files:**
- Create: `src/obs.rs`
- Modify: `src/lib.rs` (add `mod obs;` — match the existing `mod` declaration style/order)

Design: no new heavy dependency. Use the already-present `chrono` for timestamps and `std` for file append. Provide:
- `obs::init(storage_root: &std::path::Path, profile: bool)` — sets a global `OnceLock`-held config: the log file path `storage_root/logs/daemon.log` (create `logs/` if missing) and the `profile` flag.
- `obs::event(category: &str, msg: &str)` — writes one line `"<ISO8601> [<category>] <msg>"` to stderr **and** appends it to `daemon.log`. Append-open per call (simple, robust); rotate when the file exceeds 8 MB by renaming to `daemon.log.1`.
- `obs::span(category: &str, label: &str) -> Span` where `Span` records `Instant::now()` on create and, on `drop` (or explicit `.finish()`), emits `"<label> took <ms> ms"` via `event` **only when `profile` is true** (or always for category `"capture"`).

- [ ] **Step 1: Write the failing test** — append to `src/obs.rs` a `#[cfg(test)]` module:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn event_writes_line_to_log_file() {
        let dir = std::env::temp_dir().join(format!("ss_obs_test_{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        init(&dir, false);
        event("test", "hello world");
        let log = fs::read_to_string(dir.join("logs").join("daemon.log")).unwrap();
        assert!(log.contains("[test]"), "category missing: {log}");
        assert!(log.contains("hello world"), "message missing: {log}");
        let _ = fs::remove_dir_all(&dir);
    }
}
```

- [ ] **Step 2: Run the test, verify it fails to compile** — `obs` does not exist yet.

Run: `cargo test --lib obs::tests::event_writes_line_to_log_file`
Expected: FAIL — `cannot find module/function` (module not registered / `init`,`event` undefined).

- [ ] **Step 3: Implement `src/obs.rs`** — global config via `std::sync::OnceLock<ObsConfig>`; `event` formats `chrono::Utc::now().to_rfc3339()`, writes to stderr via `eprintln!`, and appends to the log file with `std::fs::OpenOptions::new().create(true).append(true)`. If `init` was never called, `event` still prints to stderr but skips the file (so non-serve commands are unaffected). Implement `span`/`Span` with `std::time::Instant`. Register the module in `src/lib.rs`.

- [ ] **Step 4: Run the test, verify it passes** — Run: `cargo test --lib obs::tests::event_writes_line_to_log_file`. Expected: PASS (1 passed).

- [ ] **Step 5: Build the workspace** — Run: `cargo build`. Expected: builds clean, zero warnings (the repo's standard).

- [ ] **Step 6: Commit**

```bash
git add src/obs.rs src/lib.rs
git commit -m "feat(obs): add daemon logging module (stderr + rotating daemon.log)"
```

### Task 1.2: Initialize `obs` in `serve` and add `--profile`

**Files:**
- Modify: `src/cli.rs` — the `Serve` subcommand definition and `cmd_serve` (banner area near [cli.rs:716-801](../../../src/cli.rs#L716))

- [ ] **Step 1: Add the flag** — in the `Serve { … }` variant of `enum Commands`, add `#[arg(long)] profile: bool,`. Thread it into `cmd_serve`.

- [ ] **Step 2: Initialize obs at serve startup** — immediately after `Storage` is constructed in `cmd_serve` (so `storage.root` is known), call `crate::obs::init(&storage.root, profile);` then replace the bare banner `println!`s with a paired `crate::obs::event("serve", &format!("Studio Stud v{} on http://{address}", env!("CARGO_PKG_VERSION")));` (keep the human-facing `println!` banner too — the log line is additive, the banner is the console UX).

- [ ] **Step 3: Instrument the request loop** — find the per-request handler dispatch in `cmd_serve`/`handle_daemon_request` and emit `crate::obs::event("http", &format!("{method} {path} -> {status} ({ms} ms)"))` per request, plus convert the existing error `eprintln!` ([cli.rs:827](../../../src/cli.rs#L827)) to `crate::obs::event("http-error", …)`.

- [ ] **Step 4: Build** — Run: `cargo build`. Expected: clean.

- [ ] **Step 5: Manual smoke (optional but recommended)** — Run `cargo run -- serve` from a repo with a `.studio-stud`, hit `http://127.0.0.1:31878/studio-stud/ping` once, Ctrl+C, then confirm `logs/daemon.log` under the storage root contains a `[serve]` line and an `[http] … /ping -> 200` line.

- [ ] **Step 6: Commit**

```bash
git add src/cli.rs
git commit -m "feat(obs): init logging in serve, add --profile, log per-request timing"
```

### Task 1.3: Route live-delta diagnostics through `obs`

**Files:**
- Modify: `src/live.rs` (replace the two `eprintln!` blocks at [live.rs:124-127](../../../src/live.rs#L124) and [live.rs:149-156](../../../src/live.rs#L149))
- Modify: `src/http.rs` (the `/studio-stud/live/delta` branch near [http.rs:230-240](../../../src/http.rs#L230))

- [ ] **Step 1: Convert the reject log** — replace the `eprintln!("[studio-stud] delta rejected: revision_mismatch …")` at `live.rs:124` with `crate::obs::event("live-delta", &format!("REJECT revision_mismatch place={} base={} live={}", request.place_id, request.base_revision, live.revision));`.

- [ ] **Step 2: Convert the apply log** — replace the `eprintln!("[studio-stud] delta applied …")` at `live.rs:149` with `crate::obs::event("live-delta", &format!("APPLY place={} rev {}->{} removed={} upserted={}", request.place_id, live.revision, live.revision + 1, request.removed.len(), request.upserted.len()));` and add, right after, a per-id trace of removals so Phase 3 can see exactly which ids were deleted: `for id in &request.removed { crate::obs::event("live-delta", &format!("removed id={id}")); }`.

- [ ] **Step 3: Log delta receipt at the HTTP boundary** — in the `/live/delta` branch in `http.rs`, before `apply_delta(...)`, add `crate::obs::event("live-delta", &format!("RECV delta upserted={} removed={}", delta.upserted.len(), delta.removed.len()));`.

- [ ] **Step 4: Build + test** — Run: `cargo build` then `cargo test`. Expected: clean build, existing tests green.

- [ ] **Step 5: Commit**

```bash
git add src/live.rs src/http.rs
git commit -m "feat(obs): surface live-delta receive/apply/reject + per-id removals"
```

**Phase 1 exit criteria:** Running `serve` produces `logs/daemon.log` with per-request timing and full live-delta decisions, including per-id removals. This is the instrument Phase 3 depends on.

---

# Phase 2 — Install integrity (Cluster A / F-1, F-2, F-3-partial) — PREREQUISITE

**Maintainer decision:** Do **not** pre-clean the test machine. Build idempotent cleanup/migration into the installer and use the corrupted machine as the test case. Success = running the new installer/cleanup on that machine yields one canonical launcher winning PATH, one daemon binary, and a clean PATH.

**Root causes (verified — note the report's framing was partly wrong):**
- The *current* installer correctly targets `%LOCALAPPDATA%\Programs\StudioStud\bin` ([install.rs:26-30,138-162](../../../src/setup_core/install.rs#L138)) — the `system32` install is a **legacy leftover**, not a current-installer bug.
- Real bug 1: `scripts/launcher.ps1:4` hardcodes the legacy `$Root\.studio-stud-tool\bin\studio-stud.exe` path — divergent from where the installer now lays the binary.
- Real bug 2: cleanup is incomplete — `migrate_legacy_repo` only handles a single repo's `.studio-stud-tool/`, and PATH de-dup only edits user PATH, so it can never remove shim files dropped *inside* `C:\WINDOWS\system32` (needs admin).
- Real bug 3: "apply staged update" does not hot-swap ([update_apply.rs:17-35](../../../setup/src/update_apply.rs#L17)) — it stops, lays the binary, returns. The "Now running it" message is false.

### Task 2.1: Converge `launcher.ps1` on the canonical daemon path

**Files:**
- Modify: `scripts/launcher.ps1`

- [ ] **Step 1: Read the current launcher** — open `scripts/launcher.ps1` and confirm line 4 computes `$StudioStudExe = Join-Path $Root ".studio-stud-tool/bin/studio-stud.exe"`.

- [ ] **Step 2: Repoint to the canonical install** — change the exe resolution to prefer the canonical install root, with the legacy path only as a fallback:

```powershell
# Resolve the canonical daemon first; fall back to a co-located legacy bundle.
$Canonical = Join-Path $env:LOCALAPPDATA "Programs\StudioStud\bin\studio-stud.exe"
$Legacy    = Join-Path $PSScriptRoot ".studio-stud-tool\bin\studio-stud.exe"
if (Test-Path $Canonical) {
    $StudioStudExe = $Canonical
} elseif (Test-Path $Legacy) {
    $StudioStudExe = $Legacy
} else {
    Write-Error "studio-stud daemon not found at $Canonical or $Legacy. Reinstall: irm <install-url> | iex"
    exit 1
}
```

- [ ] **Step 3: Verify the canonical shim that the installer writes uses the same logic** — open `src/setup_core/install.rs` `install_path_shim` (≈[install.rs:138-162](../../../src/setup_core/install.rs#L138)) and confirm the shim it generates resolves the daemon from the install root (not a per-repo `.studio-stud-tool`). If the generated shim text still embeds the legacy path, update the generated string to match Step 2's logic.

- [ ] **Step 4: Commit**

```bash
git add scripts/launcher.ps1 src/setup_core/install.rs
git commit -m "fix(install): launcher resolves canonical daemon path, legacy as fallback (F-1)"
```

### Task 2.2: Pure legacy-install detection + removal (unit-tested)

**Files:**
- Create: `setup/src/legacy_cleanup.rs`
- Modify: `setup/src/main.rs` or the setup crate's `lib`/`mod` root to register `mod legacy_cleanup;`

Design: a pure function operating on an injected list of candidate paths so it is unit-testable without touching the real machine. The IO wrapper enumerates real locations.

```rust
// setup/src/legacy_cleanup.rs
use std::path::{Path, PathBuf};

/// A legacy artifact we should remove, plus whether removing it needs admin
/// (true for anything under %SystemRoot%\system32).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LegacyArtifact {
    pub path: PathBuf,
    pub needs_admin: bool,
}

/// Given the set of candidate paths that exist on disk, classify which are
/// legacy Studio Stud artifacts to remove. `system_root` is injected for tests.
pub fn classify_legacy(existing: &[PathBuf], system_root: &Path, canonical_bin: &Path) -> Vec<LegacyArtifact> {
    existing
        .iter()
        .filter(|p| is_legacy_artifact(p, canonical_bin))
        .map(|p| LegacyArtifact {
            path: p.clone(),
            needs_admin: p.starts_with(system_root),
        })
        .collect()
}

fn is_legacy_artifact(p: &Path, canonical_bin: &Path) -> bool {
    // Never flag the canonical install.
    if p.starts_with(canonical_bin) {
        return false;
    }
    let s = p.to_string_lossy().to_lowercase();
    s.ends_with("studio-stud.ps1")
        || s.ends_with("studio-stud.cmd")
        || s.ends_with("studio-stud.old")
        || s.contains(".studio-stud-tool")
}
```

- [ ] **Step 1: Write the failing test** — append to `setup/src/legacy_cleanup.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn flags_system32_shim_as_admin_and_skips_canonical() {
        let sysroot = PathBuf::from(r"C:\WINDOWS");
        let canonical = PathBuf::from(r"C:\Users\u\AppData\Local\Programs\StudioStud\bin");
        let existing = vec![
            PathBuf::from(r"C:\WINDOWS\system32\studio-stud.ps1"),
            PathBuf::from(r"C:\WINDOWS\system32\.studio-stud-tool\bin\studio-stud.exe"),
            PathBuf::from(r"C:\Users\u\GitHub\FishersLife\studio-stud.cmd"),
            PathBuf::from(r"C:\Users\u\AppData\Local\Programs\StudioStud\bin\studio-stud.exe"),
        ];
        let out = classify_legacy(&existing, &sysroot, &canonical);
        // canonical exe is NOT flagged
        assert!(!out.iter().any(|a| a.path.ends_with("Programs\\StudioStud\\bin\\studio-stud.exe")));
        // the three legacy artifacts ARE flagged
        assert_eq!(out.len(), 3);
        // system32 ones require admin; the sibling-repo one does not
        assert!(out.iter().filter(|a| a.needs_admin).count() == 2);
        assert!(out.iter().filter(|a| !a.needs_admin).count() == 1);
    }
}
```

- [ ] **Step 2: Run the test, verify it fails** — Run: `cargo test -p studio-stud-setup legacy_cleanup::tests::flags_system32_shim_as_admin_and_skips_canonical`. Expected: FAIL (module/function not found).

- [ ] **Step 3: Implement** the module above and register `mod legacy_cleanup;` in the setup crate root.

- [ ] **Step 4: Run the test, verify it passes** — same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add setup/src/legacy_cleanup.rs setup/src/main.rs
git commit -m "feat(install): pure legacy-artifact classifier (system32/sibling shims, bundles) (F-1)"
```

### Task 2.3: `cleanup-legacy` subcommand with system32 elevation

**Files:**
- Modify: `setup/src/main.rs` (add subcommand + IO wrapper that enumerates real locations and deletes; for `needs_admin` artifacts, relaunch just the deletion elevated)

Design: the setup binary is intentionally `asInvoker` (F3 fix — do not change that). So the cleanup deletes user-writable artifacts in-process, and for any `needs_admin` artifact it writes a one-shot `cleanup-elevated.ps1` (a list of `Remove-Item -Force` for the exact paths) and relaunches it elevated via `Start-Process -Verb RunAs powershell -ArgumentList …` (single UAC prompt). Enumeration sources: every directory on the user+machine PATH, the `system32` dir, and known sibling repos discovered from `config.json.repos`.

- [ ] **Step 1: Add the subcommand** — in the setup clap `Commands` enum add `CleanupLegacy { #[arg(long)] dry_run: bool }`. Wire a `cmd_cleanup_legacy(dry_run)` handler.

- [ ] **Step 2: Implement enumeration + classification** — gather candidate paths (PATH entries' `studio-stud.ps1/.cmd`, `system32\studio-stud.*`, `system32\.studio-stud-tool`, `*.old`, sibling-repo shims), filter with `classify_legacy`, print the plan. If `dry_run`, stop here and print what *would* be removed.

- [ ] **Step 3: Implement removal + elevation** — delete non-admin artifacts in-process (`std::fs::remove_file`/`remove_dir_all`). If any `needs_admin` artifacts remain, generate `cleanup-elevated.ps1` listing exactly those paths and run:

```rust
// Pseudocode shape — implement with std::process::Command:
// powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-File','<script>'"
```

Emit a clear console message that a UAC prompt is required to remove `system32` artifacts.

- [ ] **Step 4: Build** — Run: `cargo build`. Expected: clean.

- [ ] **Step 5: Manual verification on the corrupted test machine** (the chosen test case):
  - Run `studio-stud-setup cleanup-legacy --dry-run` → confirm it lists the system32 shim, `system32\.studio-stud-tool`, `studio-stud.old`, and the `FishersLife` sibling shims.
  - Run `studio-stud-setup cleanup-legacy` → approve the single UAC prompt.
  - Run `Get-Command studio-stud -All` → expected: only the canonical `%LOCALAPPDATA%\Programs\StudioStud\bin` launcher (plus its `.cmd`) remain; **no `system32` entries**.
  - Run `studio-stud --version` (after Phase 6) or `studio-stud-setup --version` → resolves the single canonical 0.4.9 daemon.

- [ ] **Step 6: Commit**

```bash
git add setup/src/main.rs
git commit -m "feat(install): cleanup-legacy subcommand removes legacy installs, elevates for system32 (F-1)"
```

### Task 2.4: Call cleanup from install + make install idempotent

**Files:**
- Modify: `setup/src/install_flow.rs` (`run_install_headless` — the install orchestration in the **setup crate**, which can call `legacy_cleanup` from Task 2.2). Locate it with `git grep -n "fn run_install_headless"`.
- Possibly modify: `src/setup_core/install.rs` (only if the PATH-prepend tweak in Step 2 lives in the primitive).

- [ ] **Step 1: Invoke cleanup before laying the new install** — near the start of `run_install_headless`, call the legacy enumeration+classification (the shared IO wrapper from Task 2.3) and remove user-writable legacy artifacts, triggering the elevated step if system32 artifacts exist, so a fresh install over a dirty machine self-heals. Keep the enumeration/removal wrapper in `setup/src/legacy_cleanup.rs` (or a sibling in the setup crate) so both the `cleanup-legacy` subcommand and the install flow share it.

- [ ] **Step 2: Make PATH registration idempotent** — confirm `install_path_shim` de-dupes (it does, [src/setup_core/install.rs](../../../src/setup_core/install.rs) `install_path_shim`); additionally ensure the canonical bin dir is *prepended* so it wins precedence over any residual entries that elevation could not remove.

- [ ] **Step 3: Build + test** — Run: `cargo build` then `cargo test`. Expected: clean, green.

- [ ] **Step 4: Commit**

```bash
git add src/setup_core/install.rs
git commit -m "fix(install): run legacy cleanup on install; idempotent path shim (F-1)"
```

### Task 2.5: Honest staged-update apply (hot-swap or accurate message)

**Files:**
- Modify: `setup/src/update_apply.rs` (`apply_channel_update`, [update_apply.rs:17-35](../../../setup/src/update_apply.rs#L17))
- Modify: the daemon's "applied staged update / Now running it" banner (search `cli.rs`/`http.rs` for the literal string)

Default approach (lower risk): make the message **accurate** rather than attempting an in-process exec hot-swap. After `apply_channel_update` lays the new binary, the daemon should re-exec itself so "Now running it" is true.

- [ ] **Step 1: Locate the banner** — Run: `git grep -n "Now running it"` and `git grep -n "applied staged update"`. Note the file:line.

- [ ] **Step 2: Re-exec after apply** — where the daemon detects a staged update was applied at startup, after `apply_channel_update` succeeds, re-exec the freshly-installed canonical binary with the same args using `std::process::Command::new(canonical_daemon_path).args(env::args_os().skip(1)).spawn()` then exit the current process (so the new 0.4.9 process takes over). Emit `obs::event("update", "re-exec into v<new> after staged apply")`.

- [ ] **Step 3: If re-exec is rejected in review, fall back** — change the banner to `applied staged update (<ver>). Restart 'studio-stud serve' to run it.` and do **not** claim it is running.

- [ ] **Step 4: Build + test** — Run: `cargo build` then `cargo test`. Expected: clean, green.

- [ ] **Step 5: Manual verification** — On the test machine, with a staged update pending, run `studio-stud serve` once and confirm the banner version matches the running version (no second relaunch needed), or — if the fallback path — that the message honestly says "restart required."

- [ ] **Step 6: Commit**

```bash
git add setup/src/update_apply.rs src/cli.rs
git commit -m "fix(update): re-exec into applied staged update so 'Now running it' is true (F-2)"
```

**Phase 2 exit criteria:** On the test machine, `Get-Command studio-stud -All` shows only the canonical launcher; one daemon binary; `studio-stud serve` runs 0.4.9 in one launch. Re-testing now happens on a trustworthy install.

---

# Phase 3 — Deletes not live (Cluster C / F-I, Call-out 1)

**Report's suspected cause is REFUTED.** Verified facts:
- The plugin **does** connect `DescendantRemoving` → queues `dirtyRemoved` → builds `removed[]` → POSTs ([plugin:2259-2347](../../../plugin/StudioStud.plugin.lua#L2259)).
- The daemon **does** delete (DELETE across 6 tables + class-count adjust, [live.rs:203-223](../../../src/live.rs#L203)).
- `revision_mismatch` is handled gracefully with a retry that **preserves** pending ops ([plugin:2348-2366](../../../plugin/StudioStud.plugin.lua#L2348)).

So the defect is subtler. Three live hypotheses remain; the evidence (count decremented for `StudTest_Alpha` but the ghost row still returned by `query`; a separate disposable delete did not decrement at all) is ambiguous between them. **Diagnose with Phase 1 logging before writing a fix.**

- **H-A:** nil-id at `DescendantRemoving` time for subtree descendants → never enters `dirtyRemoved` (fits the "disposable didn't decrement").
- **H-B:** remove-then-upsert interplay (`markSiblingsDirty` + ordering) re-adds a ghost row (fits "count decremented but query still finds it").
- **H-C:** revision thrash defers the remove flush under rapid edits.

### Task 3.1: Diagnose with an instrumented repro (NO fix yet)

**Files:** none (observation only — uses Phase 1 logging)

- [x] **Step 1: Build + run the instrumented daemon** — `cargo run -- serve` (Phase 1 logging active). Connect the dev place in Studio, full-capture to "Live".

- [x] **Step 2: Reproduce the exact runbook sequence** — add `StudTest_Alpha`; rename a part to `StudTest_Bravo`; move one; delete one disposable; delete `StudTest_Alpha`; then undo/redo. (Same as F-I repro.) *(Partial runs + focused add/delete sessions on 2026-06-04; full runbook not repeated end-to-end.)*

- [x] **Step 3: Read `logs/daemon.log`** and answer, for each delete:
  - Did an `[live-delta] RECV delta … removed=N` line appear with N≥1, or was `removed=0` (→ **H-A**, plugin never sent the id)?
  - Did `[live-delta] APPLY … removed=1` + `removed id=<id>` appear, or `[live-delta] REJECT revision_mismatch` (→ **H-C**)?
  - If APPLY fired, did a subsequent `[live-delta] APPLY … upserted=…` re-add the same id (→ **H-B**)? Cross-check by querying the id right after.
  - Also enable the plugin's `debugLog` (the plugin already logs `delta POST: upserted=… removed=… baseRev=…` at [plugin:2337](../../../plugin/StudioStud.plugin.lua#L2337)) and compare what the plugin *sent* vs what the daemon *received*.

- [x] **Step 4: Record the verdict** — **Confirmed hypothesis: _None (no Phase 3 code fix)._** See **Phase 3 closure** below.

### Task 3.2 (if H-A): track ids for the whole removed subtree — **CANCELLED** (H-A not confirmed)

**Files:** Modify `plugin/StudioStud.plugin.lua` (`onDescendantRemoving` ≈ line 2179; `unregisterSubtree` ≈ line 2130)

- [ ] **Step 1:** In `onDescendantRemoving`, before unregistering, walk `child:GetDescendants()` and add every descendant's `instanceIdByRef[d]` (when non-nil) to `dirtyRemoved`, not just the root — so deleting a model removes all its tracked descendants live. Guard against nil ids.
- [ ] **Step 2: In-Studio verify** — delete a multi-part Model; confirm `logs/daemon.log` shows `removed=` equal to the tracked descendant count, and `query --find` returns nothing for any removed child within ~1–2 s (no wait for `verify`).
- [ ] **Step 3: Commit** `fix(plugin): emit removal deltas for full subtree on DescendantRemoving (F-I)`.

### Task 3.3 (if H-B): prevent ghost re-add — **CANCELLED** (H-B not confirmed)

**Files:** Modify `plugin/StudioStud.plugin.lua` (flush, ≈ lines 2283-2320) and/or `src/live.rs` (`apply_delta_tx`, line 203)

- [ ] **Step 1:** Ensure an id present in `removed` is never also emitted in `upserted` in the same delta. The plugin already guards `not Live.dirtyRemoved[id]` at [plugin:2286](../../../plugin/StudioStud.plugin.lua#L2286) — verify the guard key matches the removed key type (id vs instance). If the daemon is the culprit, in `apply_delta_tx` build a `removed: HashSet<&str>` and `continue` past any upsert whose id is in it, so removals always win within a transaction.
- [ ] **Step 2: In-Studio verify** — delete `StudTest_Alpha`; confirm count decrements **and** `query --find StudTest_Alpha` returns `total:0` within ~1–2 s.
- [ ] **Step 3: Commit** `fix(live): removals win over upserts within a delta; no ghost re-add (F-I)`.

### Task 3.4 (if H-C): make the remove flush survive revision thrash — **CANCELLED** (H-C ruled out)

**Files:** Modify `plugin/StudioStud.plugin.lua` (flush/retry, ≈ lines 2348-2366)

- [ ] **Step 1:** On `revision_mismatch`, the retry already preserves ops; ensure the retry is not starved by continuous upsert flushes — give `dirtyRemoved` priority by flushing removals in their own delta first when a mismatch was just seen.
- [ ] **Step 2: In-Studio verify** — rapid add+delete churn; confirm no delete waits for `verify` (watch `logs/daemon.log` for `REJECT` storms clearing within one retry).
- [ ] **Step 3: Commit** `fix(plugin): prioritize removal flush after revision_mismatch (F-I)`.

**Phase 3 exit criteria:** In the runbook delete sequence, 3/3 deletes reflect live within ~1–2 s (no reliance on the periodic `verify`), and `logs/daemon.log` shows clean `APPLY removed=1` per delete. The drift backstop remains a net, not the primary delete path.

**Phase 3 closure (2026-06-04, maintainer sign-off):**

| Check | Result |
|---|---|
| H-C (`REJECT revision_mismatch`) | **Ruled out** — zero `REJECT` lines across all instrumented sessions |
| H-A (removals never sent) | **Not confirmed** — `RECV removed=7` + per-id `removed id=…` + `APPLY` when Bravo subtree deleted (rev 1→2, 11→12) |
| H-B (ghost re-add) | **Not confirmed** — original F-I ghost `query` after Alpha delete not reproduced; duplicate remove of same 7 ids may be undo/redo or re-delete, not proven ghost |
| Add / `query` after create | **Explained** — CLI reads SQLite only after `APPLY`; ~1.7–4 s delta latency + debounce; wait for **rev bump** or ~5 s |
| Latest log tail (`00:25–00:26 UTC`) | **Re-baseline only** — two `materialize_snapshot` (~33.7 s each); **no** `[live-delta]` lines (Phase 4 prep, not F-I repro) |

**Outcome:** Close Phase 3 **without** shipping Tasks 3.2–3.4. The 2026-06-03 validation F-I behavior was **not reproduced** on the instrumented `development` build; live removal deltas **do** reach the daemon when the plugin sends them. Residual risk: original ghost/delete lag may return under edge cases — re-open 3.3 if a future session shows `APPLY removed` then `query` still finds the row **after** waiting for rev bump.

**Operator rule (until plugin UX improves):** After **Latest capture: OK** + **Live** (not Finalizing), edits are captured when `rev` increments or `delta OK` appears; run `query` only then.

---

# Phase 4 — Capture/DB performance (Cluster D / F-H, F-J)

**Root causes (confirmed):**
- F-H is plugin-side: capture/complete uses the default 30 s timeout ([plugin:1013,1815](../../../plugin/StudioStud.plugin.lua#L1815)) but Roblox `HttpService` caps long requests lower (~10 s observed), and the daemon **blocks** the response thread while writing the whole DB ([http.rs:605-659](../../../src/http.rs#L605)).
- The 287 MB DB is bloated by **double-storage** (`instances.property_json` + per-property `instance_properties` rows, [capture.rs:402-440](../../../src/capture.rs#L402)) and WAL with **no `VACUUM`/`auto_vacuum`** ([util.rs:129-138](../../../src/util.rs#L129)).
- F-J re-baseline does full `delete_all_tables` + `ingest_rows` every time ([capture.rs:28-106](../../../src/capture.rs#L28)).

### Task 4.1: `/capture/complete` acks immediately, finalizes async (fixes F-H) — **DONE** (`9cc9317`)

**Files:** Modify `src/http.rs` (`complete_daemon_upload`, [http.rs:605-659](../../../src/http.rs#L605))

- [x] **Step 1: Write a failing test** for the new contract — a `tests/*.rs` (or inline in `http.rs`) test that posting a "complete" returns a fast `{ "ok": true, "status": "finalizing", "syncId": … }` and that a follow-up `GET /studio-stud/capture/status?syncId=…` transitions to `done`. (If the existing handler shape makes a unit test impractical, write a focused test around the extracted finalize function and its status map.)

- [ ] **Step 2: Run it red** — Run: `cargo test capture_complete`. Expected: FAIL.

- [ ] **Step 3: Implement** — split `complete_daemon_upload` into (a) validate+register the upload, insert a `finalizing` entry into a `Mutex<HashMap<syncId, CompleteStatus>>` in `DaemonState`, spawn the heavy `materialize_snapshot` on a worker thread, and immediately return `{ok:true,status:"finalizing"}`; (b) the worker updates the status to `done`/`error` with the resulting captureId. Add `GET /studio-stud/capture/status` to read it. Wrap the finalize in `crate::obs::span("capture", "materialize_snapshot")`.

- [ ] **Step 4: Run it green** — Run: `cargo test capture_complete`. Expected: PASS.

- [ ] **Step 5: Plugin side** — change the capture/complete call ([plugin:1815](../../../plugin/StudioStud.plugin.lua#L1815)) to treat `status:"finalizing"` as success-in-progress, then poll `GET /capture/status` until `done` (bounded, e.g. 120 s) before declaring the capture failed. Raise the explicit timeout on the complete POST to a safe value regardless.

- [ ] **Step 6: Build + test** — Run: `cargo build` then `cargo test`. Expected: clean, green.

- [ ] **Step 7: In-Studio verify** — full capture of the 38,737-instance place reports success (no false `HttpError: Timedout`) on the first attempt; `logs/daemon.log` shows `[capture] materialize_snapshot took N ms`.

- [ ] **Step 8: Commit**

```bash
git add src/http.rs plugin/StudioStud.plugin.lua
git commit -m "fix(capture): ack /capture/complete immediately, finalize async + status poll (F-H)"
```

### Task 4.2: Shrink the DB (kill double-storage and/or compact) — **DONE** (`d88e206`)

**Files:** Modify `src/util.rs` (`open_db`, [util.rs:129-138](../../../src/util.rs#L129)), `src/capture.rs` (ingest path [capture.rs:402-440](../../../src/capture.rs#L402))

Decision point for the executor (measure first): the cheapest win is compaction; the structural win is removing the duplicate property storage. Do compaction first (low risk), then evaluate de-dup.

- [x] **Step 1: Add compaction PRAGMA** — in `open_db`, add `PRAGMA auto_vacuum = INCREMENTAL;` (must be set before tables exist on a fresh DB) and, after a full re-ingest/`delete_all_tables`, run `PRAGMA incremental_vacuum;` (or a one-shot `VACUUM` in the materialize path). Note: `auto_vacuum` only takes effect on a freshly-created DB or after a `VACUUM`, so include a one-time `VACUUM` migration on open if the existing DB has `auto_vacuum=0`.

- [ ] **Step 2: Measure** — capture the place, record `syncs.db` size before/after. Confirm a meaningful reduction from 287 MB. *(Pending maintainer: one capture on build `d88e206`+.)*

- [x] **Step 3: Evaluate de-dup** — stopped writing `instance_properties` rows; readers use `property_json` (legacy rows still read if present).

- [x] **Step 4: Build + test** — `cargo test` green.

- [x] **Step 5: Commit**

```bash
git add src/util.rs src/capture.rs src/storage.rs
git commit -m "perf(db): incremental auto_vacuum + remove duplicate property storage (F-H/F-J)"
```

### Task 4.3: Speed up re-baseline (F-J)

**Files:** Modify `src/capture.rs` (`materialize_snapshot` / re-baseline path [capture.rs:28-106](../../../src/capture.rs#L28))

- [x] **Step 1: Instrument** — `obs::span` sub-stages in `materialize_snapshot` (`materialize_delete_all`, `materialize_ingest_rows`, `materialize_commit`, `materialize_write_live_state`, `materialize_compact`); outer `materialize_snapshot` span unchanged in `http.rs`.
- [x] **Step 2: Optimize the dominant cost** — baseline ingest uses `insert_instance` (no per-row `delete_instance_rows` after `delete_all_tables`); fingerprint computed in-memory during ingest (skips post-commit `fingerprint_state` scan); WAL checkpoint `PASSIVE` instead of `TRUNCATE`.
- [ ] **Step 3: In-Studio verify** — full capture; `daemon.log` should show sub-stage timings and lower `materialize_snapshot` total than ~33 s baseline.
- [ ] **Step 4: Commit** `perf(capture): faster re-baseline via batched ingest + compacted DB (F-J)`.

**Phase 4 exit criteria:** First full capture succeeds without false timeout; `syncs.db` is materially smaller; re-baseline is meaningfully faster; all timings visible in `logs/daemon.log`.

---

# Phase 5 — Config self-heal + channel resolution (Cluster B / F-3, F-G)

**Root causes (verified):**
- `bind_place()` *does* persist repos ([registry.rs:72-98](../../../src/setup_core/registry.rs#L72)), but `versions.*` is **never populated anywhere** ([config.rs:10-21](../../../src/setup_core/config.rs#L10)), and `channel` seeding is **circular** — it reads `installRoot/version.json`, but `installRoot` was empty so it never seeds ([config.rs:102-120](../../../src/setup_core/config.rs#L102)). Empty `channel` → `default_channel()` returns `"release"` ([config.rs:42-57](../../../src/setup_core/config.rs#L42)) → root of F-G.
- `update --check` has no `--channel` override and ignores `version.json`.

### Task 5.1: Populate install/config fields at install time

**Files:** Modify `src/setup_core/config.rs`, `src/setup_core/install.rs`

- [ ] **Step 1: Write a failing test** — in `config.rs` `#[cfg(test)]`, construct a config, call a new `populate_install_fields(&mut cfg, install_root, plugins_dir, channel, versions)`, assert all four fields are non-empty afterward.
- [ ] **Step 2: Run red** — `cargo test config::tests::populate_install_fields_fills_all`. Expected: FAIL.
- [ ] **Step 3: Implement** `populate_install_fields` and call it from the install flow with the real install root, plugins dir, resolved channel, and the building binaries' versions (`env!("CARGO_PKG_VERSION")` for daemon/setup; the plugin version from the bundle). Fill `VersionsInfo` (currently dead).
- [ ] **Step 4: Run green** — same command. Expected: PASS.
- [ ] **Step 5: Commit** `fix(config): populate installRoot/pluginsDir/channel/versions on install (F-3)`.

### Task 5.2: Self-heal config on serve start

**Files:** Modify `src/cli.rs` (`cmd_serve`, after config load ≈[cli.rs:730](../../../src/cli.rs#L730)), `src/setup_core/config.rs`

- [ ] **Step 1:** After `load_config_or_default()`, if `installRoot` is empty, infer it from the running daemon's own location (`std::env::current_exe()` → parent of `bin/`), then re-run `seed_config_from_install_version` so `channel` and `versions` fill even when the install record was blank. `save_config` if anything changed. Emit `obs::event("config", "self-healed installRoot/channel on serve")`.
- [ ] **Step 2: Build + test** — `cargo build` && `cargo test`. Expected clean/green.
- [ ] **Step 3: Manual verify** — on the cleaned machine, after one `serve`, `studio-stud-setup health --json` returns `ok:true` with non-empty `installRoot`/`channel` and `repoCount` including the real place's repo once bound.
- [ ] **Step 4: Commit** `fix(config): self-heal installRoot/channel/versions on serve start (F-3/Call-out 2)`.

### Task 5.3: `update --check` honors channel + `--channel` override (F-G)

**Files:** Modify `setup/src/main.rs` (`cmd_update`), `src/setup_core/config.rs`

- [ ] **Step 1: Write a failing test** for channel resolution precedence: explicit `--channel` > `config.json.channel` (if non-empty) > `version.json.channel` > `"release"`. Put the precedence in a pure `resolve_update_channel(explicit, &cfg, version_json_channel)` function and test all four branches.
- [ ] **Step 2: Run red** — `cargo test -p studio-stud-setup resolve_update_channel`. Expected FAIL.
- [ ] **Step 3: Implement** the pure resolver + add `#[arg(long)] channel: Option<String>` (and a `--dev` convenience) to the `update` subcommand; have `cmd_update` use the resolver and fall back to `version.json` when `config.json.channel` is empty.
- [ ] **Step 4: Run green** — same command. Expected PASS.
- [ ] **Step 5: Manual verify** — `studio-stud-setup update --check --json` on the dev install now reports `channel:"dev"` (matching `/ping`), and `--channel dev` forces it explicitly.
- [ ] **Step 6: Commit** `fix(update): honor version.json channel + add --channel override (F-G)`.

**Phase 5 exit criteria:** `health --json` → `ok:true` with populated fields; `update --check` resolves `dev` on the dev install; `config.json` and `version.json` agree.

---

# Phase 6 — CLI papercuts (Cluster F / F-A, F-B, F-K, minor)

All confirmed, all small, all unit-testable.

### Task 6.1: `studio-stud --version` (F-A)

**Files:** Modify `src/cli.rs` (`Cli` struct [cli.rs:34-41](../../../src/cli.rs#L34) and the dispatch `match`)

- [ ] **Step 1: Write a failing integration test** — `tests/cli_version.rs`:

```rust
#[test]
fn version_flag_prints_version() {
    let out = std::process::Command::new(env!("CARGO_BIN_EXE_studio-stud"))
        .arg("--version")
        .output()
        .expect("run studio-stud --version");
    assert!(out.status.success(), "exit not success: {:?}", out);
    let s = String::from_utf8_lossy(&out.stdout);
    assert!(s.contains(env!("CARGO_PKG_VERSION")), "version missing: {s}");
}
```

- [ ] **Step 2: Run red** — Run: `cargo test --test cli_version`. Expected: FAIL (`--version` rejected as unexpected argument).

- [ ] **Step 3: Implement** — change `command: Commands` to `command: Option<Commands>` so clap's auto `--version`/`--help` short-circuit without requiring a subcommand; in the dispatch `match`, add a `None =>` arm that prints help (`Cli::command().print_help()` or the long help) and returns. Keep `#[command(version = env!("CARGO_PKG_VERSION"))]`.

- [ ] **Step 4: Run green** — Run: `cargo test --test cli_version`. Expected: PASS. Also confirm bare `studio-stud` prints help (not a panic).

- [ ] **Step 5: Commit** `feat(cli): support 'studio-stud --version' (F-A)`.

### Task 6.2: `--repo-root .` works (F-B)

**Files:** Modify `src/policy.rs` (`resolve_repo_root` ≈[policy.rs:187](../../../src/policy.rs#L187))

- [ ] **Step 1: Read `resolve_repo_root` fully** (both the `Some(explicit)` and the default branch) so the fix covers relative explicit *and* default (both fail per F-B).

- [ ] **Step 2: Write a failing test** — in `policy.rs` `#[cfg(test)]`: create a temp dir with `.studio-stud/policy.json`, `std::env::set_current_dir` into it, call `resolve_repo_root(Some(Path::new(".")))`, assert the returned path is absolute and that `returned.join(".studio-stud/policy.json")` exists. (Guard with a mutex if other tests touch CWD.)

- [ ] **Step 3: Run red** — Run: `cargo test --lib policy::tests::repo_root_relative_resolves`. Expected: FAIL (returned path is `.`, join fails / not absolute).

- [ ] **Step 4: Implement** — make `resolve_repo_root` return an absolute path in every branch: if the chosen root is relative, join it onto `std::env::current_dir()` and canonicalize (`std::fs::canonicalize`), mapping IO errors to the existing `BlockedReason`. Apply to both the explicit and default branches.

- [ ] **Step 5: Run green** — same command. Expected: PASS. Also manually confirm `studio-stud project check --repo-root .` and `policy check --repo-root .` now return `ok:true` from the repo root.

- [ ] **Step 6: Commit** `fix(cli): canonicalize --repo-root against CWD so '.' works (F-B)`.

### Task 6.3: `allowedPlaceIds` accepts strings (F-K)

**Files:** Modify `src/policy.rs` (`Policy.allowed_place_ids` [policy.rs:29](../../../src/policy.rs#L29)); Create `tests/policy_place_ids.rs`

- [ ] **Step 1: Write a failing test** — `tests/policy_place_ids.rs` deserializes a policy JSON with `"allowedPlaceIds": ["109595751023912"]` and asserts it parses and contains `109595751023912i64`:

```rust
use studio_stud::policy::Policy; // adjust to the actual public path

#[test]
fn allowed_place_ids_accepts_string_and_int() {
    let s = Policy::from_json_str(r#"{"allowedPlaceIds":["109595751023912"]}"#).unwrap();
    assert_eq!(s.allowed_place_ids, vec![109595751023912]);
    let i = Policy::from_json_str(r#"{"allowedPlaceIds":[109595751023912]}"#).unwrap();
    assert_eq!(i.allowed_place_ids, vec![109595751023912]);
}
```

(If `Policy` has no public `from_json_str`, deserialize via `serde_json::from_str::<Policy>` and make the test path match the real visibility; expose a small `pub fn from_json_str` if needed.)

- [ ] **Step 2: Run red** — Run: `cargo test --test policy_place_ids`. Expected: FAIL (`invalid type: string … expected i64`).

- [ ] **Step 3: Implement the string-or-int deserializer** — add to `policy.rs`:

```rust
fn de_place_ids<'de, D>(d: D) -> Result<Vec<i64>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::Deserialize;
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum StrOrInt { S(String), I(i64) }
    let raw: Vec<StrOrInt> = Vec::deserialize(d)?;
    raw.into_iter()
        .map(|v| match v {
            StrOrInt::I(n) => Ok(n),
            StrOrInt::S(s) => s.trim().parse::<i64>().map_err(|_| {
                serde::de::Error::custom(format!("allowedPlaceIds: '{s}' is not a valid place id"))
            }),
        })
        .collect()
}
```

Then annotate the field: `#[serde(default, deserialize_with = "de_place_ids")] pub allowed_place_ids: Vec<i64>,`. Note the field-named error message (addresses the "never names allowedPlaceIds" complaint).

- [ ] **Step 4: Run green** — Run: `cargo test --test policy_place_ids`. Expected: PASS. Run `cargo test` to confirm no policy regressions.

- [ ] **Step 5: Commit** `fix(policy): accept string or int allowedPlaceIds with named error (F-K)`.

### Task 6.4: Minor fixes

**Files:** Modify `src/query.rs` (count-only output) and confirm the fail-open security default

- [ ] **Step 1: `--count-only` output** — find where `--count-only` builds its JSON and stop emitting `limit`/`truncated` when only counting (they are misleading). Add/adjust a test asserting `count-only` JSON has no `truncated` field.
- [ ] **Step 2: Document the fail-open default** — empty `allowedPlaceIds` = allow-all is a **product decision**, not a code bug. Do not silently change it. Add a one-line doc comment near the policy place-check and surface the decision to the maintainer: confirm whether an empty allowlist on a write-safety gate should fail-open (current) or fail-closed. Record the answer; only change behavior if the maintainer asks.
- [ ] **Step 3: Commit** `fix(query): count-only omits misleading limit/truncated; doc fail-open allowlist`.

**Phase 6 exit criteria:** `studio-stud --version` works; `--repo-root .` works for `project check`/`policy check`; string `allowedPlaceIds` parse; count-only output is honest.

---

## Validated-solid — DO NOT REGRESS (guard with `cargo test` each phase)

Protocol-1 handshake + plugin auto-connect; `analyze` bounded output + `--limit` truncation; `query --find/--name/--class --count-only`; live add/rename/bulk-paste ~1–2 s; the drift `verify` backstop reconverging churn; `project diff` bounded structured diff + policy gate; the policy engine (`allowed`/`pathNotAllowed`/`placeMismatch`); `/write/validate` + `/write/preview` 401 token gate. Run `cargo test` (full suite) before every commit; if any of these break, stop and treat it as a Phase regression.

---

## Self-review (completed against `docs/validation-report-2026-06-03.md`)

- **Spec coverage:** F-1→2.1-2.4; F-2→2.5; F-3→2.4/5.1/5.2; F-G→5.3; F-H→4.1/4.2; F-I→3.x; F-J→4.2/4.3; F-OBS→1.x; F-A→6.1; F-B→6.2; F-K→6.3; minor (count-only, fail-open)→6.4. Out-of-scope items (Stage 7/8, CI dev-publish) explicitly noted, not silently dropped.
- **Placeholders:** the only intentionally-deferred content is Phase 3's *fix* code, which is correctly gated behind Task 3.1's diagnosis (writing the fix before diagnosis would violate systematic-debugging). All other tasks carry real code/tests/commands.
- **Type consistency:** `obs::init/event/span`, `classify_legacy`/`LegacyArtifact`, `resolve_update_channel`, `de_place_ids`, `populate_install_fields` are each defined where first used and referenced consistently.

---

## Execution note for the worker

Sequence is intentional: **Phase 1 and Phase 2 are prerequisites** (observability unblocks Phase 3's diagnosis; a clean install unblocks trustworthy re-testing). Do not start Phase 3 before Phase 1 is merged and the instrumented daemon is running. Each Luau/installer task ends in an **in-Studio or on-machine** verification — those cannot be skipped or asserted from code alone.
