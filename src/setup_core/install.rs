use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use anyhow::{Result, anyhow};
use serde_json::{Value, json};

use super::config::{StudioStudConfig, daemon_lock_path};

pub const LEGACY_TOOL_DIR: &str = ".studio-stud-tool";
pub const REPO_MARKER: &str = ".studio-stud/.installed";

const STUDIO_STUD_DIR_GITIGNORE: &str = "\
# Studio Stud — per-repo managed folder.
# COMMITTED (shared across all developers): policy.json, addons/, this file.
# IGNORED (per-machine, never commit): everything else
#   .installed, base-ledger/, stash/, merge/, write.token, *.tmp, cache/
*
!.gitignore
!policy.json
!addons/
!addons/**
";

pub fn default_install_root() -> PathBuf {
    dirs::data_local_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("Programs")
        .join("StudioStud")
}

/// Canonical daemon binary under the global install root (`…/StudioStud/bin/studio-stud.exe`).
pub fn canonical_daemon_exe(install_root: &Path) -> PathBuf {
    install_root.join("bin").join("studio-stud.exe")
}

pub fn default_plugins_dir() -> PathBuf {
    dirs::data_local_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("Roblox")
        .join("Plugins")
}

pub fn is_valid_repo_root(path: &Path) -> bool {
    path.join(".git").exists() || path.join("default.project.json").is_file()
}

pub fn repo_already_registered(cfg: &StudioStudConfig, path: &Path) -> bool {
    let canon = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    let key = canon.display().to_string();
    cfg.repos
        .iter()
        .any(|r| r.path.eq_ignore_ascii_case(&key))
}

pub fn lay_tool_payload(
    install_root: &Path,
    daemon_exe: &Path,
    plugin_lua: &Path,
    version_meta: &Value,
) -> Result<()> {
    let bin_dir = install_root.join("bin");
    let plugin_dir = install_root.join("plugin");
    fs::create_dir_all(&bin_dir)?;
    fs::create_dir_all(&plugin_dir)?;
    fs::create_dir_all(install_root.join("addons"))?;
    fs::copy(daemon_exe, bin_dir.join("studio-stud.exe"))?;
    // Also copy the setup binary so `studio-stud-setup` is on PATH alongside the daemon.
    if let Some(setup_src) = resolve_setup_src(daemon_exe) {
        let _ = fs::copy(setup_src, bin_dir.join("studio-stud-setup.exe"));
    }
    fs::copy(plugin_lua, plugin_dir.join("StudioStud.plugin.lua"))?;
    fs::write(
        install_root.join("version.json"),
        serde_json::to_string_pretty(version_meta)?,
    )?;
    Ok(())
}

/// Locate `studio-stud-setup.exe` relative to the daemon source or current exe.
fn resolve_setup_src(daemon_exe: &Path) -> Option<PathBuf> {
    // Same dir as daemon_exe (e.g. dist/ or bin/)
    if let Some(dir) = daemon_exe.parent() {
        let p = dir.join("studio-stud-setup.exe");
        if p.is_file() {
            return Some(p);
        }
    }
    // Running from a cargo target tree: target/debug/ or target/release/
    if let Ok(current) = std::env::current_exe() {
        let p = current.with_file_name("studio-stud-setup.exe");
        if p.is_file() {
            return Some(p);
        }
    }
    None
}

pub fn install_core_plugin(plugins_dir: &Path, plugin_src: &Path) -> Result<()> {
    fs::create_dir_all(plugins_dir)?;
    fs::copy(
        plugin_src,
        plugins_dir.join("StudioStud.plugin.lua"),
    )?;
    Ok(())
}

pub fn write_starter_policy(repo_root: &Path, channel: &str) -> Result<()> {
    let policy_dir = repo_root.join(".studio-stud");
    fs::create_dir_all(&policy_dir)?;

    let gitignore_path = policy_dir.join(".gitignore");
    if !gitignore_path.is_file() {
        fs::write(&gitignore_path, STUDIO_STUD_DIR_GITIGNORE)?;
    }

    let policy_path = policy_dir.join("policy.json");
    if !policy_path.is_file() {
        // Pin the repo to the channel of whoever installs first. Committed and
        // shared, so teammates on other channels are blocked from writing until
        // they match (see policy::channel_pin_violation).
        let starter = json!({
            "version": 1,
            "targetChannel": channel,
            "allowedPlaceIds": [],
            "allowedWritePaths": [],
            "requireGeneratedHeaderPaths": [],
            "maxPatchBytes": 1048576,
            "maxPatchItems": 500,
            "maxDeleteCount": 50,
        });
        fs::write(&policy_path, serde_json::to_string_pretty(&starter)?)?;
    }

    let marker = repo_root.join(REPO_MARKER);
    if !marker.is_file() {
        fs::write(&marker, crate::util::now_utc())?;
    }
    Ok(())
}

/// User-writable PATH entry: the install `bin/` dir (not per-repo `.studio-stud-tool`).
pub fn install_path_shim(install_root: &Path) -> Result<()> {
    let bin = install_root.join("bin");
    let bin_str = bin.display().to_string();

    // Read the current *user* PATH from registry so we don't inherit the
    // process-level PATH (which already has the old entry from the current session).
    let user_path = read_user_path_registry().unwrap_or_default();

    // Strip any existing studio-stud bin entries to avoid stale duplicates,
    // then prepend the new one so it wins regardless of order.
    let cleaned: Vec<&str> = user_path
        .split(';')
        .filter(|p| !p.is_empty() && !is_studio_stud_bin(p))
        .collect();

    let new_path = if cleaned.is_empty() {
        bin_str.clone()
    } else {
        format!("{bin_str};{}", cleaned.join(";"))
    };

    // Write via .NET SetEnvironmentVariable (mirror of uninstall_path_shim): preserves the full
    // value (setx truncates at 1024 chars) and broadcasts the change to new processes.
    write_user_path_registry(&new_path);

    Ok(())
}

/// Returns true when a PATH `entry` directory should be removed because it
/// contains a legacy per-repo `studio-stud.cmd` / `studio-stud.exe` shim,
/// OR it's a known studio-stud install bin directory.
fn is_studio_stud_bin(entry: &str) -> bool {
    let lower = entry.to_lowercase();
    // Named install dirs (old layout "studio-stud\bin", new "StudioStud\bin").
    if lower.contains("studio-stud") || lower.contains("studiostud") {
        return true;
    }
    // Per-repo legacy shim: directory that contains studio-stud.cmd or studio-stud.exe.
    let p = std::path::Path::new(entry);
    p.join("studio-stud.cmd").is_file() || p.join("studio-stud.exe").is_file()
}

/// Read the user-level PATH directly from the registry so we only touch
/// the user's own entries, not the machine PATH.
fn read_user_path_registry() -> Option<String> {
    #[cfg(windows)]
    {
        use std::process::Command;
        let out = Command::new("powershell")
            .args([
                "-NoProfile",
                "-Command",
                r"(Get-ItemProperty -Path 'HKCU:\Environment' -Name PATH -ErrorAction SilentlyContinue).PATH",
            ])
            .output()
            .ok()?;
        let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if s.is_empty() { None } else { Some(s) }
    }
    #[cfg(not(windows))]
    {
        std::env::var("PATH").ok()
    }
}

/// Remove Studio Stud's bin directory from the user PATH — the mirror of
/// `install_path_shim`. Deliberately conservative: it only strips entries that
/// are provably ours — the exact configured install bin (`known_bin`), a
/// `…/StudioStud/bin` (or `…/studio-stud/bin`) directory, or a directory holding
/// a per-repo `studio-stud` shim. A path that merely *contains* the substring
/// "studio-stud" (e.g. an entry living under a similarly named user profile) is
/// left untouched, and the PATH is rewritten only when something actually matched.
pub fn uninstall_path_shim(known_bin: Option<&Path>) -> Result<()> {
    let Some(user_path) = read_user_path_registry() else {
        return Ok(());
    };
    let known = known_bin.map(|p| p.display().to_string());
    if let Some(new_path) = path_without_studio_stud(&user_path, known.as_deref()) {
        write_user_path_registry(&new_path);
    }
    Ok(())
}

/// Pure filter behind `uninstall_path_shim`: drop Studio Stud entries from a
/// `;`-separated PATH. Returns `Some(new_path)` only when an entry was removed,
/// so callers never rewrite an untouched PATH.
fn path_without_studio_stud(user_path: &str, known_bin: Option<&str>) -> Option<String> {
    let known = known_bin.map(norm_path_key);
    let segments: Vec<&str> = user_path.split(';').collect();
    let non_empty = segments.iter().filter(|p| !p.is_empty()).count();
    let kept: Vec<&str> = segments
        .into_iter()
        .filter(|p| !p.is_empty())
        .filter(|p| {
            let is_known = known
                .as_ref()
                .map(|k| &norm_path_key(p) == k)
                .unwrap_or(false);
            !(is_known || is_studio_stud_path_entry(p))
        })
        .collect();
    if kept.len() == non_empty {
        None
    } else {
        Some(kept.join(";"))
    }
}

/// Normalize a path string for case-insensitive equality (lowercase, forward
/// slashes folded to back, trailing separators trimmed). Textual only — never
/// touches the filesystem, so it works on already-deleted paths.
fn norm_path_key(s: &str) -> String {
    s.trim()
        .trim_end_matches(['\\', '/'])
        .replace('/', "\\")
        .to_lowercase()
}

/// Precise structural check for a Studio Stud install / shim bin directory.
/// Matches `…/StudioStud/bin` (or `…/studio-stud/bin`) by directory structure,
/// or any directory that holds a per-repo `studio-stud` shim. Crucially it does
/// NOT match on a loose substring, so unrelated entries are preserved.
fn is_studio_stud_path_entry(entry: &str) -> bool {
    let path = Path::new(entry.trim());
    let leaf_is_bin = path
        .file_name()
        .map(|n| n.eq_ignore_ascii_case("bin"))
        .unwrap_or(false);
    if leaf_is_bin
        && let Some(parent) = path.parent().and_then(Path::file_name)
    {
        let pl = parent.to_string_lossy().to_lowercase();
        if pl == "studiostud" || pl == "studio-stud" {
            return true;
        }
    }
    path.join("studio-stud.cmd").is_file() || path.join("studio-stud.exe").is_file()
}

#[cfg(windows)]
fn write_user_path_registry(new_path: &str) {
    // Write via .NET so the full value is preserved (setx truncates at 1024 chars)
    // and the change is broadcast to new processes. The value is passed through an
    // env var to avoid any quoting/escaping pitfalls.
    let _ = Command::new("powershell")
        .env("SS_NEW_PATH", new_path)
        .args([
            "-NoProfile",
            "-Command",
            "[Environment]::SetEnvironmentVariable('PATH', $env:SS_NEW_PATH, 'User')",
        ])
        .status();
}

#[cfg(not(windows))]
fn write_user_path_registry(_new_path: &str) {}

pub fn stop_daemon_graceful(write_token: &str, port: u16) -> Result<()> {
    let url = format!("http://127.0.0.1:{port}/studio-stud/admin/shutdown");
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(3)))
        .build()
        .into();
    let body = json!({ "token": write_token });
    let _ = agent.post(&url).send_json(body);
    for _ in 0..20 {
        if !daemon_lock_path().is_file() {
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    Ok(())
}

pub fn read_daemon_lock_port() -> Option<u16> {
    let text = fs::read_to_string(daemon_lock_path()).ok()?;
    let v: serde_json::Value = serde_json::from_str(&text).ok()?;
    v.get("port").and_then(|p| p.as_u64()).map(|p| p as u16)
}

pub fn migrate_legacy_repo(repo_root: &Path, cfg: &mut StudioStudConfig) -> Result<bool> {
    let legacy = repo_root.join(LEGACY_TOOL_DIR);
    if !legacy.is_dir() {
        return Ok(false);
    }
    super::config::register_repo(cfg, repo_root)?;
    fs::remove_dir_all(&legacy).ok();
    let _ = fs::remove_file(repo_root.join("studio-stud.ps1"));
    let _ = fs::remove_file(repo_root.join("studio-stud.cmd"));
    Ok(true)
}

pub fn list_bundled_addons(install_root: &Path) -> Result<Vec<(String, PathBuf)>> {
    let addons_dir = install_root.join("addons");
    if !addons_dir.is_dir() {
        return Ok(Vec::new());
    }
    let mut out = Vec::new();
    for entry in fs::read_dir(&addons_dir)? {
        let entry = entry?;
        if entry.file_type()?.is_dir() {
            let id = entry.file_name().to_string_lossy().to_string();
            let manifest = entry.path().join("addon.json");
            if manifest.is_file() {
                out.push((id, entry.path()));
            }
        }
    }
    Ok(out)
}

pub fn enable_addon(
    install_root: &Path,
    plugins_dir: &Path,
    repo_root: &Path,
    addon_id: &str,
) -> Result<()> {
    let src = install_root.join("addons").join(addon_id);
    if !src.join("addon.json").is_file() {
        return Err(anyhow!("unknown bundled addon: {addon_id}"));
    }
    let dest = plugins_dir.join(addon_id);
    if dest.exists() {
        fs::remove_dir_all(&dest).ok();
    }
    copy_dir_all(&src, &dest)?;
    let addon_cfg = repo_root
        .join(".studio-stud")
        .join("addons")
        .join(format!("{addon_id}.json"));
    fs::create_dir_all(addon_cfg.parent().unwrap())?;
    fs::write(&addon_cfg, json!({ "enabled": true, "addonId": addon_id }).to_string())?;
    Ok(())
}

pub fn disable_addon(plugins_dir: &Path, repo_root: &Path, addon_id: &str) -> Result<()> {
    let dest = plugins_dir.join(addon_id);
    if dest.is_dir() {
        fs::remove_dir_all(&dest)?;
    }
    let addon_cfg = repo_root
        .join(".studio-stud")
        .join("addons")
        .join(format!("{addon_id}.json"));
    if addon_cfg.is_file() {
        fs::remove_file(addon_cfg)?;
    }
    Ok(())
}

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

fn copy_dir_all(src: &Path, dst: &Path) -> Result<()> {
    fs::create_dir_all(dst)?;
    for entry in fs::read_dir(src)? {
        let entry = entry?;
        let ty = entry.file_type()?;
        let to = dst.join(entry.file_name());
        if ty.is_dir() {
            copy_dir_all(&entry.path(), &to)?;
        } else {
            fs::copy(entry.path(), to)?;
        }
    }
    Ok(())
}

pub fn copy_addon_payloads_from_repo(dev_repo: &Path, install_root: &Path) -> Result<()> {
    let src = dev_repo.join("addon-plugins");
    if !src.is_dir() {
        return Ok(());
    }
    let dest = install_root.join("addons");
    fs::create_dir_all(&dest)?;
    for entry in fs::read_dir(&src)? {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            continue;
        }
        let name = entry.file_name().to_string_lossy().to_string();
        if name.starts_with('_') || name == "sdk" {
            continue;
        }
        let to = dest.join(&name);
        if to.exists() {
            fs::remove_dir_all(&to).ok();
        }
        copy_dir_all(&entry.path(), &to)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn reconcile_repo_addons_lays_down_enabled_committed_addons() {
        let base = std::env::temp_dir().join(format!(
            "studio-stud-reconcile-{}",
            std::process::id()
        ));
        let install_root = base.join("install");
        let plugins_dir = base.join("plugins");
        let repo_root = base.join("repo");
        let addon_id = "boat-modification";

        fs::create_dir_all(install_root.join("addons").join(addon_id)).unwrap();
        fs::write(
            install_root
                .join("addons")
                .join(addon_id)
                .join("addon.json"),
            r#"{"id":"boat-modification"}"#,
        )
        .unwrap();
        fs::create_dir_all(repo_root.join(".studio-stud").join("addons")).unwrap();
        fs::write(
            repo_root
                .join(".studio-stud")
                .join("addons")
                .join(format!("{addon_id}.json")),
            json!({ "enabled": true, "addonId": addon_id }).to_string(),
        )
        .unwrap();
        fs::create_dir_all(&plugins_dir).unwrap();

        let enabled =
            reconcile_repo_addons(&install_root, &plugins_dir, &repo_root).unwrap();
        assert_eq!(enabled, vec![addon_id.to_string()]);
        assert!(plugins_dir.join(addon_id).join("addon.json").is_file());

        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn path_filter_strips_known_install_bin() {
        let p = r"C:\Windows;C:\Users\tyler\AppData\Local\Programs\StudioStud\bin;C:\Tools\bin";
        let out = path_without_studio_stud(
            p,
            Some(r"C:\Users\tyler\AppData\Local\Programs\StudioStud\bin"),
        )
        .unwrap();
        assert_eq!(out, r"C:\Windows;C:\Tools\bin");
    }

    #[test]
    fn path_filter_matches_default_layout_without_known_bin() {
        // Even without the configured path, the …/StudioStud/bin structure is recognized.
        let p = r"C:\Windows;C:\Users\me\AppData\Local\Programs\StudioStud\bin";
        assert_eq!(path_without_studio_stud(p, None).unwrap(), r"C:\Windows");
    }

    #[test]
    fn path_filter_preserves_lookalike_username() {
        // A profile literally named "studiostud" must not drag unrelated entries out.
        let p = r"C:\Users\studiostud\AppData\Local\OtherTool\bin;C:\Windows";
        assert!(path_without_studio_stud(p, None).is_none());
    }

    #[test]
    fn path_filter_returns_none_when_absent() {
        let p = r"C:\Windows;C:\Tools\bin";
        assert!(path_without_studio_stud(p, None).is_none());
    }

    #[test]
    fn path_filter_handles_custom_install_location() {
        // Custom install root: matched only via the known-bin path, not structure.
        let p = r"D:\apps\StudioStudCustom\bin;C:\Windows";
        let out = path_without_studio_stud(p, Some(r"D:\apps\StudioStudCustom\bin")).unwrap();
        assert_eq!(out, r"C:\Windows");
    }
}
