# Boot-Time Auto-Update (in-daemon stage + re-exec) — 0.4.25 Implementation Plan

> **For agentic workers (Composer 2.5):** implement task-by-task; standard Rust TDD. Steps use `- [ ]`. **Rust-only** (daemon + setup) — no plugin logic change (only a version-string bump + bundle regen). Do NOT change the `/tick` protocol, the live-sync engine, or the dev-main deploy/anti-rollback behavior.

## Goal
When `studio-stud serve` starts, **before it binds the port**, the daemon checks its channel for a newer published build; if there is one it downloads + decrypts the bundle, **stages** the new daemon exe and **overwrites the plugin file**, then re-execs into the new version and serves. The polling plugin just keeps showing "Waiting for studio-stud serve…" during the swap and connects to the now-current daemon. This replaces the manual `install-dev.ps1` reinstall and makes the "update available" banner self-clearing.

## Design (approved)
- **Cadence:** boot-only (each `serve` start). To pick up a new build, restart the daemon (Studio reload / restart `serve`). No mid-session restarts.
- **Mechanism:** in-daemon **stage + re-exec**, reusing the existing staging machinery (`apply_staged_on_boot` already renames the running exe → `.old`, swaps `<exe>.new` → exe, re-execs in the same terminal). The Windows "can't overwrite a running exe" constraint is why we stage rather than overwrite.
- **Key:** reuses the existing `channelKeyDpapi` in `%LOCALAPPDATA%\StudioStud\config.json` (DPAPI, current-user). Release is unencrypted → no key needed; dev needs it seeded (post-0.4.12 `install.ps1` does this).
- **Plugin caveat (accepted):** the daemon overwrites the plugin *file*, but Studio only loads plugins at startup. Same-protocol updates keep working immediately; a protocol-breaking one shows the existing "plugin outdated — reload" handshake message until Studio reloads. Unavoidable.

## Non-negotiable safety
- **Never block startup.** Offline / manifest-fetch timeout / download failure / `channelKeyDpapi` absent → log and serve the *current* version.
- **Loop guard:** the seq is recorded on a successful stage, so the re-exec'd boot sees a matching seq and won't re-stage.
- **`--no-update`** pins the installed version (deliberately testing an older build).
- Same behavior on `release` as `dev` (release just needs no key).

---

## Task 1 — `setup`: a stage-only update path

**Files:** `setup/src/main.rs` (the `Update` subcommand + `cmd_update`), `setup/src/update_apply.rs` (new `stage_channel_update`).

- [ ] **Step 1 — add the `--stage` flag.** In `Commands::Update { … }` (`setup/src/main.rs:62`) add `#[arg(long)] stage: bool`, and thread it through `Commands::Update { check, channel, dev, stage } => cmd_update(check, channel, dev, stage, cli.json)?`. Add `stage: bool` to `cmd_update`'s signature.
- [ ] **Step 2 — route to staging when asked.** In `cmd_update`, the apply branch is currently `if !check && update_available { apply_channel_update(&cfg, &manifest, resolved)?; }` (`:315`). Change to:
  ```rust
  if !check && update_available {
      if stage {
          update_apply::stage_channel_update(&cfg, &manifest, resolved)?;
      } else {
          update_apply::apply_channel_update(&cfg, &manifest, resolved)?;
      }
  }
  ```
- [ ] **Step 3 — implement `stage_channel_update`** in `update_apply.rs`. It mirrors `apply_channel_update` but **stages the exe instead of overwriting**, and **does NOT call `stop_running_daemon`** (the running daemon is the caller). Concretely:
  - `let (daemon_path, plugin_path) = download_extract_bundle_paths(cfg, manifest, resolved)?;` (reuse — handles decrypt via `channelKeyDpapi`).
  - Resolve the canonical daemon exe: `let exe = studio_stud::setup_core::install::canonical_daemon_exe(&PathBuf::from(&cfg.install_root));` and the staged path `let staged = exe.with_file_name(format!("{}.new", exe.file_name()…));` — **must equal `update::staged_exe_path`'s convention `<exe>.new`** (so `apply_staged` finds it).
  - `fs::copy(&daemon_path, &staged)?;` (stage the new exe; never touch the running `exe`).
  - Overwrite the plugin file in the Plugins dir — reuse the install path's plugin install (e.g. expose/call `install_core_plugin(&PathBuf::from(&cfg.plugins_dir), &plugin_path)`; make it `pub` if needed). The plugin file is not locked, so a direct overwrite is fine.
  - **Write `version.json`** (next to the canonical exe — the same file `update::apply_staged` reads via `version_json_path(exe)`): set `stagedDaemonVersion = manifest.daemon_version`, `pluginVersion = manifest.plugin_version` (the plugin IS updated now), and the channel/`channelSequence` fields; **leave `daemonVersion` unchanged** (the running exe is still old until `apply_staged` promotes it). Reuse/extend the existing version.json writers (`install_version_json` / `write_version_json`) — do not hand-roll JSON.
  - `record_channel_sequence(&mut updated_cfg, resolved, manifest.channel_sequence)` + `save_config(&updated_cfg)?`.
- [ ] **Step 4 — tests** (`setup/src/update_apply.rs` or a sibling test module, sandboxed temp dirs; no network — call `stage_channel_update`'s file-laying helper with a local extracted bundle, or factor the file-staging into a pure helper `stage_files(exe, plugins_dir, daemon_src, plugin_src, version_meta)` and unit-test THAT): staged `.new` exists, `version.json` has `stagedDaemonVersion`=new and `daemonVersion`=old, the plugin file was overwritten, the running exe is untouched, and the seq is recorded. `apply_channel_update` / `record_install_baseline_seq` paths remain unchanged. Commit `feat(update): stage-only update mode for in-daemon auto-update`.

## Task 2 — daemon: stage at `serve` boot + wire `--no-update`

**Files:** `src/cli.rs` (`cmd_serve`), a small new helper (locate setup + spawn with timeout).

- [ ] **Step 1 — expose the setup locator.** Make `resolve_setup_src` (`src/setup_core/install.rs:82`) `pub`, OR add a tiny `pub fn setup_exe_path(install_root: &Path) -> PathBuf` that returns `canonical_daemon_exe(install_root).with_file_name("studio-stud-setup.exe")`. Prefer reusing `resolve_setup_src` (it already falls back to the cargo target tree for dev runs).
- [ ] **Step 2 — auto-update step in `cmd_serve`.** Rename the unused `_no_update` param to `no_update` and use it. **Before** the existing `apply_staged_on_boot()` call (`src/cli.rs:812`), add:
  ```rust
  if !no_update {
      crate::update::stage_update_via_setup(); // best-effort, logged, timeout-bounded
  }
  crate::update::apply_staged_on_boot();
  ```
- [ ] **Step 3 — implement `stage_update_via_setup`** in `src/update.rs` (keeps `cmd_serve` clean and is unit-testable in parts):
  - Locate `studio-stud-setup.exe` (Step 1 helper); if not found → log + return (serve current).
  - `Command::new(setup).args(["update", "--stage"]).spawn()` then **wait with a backstop timeout** (poll `try_wait` until a deadline, e.g. 120 s; on timeout `kill()` + return). setup's own HTTP timeouts (`fetch_manifest`, `download_to`) handle the offline case fast, so this is just a backstop against a hung process.
  - Log the outcome via `crate::obs::event("update", …)` ("staged vX", "up to date", "skipped: <reason>"). **Any error is non-fatal** — always fall through to serve.
  - (`stage_update_via_setup` resolves the channel from config inside setup; no `--channel` needed.)
- [ ] **Step 4 — tests.** Unit-test the timeout wrapper with a dummy long-running / fast / failing command (a pure `wait_with_timeout(child, dur)` helper), and the setup-locator. The end-to-end stage→apply→re-exec is the manual gate. `cargo test --workspace -- --test-threads=1` green. Commit `feat(serve): check + stage channel update before binding (boot-time auto-update)`.

## Task 3 — version bump + gate + ship

- [ ] `Cargo.toml` → `0.4.25`; `plugin/src/Config.luau` `PLUGIN_VERSION = "0.4.25"` (the CI version-bump gate requires daemon == plugin).
- [ ] **Regenerate the bundle** (PLUGIN_VERSION lives in it): `darklua process --config plugin/.darklua.json plugin/src/init.luau plugin/StudioStud.plugin.lua`, and **commit `plugin/StudioStud.plugin.lua`** (CI ships the committed bundle as-is — there is no darklua step in CI).
- [ ] Full gate: `cargo test --workspace -- --test-threads=1` green (the 3 `serve_workers_http` wall-clock tests stay `#[ignore]`); `selene --config plugin/selene.toml plugin/src` 0/0/0; `luau-lsp analyze --defs=plugin/globalTypes.d.luau --base-luaurc=plugin/.luaurc plugin/src` 0 errors; lune specs pass; bundle compiles, 0 `require`s, contains `0.4.25`.
- [ ] Commit `chore: boot-time auto-update (0.4.25)`. **Do NOT merge** — controller pushes/merges.

---

## ✅ GATE
**Headless:** `cargo test --workspace` green incl. the new stage + timeout tests; selene/luau-lsp/lune clean; bundle current.

**Manual (daemon, on dev with `channelKeyDpapi` seeded):**
1. Be on build N. Deploy N+1. Restart `studio-stud serve --verbose` → log shows it staged vN+1, applied the swap, re-exec'd; the daemon now reports vN+1; plugin connects.
2. Open Studio → the "update available" banner is **gone**; after a Studio reload the plugin is also N+1.
3. `studio-stud serve --no-update` → no check, serves the installed version.
4. **Offline test:** disconnect network → `serve` still starts (current version) within a couple seconds, logs "update check skipped".
5. **No key:** on a config without `channelKeyDpapi` (release channel) → release auto-update works with no key; on dev without the key → logs "run install-dev.ps1 once", serves current.

## Out of scope (deliberate)
- Periodic / mid-session auto-update (boot-only by design).
- Forcing Studio to hot-reload the plugin (impossible; handshake already covers protocol-break).
- A persistent `autoUpdate` config toggle (the `--no-update` flag suffices for now).

## Self-review
- Reuses the proven download/decrypt/extract (`download_extract_bundle_paths`) + staging/re-exec (`apply_staged`); the only NEW logic is "lay staged files instead of overwrite" + "spawn setup with a timeout at boot". ✓
- Offline-safe, loop-guarded, key reused (no new secret storage), plugin/protocol untouched. ✓
- Staged path + `stagedDaemonVersion` marker match `apply_staged`'s exact expectations. ✓
