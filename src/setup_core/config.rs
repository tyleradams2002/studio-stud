use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::install::default_install_root;

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

pub fn backup_corrupt_config(path: &Path, text: &str) -> Result<()> {
    let stamp = crate::util::now_utc().replace([':', 'T', 'Z'], "");
    let backup = path.with_extension(format!("json.corrupt-{stamp}"));
    fs::write(&backup, text).with_context(|| format!("backup corrupt config to {}", backup.display()))?;
    eprintln!(
        "Studio Stud: config at {} was corrupt — backed up to {}",
        path.display(),
        backup.display()
    );
    Ok(())
}

fn install_version_json_path(cfg: &StudioStudConfig) -> PathBuf {
    if cfg.install_root.is_empty() {
        default_install_root().join("version.json")
    } else {
        PathBuf::from(&cfg.install_root).join("version.json")
    }
}

pub fn seed_config_from_install_version(cfg: &mut StudioStudConfig) {
    let path = install_version_json_path(cfg);
    let Ok(text) = fs::read_to_string(&path) else {
        return;
    };
    let Ok(v) = serde_json::from_str::<Value>(&text) else {
        return;
    };
    if let Some(ch) = v.get("channel").and_then(Value::as_str)
        && !ch.is_empty()
    {
        cfg.channel = ch.to_string();
    }
    if let Some(seq) = v.get("lastChannelSequence").and_then(Value::as_object) {
        for (k, val) in seq {
            cfg.last_channel_sequence.insert(k.clone(), val.clone());
        }
    }
}

pub fn load_config() -> Result<Option<StudioStudConfig>> {
    let path = config_path();
    if !path.is_file() {
        return Ok(None);
    }
    let text = fs::read_to_string(&path).with_context(|| format!("read {}", path.display()))?;
    match serde_json::from_str::<StudioStudConfig>(&text) {
        Ok(cfg) => Ok(Some(cfg)),
        Err(err) => {
            let _ = backup_corrupt_config(&path, &text);
            Err(err).with_context(|| format!("parse {}", path.display()))
        }
    }
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
    match load_config() {
        Ok(Some(cfg)) => cfg,
        Ok(None) => {
            let mut cfg = StudioStudConfig::default();
            seed_config_from_install_version(&mut cfg);
            cfg
        }
        Err(err) => {
            eprintln!("Studio Stud: using default config ({err:#})");
            let mut cfg = StudioStudConfig::default();
            seed_config_from_install_version(&mut cfg);
            cfg
        }
    }
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

    #[test]
    fn seed_config_from_install_version_restores_channel() {
        let dir = std::env::temp_dir().join(format!("ss-config-seed-{}", std::process::id()));
        let _ = fs::create_dir_all(&dir);
        fs::write(
            dir.join("version.json"),
            r#"{"channel":"beta","lastChannelSequence":{"beta":3}}"#,
        )
        .unwrap();
        let mut cfg = StudioStudConfig {
            install_root: dir.display().to_string(),
            ..Default::default()
        };
        seed_config_from_install_version(&mut cfg);
        assert_eq!(cfg.channel, "beta");
        assert_eq!(cfg.last_channel_sequence["beta"], json!(3));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn backup_corrupt_config_writes_sidecar() {
        let dir = std::env::temp_dir().join(format!("ss-config-backup-{}", std::process::id()));
        let _ = fs::create_dir_all(&dir);
        let path = dir.join("config.json");
        fs::write(&path, "{not json").unwrap();
        backup_corrupt_config(&path, "{not json").unwrap();
        let backups: Vec<_> = fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().contains("corrupt"))
            .collect();
        assert_eq!(backups.len(), 1);
        let _ = fs::remove_dir_all(&dir);
    }
}
