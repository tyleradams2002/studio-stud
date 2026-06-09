use std::path::Path;

use serde_json::{Value, json};

use crate::util::{DoctorCheck, fail, pass, warn};

use super::channels::{Channel, fetch_manifest_with_fallback, verify_manifest_signature};
use super::config::{StudioStudConfig, config_path, load_config_or_default};
use super::install::{
    LEGACY_TOOL_DIR, REPO_MARKER, default_plugins_dir, user_path_contains,
};

const ADD_REPO_HINT: &str =
    "run: studio-stud-setup add-repo \"C:\\path\\to\\your\\project\"";

pub fn user_health_checks(cfg: &StudioStudConfig) -> Vec<DoctorCheck> {
    let mut checks = Vec::new();
    let install_root = Path::new(&cfg.install_root);
    let exe = install_root.join("bin").join("studio-stud.exe");
    if cfg.install_root.is_empty() {
        checks.push(fail(
            "installRoot",
            "install root not configured — reinstall with studio-stud-setup install".into(),
        ));
    } else if !exe.is_file() {
        checks.push(fail(
            "daemonExe",
            format!("missing {} — reinstall with studio-stud-setup install", exe.display()),
        ));
    } else {
        checks.push(pass("daemonExe", exe.display().to_string()));
    }

    if cfg.install_root.is_empty() {
        checks.push(fail(
            "pathShim",
            format!("install bin not on PATH — {ADD_REPO_HINT} after fixing install"),
        ));
    } else {
        let bin = install_root.join("bin");
        let bin_str = bin.display().to_string();
        if user_path_contains(&bin_str) {
            checks.push(pass("pathShim", bin_str));
        } else {
            checks.push(fail(
                "pathShim",
                format!(
                    "{bin_str} not on user PATH — open a NEW terminal after install, or rerun studio-stud-setup repair"
                ),
            ));
        }
    }

    let plugin = Path::new(&cfg.plugins_dir).join("StudioStud.plugin.lua");
    if cfg.plugins_dir.is_empty() {
        checks.push(fail(
            "corePlugin",
            "plugins directory not configured — reinstall with studio-stud-setup install".into(),
        ));
    } else if !plugin.is_file() {
        checks.push(fail(
            "corePlugin",
            format!("missing {} — reinstall with studio-stud-setup install", plugin.display()),
        ));
    } else {
        checks.push(pass("corePlugin", plugin.display().to_string()));
    }

    let cfg_path = config_path();
    if !cfg_path.is_file() {
        checks.push(fail(
            "config",
            format!("missing {} — reinstall with studio-stud-setup install", cfg_path.display()),
        ));
    } else if let Ok(text) = std::fs::read_to_string(&cfg_path) {
        if serde_json::from_str::<StudioStudConfig>(&text).is_ok() {
            checks.push(pass("config", cfg_path.display().to_string()));
        } else {
            checks.push(fail(
                "config",
                format!(
                    "invalid JSON at {} — run studio-stud-setup repair or delete and reinstall",
                    cfg_path.display()
                ),
            ));
        }
    } else {
        checks.push(fail(
            "config",
            format!("unreadable {} — check file permissions", cfg_path.display()),
        ));
    }

    if cfg.repos.is_empty() {
        checks.push(warn(
            "repos",
            format!("no registered repos — {ADD_REPO_HINT}"),
        ));
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn temp_dir(name: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!("studio-stud-health-{name}-{}", std::process::id()))
    }

    #[test]
    fn health_fails_when_daemon_exe_missing() {
        let base = temp_dir("missing-exe");
        let install = base.join("install");
        fs::create_dir_all(install.join("bin")).unwrap();
        let cfg = StudioStudConfig {
            install_root: install.display().to_string(),
            plugins_dir: base.join("plugins").display().to_string(),
            ..Default::default()
        };
        let checks = user_health_checks(&cfg);
        assert!(checks.iter().any(|c| c.name == "daemonExe" && c.status == "fail"));
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn health_passes_daemon_exe_when_present() {
        let base = temp_dir("present-exe");
        let install = base.join("install");
        let plugins = base.join("plugins");
        fs::create_dir_all(install.join("bin")).unwrap();
        fs::create_dir_all(&plugins).unwrap();
        fs::write(install.join("bin").join("studio-stud.exe"), b"").unwrap();
        fs::write(plugins.join("StudioStud.plugin.lua"), b"").unwrap();
        let cfg_path = base.join("config.json");
        let cfg = StudioStudConfig {
            install_root: install.display().to_string(),
            plugins_dir: plugins.display().to_string(),
            repos: vec![super::super::config::RepoEntry {
                path: "C:/repo".into(),
                place_id: None,
                enabled_addons: vec![],
                registered_at: String::new(),
            }],
            ..Default::default()
        };
        fs::write(&cfg_path, serde_json::to_string(&cfg).unwrap()).unwrap();
        unsafe {
            std::env::set_var("STUDIO_STUD_CONFIG", cfg_path.display().to_string());
        }
        let checks = user_health_checks(&cfg);
        assert!(checks.iter().any(|c| c.name == "daemonExe" && c.status == "pass"));
        unsafe {
            std::env::remove_var("STUDIO_STUD_CONFIG");
        }
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn health_warns_when_zero_repos() {
        let cfg = StudioStudConfig {
            install_root: "C:/Programs/StudioStud".into(),
            ..Default::default()
        };
        let checks = user_health_checks(&cfg);
        let repos = checks.iter().find(|c| c.name == "repos").unwrap();
        assert_eq!(repos.status, "warn");
        assert!(repos.detail.contains("add-repo"));
    }

    #[test]
    fn health_passes_when_repos_registered() {
        let cfg = StudioStudConfig {
            repos: vec![super::super::config::RepoEntry {
                path: "C:/repo".into(),
                place_id: None,
                enabled_addons: vec![],
                registered_at: String::new(),
            }],
            ..Default::default()
        };
        let checks = user_health_checks(&cfg);
        let repos = checks.iter().find(|c| c.name == "repos").unwrap();
        assert_eq!(repos.status, "pass");
    }
}
