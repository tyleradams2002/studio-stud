use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
};

use globset::{Glob, GlobSet, GlobSetBuilder};

use crate::{
    util::normalize_query_path,
    write::safety::{normalize_newlines, parse_luau, sha256_hex},
};

use super::{
    index::{FileRole, RepoIndex, classify_file},
    manifest::{
        PathNodeResolution, ProjectError, ProjectManifest, ProjectNode, effective_ignore_unknown,
        emit_legacy_scripts_default, resolve_class_name, resolve_node_class_name,
        resolve_path_node, validate_class_name,
    },
};

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DesiredProjection {
    pub by_key: BTreeMap<String, DesiredInstance>,
    pub errors: Vec<ProjectionError>,
    pub warnings: Vec<ProjectionWarning>,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DesiredInstance {
    pub studio_path: String,
    pub normalized_key: String,
    pub class_name: String,
    pub ignore_unknown: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_repo_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_hash: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parse_ok: Option<bool>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct ProjectionError {
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct ProjectionWarning {
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
}

struct ProjectionCtx<'a> {
    repo_root: &'a Path,
    ignore_globs: GlobSet,
    legacy_scripts: bool,
    by_key: BTreeMap<String, DesiredInstance>,
    errors: Vec<ProjectionError>,
    warnings: Vec<ProjectionWarning>,
}

pub fn build_projection(
    manifest: &ProjectManifest,
    repo_root: &Path,
    index: &RepoIndex,
) -> DesiredProjection {
    let _ = index;
    let ignore_globs =
        compile_glob_ignore(&manifest.glob_ignore_paths).unwrap_or_else(|_| GlobSet::empty());
    let mut ctx = ProjectionCtx {
        repo_root,
        ignore_globs,
        legacy_scripts: emit_legacy_scripts_default(manifest),
        by_key: BTreeMap::new(),
        errors: Vec::new(),
        warnings: Vec::new(),
    };

    let root_class = manifest
        .tree
        .class_name
        .clone()
        .unwrap_or_else(|| "DataModel".to_string());

    for (child_name, child) in &manifest.tree.children {
        if let Err(err) = ctx.project_tree_node(child_name, child, &root_class, "") {
            ctx.errors.push(ProjectionError {
                message: err.message,
                path: err.detail,
            });
        }
    }

    DesiredProjection {
        by_key: ctx.by_key,
        errors: ctx.errors,
        warnings: ctx.warnings,
    }
}

fn compile_glob_ignore(patterns: &[String]) -> Result<GlobSet, globset::Error> {
    let mut builder = GlobSetBuilder::new();
    for pattern in patterns {
        builder.add(Glob::new(pattern)?);
    }
    builder.build()
}

impl ProjectionCtx<'_> {
    fn project_tree_node(
        &mut self,
        instance_name: &str,
        node: &ProjectNode,
        parent_class: &str,
        studio_parent: &str,
    ) -> Result<(), ProjectError> {
        if let Some(path_node) = &node.path {
            match resolve_path_node(self.repo_root, path_node)? {
                PathNodeResolution::SkippedOptional => return Ok(()),
                PathNodeResolution::Directory { abs_path, rel_path } => {
                    let class =
                        resolve_node_class_name(node, instance_name, parent_class, self.repo_root)?;
                    let class = class.ok_or_else(|| {
                        ProjectError::new(format!("no class for `{instance_name}`"))
                    })?;
                    self.insert_instance(
                        studio_parent,
                        instance_name,
                        &class,
                        effective_ignore_unknown(node),
                        None,
                        None,
                        None,
                    )?;
                    let child_studio = join_studio(studio_parent, instance_name);
                    self.expand_path_root(&child_studio, &abs_path, &rel_path)?;
                    for (name, child) in &node.children {
                        self.project_tree_node(name, child, &class, &child_studio)?;
                    }
                    return Ok(());
                }
                PathNodeResolution::File {
                    abs_path,
                    rel_path,
                    class_name,
                } => {
                    let resolved_class = resolve_class_name(
                        node,
                        instance_name,
                        parent_class,
                        Some(&PathNodeResolution::File {
                            abs_path: abs_path.clone(),
                            rel_path: rel_path.clone(),
                            class_name: class_name.clone(),
                        }),
                    )?;
                    let class = resolved_class.unwrap_or(class_name);
                    let (hash, parse_ok) = script_source_meta(&abs_path)?;
                    self.insert_instance(
                        studio_parent,
                        instance_name,
                        &class,
                        effective_ignore_unknown(node),
                        Some(rel_path),
                        Some(hash),
                        parse_ok,
                    )?;
                    for (name, child) in &node.children {
                        self.project_tree_node(name, child, &class, studio_parent)?;
                    }
                    return Ok(());
                }
            }
        }

        let class = resolve_node_class_name(node, instance_name, parent_class, self.repo_root)?;
        let Some(class) = class else {
            return Ok(());
        };
        self.insert_instance(
            studio_parent,
            instance_name,
            &class,
            effective_ignore_unknown(node),
            None,
            None,
            None,
        )?;
        let child_studio = join_studio(studio_parent, instance_name);
        for (name, child) in &node.children {
            self.project_tree_node(name, child, &class, &child_studio)?;
        }
        Ok(())
    }

    /// Expand contents of a `$path` directory (service root already inserted).
    fn expand_path_root(
        &mut self,
        studio_parent: &str,
        abs_dir: &Path,
        rel_dir: &str,
    ) -> Result<(), ProjectError> {
        if abs_dir.join("default.project.json").is_file() {
            self.warnings.push(ProjectionWarning {
                message: "nested default.project.json is not fully supported".to_string(),
                path: Some(rel_dir.to_string()),
            });
        }
        let mut names: Vec<_> = fs::read_dir(abs_dir)
            .map_err(|e| ProjectError::with_detail("read_dir", e.to_string()))?
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().to_string())
            .collect();
        names.sort();
        for name in names {
            let rel = format!("{}/{}", rel_dir.trim_end_matches('/'), name).replace('\\', "/");
            if self.ignore_globs.is_match(&rel) {
                continue;
            }
            let abs = abs_dir.join(&name);
            if abs.is_dir() {
                self.expand_subdirectory(studio_parent, &abs, &rel)?;
            } else if abs.is_file() {
                self.project_file_child(studio_parent, &abs, &rel)?;
            }
        }
        Ok(())
    }

    fn expand_subdirectory(
        &mut self,
        studio_parent: &str,
        abs_dir: &Path,
        rel_dir: &str,
    ) -> Result<(), ProjectError> {
        let dir_name = abs_dir
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| "Folder".to_string());

        if let Some((class, init_rel, init_abs)) = find_init_collapse(abs_dir, rel_dir) {
            let (hash, parse_ok) = script_source_meta(&init_abs)?;
            self.insert_instance(
                studio_parent,
                &dir_name,
                &class,
                false,
                Some(init_rel),
                Some(hash),
                parse_ok,
            )?;
            let child_studio = join_studio(studio_parent, &dir_name);
            self.expand_dir_children(&child_studio, abs_dir, rel_dir, true)?;
        } else {
            self.insert_instance(studio_parent, &dir_name, "Folder", false, None, None, None)?;
            let child_studio = join_studio(studio_parent, &dir_name);
            self.expand_dir_children(&child_studio, abs_dir, rel_dir, false)?;
        }
        Ok(())
    }

    fn expand_dir_children(
        &mut self,
        studio_parent: &str,
        abs_dir: &Path,
        rel_dir: &str,
        skip_init: bool,
    ) -> Result<(), ProjectError> {
        let mut names: Vec<_> = fs::read_dir(abs_dir)
            .map_err(|e| ProjectError::with_detail("read_dir", e.to_string()))?
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().to_string())
            .collect();
        names.sort();
        for name in names {
            if skip_init && is_init_script_name(&name.to_ascii_lowercase()) {
                continue;
            }
            let rel = format!("{}/{}", rel_dir.trim_end_matches('/'), name).replace('\\', "/");
            if self.ignore_globs.is_match(&rel) {
                continue;
            }
            let abs = abs_dir.join(&name);
            if abs.is_dir() {
                self.expand_subdirectory(studio_parent, &abs, &rel)?;
            } else if abs.is_file() {
                self.project_file_child(studio_parent, &abs, &rel)?;
            }
        }
        Ok(())
    }

    fn project_file_child(
        &mut self,
        studio_parent: &str,
        abs: &Path,
        rel: &str,
    ) -> Result<(), ProjectError> {
        let role = classify_file(abs).unwrap_or(FileRole::Unsupported);
        match role {
            FileRole::Unsupported => {
                self.warnings.push(ProjectionWarning {
                    message: "unsupported file type (Stage 7)".to_string(),
                    path: Some(rel.to_string()),
                });
                return Ok(());
            }
            FileRole::Folder | FileRole::ProjectFile | FileRole::InitScript => return Ok(()),
            FileRole::ServerScript | FileRole::ClientScript | FileRole::ModuleScript => {
                let (instance_name, class) = script_instance_from_file(abs, self.legacy_scripts)?;
                let (hash, parse_ok) = script_source_meta(abs)?;
                self.insert_instance(
                    studio_parent,
                    &instance_name,
                    &class,
                    false,
                    Some(rel.to_string()),
                    Some(hash),
                    parse_ok,
                )?;
            }
        }
        Ok(())
    }

    fn insert_instance(
        &mut self,
        studio_parent: &str,
        name: &str,
        class_name: &str,
        ignore_unknown: bool,
        source_repo_path: Option<String>,
        source_hash: Option<String>,
        parse_ok: Option<bool>,
    ) -> Result<(), ProjectError> {
        if !validate_class_name(class_name) {
            return Err(ProjectError::new(format!("unknown class `{class_name}`")));
        }
        let studio_path = join_studio(studio_parent, name);
        let normalized_key = normalize_query_path(&studio_path);
        if self.by_key.contains_key(&normalized_key) {
            return Err(ProjectError::new(format!(
                "duplicate projected key `{normalized_key}`"
            )));
        }
        self.by_key.insert(
            normalized_key.clone(),
            DesiredInstance {
                studio_path,
                normalized_key,
                class_name: class_name.to_string(),
                ignore_unknown,
                source_repo_path,
                source_hash,
                parse_ok,
            },
        );
        Ok(())
    }
}

fn join_studio(parent: &str, name: &str) -> String {
    if parent.is_empty() {
        name.to_string()
    } else {
        format!("{parent}/{name}")
    }
}

fn find_init_collapse(abs_dir: &Path, rel_dir: &str) -> Option<(String, String, PathBuf)> {
    let candidates = [
        ("init.luau", "ModuleScript"),
        ("init.lua", "ModuleScript"),
        ("init.server.luau", "Script"),
        ("init.server.lua", "Script"),
        ("init.client.luau", "LocalScript"),
        ("init.client.lua", "LocalScript"),
    ];
    for (file, class) in candidates {
        let path = abs_dir.join(file);
        if path.is_file() {
            let init_rel = format!("{}/{}", rel_dir.trim_end_matches('/'), file).replace('\\', "/");
            return Some((class.to_string(), init_rel, path));
        }
    }
    None
}

fn script_instance_from_file(path: &Path, legacy: bool) -> Result<(String, String), ProjectError> {
    let file_name = path
        .file_name()
        .ok_or_else(|| ProjectError::new("file has no name"))?
        .to_string_lossy()
        .to_string();
    let lower = file_name.to_ascii_lowercase();
    if lower.ends_with(".server.luau") || lower.ends_with(".server.lua") {
        let stem = file_name.trim_end_matches(".luau").trim_end_matches(".lua");
        let stem = stem.trim_end_matches(".server");
        return Ok((stem.to_string(), "Script".to_string()));
    }
    if lower.ends_with(".client.luau") || lower.ends_with(".client.lua") {
        let stem = file_name.trim_end_matches(".luau").trim_end_matches(".lua");
        let stem = stem.trim_end_matches(".client");
        let class = if legacy { "LocalScript" } else { "Script" };
        return Ok((stem.to_string(), class.to_string()));
    }
    if lower.ends_with(".luau") || lower.ends_with(".lua") {
        let stem = path
            .file_stem()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or(file_name);
        return Ok((stem, "ModuleScript".to_string()));
    }
    Err(ProjectError::new("not a script file"))
}

fn script_source_meta(path: &Path) -> Result<(String, Option<bool>), ProjectError> {
    let bytes =
        fs::read(path).map_err(|e| ProjectError::with_detail("read script", e.to_string()))?;
    let text = String::from_utf8_lossy(&bytes);
    let normalized = normalize_newlines(&text);
    let hash = sha256_hex(normalized.as_bytes());
    let parse_ok = match parse_luau(&normalized) {
        Ok(()) => Some(true),
        Err(_) => Some(false),
    };
    Ok((hash, parse_ok))
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
