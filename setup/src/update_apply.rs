//! Download channel artifacts and apply an update via headless install.
//!
//! Option B: the setup binary downloads `binaryUrl` + `pluginUrl` from the signed channel
//! manifest and lays them down directly (the release `studio-stud-setup.exe` artifact does not
//! bundle daemon/plugin files).
//!
//! MANUAL SMOKE TEST (Windows, with channel secrets published):
//! 1. Install via install-beta.ps1 or install.ps1 on a channel.
//! 2. Push a newer build to that channel; run `studio-stud-setup update --check`.
//! 3. Run `studio-stud-setup update` and confirm `%LOCALAPPDATA%\Programs\StudioStud\bin\`
//!    reflects the new daemon version.

use std::fs;
use std::path::PathBuf;

use anyhow::{Context, Result, anyhow};
use studio_stud::setup_core::channels::{
    Channel, ChannelManifest, record_channel_sequence, required_binary_url, required_plugin_url,
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

    let temp = std::env::temp_dir().join(format!(
        "studio-stud-update-{}",
        std::process::id()
    ));
    fs::create_dir_all(&temp).with_context(|| format!("create {}", temp.display()))?;

    let daemon_path = temp.join("studio-stud.exe");
    let plugin_path = temp.join("StudioStud.plugin.lua");
    update::download_to(&required_binary_url(manifest)?, &daemon_path)?;
    update::download_to(&required_plugin_url(manifest)?, &plugin_path)?;

    if resolved.is_encrypted() {
        let _ = decrypt_setup_smoke_check(cfg, manifest)?;
    }

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

fn decrypt_setup_smoke_check(cfg: &StudioStudConfig, manifest: &ChannelManifest) -> Result<PathBuf> {
    let enc_url = manifest
        .setup_enc_url
        .as_deref()
        .ok_or_else(|| anyhow!("manifest missing setupEncUrl"))?;
    let dpapi = cfg
        .channel_key_dpapi
        .as_deref()
        .ok_or_else(|| {
            anyhow!(
                "channel password not stored — reinstall via your channel installer \
                 (install-beta.ps1 or install-dev.ps1)"
            )
        })?;
    let password = String::from_utf8(dpapi_unprotect(dpapi)?)
        .map_err(|_| anyhow!("stored channel password is invalid"))?;
    let enc_path = std::env::temp_dir().join("studio-stud-setup.exe.enc");
    update::download_to(enc_url, &enc_path)?;
    let blob = fs::read(&enc_path)?;
    let _plain = channel_decrypt(&password, &blob).map_err(|_| {
        anyhow!(
            "could not decrypt channel artifact — reinstall via your channel installer \
             (install-beta.ps1 or install-dev.ps1)"
        )
    })?;
    Ok(enc_path)
}
