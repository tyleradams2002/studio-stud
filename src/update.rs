//! Version checking + self-update.
//!
//! On `serve` startup the daemon applies any update staged on a previous run by swapping in
//! `studio-stud.exe.new` (Windows cannot overwrite a running exe, but it can rename one). It does
//! not fetch or download anything itself — checking `latest.json` and staging new artifacts is
//! owned by `studio-stud-setup update`, which avoids races on the manifest. The fetch/compare
//! helpers here remain public so the setup binary can reuse them.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::time::{Duration, Instant};

use anyhow::{Result, anyhow};
use serde_json::{Value, json};

pub const LATEST_URL: &str = "https://tyleradams2002.github.io/studio-stud/latest.json";
pub const INSTALL_CMD: &str = "irm https://tyleradams2002.github.io/studio-stud/install.ps1 | iex";

pub fn current_daemon_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

fn agent() -> ureq::Agent {
    ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(6)))
        .build()
        .into()
}

fn parse_ver(s: &str) -> Vec<u64> {
    s.split('.')
        .map(|part| {
            part.trim()
                .chars()
                .take_while(|c| c.is_ascii_digit())
                .collect::<String>()
                .parse::<u64>()
                .unwrap_or(0)
        })
        .collect()
}

/// True if `latest` is a strictly higher version than `current`.
pub fn is_newer(latest: &str, current: &str) -> bool {
    if latest.is_empty() {
        return false;
    }
    let a = parse_ver(latest);
    let b = parse_ver(current);
    for i in 0..a.len().max(b.len()) {
        let x = a.get(i).copied().unwrap_or(0);
        let y = b.get(i).copied().unwrap_or(0);
        if x != y {
            return x > y;
        }
    }
    false
}

pub fn download_to(url: &str, dest: &Path) -> Result<u64> {
    let mut resp = agent()
        .get(url)
        .call()
        .map_err(|e| anyhow!("download failed {url}: {e}"))?;
    let bytes = resp
        .body_mut()
        .with_config()
        .limit(256 * 1024 * 1024)
        .read_to_vec()
        .map_err(|e| anyhow!("could not read body {url}: {e}"))?;
    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent)?;
    }
    let tmp = dest.with_extension("download");
    fs::write(&tmp, &bytes)?;
    fs::rename(&tmp, dest)?;
    Ok(bytes.len() as u64)
}

pub fn fetch_latest(url: &str) -> Result<Value> {
    let mut resp = agent()
        .get(url)
        .call()
        .map_err(|e| anyhow!("could not reach {url}: {e}"))?;
    let text = resp
        .body_mut()
        .read_to_string()
        .map_err(|e| anyhow!("could not read {url}: {e}"))?;
    let value: Value =
        serde_json::from_str(&text).map_err(|e| anyhow!("malformed latest.json: {e}"))?;
    Ok(value)
}

/// `studio-stud.exe` -> `studio-stud.exe.new`
pub fn staged_exe_path(exe: &Path) -> PathBuf {
    let name = exe
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "studio-stud.exe".to_string());
    exe.with_file_name(format!("{name}.new"))
}

/// `<exe>/../../` from `.studio-stud-tool/bin/studio-stud.exe` -> `.studio-stud-tool`
fn tool_dir(exe: &Path) -> Option<PathBuf> {
    exe.parent().and_then(Path::parent).map(Path::to_path_buf)
}

fn version_json_path(exe: &Path) -> Option<PathBuf> {
    tool_dir(exe).map(|d| d.join("version.json"))
}

fn read_version_json(exe: &Path) -> Value {
    version_json_path(exe)
        .and_then(|p| fs::read_to_string(p).ok())
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .unwrap_or_else(|| json!({}))
}

fn write_version_json(exe: &Path, value: &Value) {
    if let Some(path) = version_json_path(exe)
        && let Ok(text) = serde_json::to_string_pretty(value)
    {
        let _ = fs::write(path, text);
    }
}

/// Installed-on-disk daemon version: prefer version.json, fall back to the running build.
/// Public so the setup binary can compare against a channel manifest without re-fetching
/// the release manifest.
pub fn installed_version() -> String {
    let exe = std::env::current_exe().ok();
    exe.as_deref()
        .map(installed_daemon_version)
        .unwrap_or_else(|| current_daemon_version().to_string())
}

fn installed_daemon_version(exe: &Path) -> String {
    read_version_json(exe)
        .get("daemonVersion")
        .and_then(Value::as_str)
        .map(str::to_string)
        .unwrap_or_else(|| current_daemon_version().to_string())
}

/// Swap in an exe staged on a previous run. Returns the new version if a swap happened.
/// Safe on Windows: the running exe can be renamed (not deleted) while executing.
pub fn apply_staged() -> Option<String> {
    let exe = std::env::current_exe().ok()?;
    let staged = staged_exe_path(&exe);
    let old = exe.with_extension("old");
    let _ = fs::remove_file(&old);
    if !staged.exists() {
        return None;
    }
    if fs::rename(&exe, &old).is_err() {
        return None;
    }
    if fs::rename(&staged, &exe).is_err() {
        // try to restore
        let _ = fs::rename(&old, &exe);
        return None;
    }
    let meta = read_version_json(&exe);
    let staged_version = meta
        .get("stagedDaemonVersion")
        .and_then(Value::as_str)
        .map(str::to_string);
    if let Some(ref v) = staged_version {
        let mut obj = meta.as_object().cloned().unwrap_or_default();
        obj.insert("daemonVersion".into(), json!(v));
        obj.remove("stagedDaemonVersion");
        write_version_json(&exe, &Value::Object(obj));
    }
    staged_version.or_else(|| Some("(updated)".to_string()))
}

pub struct UpdateReport {
    pub installed_daemon: String,
    pub latest_daemon: String,
    pub latest_plugin: String,
    pub update_available: bool,
}

pub fn check(url: &str) -> Result<UpdateReport> {
    let exe = std::env::current_exe().ok();
    let installed = exe
        .as_deref()
        .map(installed_daemon_version)
        .unwrap_or_else(|| current_daemon_version().to_string());
    let latest = fetch_latest(url)?;
    let latest_daemon = latest
        .get("daemonVersion")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let latest_plugin = latest
        .get("pluginVersion")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    Ok(UpdateReport {
        update_available: is_newer(&latest_daemon, &installed),
        installed_daemon: installed,
        latest_daemon,
        latest_plugin,
    })
}

/// Best-effort channel update check at `serve` boot: spawn `studio-stud-setup update --stage`
/// with a backstop timeout. Any failure is logged and ignored — startup always continues.
pub fn stage_update_via_setup() {
    if let Err(reason) = stage_update_via_setup_inner() {
        crate::obs::event("update", &format!("skipped: {reason}"));
    }
}

fn stage_update_via_setup_inner() -> Result<(), String> {
    let install_root = crate::setup_core::config::infer_install_root_from_exe()
        .unwrap_or_else(crate::setup_core::install::default_install_root);
    let daemon_exe = crate::setup_core::install::canonical_daemon_exe(&install_root);
    let setup = crate::setup_core::install::resolve_setup_src(&daemon_exe)
        .ok_or_else(|| "studio-stud-setup.exe not found".to_string())?;

    let mut child = Command::new(&setup)
        .args(["update", "--stage"])
        .spawn()
        .map_err(|e| format!("spawn failed: {e}"))?;

    wait_with_timeout(&mut child, Duration::from_secs(120))
        .map_err(|e| format!("{e}"))?;

    let status = child
        .wait()
        .map_err(|e| format!("wait failed: {e}"))?;
    if !status.success() {
        return Err(format!(
            "setup exited with {}",
            status.code().unwrap_or(-1)
        ));
    }

    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let staged = staged_exe_path(&exe);
    if staged.exists() {
        let meta = read_version_json(&exe);
        let staged_version = meta
            .get("stagedDaemonVersion")
            .and_then(Value::as_str)
            .unwrap_or("?");
        crate::obs::event("update", &format!("staged v{staged_version}"));
    } else {
        crate::obs::event("update", "up to date");
    }
    Ok(())
}

/// Poll `child.try_wait()` until it exits or `timeout` elapses; kills on timeout.
pub fn wait_with_timeout(child: &mut Child, timeout: Duration) -> Result<(), String> {
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return Ok(()),
            Ok(None) => {
                if Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err("timed out after 120s".to_string());
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            Err(e) => return Err(format!("try_wait failed: {e}")),
        }
    }
}

/// Run at `serve` startup: apply a previously staged update only.
/// Remote check/download is owned by `studio-stud-setup update` (no race on latest.json).
pub fn apply_staged_on_boot() {
    if let Some(v) = apply_staged() {
        crate::obs::event("update", &format!("staged update applied ({v}), re-exec"));
        if reexec_daemon_process().is_ok() {
            std::process::exit(0);
        }
        println!(
            "Studio Stud: applied staged update ({v}). Restart 'studio-stud serve' to run it."
        );
    }
}

fn reexec_daemon_process() -> Result<()> {
    let target = reexec_target_exe();
    let args: Vec<std::ffi::OsString> = std::env::args_os().skip(1).collect();
    Command::new(&target).args(&args).spawn()?;
    Ok(())
}

fn reexec_target_exe() -> PathBuf {
    let canonical =
        crate::setup_core::install::canonical_daemon_exe(&crate::setup_core::install::default_install_root());
    if canonical.is_file() {
        return canonical;
    }
    std::env::current_exe().unwrap_or(canonical)
}

/// Legacy entry — kept for `studio-stud update` CLI until setup binary owns it fully.
pub fn run_on_serve(_url: &str, _enabled: bool) {
    apply_staged_on_boot();
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::process::Stdio;

    #[test]
    fn wait_with_timeout_returns_on_fast_exit() {
        let mut child = if cfg!(windows) {
            Command::new("cmd")
                .args(["/C", "exit", "0"])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap()
        } else {
            Command::new("true")
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap()
        };
        wait_with_timeout(&mut child, Duration::from_secs(5)).unwrap();
        assert!(child.wait().unwrap().success());
    }

    #[test]
    fn wait_with_timeout_kills_slow_child() {
        let mut child = if cfg!(windows) {
            Command::new("ping")
                .args(["127.0.0.1", "-n", "60"])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap()
        } else {
            Command::new("sleep")
                .arg("30")
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap()
        };
        let err = wait_with_timeout(&mut child, Duration::from_millis(200)).unwrap_err();
        assert!(err.contains("timed out"));
    }

    #[test]
    fn resolve_setup_src_finds_sibling_setup_exe() {
        let base = std::env::temp_dir().join(format!(
            "studio-stud-setup-locate-{}",
            std::process::id()
        ));
        let bin_dir = base.join("bin");
        fs::create_dir_all(&bin_dir).unwrap();
        let daemon = bin_dir.join("studio-stud.exe");
        let setup = bin_dir.join("studio-stud-setup.exe");
        fs::write(&daemon, b"daemon").unwrap();
        fs::write(&setup, b"setup").unwrap();

        let found = crate::setup_core::install::resolve_setup_src(&daemon).unwrap();
        assert_eq!(found, setup);

        let _ = fs::remove_dir_all(&base);
    }
}
