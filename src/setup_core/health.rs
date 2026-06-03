use std::path::Path;

use serde_json::{Value, json};

use crate::util::{DoctorCheck, fail, pass, warn};

use super::channels::{Channel, fetch_manifest_with_fallback, verify_manifest_signature};
use super::config::{StudioStudConfig, load_config_or_default};
use super::install::{LEGACY_TOOL_DIR, REPO_MARKER, default_plugins_dir};

pub fn user_health_checks(cfg: &StudioStudConfig) -> Vec<DoctorCheck> {
    let mut checks = Vec::new();
    let install_root = Path::new(&cfg.install_root);
    let exe = install_root.join("bin").join("studio-stud.exe");
    if cfg.install_root.is_empty() {
        checks.push(fail(
            "installRoot",
            "install root not configured".into(),
        ));
    } else if !exe.is_file() {
        checks.push(fail(
            "daemonExe",
            format!("missing {}", exe.display()),
        ));
    } else {
        checks.push(pass("daemonExe", exe.display().to_string()));
    }
    let plugin = Path::new(&cfg.plugins_dir).join("StudioStud.plugin.lua");
    if cfg.plugins_dir.is_empty() {
        checks.push(warn(
            "pluginsDir",
            "plugins directory not configured".into(),
        ));
    } else if !plugin.is_file() {
        checks.push(fail(
            "corePlugin",
            format!("missing {}", plugin.display()),
        ));
    } else {
        checks.push(pass("corePlugin", plugin.display().to_string()));
    }
    if cfg.repos.is_empty() {
        checks.push(warn("repos", "no registered repos".into()));
    } else {
        checks.push(pass(
            "repos",
            format!("{} registered", cfg.repos.len()),
        ));
    }
    checks
}

pub fn repo_health_checks(repo_root: &Path) -> Vec<DoctorCheck> {
    let mut checks = Vec::new();
    let policy = repo_root.join(".studio-stud").join("policy.json");
    if policy.is_file() {
        checks.push(pass("policy", policy.display().to_string()));
    } else {
        checks.push(warn(
            "policy",
            "missing .studio-stud/policy.json".into(),
        ));
    }
    let marker = repo_root.join(REPO_MARKER);
    if marker.is_file() {
        checks.push(pass("repoMarker", marker.display().to_string()));
    } else {
        checks.push(warn("repoMarker", "repo not marked as Studio Stud managed".into()));
    }
    let legacy = repo_root.join(LEGACY_TOOL_DIR);
    if legacy.is_dir() {
        checks.push(warn(
            "legacyBundle",
            format!("legacy {} present — run repo-repair to migrate", LEGACY_TOOL_DIR),
        ));
    }
    checks
}

fn checks_json(checks: &[DoctorCheck]) -> Value {
    Value::Array(
        checks
            .iter()
            .map(|c| {
                json!({
                    "name": c.name,
                    "status": c.status,
                    "detail": c.detail,
                })
            })
            .collect(),
    )
}

pub fn repo_health_json(repo_root: &Path) -> Value {
    let checks = repo_health_checks(repo_root);
    json!({ "ok": !checks.iter().any(|c| c.status == "fail"), "checks": checks_json(&checks) })
}

pub fn health_json() -> Value {
    let cfg = load_config_or_default();
    let user = user_health_checks(&cfg);
    let failed = user.iter().any(|c| c.status == "fail");
    json!({
        "ok": !failed,
        "user": user,
        "config": {
            "installRoot": cfg.install_root,
            "pluginsDir": cfg.plugins_dir,
            "channel": cfg.channel,
            "repoCount": cfg.repos.len(),
        },
    })
}

pub fn version_compat_matrix(cfg: &StudioStudConfig) -> Value {
    json!({
        "installed": cfg.versions,
        "daemonBuild": env!("CARGO_PKG_VERSION"),
        "note": "Plugin hot-load of folder addons may require Studio reload — see docs/version-compat.md",
    })
}

pub fn check_channel_versions(cfg: &StudioStudConfig) -> anyhow::Result<Vec<DoctorCheck>> {
    let requested = Channel::from_str(&cfg.channel);
    let (manifest, raw, resolved) = fetch_manifest_with_fallback(requested)?;
    verify_manifest_signature(&raw, &manifest)?;
    let label = if resolved != requested {
        format!(
            "daemon {} on channel {} (fallback from {})",
            manifest.daemon_version,
            resolved.as_str(),
            requested.as_str()
        )
    } else {
        format!("daemon {} on channel {}", manifest.daemon_version, resolved.as_str())
    };
    let mut checks = vec![pass("channelManifest", label)];
    if !cfg.versions.daemon.is_empty() && cfg.versions.daemon != manifest.daemon_version {
        checks.push(warn(
            "daemonVersion",
            format!(
                "installed {} != channel {}",
                cfg.versions.daemon, manifest.daemon_version
            ),
        ));
    }
    Ok(checks)
}

pub fn default_plugins_dir_check() -> bool {
    default_plugins_dir().is_dir()
}
