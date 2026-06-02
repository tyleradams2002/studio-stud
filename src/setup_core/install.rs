use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use anyhow::{Result, anyhow};
use serde_json::json;

use super::config::{StudioStudConfig, daemon_lock_path};

pub const LEGACY_TOOL_DIR: &str = ".studio-stud-tool";
pub const REPO_MARKER: &str = ".studio-stud/.installed";

pub fn default_install_root() -> PathBuf {
    dirs::data_local_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("Programs")
        .join("StudioStud")
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

pub fn lay_tool_payload(install_root: &Path, daemon_exe: &Path, plugin_lua: &Path) -> Result<()> {
    let bin_dir = install_root.join("bin");
    let plugin_dir = install_root.join("plugin");
    fs::create_dir_all(&bin_dir)?;
    fs::create_dir_all(&plugin_dir)?;
    fs::create_dir_all(install_root.join("addons"))?;
    fs::copy(daemon_exe, bin_dir.join("studio-stud.exe"))?;
    fs::copy(plugin_lua, plugin_dir.join("StudioStud.plugin.lua"))?;
    let version = json!({
        "daemonVersion": env!("CARGO_PKG_VERSION"),
        "installedAt": crate::util::now_utc(),
    });
    fs::write(
        install_root.join("version.json"),
        serde_json::to_string_pretty(&version)?,
    )?;
    Ok(())
}

pub fn install_core_plugin(plugins_dir: &Path, plugin_src: &Path) -> Result<()> {
    fs::create_dir_all(plugins_dir)?;
    fs::copy(
        plugin_src,
        plugins_dir.join("StudioStud.plugin.lua"),
    )?;
    Ok(())
}

pub fn write_starter_policy(repo_root: &Path) -> Result<()> {
    let policy_dir = repo_root.join(".studio-stud");
    let policy_path = policy_dir.join("policy.json");
    if policy_path.is_file() {
        return Ok(());
    }
    fs::create_dir_all(&policy_dir)?;
    let starter = json!({
        "version": 1,
        "allowedPlaceIds": [],
        "allowedWritePaths": [],
        "requireGeneratedHeaderPaths": [],
        "maxPatchBytes": 1048576,
        "maxPatchItems": 500,
        "maxDeleteCount": 50,
    });
    fs::write(&policy_path, serde_json::to_string_pretty(&starter)?)?;
    fs::write(repo_root.join(REPO_MARKER), crate::util::now_utc())?;
    Ok(())
}

pub fn install_path_shim(install_root: &Path) -> Result<()> {
    let bin = install_root.join("bin");
    if let Ok(path) = std::env::var("PATH") {
        let bin_str = bin.display().to_string();
        if !path.split(';').any(|p| p.eq_ignore_ascii_case(&bin_str)) {
            let new_path = if path.is_empty() {
                bin_str
            } else {
                format!("{bin_str};{path}")
            };
            // User PATH via setx is best-effort; installer prints reminder
            let _ = Command::new("setx")
                .args(["PATH", &new_path])
                .status();
        }
    }
    Ok(())
}

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
