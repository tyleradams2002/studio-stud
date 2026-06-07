use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde_json::{Map, Value, json};
use studio_stud::setup_core::channels::last_channel_sequence_json;
use studio_stud::setup_core::config::{
    StudioStudConfig, load_config_or_default, populate_install_fields, register_repo, save_config,
    store_channel_key_if_encrypted,
};
use studio_stud::setup_core::install::{
    copy_addon_payloads_from_repo, install_core_plugin, install_path_shim, lay_tool_payload,
    migrate_legacy_repo, write_starter_policy,
};

use crate::legacy_cleanup;

pub struct HeadlessInstallParams {
    pub install_root: PathBuf,
    pub plugins_dir: PathBuf,
    pub daemon_src: PathBuf,
    pub plugin_src: PathBuf,
    pub repo_paths: Vec<String>,
    /// When set, overwrites the saved channel (GUI fresh install). When None, preserves config.
    pub channel: Option<String>,
    pub daemon_version: String,
    pub plugin_version: String,
    pub install_repos: bool,
}

pub fn run_install_headless(params: &HeadlessInstallParams) -> Result<()> {
    let repo_paths: Vec<String> = params.repo_paths.clone();
    legacy_cleanup::run_legacy_cleanup(false, &params.install_root, &repo_paths)?;

    let version_meta = install_version_json(
        &params.daemon_version,
        &params.plugin_version,
        params.channel.as_deref(),
        None,
    );
    lay_tool_payload(
        &params.install_root,
        &params.daemon_src,
        &params.plugin_src,
        &version_meta,
    )?;
    if let Ok(dev_repo) = std::env::current_dir() {
        copy_addon_payloads_from_repo(&dev_repo, &params.install_root).ok();
    }
    install_core_plugin(&params.plugins_dir, &params.plugin_src)?;
    install_path_shim(&params.install_root)?;

    let mut cfg = load_config_or_default();
    let channel = params
        .channel
        .clone()
        .unwrap_or_else(|| cfg.channel.clone());
    populate_install_fields(
        &mut cfg,
        &params.install_root,
        &params.plugins_dir,
        &channel,
        env!("CARGO_PKG_VERSION"),
        &params.daemon_version,
        &params.plugin_version,
    );
    // Persist the channel password so self-update can decrypt the bundle later. install.ps1
    // captures the password and forwards it via this env var; both the GUI and silent install
    // paths funnel through here, so this is the single seam that needs it.
    let channel_password = std::env::var("STUDIO_STUD_CHANNEL_PASSWORD").ok();
    store_channel_key_if_encrypted(&mut cfg, &channel, channel_password.as_deref())?;
    if params.install_repos {
        for r in &params.repo_paths {
            let p = PathBuf::from(r);
            register_repo(&mut cfg, &p)?;
            write_starter_policy(&p, &cfg.channel)?;
            let _ = migrate_legacy_repo(&p, &mut cfg);
        }
    }
    // Record the installed build's channelSequence when install.ps1 forwards it; otherwise
    // fall through to the offline-safe baseline fetch (unchanged repair/reinstall behavior).
    let channel_sequence = std::env::var("STUDIO_STUD_CHANNEL_SEQUENCE").ok();
    if !studio_stud::setup_core::channels::record_install_sequence_from_env(
        &mut cfg,
        &channel,
        channel_sequence.as_deref(),
    ) {
        studio_stud::setup_core::channels::record_install_baseline_seq(&mut cfg);
    }
    sync_version_json_channel(&params.install_root, &cfg)?;
    save_config(&cfg)?;
    Ok(())
}

pub fn run_update_headless(
    cfg: &StudioStudConfig,
    daemon_src: &Path,
    plugin_src: &Path,
    daemon_version: &str,
    plugin_version: &str,
    channel: &str,
    last_channel_sequence: &Map<String, Value>,
) -> Result<()> {
    let install_root = PathBuf::from(&cfg.install_root);
    let plugins_dir = PathBuf::from(&cfg.plugins_dir);
    let version_meta = install_version_json(
        daemon_version,
        plugin_version,
        Some(channel),
        Some(last_channel_sequence),
    );
    lay_tool_payload(&install_root, daemon_src, plugin_src, &version_meta)?;
    install_core_plugin(&plugins_dir, plugin_src)?;
    install_path_shim(&install_root)?;
    let mut updated = cfg.clone();
    updated.versions.daemon = daemon_version.to_string();
    updated.versions.plugin = plugin_version.to_string();
    sync_version_json_channel(&install_root, &updated)?;
    save_config(&updated)?;
    Ok(())
}

pub fn install_version_json(
    daemon_version: &str,
    plugin_version: &str,
    channel: Option<&str>,
    last_channel_sequence: Option<&Map<String, Value>>,
) -> Value {
    let mut obj = json!({
        "daemonVersion": daemon_version,
        "pluginVersion": plugin_version,
        "installedAt": studio_stud::util::now_utc(),
    });
    if let Some(ch) = channel {
        obj["channel"] = json!(ch);
    }
    if let Some(seq) = last_channel_sequence {
        obj["lastChannelSequence"] = Value::Object(seq.clone());
    }
    obj
}

fn sync_version_json_channel(install_root: &Path, cfg: &StudioStudConfig) -> Result<()> {
    let path = install_root.join("version.json");
    let mut v: Value = if path.is_file() {
        serde_json::from_str(&std::fs::read_to_string(&path).with_context(|| {
            format!("read {}", path.display())
        })?)
        .with_context(|| format!("parse {}", path.display()))?
    } else {
        json!({})
    };
    let obj = v.as_object_mut().ok_or_else(|| anyhow::anyhow!("version.json not an object"))?;
    obj.insert("channel".into(), json!(cfg.channel));
    obj.insert(
        "lastChannelSequence".into(),
        Value::Object(last_channel_sequence_json(cfg)),
    );
    std::fs::write(path, serde_json::to_string_pretty(&v)?)?;
    Ok(())
}

pub fn resolve_daemon_src() -> Option<PathBuf> {
    let mut candidates = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            candidates.push(dir.join("studio-stud.exe"));
            candidates.push(dir.join("..").join("studio-stud.exe"));
            candidates.push(dir.join("..").join("bin").join("studio-stud.exe"));
        }
    }
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..");
    candidates.push(root.join("bin").join("studio-stud.exe"));
    candidates.push(root.join("target").join("debug").join("studio-stud.exe"));
    candidates.push(root.join("target").join("release").join("studio-stud.exe"));
    candidates.into_iter().find(|p| p.is_file())
}

pub fn resolve_plugin_src() -> Option<PathBuf> {
    let mut candidates = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            candidates.push(dir.join("StudioStud.plugin.lua"));
            candidates.push(dir.join("..").join("plugin").join("StudioStud.plugin.lua"));
        }
    }
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..");
    candidates.push(root.join("plugin").join("StudioStud.plugin.lua"));
    candidates.into_iter().find(|p| p.is_file())
}
