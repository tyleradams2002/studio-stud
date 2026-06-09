# Studio Stud — Install / Uninstall Deep Dive & Fresh-Device Failure Analysis

**Status:** Review (analysis only — no fix yet). Author pass: 2026-06-08.
**Why:** A new user (Clayton) installed on a brand-new Windows device and it was a "complete disaster" —
`studio-stud` was not runnable even from new terminals, the daemon found no DB, and it was generally lost.
This is a teardown of the *as-built* install + uninstall to find exactly what's missed, before we touch a fix.

---

## TL;DR — the four core failures

1. **The "one-liner" launches a GUI that requires manual clicks.** `irm …/install.ps1 | iex` ends up running
   `setup.exe install --channel X` **without `--silent`**, which opens the **GUI installer**. The user must click
   **"Install"**; if they close it early or mis-click, nothing is written — and the one-liner still reports success.
2. **A fresh install registers ZERO repos → the place is "unbound" → no database is ever created.** Both the GUI
   (checkbox default off) and the silent path (`install_repos: false`) skip repo registration. An unbound place is
   **rejected** (`Unbound`), it does **not** auto-create a DB. Repo registration lives in per-device `config.json`,
   so it **does not transfer** from an old device.
3. **Every failure is swallowed.** `install.ps1` never checks `setup.exe`'s exit code and `exit 0`s unconditionally;
   the install/uninstall code is littered with `let _ =` discards. A broken install looks identical to a good one.
4. **PATH is set in the user registry but is unverified and the success flag is wrong.** `install_path_shim`'s
   registry write is `let _ =` (failures vanish), and `config.json` records `"pathShimInstalled": false` even on a
   *working* install — so we can't even trust the recorded state.

Net effect for a new user: a "successful" install that may have done nothing, with no error and no DB.

---

## 1. Ground truth — what a WORKING install looks like (Tyler's machine)

Read-only inspection of the maintainer's working install, for comparison:

- **PATH (HKCU\Environment\Path):** contains `…\AppData\Local\Programs\StudioStud\bin` ✅ (so the shim *can* work).
- **Install root** `%LOCALAPPDATA%\Programs\StudioStud`: `version.json`, `bin\studio-stud.exe`,
  `bin\studio-stud-setup.exe`, `plugin\StudioStud.plugin.lua`.
- **Storage/config root** `%LOCALAPPDATA%\StudioStud`: `config.json`, `ExampleProject\places\109595751023912\syncs.db`.
- **`config.json` anomalies (even here):**
  - `"pathShimInstalled": false` — **wrong** (PATH *is* set). The flag is never trusted/updated correctly.
  - registered `repos[0].placeId = 100000000000001`, but the live DB is for place `109595751023912` — they don't
    match, yet a DB exists ⇒ the place was bound by a separate path (`bind_place`), and the config's `placeId` is stale.
  - `versions = { setup: 0.4.10, daemon: 0.4.11, plugin: 0.4.27, protocol: 1 }` — **stale** (machine is actually on
    0.5.0). The `versions` block is not kept current.

These anomalies mean: *even a working install carries inconsistent recorded state*, so any logic that trusts
`config.json`'s `pathShimInstalled`/`versions`/`placeId` is on thin ice.

---

## 2. As-built: the INSTALL process

### 2.1 The one-liner (`site/install.ps1`)
1. Fetch the channel manifest; pick `bundleEncUrl` (dev/encrypted) or `bundleUrl` (release).
2. (Encrypted) prompt for the channel password, download + AES-decrypt + extract the bundle.
3. Forward `STUDIO_STUD_CHANNEL_PASSWORD` / `STUDIO_STUD_CHANNEL_SEQUENCE` via env.
4. **`Invoke-Setup`** → `Start-Process setup.exe install --channel <ch> -Wait` → **`exit 0`**.
   - ⚠️ **No `-PassThru`, no `$proc.ExitCode` check.** Setup's success/failure is discarded; the script always exits 0
     (`install.ps1:99/114`).
   - ⚠️ No `--silent`, so this is the **GUI** path (`setup/src/main.rs` → `Commands::Install{silent:false}` →
     `gui::run_install_gui`).

### 2.2 The GUI installer (`setup/src/gui.rs::run_install_gui`)
Screens: **Location → Plugins dir → Repos → Confirm → Install**. Key points:
- The install runs **only when the user clicks "Install"** (`gui.rs:311-313`). Closing the window before that writes
  nothing; closing *during* the background install can orphan partial state.
- **Repos checkbox defaults OFF** (`install_repos: false`, `gui.rs:99`). A default click-through registers no repo.
- Errors *are* shown in an `error_card()` on the failure screen — but only if the user clicked Install, stayed, and read it.

### 2.3 The headless core (`setup/src/install_flow.rs::run_install_headless`) — exact order
1. `run_legacy_cleanup` →
2. `lay_tool_payload` (daemon exe + plugin → `install_root/bin`, `version.json`) →
3. `copy_addon_payloads_from_repo(current_dir())` *(uses the CWD — on a one-liner that's wherever they ran it; `.ok()` swallows)* →
4. `install_core_plugin` (plugin → Roblox `Plugins/`) →
5. **`install_path_shim`** (PATH) →
6. `load_config_or_default` + `populate_install_fields` →
7. `store_channel_key_if_encrypted` (DPAPI key for auto-update) →
8. **`if install_repos { register_repo … }`** ← skipped on a default install →
9. record channelSequence → `save_config`.

If **any** of steps 2/4/5/6 returns `Err`, the function aborts **before** later steps (e.g., a failed `lay_tool_payload`
means no PATH and no exe). The GUI surfaces it; the one-liner does not.

### 2.4 The silent path (`cmd_install_silent`, setup/main.rs)
- Computes `install_root`/`plugins_dir` from config-or-defaults, fetches the bundle if needed, runs
  `run_install_headless` — **but hardcodes `install_repos: false`.** So **silent also registers no repo.**
- This path is actually *more* robust for a novice (no GUI clicks, sets PATH, lays files) — it's just **not what the
  one-liner uses**, and it still leaves 0 repos.

### 2.5 PATH mechanics (`src/setup_core/install.rs::install_path_shim`)
- Reads the **user** PATH from the registry, strips stale studio-stud entries, prepends `install_root\bin`, writes via
  `[Environment]::SetEnvironmentVariable('PATH', …, 'User')` (a spawned PowerShell).
- ⚠️ The write is `let _ = …status()` (`install.rs:295`) — **any failure is swallowed**, and `install_path_shim`
  returns `Ok(())` regardless (`install.rs:169`).
- ⚠️ **A User-scope PATH change does not apply to already-open shells.** A new terminal *should* see it — so if
  *new terminals still* can't find `studio-stud`, the write **failed or never ran** (install aborted earlier), or the
  exe was never laid down.

---

## 3. As-built: place → repo → DB binding (answers "wouldn't it make a new db?")

`src/setup_core/registry.rs::resolve_repo_root(place_id)`:
- **Given a `place_id` that matches a registered repo** → returns that repo root.
- **Given a `place_id` with NO match** → returns **`Unbound`** (with the list of registered repos). **No DB, no project_key, nothing persisted.**
- **Given no `place_id`** → falls back to the first registered repo (this is the *only* fallback).

`Storage`/`open_db` (`src/storage.rs`, `src/util.rs`): for a **bound** place, opening
`storage_root/<project_key>/places/<place>/syncs.db` **auto-creates** the dirs + DB + schema on first write
(SQLite `Connection::open`). So DB creation is automatic **only after binding**.

**Conclusion:** the daemon does **not** invent a DB for an unrecognized place — it rejects it as `Unbound`. And repo
registration is per-device `config.json`, which **does not move to a new device**. So on Clayton's new device with no
registered repo, *every* place is unbound and *no* DB is ever created — exactly the "can't find the db / lost" symptom.
(There's a `bind_place` path that can associate a place to a repo at runtime; that's how Tyler's `109…` place got a DB
despite the stale `100…` placeId — but it still requires a registered repo to bind *to*.)

---

## 4. As-built: the UNINSTALL process (`setup/src/gui.rs::run_uninstall` / `run_uninstall_gui`)

Order: **stop daemon → remove PATH entry → remove core plugin → remove addon dirs → remove install root → remove app data.**
- ⚠️ **Every step is `let _ =`** (`gui.rs:1128,1138,1146,1156,1164,1221,1230,1234,1239`). All failures swallowed; the
  success screen reports removal even if it failed.
- **Orphan risks:**
  - Daemon stop fails silently → exe stays **locked** → `remove_dir_all(install_root)` fails → bin left behind, PATH points at a half-deleted dir.
  - PATH entry not removed → orphan env var pointing at a deleted folder.
  - Addon dirs only removed if an `addon.json` marker exists → otherwise orphaned in `Plugins/`.
  - Config/storage dir locked → `config.json` + place DBs left behind.
- **Reinstall-on-top hazard:** a partial uninstall leaves orphans; a later install layers on top → compounding confusion.
  (Clayton uninstalled — so before any reinstall we should verify the machine is actually clean; see §6.)

---

## 5. What's missed — prioritized failure list

| # | Severity | What's missed | Where | Effect on a fresh device |
|---|----------|---------------|-------|--------------------------|
| F1 | **Critical** | One-liner runs the **GUI** (requires clicking Install), not a silent auto-install | `install.ps1` Invoke-Setup (no `--silent`) | User can close it / mis-click → nothing installed |
| F2 | **Critical** | **No repo registered** by any install path → place **Unbound** → **no DB** | `gui.rs:99` (checkbox off), `cmd_install_silent` `install_repos:false`, `registry.rs:40` Unbound | Daemon "Registry: 0 repo(s)", plugin "place not bound", no DB |
| F3 | **Critical** | `install.ps1` ignores setup exit code, always `exit 0` | `install.ps1:99/114` | Broken install reported as success, no error |
| F4 | High | PATH write failure swallowed + needs new shell + `pathShimInstalled` flag wrong | `install.rs:169/295`, config flag | "studio-stud not found" with no signal of why |
| F5 | High | Repo registration is **per-device** and assumed to transfer | `config.json` `repos[]` | New device has no repo even if old device did |
| F6 | High | Uninstall swallows all errors → orphans → reinstall-on-top breakage | `gui.rs` `run_uninstall` `let _` | Half-removed state masquerades as clean |
| F7 | Medium | Config records stale/incorrect state (`pathShimInstalled`, `versions`, `placeId`) | `config.json` | Any logic trusting it is unreliable; hard to diagnose |
| F8 | Medium | No post-install verification / no automatic `health` gate | install flow end | Install "completes" without proving it works |

---

## 6. My own testing (what I ran)

- **Ground-truth inspection** (read-only) of the working install + its `config.json` — surfaced F4/F5/F7 anomalies above.
- **Unit/integration tests** for the install surface — `cargo test … path_shim install config registry repo`:
  **24 passed, 0 failed** (`populate_install_fields_fills_all`, `path_filter_strips_known_install_bin`,
  `store_channel_key_*`, `install_sequence_from_env_*`, etc.), plus the protocol-v2 ping/tick tests.
  → **The pure functions are correct.** The failures are at the **orchestration/UX/workflow** layer, which has **no
  end-to-end test** (an install test would touch HKCU PATH + the filesystem).
- **Not run (deliberately):** a live install/uninstall on this machine — `install_path_shim` rewrites HKCU PATH and a
  bad sandbox restore could clobber the maintainer's working install. The live end-to-end is exactly what the manual
  tests below are for.

---

## 7. Manual tests to run on Clayton's device (the data we need before fixing)

Run these in order and capture the output; each line maps to a failure above. (Clayton currently has nothing
installed — these double as a clean reproduction.)

**A. Confirm the machine is actually clean (rules out orphans / F6)**
```powershell
Test-Path "$env:LOCALAPPDATA\Programs\StudioStud"        # expect False
Test-Path "$env:LOCALAPPDATA\StudioStud"                 # expect False (config/DBs)
((Get-ItemProperty HKCU:\Environment -Name Path).Path -split ';') | Where-Object { $_ -match 'studio' }   # expect nothing
```
→ If any are True/non-empty, the uninstall left **orphans** (F6) — capture them.

**B. Run the install one-liner and OBSERVE (F1/F3)**
- Run `irm https://tyleradams2002.github.io/studio-stud/install-dev.ps1 | iex` and **watch what happens**:
  - Did a **GUI window** open? **Screenshot every screen.**
  - Did you reach and click the **"Install"** button? Did the **Repos** checkbox get enabled + a folder added?
  - Any **red error card**? Screenshot it.
  - Did the PowerShell print any error, or just finish? (We expect it to "succeed" regardless — that's F3.)

**C. Did files actually land? (F1/F4)**
```powershell
Get-ChildItem -Recurse "$env:LOCALAPPDATA\Programs\StudioStud" | Select FullName   # expect bin\studio-stud.exe etc.
Get-Content "$env:LOCALAPPDATA\Programs\StudioStud\version.json"
```
→ If `studio-stud.exe` is **absent**, the install never completed (GUI not finished) — the headline bug.

**D. PATH (F4)**
```powershell
((Get-ItemProperty HKCU:\Environment -Name Path).Path -split ';') | Where-Object { $_ -match 'StudioStud' }
# THEN open a brand-new terminal and run:
studio-stud --version
```
→ Registry has the entry but a **new** terminal can't find it ⇒ exe missing or wrong dir. Neither ⇒ PATH write failed (F4).

**E. Config + health (F2/F5/F7)**
```powershell
Get-Content "$env:LOCALAPPDATA\StudioStud\config.json"     # repos: []? channel? channelKeyDpapi present?
studio-stud-setup health                                    # the built-in doctor — capture output
```

**F. Daemon view (F2)**
```powershell
studio-stud serve --verbose      # capture the first ~8 lines: "Storage root", "Registry: N repo(s)", "Install root"
```
→ **"Registry: 0 repo(s)"** confirms F2 (unbound). Leave it running for step G.

**G. Bind a repo, prove the DB appears (confirms the fix direction)**
```powershell
# in a second terminal:
studio-stud-setup add-repo "C:\path\to\claytons\project"
studio-stud serve --verbose      # restart — should now show "Registry: 1 repo(s)"
```
→ Then open the place in Studio, let it capture, and check a DB now exists:
```powershell
Get-ChildItem -Recurse -Filter syncs.db "$env:LOCALAPPDATA\StudioStud"
```
→ If binding the repo makes the place work + a DB appears, that **proves F2 is the core issue** and the fix is "make a
fresh install register/guide a repo."

---

## 8. Fix direction (preview — NOT building yet)

Once the manual tests confirm the above, the fix likely covers:
1. **Make the one-liner install non-interactive by default** — use `setup.exe install --silent` (auto paths, sets PATH,
   lays files) so it can't be half-completed; keep the GUI for `setup.exe install` run manually.
2. **Register/guide a repo on install** — prompt for (or accept a `--repo` arg in) the install, and make `serve` with
   0 repos print a loud actionable "no repo registered — run `studio-stud-setup add-repo <path>`" instead of sitting unbound.
3. **Stop swallowing failures** — `install.ps1` checks `$proc.ExitCode` and fails loudly; replace the load-bearing
   `let _ =` in install/uninstall with surfaced errors; print the new-terminal note + resolved bin path.
4. **Post-install verification** — run `health` at the end and report PASS / what's missing, so a broken install can't
   pass as success. Fix `pathShimInstalled`/`versions` to record true state.
5. **Make uninstall verify + report** — confirm the daemon stopped (so the exe isn't locked), confirm each removal,
   and report anything left behind.

---

### Appendix — key file:line references
- One-liner + Invoke-Setup + `exit 0`: `site/install.ps1` (Invoke-Setup; encrypted path ~`:80-106`, exits `:99/114`).
- Install dispatch (GUI vs silent): `setup/src/main.rs` `Commands::Install`.
- GUI install (Install button, repos default off): `setup/src/gui.rs:99, 311-313, 422-458, 1016`.
- Headless order: `setup/src/install_flow.rs:30-90`.
- Silent install (`install_repos:false`): `setup/src/main.rs` `cmd_install_silent`.
- PATH shim (+ swallowed write): `src/setup_core/install.rs::install_path_shim` (`:144-170`, write `:284-296`).
- Repo resolve / Unbound: `src/setup_core/registry.rs:40-70`; `bind_place` `:73+`.
- DB auto-create (bound only): `src/storage.rs` `Storage::new`/`place`, `src/util.rs` `open_db`.
- Uninstall (+ swallowed removals): `setup/src/gui.rs::run_uninstall` `:1125-1165, 1215-1239`.
