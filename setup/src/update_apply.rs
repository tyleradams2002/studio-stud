//! Download channel bundle artifacts and apply an update via headless install.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, anyhow};
use serde_json::Value;
use studio_stud::setup_core::channels::{
    Channel, ChannelManifest, bundle_artifact_url, check_anti_rollback,
    fetch_manifest_with_fallback, record_channel_sequence, verify_manifest_signature,
};
use studio_stud::setup_core::config::{StudioStudConfig, save_config, write_token_path};
use studio_stud::setup_core::crypto::{channel_decrypt, dpapi_unprotect};
use studio_stud::setup_core::install::{
    canonical_daemon_exe, install_core_plugin, read_daemon_lock_port, stop_daemon_graceful,
};
use studio_stud::update;

use crate::install_flow::{run_update_headless, stage_version_json};

pub fn apply_channel_update(
    cfg: &StudioStudConfig,
    manifest: &ChannelManifest,
    resolved: Channel,
) -> Result<()> {
    stop_running_daemon(cfg)?;

    let (daemon_path, plugin_path) = download_extract_bundle_paths(cfg, manifest, resolved)?;

    let mut updated_cfg = cfg.clone();
    record_channel_sequence(&mut updated_cfg, resolved, manifest.channel_sequence);
    run_update_headless(
        &updated_cfg,
        &daemon_path,
        &plugin_path,
        &manifest.daemon_version,
        &manifest.plugin_version,
        resolved.as_str(),
        &updated_cfg.last_channel_sequence,
    )?;
    save_config(&updated_cfg)?;
    Ok(())
}

/// Download + stage a channel update for the running daemon to apply via `apply_staged_on_boot`.
/// Does not stop the daemon — the caller is the running process.
pub fn stage_channel_update(
    cfg: &StudioStudConfig,
    manifest: &ChannelManifest,
    resolved: Channel,
) -> Result<()> {
    let (daemon_path, plugin_path) = download_extract_bundle_paths(cfg, manifest, resolved)?;

    let install_root = PathBuf::from(&cfg.install_root);
    let plugins_dir = PathBuf::from(&cfg.plugins_dir);
    let current_daemon = read_installed_daemon_version(&install_root);

    let mut updated_cfg = cfg.clone();
    record_channel_sequence(&mut updated_cfg, resolved, manifest.channel_sequence);

    let version_meta = stage_version_json(
        &current_daemon,
        &manifest.daemon_version,
        &manifest.plugin_version,
        Some(resolved.as_str()),
        Some(&updated_cfg.last_channel_sequence),
    );
    stage_files(
        &install_root,
        &plugins_dir,
        &daemon_path,
        &plugin_path,
        &version_meta,
    )?;
    save_config(&updated_cfg)?;
    Ok(())
}

/// Lay staged daemon exe, overwrite plugin, and write version.json (no network).
pub fn stage_files(
    install_root: &Path,
    plugins_dir: &Path,
    daemon_src: &Path,
    plugin_src: &Path,
    version_meta: &Value,
) -> Result<()> {
    let exe = canonical_daemon_exe(install_root);
    let staged = update::staged_exe_path(&exe);
    if let Some(parent) = staged.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::copy(daemon_src, &staged)?;
    install_core_plugin(plugins_dir, plugin_src)?;
    fs::write(
        install_root.join("version.json"),
        serde_json::to_string_pretty(version_meta)?,
    )?;
    Ok(())
}

fn read_installed_daemon_version(install_root: &Path) -> String {
    let path = install_root.join("version.json");
    if let Ok(text) = fs::read_to_string(&path) {
        if let Ok(v) = serde_json::from_str::<Value>(&text) {
            if let Some(dv) = v.get("daemonVersion").and_then(Value::as_str) {
                return dv.to_string();
            }
        }
    }
    update::current_daemon_version().to_string()
}

/// Fetch the channel bundle from the manifest, download (decrypt on beta/dev), extract, and return
/// daemon + plugin paths for a fresh install when no local siblings exist.
pub fn fetch_channel_bundle(cfg: &StudioStudConfig) -> Result<(PathBuf, PathBuf)> {
    let requested = Channel::from_str(&cfg.channel);
    let (manifest, raw, resolved) = fetch_manifest_with_fallback(requested)?;
    verify_manifest_signature(&raw, &manifest)?;
    check_anti_rollback(resolved, &manifest, &cfg.last_channel_sequence)?;
    download_extract_bundle_paths(cfg, &manifest, resolved)
}

fn download_extract_bundle_paths(
    cfg: &StudioStudConfig,
    manifest: &ChannelManifest,
    resolved: Channel,
) -> Result<(PathBuf, PathBuf)> {
    let temp = std::env::temp_dir().join(format!("studio-stud-update-{}", std::process::id()));
    let extract = temp.join("bundle");
    let _ = fs::remove_dir_all(&temp);
    fs::create_dir_all(&extract).with_context(|| format!("create {}", extract.display()))?;

    let url = bundle_artifact_url(resolved, manifest)?;
    let zip_path = temp.join("bundle.zip");
    if resolved.is_encrypted() {
        let enc = temp.join("bundle.zip.enc");
        update::download_to(&url, &enc)?;
        let password = channel_password(cfg)?;
        let blob = fs::read(&enc)?;
        let plain = channel_decrypt(&password, &blob).map_err(|_| {
            anyhow!(
                "could not decrypt channel bundle — reinstall via your channel installer"
            )
        })?;
        fs::write(&zip_path, plain)?;
    } else {
        update::download_to(&url, &zip_path)?;
    }
    extract_zip(&zip_path, &extract)?;

    let daemon_path = extract.join("studio-stud.exe");
    let plugin_path = extract.join("StudioStud.plugin.lua");
    if !daemon_path.is_file() || !plugin_path.is_file() {
        return Err(anyhow!("bundle missing studio-stud.exe or StudioStud.plugin.lua"));
    }
    Ok((daemon_path, plugin_path))
}

fn channel_password(cfg: &StudioStudConfig) -> Result<String> {
    let dpapi = cfg.channel_key_dpapi.as_deref().ok_or_else(|| {
        anyhow!("channel password not stored — reinstall via install-dev.ps1")
    })?;
    String::from_utf8(dpapi_unprotect(dpapi)?)
        .map_err(|_| anyhow!("stored channel password is invalid"))
}

fn extract_zip(zip_path: &Path, dest: &Path) -> Result<()> {
    let file = fs::File::open(zip_path)?;
    let mut archive = zip::ZipArchive::new(file)?;
    archive.extract(dest)?;
    Ok(())
}

fn stop_running_daemon(_cfg: &StudioStudConfig) -> Result<()> {
    if let Some(port) = read_daemon_lock_port() {
        let token_path = write_token_path();
        if token_path.is_file()
            && let Ok(tok) = fs::read_to_string(&token_path)
        {
            let _ = stop_daemon_graceful(tok.trim(), port);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use studio_stud::setup_core::channels::record_channel_sequence;

    fn temp_base(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "studio-stud-stage-{name}-{}",
            std::process::id()
        ))
    }

    #[test]
    fn stage_files_lays_staged_exe_plugin_and_version_json() {
        let base = temp_base("files");
        let install_root = base.join("install");
        let plugins_dir = base.join("plugins");
        let bin_dir = install_root.join("bin");
        fs::create_dir_all(&bin_dir).unwrap();
        fs::create_dir_all(&plugins_dir).unwrap();

        let running_exe = bin_dir.join("studio-stud.exe");
        fs::write(&running_exe, b"running-daemon").unwrap();
        let old_plugin = plugins_dir.join("StudioStud.plugin.lua");
        fs::write(&old_plugin, b"old-plugin").unwrap();

        let daemon_src = base.join("new-daemon.exe");
        let plugin_src = base.join("new-plugin.lua");
        fs::write(&daemon_src, b"new-daemon").unwrap();
        fs::write(&plugin_src, b"new-plugin").unwrap();

        let mut cfg = StudioStudConfig::default();
        record_channel_sequence(&mut cfg, Channel::Release, 42);
        let version_meta = stage_version_json(
            "0.4.24",
            "0.4.25",
            "0.4.25",
            Some("release"),
            Some(&cfg.last_channel_sequence),
        );

        stage_files(
            &install_root,
            &plugins_dir,
            &daemon_src,
            &plugin_src,
            &version_meta,
        )
        .unwrap();

        let staged = update::staged_exe_path(&running_exe);
        assert!(staged.is_file());
        assert_eq!(fs::read(&staged).unwrap(), b"new-daemon");
        assert_eq!(fs::read(&running_exe).unwrap(), b"running-daemon");
        assert_eq!(fs::read(&old_plugin).unwrap(), b"new-plugin");

        let v: Value =
            serde_json::from_str(&fs::read_to_string(install_root.join("version.json")).unwrap())
                .unwrap();
        assert_eq!(v.get("daemonVersion").and_then(Value::as_str), Some("0.4.24"));
        assert_eq!(
            v.get("stagedDaemonVersion").and_then(Value::as_str),
            Some("0.4.25")
        );
        assert_eq!(v.get("pluginVersion").and_then(Value::as_str), Some("0.4.25"));

        let _ = fs::remove_dir_all(&base);
    }
}
