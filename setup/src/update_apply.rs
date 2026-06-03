//! Download channel bundle artifacts and apply an update via headless install.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, anyhow};
use studio_stud::setup_core::channels::{
    Channel, ChannelManifest, bundle_artifact_url, check_anti_rollback,
    fetch_manifest_with_fallback, record_channel_sequence, verify_manifest_signature,
};
use studio_stud::setup_core::config::{StudioStudConfig, save_config};
use studio_stud::setup_core::crypto::{channel_decrypt, dpapi_unprotect};
use studio_stud::setup_core::install::{read_daemon_lock_port, stop_daemon_graceful};
use studio_stud::setup_core::config::write_token_path;
use studio_stud::update;

use crate::install_flow::run_update_headless;

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
        anyhow!("channel password not stored — reinstall via install-beta.ps1 / install-dev.ps1")
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
