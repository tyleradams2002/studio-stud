use std::{
    env, fs,
    path::{Path, PathBuf},
};

use globset::{Glob, GlobSet, GlobSetBuilder};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::write::{
    BlockedReason,
    safety::{normalize_newlines, parse_luau},
};

pub const AUTO_GENERATED_MARKER: &str = "-- AUTO-GENERATED";
const DEFAULT_MAX_PATCH_BYTES: u64 = 1_048_576;
const DEFAULT_UNSUPPORTED: &str = "block";

fn de_place_ids<'de, D>(d: D) -> Result<Vec<i64>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::Deserialize;
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum StrOrInt {
        S(String),
        I(i64),
    }
    let raw: Vec<StrOrInt> = Vec::deserialize(d)?;
    raw.into_iter()
        .map(|v| match v {
            StrOrInt::I(n) => Ok(n),
            StrOrInt::S(s) => s.trim().parse::<i64>().map_err(|_| {
                serde::de::Error::custom(format!(
                    "allowedPlaceIds: '{s}' is not a valid place id"
                ))
            }),
        })
        .collect()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Policy {
    /// Channel this repo is pinned to (e.g. "release"). When set and the running
    /// build is on a different channel, writes are blocked. Absent = no pin.
    /// Added with `#[serde(default)]` so older daemons ignore it (see
    /// `.cursor/rules/policy-schema-compat.mdc`).
    #[serde(default)]
    pub target_channel: Option<String>,
    /// Place IDs allowed for write-safety checks. Empty = allow all places (fail-open default).
    #[serde(default, deserialize_with = "de_place_ids")]
    pub allowed_place_ids: Vec<i64>,
    #[serde(default)]
    pub allowed_write_paths: Vec<String>,
    #[serde(default)]
    pub require_generated_header_paths: Vec<String>,
    #[serde(default = "default_max_patch_bytes")]
    pub max_patch_bytes: u64,
    #[serde(default)]
    pub max_patch_items: Option<usize>,
    #[serde(default)]
    pub max_delete_count: Option<usize>,
    #[serde(default)]
    pub owned_paths: Vec<String>,
    #[serde(default)]
    pub owned_services: Vec<String>,
    #[serde(default)]
    pub live_capture_scope: Option<Vec<String>>,
    #[serde(default = "default_unsupported")]
    pub unsupported_feature_behavior: String,
    #[serde(default)]
    pub lease: Option<Value>,
}

fn default_max_patch_bytes() -> u64 {
    DEFAULT_MAX_PATCH_BYTES
}

fn default_unsupported() -> String {
    DEFAULT_UNSUPPORTED.to_string()
}

#[derive(Debug, Clone)]
pub struct CompiledPolicy {
    pub policy: Policy,
    allow_globs: GlobSet,
    header_globs: GlobSet,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PolicyExplain {
    pub path: String,
    pub allowed: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub matched_allow_glob: Option<String>,
    pub header_required: bool,
    pub size_cap: u64,
    pub place_allowed: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    pub note: &'static str,
}

impl Policy {
    pub fn validate(&self) -> Vec<String> {
        let mut errors = Vec::new();
        if self.max_patch_bytes == 0 {
            errors.push("maxPatchBytes must be greater than 0".to_string());
        }
        for glob in self
            .allowed_write_paths
            .iter()
            .chain(self.require_generated_header_paths.iter())
        {
            if Glob::new(glob).is_err() {
                errors.push(format!("invalid glob `{glob}`"));
            }
        }
        errors
    }

    pub fn compile(self) -> Result<CompiledPolicy, String> {
        let errors = self.validate();
        if !errors.is_empty() {
            return Err(errors.join("; "));
        }
        let mut allow_builder = GlobSetBuilder::new();
        for glob in &self.allowed_write_paths {
            allow_builder.add(Glob::new(glob).map_err(|err| err.to_string())?);
        }
        let mut header_builder = GlobSetBuilder::new();
        for glob in &self.require_generated_header_paths {
            header_builder.add(Glob::new(glob).map_err(|err| err.to_string())?);
        }
        Ok(CompiledPolicy {
            allow_globs: allow_builder.build().map_err(|err| err.to_string())?,
            header_globs: header_builder.build().map_err(|err| err.to_string())?,
            policy: self,
        })
    }

    pub fn header_required(&self, rel_path: &str) -> bool {
        self.require_generated_header_paths
            .iter()
            .any(|glob| globset_match(glob, rel_path))
    }
}

fn globset_match(glob: &str, path: &str) -> bool {
    Glob::new(glob)
        .ok()
        .is_some_and(|pattern| pattern.compile_matcher().is_match(path))
}

impl CompiledPolicy {
    pub fn policy(&self) -> &Policy {
        &self.policy
    }
}

pub fn default_policy() -> Policy {
    Policy {
        target_channel: None,
        allowed_place_ids: vec![139_581_542_512_435, 87_774_153_727_073],
        allowed_write_paths: Vec::new(),
        require_generated_header_paths: Vec::new(),
        max_patch_bytes: DEFAULT_MAX_PATCH_BYTES,
        max_patch_items: Some(500),
        max_delete_count: Some(50),
        owned_paths: Vec::new(),
        owned_services: vec![
            "ServerScriptService".to_string(),
            "ReplicatedStorage".to_string(),
            "StarterPlayer".to_string(),
        ],
        live_capture_scope: None,
        unsupported_feature_behavior: DEFAULT_UNSUPPORTED.to_string(),
        lease: Some(json!({ "enabled": true, "ttlSeconds": 60 })),
    }
}

pub fn policy_path(repo_root: &Path) -> PathBuf {
    repo_root.join(".studio-stud").join("policy.json")
}

pub fn load_policy(repo_root: &Path) -> Result<Option<Policy>, String> {
    let path = policy_path(repo_root);
    if !path.is_file() {
        return Ok(None);
    }
    let text = fs::read_to_string(&path).map_err(|err| err.to_string())?;
    let policy: Policy = serde_json::from_str(&text).map_err(|err| err.to_string())?;
    Ok(Some(policy))
}

pub fn load_compiled_policy(
    repo_root: &Path,
) -> Result<Option<CompiledPolicy>, (BlockedReason, Option<String>)> {
    match load_policy(repo_root) {
        Ok(Some(policy)) => policy
            .compile()
            .map(Some)
            .map_err(|detail| (BlockedReason::InternalError, Some(detail))),
        Ok(None) => Ok(None),
        Err(detail) => Err((BlockedReason::InternalError, Some(detail))),
    }
}

fn absolutize_repo_root(root: PathBuf) -> Result<PathBuf, BlockedReason> {
    let base = if root.is_absolute() {
        root
    } else {
        let cwd = env::current_dir().map_err(|_| BlockedReason::InternalError)?;
        cwd.join(root)
    };
    fs::canonicalize(&base).map_err(|_| BlockedReason::InternalError)
}

pub fn resolve_repo_root(explicit: Option<&Path>) -> Result<PathBuf, BlockedReason> {
    if let Some(root) = explicit {
        return absolutize_repo_root(root.to_path_buf());
    }
    let cwd = env::current_dir().map_err(|_| BlockedReason::InternalError)?;
    if let Some(root) = find_ancestor(&cwd, |path| policy_path(path).is_file()) {
        return absolutize_repo_root(root);
    }
    if let Some(root) = find_ancestor(&cwd, |path| {
        path.join("default.project.json").is_file() || path.join(".git").exists()
    }) {
        return absolutize_repo_root(root);
    }
    Err(BlockedReason::InternalError)
}

fn find_ancestor(start: &Path, predicate: impl Fn(&Path) -> bool) -> Option<PathBuf> {
    let mut current = Some(start.to_path_buf());
    while let Some(path) = current {
        if predicate(&path) {
            return Some(path);
        }
        current = path.parent().map(Path::to_path_buf);
    }
    None
}

pub fn normalize_rel_path(path: &str) -> String {
    path.replace('\\', "/")
}

pub fn check_path(
    repo_root: &Path,
    compiled: &CompiledPolicy,
    rel_path: &str,
    content: &[u8],
    place_id: Option<i64>,
) -> Option<BlockedReason> {
    let normalized_path = normalize_rel_path(rel_path);
    if normalized_path.is_empty() {
        return Some(BlockedReason::PathNotAllowed);
    }

    if path_string_unsafe(&normalized_path) {
        return Some(BlockedReason::PathNotAllowed);
    }

    if resolve_write_target(repo_root, &normalized_path).is_err() {
        return Some(BlockedReason::PathNotAllowed);
    }

    if !compiled.allow_globs.is_match(&normalized_path) {
        return Some(BlockedReason::PathNotAllowed);
    }

    if let Some(place_id) = place_id
        && !compiled.policy.allowed_place_ids.is_empty()
        && !compiled.policy.allowed_place_ids.contains(&place_id)
    {
        return Some(BlockedReason::PlaceMismatch);
    }

    let content_text = match std::str::from_utf8(content) {
        Ok(text) => text,
        Err(_) => return Some(BlockedReason::InvalidUtf8),
    };

    let normalized_content = normalize_newlines(content_text);
    let normalized_bytes = normalized_content.as_bytes();
    if normalized_bytes.len() as u64 > compiled.policy.max_patch_bytes {
        return Some(BlockedReason::Oversize);
    }

    if compiled.header_globs.is_match(&normalized_path)
        && !has_generated_header(&normalized_content)
    {
        return Some(BlockedReason::HeaderMissing);
    }

    if requires_luau_parse(&normalized_path) && parse_luau(&normalized_content).is_err() {
        return Some(BlockedReason::ParseError);
    }

    None
}

pub fn explain_path(
    repo_root: &Path,
    compiled: &CompiledPolicy,
    rel_path: &str,
    place_id: Option<i64>,
) -> PolicyExplain {
    let normalized_path = normalize_rel_path(rel_path);
    let note = "header presence, Luau parse, and CAS are checked at validate/apply time";
    let header_required = compiled.header_globs.is_match(&normalized_path);
    let size_cap = compiled.policy.max_patch_bytes;
    let place_allowed = place_allowed(&compiled.policy, place_id);
    if normalized_path.is_empty() || path_string_unsafe(&normalized_path) {
        return PolicyExplain {
            path: normalized_path,
            allowed: false,
            matched_allow_glob: None,
            header_required,
            size_cap,
            place_allowed,
            reason: Some(BlockedReason::PathNotAllowed.as_str().to_string()),
            note,
        };
    }

    if resolve_write_target(repo_root, &normalized_path).is_err() {
        return PolicyExplain {
            path: normalized_path,
            allowed: false,
            matched_allow_glob: None,
            header_required,
            size_cap,
            place_allowed,
            reason: Some(BlockedReason::PathNotAllowed.as_str().to_string()),
            note,
        };
    }

    let matched_allow_glob = compiled
        .policy
        .allowed_write_paths
        .iter()
        .find(|glob| globset_match(glob, &normalized_path))
        .cloned();

    if matched_allow_glob.is_none() {
        return PolicyExplain {
            path: normalized_path,
            allowed: false,
            matched_allow_glob: None,
            header_required,
            size_cap,
            place_allowed,
            reason: Some(BlockedReason::PathNotAllowed.as_str().to_string()),
            note,
        };
    }

    if let Some(place_id) = place_id
        && !compiled.policy.allowed_place_ids.is_empty()
        && !compiled.policy.allowed_place_ids.contains(&place_id)
    {
        return PolicyExplain {
            path: normalized_path,
            allowed: false,
            matched_allow_glob,
            header_required,
            size_cap,
            place_allowed: false,
            reason: Some(BlockedReason::PlaceMismatch.as_str().to_string()),
            note,
        };
    }

    PolicyExplain {
        path: normalized_path,
        allowed: true,
        matched_allow_glob,
        header_required,
        size_cap,
        place_allowed,
        reason: None,
        note,
    }
}

/// Empty `allowed_place_ids` allows any place (fail-open); a non-empty list enforces membership.
fn place_allowed(policy: &Policy, place_id: Option<i64>) -> bool {
    policy.allowed_place_ids.is_empty()
        || place_id.is_some_and(|id| policy.allowed_place_ids.contains(&id))
        || place_id.is_none()
}

/// Returns a block reason + human detail when the repo pins a `targetChannel` that
/// differs from the channel this build is running on. `None` when there is no pin,
/// the pin is blank, or the channels match (case-insensitive). The caller supplies
/// `running_channel` and decides any override, keeping this function pure.
pub fn channel_pin_violation(
    policy: &Policy,
    running_channel: &str,
) -> Option<(BlockedReason, String)> {
    let target = policy.target_channel.as_deref()?.trim();
    if target.is_empty() || target.eq_ignore_ascii_case(running_channel.trim()) {
        return None;
    }
    Some((
        BlockedReason::ChannelMismatch,
        format!(
            "This repo is pinned to the '{target}' channel but this build is running on \
             '{running_channel}'. Reinstall on the '{target}' channel, or set \
             STUDIO_STUD_ALLOW_CHANNEL_MISMATCH=1 to override for this command."
        ),
    ))
}

pub fn has_generated_header(content: &str) -> bool {
    content
        .lines()
        .take(3)
        .any(|line| line.trim().starts_with(AUTO_GENERATED_MARKER))
}

pub fn requires_luau_parse(rel_path: &str) -> bool {
    rel_path.ends_with(".luau") || rel_path.ends_with(".lua")
}

pub fn resolve_write_target(repo_root: &Path, rel_path: &str) -> Result<PathBuf, BlockedReason> {
    let normalized = normalize_rel_path(rel_path);
    if path_string_unsafe(&normalized) {
        return Err(BlockedReason::PathNotAllowed);
    }
    let abs = repo_root.join(normalized.replace('/', std::path::MAIN_SEPARATOR_STR));
    let parent = abs.parent().ok_or(BlockedReason::PathNotAllowed)?;
    if !parent.exists() {
        return Err(BlockedReason::PathNotAllowed);
    }
    let canon_root = repo_root
        .canonicalize()
        .map_err(|_| BlockedReason::InternalError)?;
    let canon_parent = parent
        .canonicalize()
        .map_err(|_| BlockedReason::PathNotAllowed)?;
    if !canon_parent.starts_with(&canon_root) {
        return Err(BlockedReason::PathNotAllowed);
    }
    Ok(abs)
}

fn path_string_unsafe(rel: &str) -> bool {
    if rel.is_empty() {
        return true;
    }
    if rel.starts_with('/') || rel.starts_with('\\') {
        return true;
    }
    if rel.len() >= 2 && rel.as_bytes()[1] == b':' {
        return true;
    }
    if rel.starts_with("\\\\?\\") || rel.starts_with("\\\\") {
        return true;
    }
    for segment in rel.split('/') {
        if segment == ".." || segment == "." {
            return true;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::sync::Mutex;

    static CWD_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn default_policy_validates() {
        let policy = default_policy();
        assert!(policy.validate().is_empty());
    }

    #[test]
    fn rejects_invalid_glob_on_compile() {
        let mut policy = default_policy();
        policy.allowed_write_paths = vec!["[".to_string()];
        assert!(policy.compile().is_err());
    }

    #[test]
    fn channel_pin_only_blocks_on_mismatch() {
        let mut policy = default_policy();

        // No pin → never blocks, regardless of running channel.
        assert!(channel_pin_violation(&policy, "dev").is_none());

        // Pinned and matching (case-insensitive) → allowed.
        policy.target_channel = Some("release".to_string());
        assert!(channel_pin_violation(&policy, "release").is_none());
        assert!(channel_pin_violation(&policy, "RELEASE").is_none());

        // Blank pin is treated as no pin.
        policy.target_channel = Some("  ".to_string());
        assert!(channel_pin_violation(&policy, "dev").is_none());

        // Pinned to release, running dev → blocked with a ChannelMismatch reason.
        policy.target_channel = Some("release".to_string());
        let (reason, detail) = channel_pin_violation(&policy, "dev").expect("should block");
        assert_eq!(reason, BlockedReason::ChannelMismatch);
        assert!(detail.contains("release") && detail.contains("dev"));
    }

    #[test]
    fn repo_root_relative_resolves() {
        let _guard = CWD_LOCK.lock().unwrap();
        let prev = env::current_dir().unwrap();
        let dir = env::temp_dir().join(format!(
            "studio_stud_repo_root_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(dir.join(".studio-stud")).unwrap();
        fs::write(dir.join(".studio-stud/policy.json"), r#"{"version":1}"#).unwrap();
        env::set_current_dir(&dir).unwrap();
        let root = resolve_repo_root(Some(Path::new("."))).expect("resolve .");
        assert!(root.is_absolute());
        assert!(policy_path(&root).is_file());
        env::set_current_dir(&prev).unwrap();
        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn check_path_blocks_traversal_and_allows_clean_path() {
        let dir = std::env::temp_dir().join(format!(
            "studio_stud_policy_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(dir.join("synced")).unwrap();
        fs::create_dir_all(dir.join(".studio-stud")).unwrap();
        fs::write(
            dir.join(".studio-stud/policy.json"),
            r#"{
            "version": 1,
            "allowedWritePaths": ["synced/**/*.luau"],
            "maxPatchBytes": 1024
        }"#,
        )
        .unwrap();
        let policy = load_policy(&dir).unwrap().unwrap().compile().unwrap();
        let content = b"--!strict\nreturn 1\n";
        assert_eq!(
            check_path(&dir, &policy, "../escape.luau", content, None),
            Some(BlockedReason::PathNotAllowed)
        );
        assert_eq!(
            check_path(&dir, &policy, "synced/foo.luau", content, None),
            None
        );
        fs::remove_dir_all(dir).ok();
    }
}
