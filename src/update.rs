//! Version checking + self-update.
//!
//! On `serve` startup the daemon (a) applies any update staged on a previous run, then (b) checks
//! the published `latest.json` and, if a newer release exists, downloads it next to the running exe
//! as `studio-stud.exe.new` (Windows cannot overwrite a running exe) plus refreshes the plugin file.
//! The staged exe is swapped in on the next launch. All network work is best-effort: offline or
//! malformed responses warn and never block serving.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

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

fn download_to(url: &str, dest: &Path) -> Result<u64> {
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

/// `studio-stud.exe` -> `studio-stud.exe.new`
fn staged_exe_path(exe: &Path) -> PathBuf {
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

fn plugin_path(exe: &Path) -> Option<PathBuf> {
    tool_dir(exe).map(|d| d.join("plugin").join("StudioStud.plugin.lua"))
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

/// Download the new exe (staged) and refresh the plugin file. Returns the staged version.
fn stage(url_meta: &Value, exe: &Path) -> Result<String> {
    let latest_daemon = url_meta
        .get("daemonVersion")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let binary_url = url_meta
        .get("binaryUrl")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("latest.json missing binaryUrl"))?;
    let staged = staged_exe_path(exe);
    download_to(binary_url, &staged)?;

    if let (Some(plugin_url), Some(plugin_dest)) = (
        url_meta.get("pluginUrl").and_then(Value::as_str),
        plugin_path(exe),
    ) {
        let _ = download_to(plugin_url, &plugin_dest);
    }

    let mut obj = read_version_json(exe)
        .as_object()
        .cloned()
        .unwrap_or_default();
    obj.insert("stagedDaemonVersion".into(), json!(latest_daemon));
    if let Some(p) = url_meta.get("pluginVersion").and_then(Value::as_str) {
        obj.insert("pluginVersion".into(), json!(p));
    }
    write_version_json(exe, &Value::Object(obj));
    Ok(latest_daemon)
}

/// Run at `serve` startup: apply a previously staged update only.
/// Remote check/download is owned by `studio-stud-setup update` (no race on latest.json).
pub fn apply_staged_on_boot() {
    if let Some(v) = apply_staged() {
        println!("Studio Stud: applied staged update ({v}). Now running it.");
    }
}

/// Legacy entry — kept for `studio-stud update` CLI until setup binary owns it fully.
pub fn run_on_serve(_url: &str, _enabled: bool) {
    apply_staged_on_boot();
}
