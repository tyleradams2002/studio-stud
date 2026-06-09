use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::channels::Channel;
use super::crypto::dpapi_protect;
use super::install::default_install_root;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
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

/// Fill install paths, channel, and version metadata after a successful install.
pub fn populate_install_fields(
    cfg: &mut StudioStudConfig,
    install_root: &Path,
    plugins_dir: &Path,
    channel: &str,
    setup_version: &str,
    daemon_version: &str,
    plugin_version: &str,
) {
    cfg.install_root = install_root.display().to_string();
    cfg.plugins_dir = plugins_dir.display().to_string();
    if !channel.is_empty() {
        cfg.channel = channel.to_string();
    }
    cfg.versions.setup = setup_version.to_string();
    cfg.versions.daemon = daemon_version.to_string();
    cfg.versions.plugin = plugin_version.to_string();
    cfg.versions.protocol = crate::util::PROTOCOL_VERSION.to_string();
}

/// Store the channel decryption password (DPAPI-protected) so self-update can decrypt the
/// bundle later. No-op for the unencrypted `release` channel or when no password is supplied
/// (so reinstall/repair without a password preserves any previously stored key).
pub fn store_channel_key_if_encrypted(
    cfg: &mut StudioStudConfig,
    channel: &str,
    password: Option<&str>,
) -> Result<()> {
    if let Some(pw) = password.filter(|p| !p.is_empty()) {
        if Channel::from_str(channel).is_encrypted() {
            cfg.channel_key_dpapi = Some(dpapi_protect(pw.as_bytes())?);
        }
    }
    Ok(())
}

/// Infer global install root from a daemon running at `{installRoot}/bin/studio-stud.exe`.
pub fn infer_install_root_from_exe() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let bin_dir = exe.parent()?;
    if bin_dir.file_name().and_then(|n| n.to_str()) == Some("bin") {
        return bin_dir.parent().map(Path::to_path_buf);
    }
    None
}

pub fn read_install_version_channel(cfg: &StudioStudConfig) -> Option<String> {
    let path = install_version_json_path(cfg);
    let text = fs::read_to_string(&path).ok()?;
    let v: Value = serde_json::from_str(&text).ok()?;
    v.get("channel")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

/// Channel for `update --check`: explicit CLI flag > config > install version.json > release.
pub fn resolve_update_channel(
    explicit: Option<&str>,
    cfg: &StudioStudConfig,
    version_json_channel: Option<&str>,
) -> String {
    if let Some(ch) = explicit.filter(|s| !s.is_empty()) {
        return ch.to_string();
    }
    if !cfg.channel.is_empty() {
        return cfg.channel.clone();
    }
    if let Some(ch) = version_json_channel.filter(|s| !s.is_empty()) {
        return ch.to_string();
    }
    default_channel()
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
    seed_versions_from_install_version(cfg, &v);
}

fn seed_versions_from_install_version(cfg: &mut StudioStudConfig, v: &Value) {
    if cfg.versions.daemon.is_empty() {
        if let Some(s) = v.get("daemonVersion").and_then(Value::as_str) {
            cfg.versions.daemon = s.to_string();
        }
    }
    if cfg.versions.plugin.is_empty() {
        if let Some(s) = v.get("pluginVersion").and_then(Value::as_str) {
            cfg.versions.plugin = s.to_string();
        }
    }
    if cfg.versions.protocol.is_empty() {
        cfg.versions.protocol = crate::util::PROTOCOL_VERSION.to_string();
    }
    if cfg.versions.setup.is_empty() {
        cfg.versions.setup = env!("CARGO_PKG_VERSION").to_string();
    }
}

/// Backfill empty install paths and channel/versions from on-disk install metadata.
pub fn self_heal_config_on_serve(cfg: &mut StudioStudConfig) -> bool {
    let mut changed = false;
    if cfg.install_root.is_empty() {
        if let Some(root) = infer_install_root_from_exe() {
            cfg.install_root = root.display().to_string();
            changed = true;
        }
    }
    if cfg.plugins_dir.is_empty() {
        cfg.plugins_dir = super::install::default_plugins_dir().display().to_string();
        changed = true;
    }
    let before_channel = cfg.channel.clone();
    let before_versions = cfg.versions.clone();
    let before_seq = cfg.last_channel_sequence.clone();
    seed_config_from_install_version(cfg);
    if cfg.channel != before_channel
        || cfg.versions != before_versions
        || cfg.last_channel_sequence != before_seq
    {
        changed = true;
    }
    changed
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
    fn populate_install_fields_fills_all() {
        let mut cfg = StudioStudConfig::default();
        populate_install_fields(
            &mut cfg,
            Path::new("C:/Programs/StudioStud"),
            Path::new("C:/Roblox/Plugins"),
            "dev",
            "0.5.1",
            "0.5.1",
            "0.5.1",
        );
        assert!(!cfg.install_root.is_empty());
        assert!(!cfg.plugins_dir.is_empty());
        assert_eq!(cfg.channel, "dev");
        assert_eq!(cfg.versions.setup, "0.5.1");
        assert_eq!(cfg.versions.daemon, "0.5.1");
        assert_eq!(cfg.versions.plugin, "0.5.1");
        assert!(!cfg.versions.protocol.is_empty());
    }

    #[test]
    fn populate_install_fields_records_live_versions() {
        let mut cfg = StudioStudConfig::default();
        populate_install_fields(
            &mut cfg,
            Path::new("C:/Programs/StudioStud"),
            Path::new("C:/Roblox/Plugins"),
            "release",
            env!("CARGO_PKG_VERSION"),
            env!("CARGO_PKG_VERSION"),
            "0.5.1",
        );
        assert_eq!(cfg.versions.setup, env!("CARGO_PKG_VERSION"));
        assert_eq!(cfg.versions.daemon, env!("CARGO_PKG_VERSION"));
        assert_eq!(cfg.versions.plugin, "0.5.1");
    }

    #[test]
    fn store_channel_key_persists_for_encrypted_channel() {
        let mut cfg = StudioStudConfig::default();
        store_channel_key_if_encrypted(&mut cfg, "dev", Some("hunter2")).unwrap();
        let stored = cfg
            .channel_key_dpapi
            .expect("key should be stored for an encrypted channel");
        let plain = crate::setup_core::crypto::dpapi_unprotect(&stored).unwrap();
        assert_eq!(plain, b"hunter2");
    }

    #[test]
    fn store_channel_key_skips_release_channel() {
        let mut cfg = StudioStudConfig::default();
        store_channel_key_if_encrypted(&mut cfg, "release", Some("hunter2")).unwrap();
        assert!(cfg.channel_key_dpapi.is_none());
    }

    #[test]
    fn store_channel_key_preserves_existing_when_no_password() {
        let mut cfg = StudioStudConfig {
            channel_key_dpapi: Some("existing".into()),
            ..Default::default()
        };
        store_channel_key_if_encrypted(&mut cfg, "dev", None).unwrap();
        assert_eq!(cfg.channel_key_dpapi.as_deref(), Some("existing"));
    }

    #[test]
    fn store_channel_key_skips_empty_string_password() {
        let mut cfg = StudioStudConfig::default();
        store_channel_key_if_encrypted(&mut cfg, "dev", Some("")).unwrap();
        assert!(cfg.channel_key_dpapi.is_none());
    }

    #[test]
    fn store_channel_key_persists_for_beta_channel() {
        let mut cfg = StudioStudConfig::default();
        store_channel_key_if_encrypted(&mut cfg, "beta", Some("s3cret")).unwrap();
        let stored = cfg
            .channel_key_dpapi
            .expect("key should be stored for the beta channel");
        let plain = crate::setup_core::crypto::dpapi_unprotect(&stored).unwrap();
        assert_eq!(plain, b"s3cret");
    }

    #[test]
    fn resolve_update_channel_precedence() {
        let cfg = StudioStudConfig {
            channel: "dev".into(),
            ..Default::default()
        };
        assert_eq!(
            resolve_update_channel(Some("beta"), &cfg, Some("release")),
            "beta"
        );
        assert_eq!(resolve_update_channel(None, &cfg, Some("release")), "dev");
        let empty_cfg = StudioStudConfig {
            channel: String::new(),
            ..Default::default()
        };
        assert_eq!(
            resolve_update_channel(None, &empty_cfg, Some("dev")),
            "dev"
        );
        assert_eq!(resolve_update_channel(None, &empty_cfg, None), "release");
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
