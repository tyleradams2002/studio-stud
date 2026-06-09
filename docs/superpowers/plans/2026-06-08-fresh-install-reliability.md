# Fresh-Install Reliability — Implementation Plan

> **For agentic workers (Composer):** implement task-by-task. Rust tasks = standard TDD. The one plugin/Luau
> task uses the **luau-craft** skill. Source of truth for the diagnosis:
> [`docs/install-deep-dive-and-fresh-device-failure.md`](../../install-deep-dive-and-fresh-device-failure.md).

**Goal:** a fresh-device install must be **reliable, non-interactive, self-verifying, and never silently broken** —
and a freshly-installed daemon must **loudly guide the user to bind a repo** instead of sitting unbound with no DB.

**Branch:** `development`. **Version:** bump to **0.5.1** at ship (Rust + plugin in lockstep per the version-gate).

**Tech:** `site/install.ps1` + `site/install-dev.ps1` (PowerShell bootstrap), `setup/` (Rust installer),
`src/setup_core/` (install/path/health/registry), `src/cli.rs` (daemon `serve`), `plugin/src/` (Luau status surface).

## Failure → fix map (from the deep-dive)
| Bug | Task |
|-----|------|
| F1 one-liner runs a GUI that can be half-completed | Task 1 |
| F3 `install.ps1` ignores exit code, always `exit 0` | Task 1 |
| F2 no repo registered → place Unbound → no DB | Tasks 2 + 4 |
| F5 repo registration is per-device, assumed to transfer | Tasks 2 + 4 |
| F4 PATH write swallowed; needs new shell; `pathShimInstalled` wrong | Task 3 |
| F7 config records stale `versions`/`pathShimInstalled` | Task 3 |
| F8 no post-install verification | Task 5 |
| F6 uninstall swallows errors → orphans | Task 6 |

---

## Task 1 — Make the one-liner a reliable, non-interactive install
**Files:** `site/install.ps1`, `site/install-dev.ps1`.

- [ ] **Silent, not GUI.** Change `Invoke-Setup` from `install --channel <ch>` to **`install --silent --channel <ch>`**
  so it runs headless (no GUI window to mis-click / close). `--silent` already exists (`setup/src/main.rs` `Commands::Install`);
  the extracted bundle next to `setup.exe` is found by `resolve_daemon_src`/`resolve_plugin_src`, so no re-fetch.
- [ ] **Check the exit code.** `Start-Process … -PassThru -Wait`, capture `$proc.ExitCode`; if non-zero, print the
  failure and **`exit 1`** (remove the unconditional `exit 0` at `install.ps1:99/114`). Same in `install-dev.ps1`.
- [ ] **Verify + guide after install.** On success: resolve the installed exe
  (`$env:LOCALAPPDATA\Programs\StudioStud\bin\studio-stud.exe`), run `& $exe --version` to PROVE it works, and print:
  the resolved bin path, **"Open a NEW terminal to use `studio-stud`,"** and the next step
  **`studio-stud-setup add-repo "C:\path\to\your\project"`**. If the exe is missing or `--version` fails, print a loud error + `exit 1`.
- [ ] **Optional one-shot repo.** If `$env:STUDIO_STUD_REPO` is set, forward it (env) so the install registers it (Task 2).
- [ ] Commit `fix(install): silent non-interactive install + exit-code check + post-install verify/guide`.

## Task 2 — Silent install can register a repo (and never pretends to)
**Files:** `setup/src/main.rs` `cmd_install_silent`, `setup/src/install_flow.rs`.

- [ ] In `cmd_install_silent`, after the base install, if `STUDIO_STUD_REPO` env is set and is a valid repo root, register
  it (reuse the `cmd_add_repo`/`register_repo` + `write_starter_policy` path, i.e. set `install_repos:true` + `repo_paths:[that]`,
  or call the add-repo helper directly). If unset, leave 0 repos (Task 4 makes that state loud, not silent).
- [ ] Do **not** silently `install_repos:false` when a repo was requested. Add a unit test: env set + valid path ⇒ config has
  the repo; env unset ⇒ unchanged.
- [ ] Commit `feat(install): silent install registers STUDIO_STUD_REPO when provided`.

## Task 3 — Stop swallowing PATH failures; record true state
**Files:** `src/setup_core/install.rs` (`install_path_shim`, `write_user_path_registry`), `src/setup_core/config.rs`
(`populate_install_fields` / version sync), `setup/src/install_flow.rs`.

- [ ] **Propagate the PATH write result.** `write_user_path_registry` returns `Result<()>` (check the spawned
  PowerShell `status().success()`); `install_path_shim` returns `Err` if the write fails (instead of `let _ =` +
  unconditional `Ok`). The GUI/silent callers already surface `Err`.
- [ ] **Make `pathShimInstalled` honest.** Set it `true` only after a successful PATH write; today it's `false` even on a
  working install (`config.json` evidence). Whatever sets it must reflect the actual write.
- [ ] **Record current versions.** Ensure `populate_install_fields` / `sync_version_json_channel` write the *installed*
  `versions {setup,daemon,plugin,protocol}` (the live `config.json` shows stale 0.4.10/0.4.11/0.4.27/1). Add a test that
  a fresh install writes the current versions + `pathShimInstalled:true`.
- [ ] Commit `fix(install): surface PATH-write failures; record accurate pathShimInstalled + versions`.

## Task 4 — Loud, actionable "no repo / unbound" guidance (daemon + plugin)
**Files:** `src/cli.rs` `cmd_serve`; the daemon tick/capture unbound path; `plugin/src/ui/CapturePanel.luau` (+ status surface).

- [ ] **Daemon `serve` with 0 repos:** after the `"Registry: {n} repo(s)"` line (`cli.rs:981`), if `n == 0` print a
  prominent multi-line warning: *"⚠ No repo registered — studio-stud cannot bind any Studio place or create a database
  until you run:  studio-stud-setup add-repo \"C:\\path\\to\\your\\project\"".*
- [ ] **Unbound place at runtime:** when a tick/capture resolves to `Unbound` (`registry.rs` `RepoResolveError::Unbound`),
  ensure the daemon logs a clear one-liner naming the placeId + the `add-repo` fix (not a silent rejection).
- [ ] **Plugin (luau-craft):** the old "Place not bound to a repo" hint was removed with the addons section in 0.4.24, so
  the plugin is currently silent on unbound. Surface it in the **status card**: when the daemon reports the place is
  unbound (a distinct response/field on `/tick` or `/ping`), set a clear status like *"Place not bound — run
  `studio-stud-setup add-repo <your project>` in a terminal."* Keep it distinct from the normal "Waiting/Live" states.
  Add a SelfTest assertion for the unbound-status path; regenerate the bundle.
- [ ] Commit `feat(serve+plugin): loud actionable guidance when no repo is bound`.

## Task 5 — Post-install health gate + comprehensive doctor
**Files:** `src/setup_core/health.rs` (`user_health_checks`), `setup/src/main.rs` (`cmd_install_silent` end), `site/install.ps1`.

- [ ] **Extend `user_health_checks`** to cover the new-device essentials, each PASS/FAIL with a fix hint:
  `studio-stud.exe` present at `install_root/bin`; the bin dir is on the user PATH; the plugin file exists in the Plugins
  dir; `config.json` is valid; **≥1 repo registered** (WARN/`fail` with the `add-repo` hint if 0).
- [ ] **Gate the install:** at the end of `cmd_install_silent`, run the health checks and print PASS / the specific
  failures (don't let a broken install report success). `install.ps1` can also run `studio-stud-setup health` and echo it.
- [ ] Unit-test the new checks (present/missing exe, PATH present/absent, 0-vs-N repos) with a temp config + temp root.
- [ ] Commit `feat(health): new-device install verification + post-install gate`.

## Task 6 — Reliable, verifying uninstall
**Files:** `setup/src/gui.rs` `run_uninstall` / `remove_user_install`.

- [ ] **Stop + verify the daemon is down** before removing the install root (poll `read_daemon_lock_port` until gone /
  timeout) so the running exe doesn't lock the dir.
- [ ] **Surface failures:** replace the load-bearing `let _ =` removals (install root, app data, PATH entry) with
  captured results; the success screen must report what was actually removed vs **left behind** (with the path), not
  claim success on partial failure.
- [ ] Commit `fix(uninstall): stop+verify daemon, surface removal failures, report orphans`.

## Task 7 — Bundle + bump + gate + ship
- [ ] Bump `Cargo.toml` + `plugin/src/Config.luau` + `Config.spec.luau` to **0.5.1**; regenerate the darklua bundle.
- [ ] Gate: `cargo test --workspace -- --test-threads=1` green (incl. new install/path/health/uninstall tests);
  `selene` 0/0/0; `luau-lsp` 0; lune specs pass (incl. the new unbound SelfTest); bundle current.
- [ ] Commit `chore: fresh-install reliability (0.5.1)`. Do NOT merge to main (controller promotes).

---

## ✅ GATE
**Headless:** full `cargo test` green incl. the new tests; plugin gate clean; bundle regenerated.

**Manual (the real proof — a fresh/sandboxed Windows account or VM, since this is exactly what unit tests can't cover):**
1. From a clean machine, run the dev one-liner → it installs **non-interactively** (no GUI), prints the verify + the
   "open a new terminal" + "add-repo" guidance, and `exit 1`s loudly if anything failed.
2. `studio-stud --version` works in a **new** terminal.
3. `studio-stud serve --verbose` with 0 repos prints the **loud "no repo — run add-repo"** warning; open the place in
   Studio → the plugin **status card shows the unbound guidance** (not silence).
4. `studio-stud-setup add-repo "<project>"` → re-serve shows "Registry: 1 repo(s)"; open the place → a `syncs.db` appears.
5. `studio-stud-setup health` reports PASS (or names exactly what's missing).
6. `studio-stud-setup uninstall` → removes everything and **reports any orphan**; a fresh machine check (`Test-Path` the
   install root / storage root / PATH entry) is clean.

## Deploy nuance (call out, don't trip on it)
- The Rust/setup + plugin fixes ship in the **bundle** (testable on the dev channel immediately).
- The **`install.ps1` / `install-dev.ps1`** changes only go live at the **gh-pages root via the `main` deploy**
  (`deploy-release`). To validate the script changes before a release, run the **local** `site/install-dev.ps1` against
  the dev channel; the published one-liner updates when 0.5.1 (or the install fix) is promoted to `main`.

## Self-review
- Every failure F1–F8 maps to a task. ✓
- Fixes are additive/surfacing (exit checks, error propagation, loud guidance, a health gate) — no protocol/data-model
  change. ✓
- The hardest-to-test layer (end-to-end install) is covered by the explicit manual gate, with unit tests for every pure
  helper (path-shim result, repo-from-env, health checks, version recording). ✓
