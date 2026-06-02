use std::{fs, path::Path};

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use globset::{Glob, GlobSet, GlobSetBuilder};

use crate::write::safety::{normalize_newlines, sha256_hex};

use super::manifest::{PathNode, ProjectManifest, ProjectNode};

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RepoIndex {
    pub entries: Vec<RepoIndexEntry>,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RepoIndexEntry {
    pub repo_path: String,
    pub size: u64,
    pub mtime_utc: String,
    pub hash: String,
    pub role: FileRole,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub studio_path: Option<String>,
    pub projected: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub enum FileRole {
    ServerScript,
    ClientScript,
    ModuleScript,
    InitScript,
    Folder,
    ProjectFile,
    Unsupported,
}

pub fn build_index(manifest: &ProjectManifest, repo_root: &Path) -> Result<RepoIndex> {
    let ignore = compile_glob_ignore(&manifest.glob_ignore_paths)?;
    let mut entries = Vec::new();
    let manifest_rel = "default.project.json";
    if repo_root.join(manifest_rel).is_file() {
        entries.push(index_file(
            repo_root,
            manifest_rel,
            FileRole::ProjectFile,
            &ignore,
        )?);
    }

    collect_path_roots(manifest, repo_root, &mut entries, &ignore)?;

    entries.sort_by(|a, b| a.repo_path.cmp(&b.repo_path));
    Ok(RepoIndex { entries })
}

fn compile_glob_ignore(patterns: &[String]) -> Result<GlobSet> {
    let mut builder = GlobSetBuilder::new();
    for pattern in patterns {
        builder.add(Glob::new(pattern).context("invalid globIgnorePaths pattern")?);
    }
    Ok(builder.build()?)
}

fn collect_path_roots(
    manifest: &ProjectManifest,
    repo_root: &Path,
    entries: &mut Vec<RepoIndexEntry>,
    ignore: &GlobSet,
) -> Result<()> {
    walk_node_paths(&manifest.tree, repo_root, entries, ignore)
}

fn walk_node_paths(
    node: &ProjectNode,
    repo_root: &Path,
    entries: &mut Vec<RepoIndexEntry>,
    ignore: &GlobSet,
) -> Result<()> {
    if let Some(path_node) = &node.path {
        let rel = match path_node {
            PathNode::Required(p) => p.clone(),
            PathNode::Optional(p) => {
                let abs = repo_root.join(p);
                if !abs.exists() {
                    for child in node.children.values() {
                        walk_node_paths(child, repo_root, entries, ignore)?;
                    }
                    return Ok(());
                }
                p.clone()
            }
        };
        let abs = repo_root.join(&rel);
        if abs.is_dir() {
            walk_dir(repo_root, &rel, &abs, entries, ignore)?;
        } else if abs.is_file() {
            let role = classify_file(&abs).unwrap_or(FileRole::Unsupported);
            let rel_str = rel.to_string_lossy().replace('\\', "/");
            entries.push(index_file_with_role(repo_root, &rel_str, role, ignore)?);
        }
    }
    for child in node.children.values() {
        walk_node_paths(child, repo_root, entries, ignore)?;
    }
    Ok(())
}

fn walk_dir(
    repo_root: &Path,
    rel_prefix: &Path,
    abs_dir: &Path,
    entries: &mut Vec<RepoIndexEntry>,
    ignore: &GlobSet,
) -> Result<()> {
    let mut names: Vec<_> = fs::read_dir(abs_dir)?
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().to_string())
        .collect();
    names.sort();

    let rel_str = rel_prefix.to_string_lossy().replace('\\', "/");
    entries.push(RepoIndexEntry {
        repo_path: rel_str.clone(),
        size: 0,
        mtime_utc: dir_mtime_utc(abs_dir)?,
        hash: String::new(),
        role: FileRole::Folder,
        studio_path: None,
        projected: false,
    });

    for name in names {
        if name == ".git" || name == "target" || name == "node_modules" || name == ".cursor" {
            continue;
        }
        let rel = rel_prefix.join(&name);
        let rel_display = rel.to_string_lossy().replace('\\', "/");
        if ignore.is_match(&rel_display) {
            continue;
        }
        let abs = abs_dir.join(&name);
        if abs.is_dir() {
            walk_dir(repo_root, &rel, &abs, entries, ignore)?;
        } else if abs.is_file() {
            let role = classify_file(&abs).unwrap_or(FileRole::Unsupported);
            entries.push(index_file_with_role(repo_root, &rel_display, role, ignore)?);
        }
    }
    Ok(())
}

pub fn classify_file(path: &Path) -> Option<FileRole> {
    let name = path.file_name()?.to_string_lossy();
    let lower = name.to_ascii_lowercase();
    if lower == "default.project.json" || lower.ends_with(".project.json") {
        return Some(FileRole::ProjectFile);
    }
    if lower.ends_with(".server.luau") || lower.ends_with(".server.lua") {
        return Some(FileRole::ServerScript);
    }
    if lower.ends_with(".client.luau") || lower.ends_with(".client.lua") {
        return Some(FileRole::ClientScript);
    }
    if lower.ends_with(".plugin.luau") || lower.ends_with(".plugin.lua") {
        return Some(FileRole::Unsupported);
    }
    if is_init_script_name(&lower) {
        return Some(FileRole::InitScript);
    }
    if lower.ends_with(".luau") || lower.ends_with(".lua") {
        return Some(FileRole::ModuleScript);
    }
    if path.extension().is_some() {
        return Some(FileRole::Unsupported);
    }
    None
}

fn is_init_script_name(lower: &str) -> bool {
    matches!(
        lower,
        "init.luau"
            | "init.lua"
            | "init.server.luau"
            | "init.server.lua"
            | "init.client.luau"
            | "init.client.lua"
    )
}

fn index_file(
    repo_root: &Path,
    rel: &str,
    role: FileRole,
    ignore: &GlobSet,
) -> Result<RepoIndexEntry> {
    index_file_with_role(repo_root, rel, role, ignore)
}

fn index_file_with_role(
    repo_root: &Path,
    rel: &str,
    role: FileRole,
    ignore: &GlobSet,
) -> Result<RepoIndexEntry> {
    if ignore.is_match(rel) {
        return Ok(RepoIndexEntry {
            repo_path: rel.to_string(),
            size: 0,
            mtime_utc: String::new(),
            hash: String::new(),
            role,
            studio_path: None,
            projected: false,
        });
    }
    let abs = repo_root.join(rel);
    let meta = fs::metadata(&abs)?;
    let bytes = fs::read(&abs)?;
    let hash = match role {
        FileRole::Unsupported => sha256_hex(&bytes),
        _ => {
            let text = String::from_utf8_lossy(&bytes);
            sha256_hex(normalize_newlines(&text).as_bytes())
        }
    };
    Ok(RepoIndexEntry {
        repo_path: rel.to_string(),
        size: meta.len(),
        mtime_utc: file_mtime_utc(&meta)?,
        hash,
        role,
        studio_path: None,
        projected: false,
    })
}

fn file_mtime_utc(meta: &fs::Metadata) -> Result<String> {
    let modified = meta.modified().context("mtime")?;
    format_mtime(modified)
}

fn dir_mtime_utc(path: &Path) -> Result<String> {
    let meta = fs::metadata(path)?;
    file_mtime_utc(&meta)
}

fn format_mtime(time: std::time::SystemTime) -> Result<String> {
    let datetime: DateTime<Utc> = time.into();
    Ok(datetime.format("%Y-%m-%dT%H:%M:%SZ").to_string())
}
