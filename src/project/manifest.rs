use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
};

use anyhow::Result;
use rbx_reflection::ClassTag;
use rbx_reflection_database::get;
use serde::Deserialize;
use serde_json::Value;

#[derive(Debug, Clone)]
pub struct ProjectError {
    pub message: String,
    pub detail: Option<String>,
}

impl ProjectError {
    pub(crate) fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            detail: None,
        }
    }

    pub(crate) fn with_detail(message: impl Into<String>, detail: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            detail: Some(detail.into()),
        }
    }
}

#[derive(Debug, Clone)]
pub struct ProjectManifest {
    pub name: String,
    pub glob_ignore_paths: Vec<String>,
    pub emit_legacy_scripts: Option<bool>,
    pub tree: ProjectNode,
}

#[derive(Debug, Clone)]
pub struct ProjectNode {
    pub class_name: Option<String>,
    pub path: Option<PathNode>,
    pub properties: serde_json::Map<String, Value>,
    pub attributes: serde_json::Map<String, Value>,
    pub ignore_unknown: Option<bool>,
    pub id: Option<String>,
    pub children: BTreeMap<String, ProjectNode>,
}

#[derive(Debug, Clone)]
pub enum PathNode {
    Required(PathBuf),
    Optional(PathBuf),
}

pub fn effective_ignore_unknown(node: &ProjectNode) -> bool {
    if let Some(explicit) = node.ignore_unknown {
        return explicit;
    }
    // Rojo default: $path set => false (repo-owned); no $path => true (leave unknown alone).
    node.path.is_none()
}

pub fn parse_manifest(repo_root: &Path) -> Result<ProjectManifest, ProjectError> {
    let path = repo_root.join("default.project.json");
    let text = std::fs::read_to_string(&path).map_err(|err| {
        ProjectError::with_detail(
            "missing or unreadable default.project.json",
            err.to_string(),
        )
    })?;
    parse_manifest_text(&text, &path)
}

pub fn parse_manifest_text(text: &str, label: &Path) -> Result<ProjectManifest, ProjectError> {
    let raw: RawProjectFile = serde_json::from_str(text).map_err(|err| {
        ProjectError::with_detail(
            format!("malformed project file at {}", label.display()),
            err.to_string(),
        )
    })?;
    let tree = parse_node_value(&raw.tree, "tree")?;
    Ok(ProjectManifest {
        name: raw.name,
        glob_ignore_paths: raw.glob_ignore_paths,
        emit_legacy_scripts: raw.emit_legacy_scripts,
        tree,
    })
}

#[derive(Deserialize)]
struct RawProjectFile {
    name: String,
    #[serde(default, rename = "globIgnorePaths")]
    glob_ignore_paths: Vec<String>,
    #[serde(default, rename = "emitLegacyScripts")]
    emit_legacy_scripts: Option<bool>,
    tree: Value,
}

fn parse_node_value(value: &Value, context: &str) -> Result<ProjectNode, ProjectError> {
    let obj = value.as_object().ok_or_else(|| {
        ProjectError::new(format!("{context}: project node must be a JSON object"))
    })?;
    let mut class_name = None;
    let mut path = None;
    let mut properties = serde_json::Map::new();
    let mut attributes = serde_json::Map::new();
    let mut ignore_unknown = None;
    let mut id = None;
    let mut children = BTreeMap::new();

    for (key, val) in obj {
        if key.starts_with('$') {
            match key.as_str() {
                "$className" => {
                    class_name = val.as_str().map(str::to_string);
                }
                "$path" => {
                    path = Some(parse_path_node(val)?);
                }
                "$properties" => {
                    if let Some(map) = val.as_object() {
                        properties = map.clone();
                    }
                }
                "$attributes" => {
                    if let Some(map) = val.as_object() {
                        attributes = map.clone();
                    }
                }
                "$ignoreUnknownInstances" => {
                    ignore_unknown = val.as_bool();
                }
                "$id" => {
                    id = val.as_str().map(str::to_string);
                }
                _ => {}
            }
        } else {
            children.insert(key.clone(), parse_node_value(val, key)?);
        }
    }

    Ok(ProjectNode {
        class_name,
        path,
        properties,
        attributes,
        ignore_unknown,
        id,
        children,
    })
}

fn parse_path_node(value: &Value) -> Result<PathNode, ProjectError> {
    if let Some(text) = value.as_str() {
        return Ok(PathNode::Required(PathBuf::from(text)));
    }
    if let Some(obj) = value.as_object()
        && let Some(opt) = obj.get("optional").and_then(Value::as_str)
    {
        return Ok(PathNode::Optional(PathBuf::from(opt)));
    }
    Err(ProjectError::new(
        "$path must be a string or { \"optional\": \"...\" }",
    ))
}

fn reflection_db() -> &'static rbx_reflection::ReflectionDatabase<'static> {
    get().expect("rbx_reflection_database")
}

pub fn validate_class_name(class_name: &str) -> bool {
    reflection_db().classes.contains_key(class_name)
}

pub fn infer_class_name(name: &str, parent_class: &str) -> Option<String> {
    if parent_class == "DataModel" {
        if let Some(class) = reflection_db().classes.get(name)
            && class.tags.contains(&ClassTag::Service)
        {
            return Some(name.to_string());
        }
    }
    if parent_class == "StarterPlayer"
        && matches!(name, "StarterPlayerScripts" | "StarterCharacterScripts")
    {
        return Some(name.to_string());
    }
    if parent_class == "Workspace" && name == "Terrain" {
        return Some(name.to_string());
    }
    None
}

/// Class from resolving a filesystem path (directory => Folder; script files => script class).
pub fn class_name_from_path(resolved: &PathNodeResolution) -> Option<String> {
    match resolved {
        PathNodeResolution::Directory { .. } => Some("Folder".to_string()),
        PathNodeResolution::File { class_name, .. } => Some(class_name.clone()),
        PathNodeResolution::SkippedOptional => None,
    }
}

#[derive(Debug, Clone)]
pub enum PathNodeResolution {
    Directory {
        abs_path: PathBuf,
        rel_path: String,
    },
    File {
        abs_path: PathBuf,
        rel_path: String,
        class_name: String,
    },
    SkippedOptional,
}

pub fn resolve_path_node(
    repo_root: &Path,
    path_node: &PathNode,
) -> Result<PathNodeResolution, ProjectError> {
    match path_node {
        PathNode::Required(rel) => {
            let abs = repo_root.join(rel);
            resolve_existing_path(abs, rel.to_string_lossy().replace('\\', "/"))
        }
        PathNode::Optional(rel) => {
            let abs = repo_root.join(rel);
            if abs.exists() {
                resolve_existing_path(abs, rel.to_string_lossy().replace('\\', "/"))
            } else {
                Ok(PathNodeResolution::SkippedOptional)
            }
        }
    }
}

fn resolve_existing_path(
    abs: PathBuf,
    rel_path: String,
) -> Result<PathNodeResolution, ProjectError> {
    if abs.is_dir() {
        return Ok(PathNodeResolution::Directory {
            abs_path: abs,
            rel_path,
        });
    }
    if abs.is_file() {
        let class_name = script_class_for_file(&abs).ok_or_else(|| {
            ProjectError::new(format!(
                "required $path file has unsupported type: {}",
                abs.display()
            ))
        })?;
        return Ok(PathNodeResolution::File {
            abs_path: abs,
            rel_path,
            class_name,
        });
    }
    Err(ProjectError::new(format!(
        "required $path does not exist: {}",
        abs.display()
    )))
}

pub fn script_class_for_file(path: &Path) -> Option<String> {
    let name = path.file_name()?.to_string_lossy();
    let lower = name.to_ascii_lowercase();
    if lower.ends_with(".server.luau") || lower.ends_with(".server.lua") {
        return Some("Script".to_string());
    }
    if lower.ends_with(".client.luau") || lower.ends_with(".client.lua") {
        return Some("LocalScript".to_string());
    }
    if lower.ends_with(".luau") || lower.ends_with(".lua") {
        if lower.contains(".server.") || lower.contains(".client.") || lower.starts_with("init") {
            return None;
        }
        return Some("ModuleScript".to_string());
    }
    None
}

pub fn resolve_class_name(
    node: &ProjectNode,
    child_name: &str,
    parent_class: &str,
    path_resolution: Option<&PathNodeResolution>,
) -> Result<Option<String>, ProjectError> {
    let explicit = node.class_name.clone();
    let from_path = path_resolution.and_then(class_name_from_path);
    let from_inference = infer_class_name(child_name, parent_class);

    match (&explicit, &from_path, &from_inference, &node.path) {
        (Some(cn), None, None, _) => Ok(Some(cn.clone())),
        (None, Some(path), None, _) => Ok(Some(path.clone())),
        (None, None, Some(inf), _) => Ok(Some(inf.clone())),
        (Some(cn), None, Some(_), _) => Ok(Some(cn.clone())),
        (None, Some(path), Some(inf), _) => {
            if path == "Folder" {
                Ok(Some(inf.clone()))
            } else {
                Ok(Some(path.clone()))
            }
        }
        (Some(cn), Some(path), _, _) => {
            if path == "Folder" {
                Ok(Some(cn.clone()))
            } else {
                Err(ProjectError::new(
                    "$className and $path both set, but $path is not a Folder",
                ))
            }
        }
        (_, None, _, Some(PathNode::Optional(_))) => Ok(None),
        (_, None, _, Some(PathNode::Required(_))) => Err(ProjectError::new(format!(
            "required $path for `{child_name}` did not resolve to a known file type"
        ))),
        (None, None, None, None) => Err(ProjectError::new(format!(
            "node `{child_name}` has no class, path, or inferable service"
        ))),
    }
}

/// Resolve class for a manifest tree node (used before path expansion details).
pub fn resolve_node_class_name(
    node: &ProjectNode,
    instance_name: &str,
    parent_class: &str,
    repo_root: &Path,
) -> Result<Option<String>, ProjectError> {
    let path_resolution = node
        .path
        .as_ref()
        .map(|pn| resolve_path_node(repo_root, pn))
        .transpose()?;
    if let Some(PathNodeResolution::SkippedOptional) = path_resolution {
        return Ok(None);
    }
    let path_ref = path_resolution.as_ref();
    let resolved = resolve_class_name(node, instance_name, parent_class, path_ref)?;
    if let Some(ref class) = resolved
        && !validate_class_name(class)
    {
        return Err(ProjectError::new(format!("unknown class `{class}`")));
    }
    Ok(resolved)
}

pub fn emit_legacy_scripts_default(manifest: &ProjectManifest) -> bool {
    manifest.emit_legacy_scripts.unwrap_or(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reflection_exit_a_gate() {
        let db = reflection_db();
        assert!(db.classes.get("Folder").is_some());
        let sss = db.classes.get("ServerScriptService").expect("service");
        assert!(sss.tags.contains(&ClassTag::Service));
        assert!(db.classes.get("NotARealClass").is_none());
    }

    #[test]
    fn effective_ignore_unknown_defaults() {
        let with_path = ProjectNode {
            class_name: None,
            path: Some(PathNode::Required(PathBuf::from("src"))),
            properties: serde_json::Map::new(),
            attributes: serde_json::Map::new(),
            ignore_unknown: None,
            id: None,
            children: BTreeMap::new(),
        };
        assert!(!effective_ignore_unknown(&with_path));

        let without_path = ProjectNode {
            class_name: Some("Workspace".to_string()),
            path: None,
            properties: serde_json::Map::new(),
            attributes: serde_json::Map::new(),
            ignore_unknown: None,
            id: None,
            children: BTreeMap::new(),
        };
        assert!(effective_ignore_unknown(&without_path));

        let mut explicit = without_path.clone();
        explicit.ignore_unknown = Some(false);
        assert!(!effective_ignore_unknown(&explicit));
    }

    #[test]
    fn class_resolution_arm6_folder_path() {
        let node = ProjectNode {
            class_name: Some("ServerScriptService".to_string()),
            path: Some(PathNode::Required(PathBuf::from("src/Server"))),
            properties: serde_json::Map::new(),
            attributes: serde_json::Map::new(),
            ignore_unknown: Some(true),
            id: None,
            children: BTreeMap::new(),
        };
        let resolution = PathNodeResolution::Directory {
            abs_path: PathBuf::from("/tmp/src/Server"),
            rel_path: "src/Server".to_string(),
        };
        let class =
            resolve_class_name(&node, "ServerScriptService", "DataModel", Some(&resolution))
                .unwrap()
                .unwrap();
        assert_eq!(class, "ServerScriptService");
    }
}
