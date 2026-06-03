# Phase 6 — Lower-priority correctness

> Hand Composer: this file + `docs/REVIEW_2026-06-02.md`. Branch: **`development`**.
> Depends on: **Phase 1** (independent of 2-5; can run any time after 1).

## Goal
Three correctness/perf cleanups: make the committed addon-enable file the source of truth, stop the first
`/ping` from blocking on the channel fetch, and remove dead fields.

## Pre-flight
```powershell
git switch development
cargo build --workspace && cargo test --workspace
```

---

## G16 — Addon enablement: committed repo file is source of truth  [M]
**Files:**
- `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\src\setup_core\install.rs`
  (`enable_addon`/`disable_addon`/`list_bundled_addons`, lines 231-308)
- `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\src\cli.rs` (`cmd_serve`, ~728-747)

**Why:** addon enablement is stored both in `config.json` `enabled_addons` (per-machine) and committed
`.studio-stud/addons/<id>.json`. They drift across machines; the committed file should win so "this repo
uses the boat tab" is a team decision each machine reconciles to.

**Change:** add a reconcile function in `install.rs`:
```rust
/// For each addon marked enabled in the repo's committed `.studio-stud/addons/*.json`, ensure this
/// machine's plugins dir has the addon folder laid down. Per-machine `config.json.enabled_addons`
/// becomes a cache, not the source of truth.
pub fn reconcile_repo_addons(
    install_root: &Path,
    plugins_dir: &Path,
    repo_root: &Path,
) -> Result<Vec<String>> {
    let dir = repo_root.join(".studio-stud").join("addons");
    let mut enabled = Vec::new();
    if !dir.is_dir() {
        return Ok(enabled);
    }
    for entry in fs::read_dir(&dir)? {
        let entry = entry?;
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let cfg: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(&path)?).unwrap_or_default();
        if cfg.get("enabled").and_then(|v| v.as_bool()) == Some(true)
            && let Some(id) = cfg.get("addonId").and_then(|v| v.as_str())
            && install_root.join("addons").join(id).join("addon.json").is_file()
        {
            // idempotent: enable_addon removes+recopies
            enable_addon(install_root, plugins_dir, repo_root, id)?;
            enabled.push(id.to_string());
        }
    }
    Ok(enabled)
}
```
In `cmd_serve` (after the registry is built, ~743), for each registered repo call `reconcile_repo_addons`
(best-effort, log on error). Keep `config.json.enabled_addons` updated to the reconciled set.

**Acceptance:** enabling the boat addon, committing `.studio-stud/addons/boat-modification.json`, then
running `serve` on a second clone copies the addon into that machine's plugins dir.

---

## G17 — Don't block the first `/ping` on the channel fetch  [S]
**Files:**
- `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\src\setup_core\channels.rs` (`fetch_manifest`, line ~100)
- `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\src\setup_core\channel_update.rs` (`ping_fields`, lines 37-47)
- `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\src\cli.rs` (`cmd_serve`, after channel_update is built, ~747)

**Why:** the first `/ping` after `serve` synchronously fetches the channel manifest (up to 12s), blocking
the plugin's first Connect.

**Changes:**
1. Drop the fetch timeout from 12s to 6s in `fetch_manifest` (`.timeout_global(Some(Duration::from_secs(6)))`).
2. Make `ping_fields` non-blocking: if the cache has never been populated, return
   `json!({ "updateAvailable": false })` immediately and trigger the refresh on a background thread
   (store an `AtomicBool` "refreshing" guard in `CacheInner` so only one refresh runs).
3. In `cmd_serve`, after constructing `channel_update`, prime it once on a background thread:
   ```rust
   let cu = std::sync::Arc::clone(&channel_update);
   std::thread::spawn(move || { let _ = cu.ping_fields(); });
   ```
   (so the cache is usually warm by the first plugin Connect, but never blocks it).

**Acceptance:** with the daemon offline-to-Pages (e.g. block the host), the first `/ping` after `serve`
returns in <100ms and reports `updateAvailable:false`.

---

## G18 — Remove dead fields  [S]
**Files:**
- `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\src\setup_core\channels.rs` (lines 66-69)
- `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\src\setup_core\config.rs` (line 14-15) +
  install flow.

**Changes:**
1. Delete the unused `kdf_salt` / `kdf_nonce` from `ChannelManifest` (the AES path derives salt from the
   blob itself — `crypto.rs:99`). Update `sample_manifest()` accordingly.
2. Either delete `VersionsInfo.setup`, or populate it: in `install_flow.rs::run_install_headless` set
   `cfg.versions.setup = env!("CARGO_PKG_VERSION").to_string();` (the setup crate version). Prefer
   populating it so `version-compat.md`'s "Setup" row is real.

**Acceptance:** `cargo build --workspace` clean, no dead-code warnings; if populated, `studio-stud-setup`
config shows a `setup` version.

---

## Verification (return to Claude)
```powershell
cargo build --workspace
cargo test --workspace
```
- Addon reconcile: enable + commit an addon json in a test repo, run `serve` from a second copy, confirm
  the addon folder appears in the plugins dir.
- First-ping latency: with Pages unreachable, time the first `/ping` after `serve` (<100ms).

## Done when
`cargo test --workspace` green; first ping is non-blocking; no dead-code warnings.
