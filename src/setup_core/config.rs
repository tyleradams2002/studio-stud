use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct VersionsInfo {
    #[serde(default)]
    pub setup: String,
    #[serde(default)]
    pub daemon: String,
    #[serde(default)]
    pub plugin: String,
    #[serde(default)]
    pub protocol: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RepoEntry {
    pub path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub place_id: Option<i64>,
    #[serde(default)]
    pub enabled_addons: Vec<String>,
    #[serde(default)]
    pub registered_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct StudioStudConfig {
    #[serde(default)]
    pub install_root: String,
    #[serde(default)]
    pub plugins_dir: String,
    #[serde(default = "default_channel")]
    pub channel: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub channel_key_dpapi: Option<String>,
    #[serde(default)]
    pub path_shim_installed: bool,
    #[serde(default)]
    pub repos: Vec<RepoEntry>,
    #[serde(default)]
    pub versions: VersionsInfo,
    #[serde(default)]
    pub last_channel_sequence: Map<String, Value>,
}

fn default_channel() -> String {
    "release".to_string()
}

pub fn config_dir() -> PathBuf {
    dirs::data_local_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("StudioStud")
}

pub fn config_path() -> PathBuf {
    if let Ok(path) = std::env::var("STUDIO_STUD_CONFIG") {
        return PathBuf::from(path);
    }
    config_dir().join("config.json")
}

pub fn daemon_lock_path() -> PathBuf {
    config_dir().join("daemon.lock")
}

/// Same location as `load_or_create_write_token` in the daemon (`%LOCALAPPDATA%/StudioStud/write.token`).
pub fn write_token_path() -> PathBuf {
    config_dir().join("write.token")
}

pub fn load_config() -> Result<Option<StudioStudConfig>> {
    let path = config_path();
    if !path.is_file() {
        return Ok(None);
    }
    let text = fs::read_to_string(&path).with_context(|| format!("read {}", path.display()))?;
    let cfg: StudioStudConfig =
        serde_json::from_str(&text).with_context(|| format!("parse {}", path.display()))?;
    Ok(Some(cfg))
}

pub fn save_config(cfg: &StudioStudConfig) -> Result<()> {
    let dir = config_dir();
    fs::create_dir_all(&dir)?;
    let path = config_path();
    let tmp = path.with_extension("json.tmp");
    let text = serde_json::to_string_pretty(cfg)?;
    fs::write(&tmp, &text)?;
    fs::rename(&tmp, &path)?;
    Ok(())
}

pub fn load_config_or_default() -> StudioStudConfig {
    load_config().ok().flatten().unwrap_or_default()
}

/// Register a repo path if not already present (normalized forward slashes).
pub fn register_repo(cfg: &mut StudioStudConfig, path: &Path) -> Result<bool> {
    let canon = path
        .canonicalize()
        .unwrap_or_else(|_| path.to_path_buf());
    let key = canon.display().to_string();
    if cfg.repos.iter().any(|r| r.path.eq_ignore_ascii_case(&key)) {
        return Ok(false);
    }
    cfg.repos.push(RepoEntry {
        path: key,
        place_id: None,
        enabled_addons: Vec::new(),
        registered_at: crate::util::now_utc(),
    });
    save_config(cfg)?;
    Ok(true)
}

pub fn write_daemon_lock(pid: u32, port: u16) -> Result<()> {
    let dir = config_dir();
    fs::create_dir_all(&dir)?;
    let payload = json!({ "pid": pid, "port": port, "startedAt": crate::util::now_utc() });
    fs::write(daemon_lock_path(), serde_json::to_string_pretty(&payload)?)?;
    Ok(())
}

pub fn remove_daemon_lock() -> Result<()> {
    let path = daemon_lock_path();
    if path.is_file() {
        fs::remove_file(path)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_round_trip_serde() {
        let cfg = StudioStudConfig {
            install_root: "C:/Programs/StudioStud".into(),
            plugins_dir: "C:/Roblox/Plugins".into(),
            channel: "release".into(),
            repos: vec![RepoEntry {
                path: "C:/repos/game".into(),
                place_id: Some(123),
                enabled_addons: vec!["boat-modification".into()],
                registered_at: "2026-01-01T00:00:00Z".into(),
            }],
            ..Default::default()
        };
        let text = serde_json::to_string(&cfg).unwrap();
        let back: StudioStudConfig = serde_json::from_str(&text).unwrap();
        assert_eq!(back.repos[0].place_id, Some(123));
    }
}
