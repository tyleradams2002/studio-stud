//! Legacy install detection and removal (system32 shims, per-repo bundles).

use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result};

/// A legacy artifact we should remove, plus whether removing it needs admin
/// (true for anything under %SystemRoot%).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LegacyArtifact {
    pub path: PathBuf,
    pub needs_admin: bool,
}

/// Given the set of candidate paths that exist on disk, classify which are
/// legacy Studio Stud artifacts to remove. `system_root` is injected for tests.
pub fn classify_legacy(
    existing: &[PathBuf],
    system_root: &Path,
    canonical_bin: &Path,
) -> Vec<LegacyArtifact> {
    existing
        .iter()
        .filter(|p| is_legacy_artifact(p, canonical_bin))
        .map(|p| LegacyArtifact {
            path: p.clone(),
            needs_admin: p.starts_with(system_root),
        })
        .collect()
}

fn is_legacy_artifact(p: &Path, canonical_bin: &Path) -> bool {
    if p.starts_with(canonical_bin) {
        return false;
    }
    let s = p.to_string_lossy().to_lowercase();
    s.ends_with("studio-stud.ps1")
        || s.ends_with("studio-stud.cmd")
        || s.ends_with("studio-stud.old")
        || s.contains(".studio-stud-tool")
}

/// Collect candidate paths that exist on disk (PATH dirs, system32, registered repos).
pub fn gather_legacy_candidates(
    system_root: &Path,
    _canonical_bin: &Path,
    repo_paths: &[String],
) -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    let sys32 = system_root.join("system32");
    for name in ["studio-stud.ps1", "studio-stud.cmd", "studio-stud.old"] {
        candidates.push(sys32.join(name));
    }
    let legacy_bundle = sys32.join(".studio-stud-tool");
    candidates.push(legacy_bundle.clone());
    candidates.push(legacy_bundle.join("bin").join("studio-stud.exe"));

    for entry in path_directories() {
        for name in ["studio-stud.ps1", "studio-stud.cmd"] {
            candidates.push(entry.join(name));
        }
        let nested = entry.join(".studio-stud-tool");
        candidates.push(nested.clone());
        candidates.push(nested.join("bin").join("studio-stud.exe"));
    }

    for repo in repo_paths {
        let root = PathBuf::from(repo);
        for name in ["studio-stud.ps1", "studio-stud.cmd"] {
            candidates.push(root.join(name));
        }
        let nested = root.join(".studio-stud-tool");
        candidates.push(nested.clone());
        candidates.push(nested.join("bin").join("studio-stud.exe"));
    }

    let mut seen = std::collections::BTreeSet::new();
    candidates
        .into_iter()
        .filter_map(|p| normalize_existing_path(&p))
        .filter(|p| seen.insert(dedup_key(p)))
        .collect()
}

fn normalize_existing_path(p: &Path) -> Option<PathBuf> {
    if !p.exists() {
        return None;
    }
    p.canonicalize().ok().or_else(|| Some(p.to_path_buf()))
}

fn dedup_key(p: &Path) -> String {
    p.to_string_lossy().to_lowercase()
}

fn path_directories() -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    for key in ["PATH", "Path"] {
        if let Ok(val) = std::env::var(key) {
            for part in val.split(';') {
                let part = part.trim();
                if !part.is_empty() {
                    dirs.push(PathBuf::from(part));
                }
            }
        }
    }
    #[cfg(windows)]
    {
        if let Some(user) = read_registry_path("User") {
            dirs.extend(user);
        }
        if let Some(machine) = read_registry_path("Machine") {
            dirs.extend(machine);
        }
    }
    dirs
}

#[cfg(windows)]
fn read_registry_path(scope: &str) -> Option<Vec<PathBuf>> {
    let script = if scope == "User" {
        r#"(Get-ItemProperty -Path 'HKCU:\Environment' -Name PATH -ErrorAction SilentlyContinue).PATH -split ';' | Where-Object { $_ }"#
    } else {
        r#"(Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name PATH -ErrorAction SilentlyContinue).PATH -split ';' | Where-Object { $_ }"#
    };
    let out = Command::new("powershell")
        .args(["-NoProfile", "-Command", &script])
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    Some(
        text.lines()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(PathBuf::from)
            .collect(),
    )
}

#[cfg(not(windows))]
fn read_registry_path(_scope: &str) -> Option<Vec<PathBuf>> {
    None
}

pub fn windows_system_root() -> PathBuf {
    std::env::var("SystemRoot")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(r"C:\WINDOWS"))
}

fn remove_artifact(path: &Path) -> Result<()> {
    if path.is_dir() {
        std::fs::remove_dir_all(path)
            .with_context(|| format!("remove dir {}", path.display()))?;
    } else if path.is_file() {
        std::fs::remove_file(path)
            .with_context(|| format!("remove file {}", path.display()))?;
    }
    Ok(())
}

fn run_elevated_cleanup(paths: &[PathBuf]) -> Result<()> {
    let script_path = std::env::temp_dir().join(format!(
        "studio-stud-cleanup-elevated-{}.ps1",
        std::process::id()
    ));
    let mut lines = vec![
        "$ErrorActionPreference = 'Stop'".to_string(),
        "".to_string(),
    ];
    for path in paths {
        let escaped = path.display().to_string().replace('\'', "''");
        if path.is_dir() {
            lines.push(format!(
                "if (Test-Path -LiteralPath '{escaped}') {{ Remove-Item -LiteralPath '{escaped}' -Recurse -Force }}"
            ));
        } else {
            lines.push(format!(
                "if (Test-Path -LiteralPath '{escaped}') {{ Remove-Item -LiteralPath '{escaped}' -Force }}"
            ));
        }
    }
    std::fs::write(&script_path, lines.join("\n"))?;
    println!(
        "Studio Stud: UAC prompt required to remove {} system artifact(s) under SystemRoot.",
        paths.len()
    );
    let script = script_path.display().to_string();
    let status = Command::new("powershell")
        .args([
            "-NoProfile",
            "-Command",
            &format!(
                "Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','{script}'"
            ),
        ])
        .status()
        .context("launch elevated cleanup")?;
    let _ = std::fs::remove_file(&script_path);
    if !status.success() {
        anyhow::bail!("elevated cleanup did not complete successfully");
    }
    Ok(())
}

/// Enumerate, classify, and optionally remove legacy install artifacts.
pub fn run_legacy_cleanup(
    dry_run: bool,
    install_root: &Path,
    repo_paths: &[String],
) -> Result<Vec<LegacyArtifact>> {
    let system_root = windows_system_root();
    let canonical_bin = install_root.join("bin");
    let existing = gather_legacy_candidates(&system_root, &canonical_bin, repo_paths);
    let artifacts = classify_legacy(&existing, &system_root, &canonical_bin);
    if artifacts.is_empty() {
        println!("Studio Stud: no legacy install artifacts found.");
        return Ok(artifacts);
    }
    println!("Studio Stud: legacy artifacts to remove ({}):", artifacts.len());
    for a in &artifacts {
        let admin = if a.needs_admin { " [admin]" } else { "" };
        println!("  {}{admin}", a.path.display());
    }
    if dry_run {
        println!("(dry-run - nothing removed)");
        return Ok(artifacts);
    }
    let (admin, user): (Vec<_>, Vec<_>) = artifacts
        .iter()
        .partition(|a| a.needs_admin);
    for a in &user {
        remove_artifact(&a.path)?;
    }
    if !admin.is_empty() {
        let mut seen = std::collections::BTreeSet::new();
        let paths: Vec<PathBuf> = admin
            .iter()
            .map(|a| a.path.clone())
            .filter(|p| seen.insert(dedup_key(p)))
            .collect();
        run_elevated_cleanup(&paths)?;
    }
    println!("Studio Stud: legacy cleanup finished.");
    Ok(artifacts)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn flags_system32_shim_as_admin_and_skips_canonical() {
        let sysroot = PathBuf::from(r"C:\WINDOWS");
        let canonical = PathBuf::from(r"C:\Users\u\AppData\Local\Programs\StudioStud\bin");
        let existing = vec![
            PathBuf::from(r"C:\WINDOWS\system32\studio-stud.ps1"),
            PathBuf::from(r"C:\WINDOWS\system32\.studio-stud-tool\bin\studio-stud.exe"),
            PathBuf::from(r"C:\Users\u\GitHub\ExampleProject\studio-stud.cmd"),
            PathBuf::from(r"C:\Users\u\AppData\Local\Programs\StudioStud\bin\studio-stud.exe"),
        ];
        let out = classify_legacy(&existing, &sysroot, &canonical);
        assert!(!out.iter().any(|a| a.path.ends_with("Programs\\StudioStud\\bin\\studio-stud.exe")));
        assert_eq!(out.len(), 3);
        assert_eq!(out.iter().filter(|a| a.needs_admin).count(), 2);
        assert_eq!(out.iter().filter(|a| !a.needs_admin).count(), 1);
    }
}
