use std::{
    collections::{BTreeMap, HashMap, HashSet},
    path::Path,
};

use anyhow::{Context, Result, anyhow};
use rusqlite::Connection;
use serde::Serialize;
use serde_json::{Value, json};

use crate::{
    policy::{check_path, load_compiled_policy, normalize_rel_path},
    project::{
        DesiredInstance, DesiredProjection, FileRole, RepoIndex, build_index, build_projection,
        parse_manifest,
    },
    storage::{Storage, read_live_state, resolve_place},
    util::{STALE_DB_SCHEMA_MSG, normalize_query_path, open_db_readonly},
};

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectDiff {
    pub ok: bool,
    pub place: String,
    pub summary: DiffSummary,
    pub projection_errors: usize,
    pub projection_warnings: usize,
    pub categories: DiffCategories,
    pub policy_readiness: PolicyReadiness,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DiffSummary {
    pub matched: usize,
    pub class_mismatch: usize,
    pub missing_in_studio: usize,
    pub extra_in_studio: usize,
    pub studio_owned: usize,
    pub unsupported: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DiffCategories {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub class_mismatch: Option<BoundedCategory<ClassMismatchItem>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub missing_in_studio: Option<BoundedCategory<MissingInStudioItem>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub extra_in_studio: Option<BoundedCategory<ExtraInStudioItem>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub matched: Option<BoundedCategory<StudioPathItem>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub studio_owned: Option<BoundedCategory<StudioPathItem>>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BoundedCategory<T> {
    pub total: usize,
    pub returned: usize,
    pub limit: usize,
    pub truncated: bool,
    pub items: Vec<T>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClassMismatchItem {
    pub studio_path: String,
    pub desired_class: String,
    pub actual_class: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MissingInStudioItem {
    pub studio_path: String,
    pub class: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_repo_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_hash: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExtraInStudioItem {
    pub studio_path: String,
    pub actual_class: String,
    pub owner_root: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StudioPathItem {
    pub studio_path: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PolicyReadiness {
    pub synced_paths_allowed: usize,
    pub synced_paths_blocked: usize,
    pub blocked_samples: Vec<BlockedPathSample>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BlockedPathSample {
    pub source_repo_path: String,
    pub reason: String,
}

#[derive(Clone)]
struct ActualRow {
    instance_id: String,
    path: String,
    class_name: String,
    key: String,
}

struct Classification {
    matched: Vec<ActualRow>,
    class_mismatch: Vec<(DesiredInstance, ActualRow)>,
    missing_in_studio: Vec<DesiredInstance>,
    extra_in_studio: Vec<(ActualRow, String)>,
    studio_owned: Vec<ActualRow>,
}

pub(crate) fn compute_diff(
    repo_root: &Path,
    storage: &Storage,
    place: Option<&str>,
    under: Option<&str>,
    limit: usize,
    verbose: bool,
) -> Result<ProjectDiff> {
    let manifest = parse_manifest(repo_root).map_err(|e| anyhow!("{}", e.message))?;
    let index = build_index(&manifest, repo_root)?;
    let projection = build_projection(&manifest, repo_root, &index);

    let place_storage = resolve_place(storage, place)?;
    let conn = open_db_readonly(&place_storage.db_path).context("open db readonly")?;
    let live = read_live_state(&conn)?.ok_or_else(|| anyhow!(STALE_DB_SCHEMA_MSG))?;

    let actual_rows = load_actual_rows(&conn, &live.capture_id)?;
    if actual_rows.is_empty() && live.instance_count > 0 {
        return Err(anyhow!(STALE_DB_SCHEMA_MSG));
    }

    let unsupported = count_unsupported(&index);
    let mut class = classify(&projection, &actual_rows, &index);

    if let Some(filter) = under {
        let prefix = normalize_query_path(filter);
        class = filter_classification(class, &prefix);
    }

    let policy_readiness = policy_readiness_report(repo_root, &projection)?;

    Ok(build_output(
        live.place_id,
        &projection,
        class,
        unsupported,
        limit,
        verbose,
        policy_readiness,
    ))
}

fn load_actual_rows(conn: &Connection, capture_id: &str) -> Result<Vec<ActualRow>> {
    let mut stmt = conn.prepare(
        "SELECT instance_id, path, class_name, path_norm FROM instances WHERE capture_id = ?1",
    )?;
    let rows = stmt.query_map([capture_id], |row| {
        let path: String = row.get(1)?;
        let path_norm: Option<String> = row.get(3)?;
        let key = path_norm
            .clone()
            .filter(|p| !p.is_empty())
            .unwrap_or_else(|| normalize_query_path(&path));
        if key.is_empty() {
            return Err(rusqlite::Error::InvalidQuery);
        }
        Ok(ActualRow {
            instance_id: row.get(0)?,
            path,
            class_name: row.get(2)?,
            key,
        })
    })?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    out.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(out)
}

fn classify(
    projection: &DesiredProjection,
    actual_rows: &[ActualRow],
    index: &RepoIndex,
) -> Classification {
    let _ = index;
    let mut unconsumed: HashSet<String> =
        actual_rows.iter().map(|r| r.instance_id.clone()).collect();

    let mut by_key: HashMap<String, Vec<&ActualRow>> = HashMap::new();
    for row in actual_rows {
        by_key.entry(row.key.clone()).or_default().push(row);
    }
    for rows in by_key.values_mut() {
        rows.sort_by(|a, b| a.path.cmp(&b.path));
    }

    let mut matched = Vec::new();
    let mut class_mismatch = Vec::new();
    let mut missing_in_studio = Vec::new();

    for desired in projection.by_key.values() {
        let rows = by_key
            .get(&desired.normalized_key)
            .cloned()
            .unwrap_or_default();
        if rows.is_empty() {
            missing_in_studio.push(desired.clone());
            continue;
        }
        let mut paired = false;
        for row in rows {
            if !unconsumed.contains(&row.instance_id) {
                continue;
            }
            if !paired {
                if row.class_name == desired.class_name {
                    matched.push(row.clone());
                    unconsumed.remove(&row.instance_id);
                } else {
                    class_mismatch.push((desired.clone(), row.clone()));
                    unconsumed.remove(&row.instance_id);
                }
                paired = true;
            }
        }
    }

    let mut extra_in_studio = Vec::new();
    let mut studio_owned = Vec::new();

    let mut remaining: Vec<&ActualRow> = actual_rows
        .iter()
        .filter(|r| unconsumed.contains(&r.instance_id))
        .collect();
    remaining.sort_by(|a, b| a.path.cmp(&b.path));

    for row in remaining {
        let ancestor = nearest_desired_ancestor(&row.key, &projection.by_key);
        match ancestor {
            Some(inst) if inst.ignore_unknown => {
                studio_owned.push(row.clone());
            }
            Some(inst) => {
                let owner = owner_root_for_extra(&row.key, &projection.by_key);
                extra_in_studio.push((
                    row.clone(),
                    owner.unwrap_or_else(|| inst.studio_path.clone()),
                ));
            }
            None => studio_owned.push(row.clone()),
        }
        unconsumed.remove(&row.instance_id);
    }

    Classification {
        matched,
        class_mismatch,
        missing_in_studio,
        extra_in_studio,
        studio_owned,
    }
}

fn nearest_desired_ancestor<'a>(
    key: &str,
    by_key: &'a BTreeMap<String, DesiredInstance>,
) -> Option<&'a DesiredInstance> {
    let mut parts: Vec<&str> = key.split('/').collect();
    while !parts.is_empty() {
        let prefix = parts.join("/");
        if let Some(inst) = by_key.get(&prefix) {
            return Some(inst);
        }
        parts.pop();
    }
    None
}

fn owner_root_for_extra(key: &str, by_key: &BTreeMap<String, DesiredInstance>) -> Option<String> {
    let mut parts: Vec<&str> = key.split('/').collect();
    parts.pop()?;
    while !parts.is_empty() {
        let parent = parts.join("/");
        if by_key.contains_key(&parent) {
            return Some(by_key.get(&parent)?.studio_path.clone());
        }
        parts.pop();
    }
    None
}

fn count_unsupported(index: &RepoIndex) -> usize {
    index
        .entries
        .iter()
        .filter(|e| e.role == FileRole::Unsupported && !e.projected)
        .count()
}

fn filter_classification(mut class: Classification, prefix: &str) -> Classification {
    let matches = |key: &str| key == prefix || key.starts_with(&format!("{prefix}/"));
    class.matched.retain(|r| matches(&r.key));
    class
        .class_mismatch
        .retain(|(d, r)| matches(&d.normalized_key) || matches(&r.key));
    class
        .missing_in_studio
        .retain(|d| matches(&d.normalized_key));
    class.extra_in_studio.retain(|(r, _)| matches(&r.key));
    class.studio_owned.retain(|r| matches(&r.key));
    class
}

fn policy_readiness_report(
    repo_root: &Path,
    projection: &DesiredProjection,
) -> Result<PolicyReadiness> {
    let compiled =
        load_compiled_policy(repo_root).map_err(|(reason, _)| anyhow!("{:?}", reason))?;
    let mut allowed = 0usize;
    let mut blocked = 0usize;
    let mut blocked_samples = Vec::new();

    for inst in projection.by_key.values() {
        let Some(ref repo_path) = inst.source_repo_path else {
            continue;
        };
        let normalized = normalize_rel_path(repo_path);
        let (is_allowed, reason) = match &compiled {
            None => (false, "noPolicy"),
            Some(cp) => {
                if check_path(repo_root, cp, &normalized, b"", None).is_none() {
                    (true, "")
                } else {
                    (false, "pathNotAllowed")
                }
            }
        };
        if is_allowed {
            allowed += 1;
        } else {
            blocked += 1;
            if blocked_samples.len() < 25 {
                blocked_samples.push(BlockedPathSample {
                    source_repo_path: normalized,
                    reason: reason.to_string(),
                });
            }
        }
    }

    Ok(PolicyReadiness {
        synced_paths_allowed: allowed,
        synced_paths_blocked: blocked,
        blocked_samples,
    })
}

fn build_output(
    place: String,
    projection: &DesiredProjection,
    class: Classification,
    unsupported: usize,
    limit: usize,
    verbose: bool,
    policy_readiness: PolicyReadiness,
) -> ProjectDiff {
    let summary = DiffSummary {
        matched: class.matched.len(),
        class_mismatch: class.class_mismatch.len(),
        missing_in_studio: class.missing_in_studio.len(),
        extra_in_studio: class.extra_in_studio.len(),
        studio_owned: class.studio_owned.len(),
        unsupported,
    };

    let extra_items: Vec<ExtraInStudioItem> = class
        .extra_in_studio
        .iter()
        .filter(|(row, _)| extra_item_visible(row, &projection.by_key))
        .map(|(row, owner)| ExtraInStudioItem {
            studio_path: row.path.clone(),
            actual_class: row.class_name.clone(),
            owner_root: owner.clone(),
        })
        .collect();

    ProjectDiff {
        ok: true,
        place,
        summary,
        projection_errors: projection.errors.len(),
        projection_warnings: projection.warnings.len(),
        categories: DiffCategories {
            class_mismatch: Some(bounded(
                class
                    .class_mismatch
                    .into_iter()
                    .map(|(d, a)| ClassMismatchItem {
                        studio_path: d.studio_path,
                        desired_class: d.class_name,
                        actual_class: a.class_name,
                    })
                    .collect(),
                limit,
            )),
            missing_in_studio: Some(bounded(
                class
                    .missing_in_studio
                    .into_iter()
                    .map(|d| MissingInStudioItem {
                        studio_path: d.studio_path,
                        class: d.class_name,
                        source_repo_path: d.source_repo_path,
                        source_hash: d.source_hash,
                    })
                    .collect(),
                limit,
            )),
            extra_in_studio: Some(bounded(extra_items, limit)),
            matched: if verbose {
                Some(bounded(
                    class
                        .matched
                        .into_iter()
                        .map(|r| StudioPathItem {
                            studio_path: r.path,
                        })
                        .collect(),
                    limit,
                ))
            } else {
                None
            },
            studio_owned: if verbose {
                Some(bounded(
                    class
                        .studio_owned
                        .into_iter()
                        .map(|r| StudioPathItem {
                            studio_path: r.path,
                        })
                        .collect(),
                    limit,
                ))
            } else {
                None
            },
        },
        policy_readiness,
    }
}

fn extra_item_visible(row: &ActualRow, by_key: &BTreeMap<String, DesiredInstance>) -> bool {
    let mut parts: Vec<&str> = row.key.split('/').collect();
    if parts.pop().is_none() {
        return false;
    }
    let parent = parts.join("/");
    by_key.contains_key(&parent)
}

fn bounded<T: Serialize>(mut items: Vec<T>, limit: usize) -> BoundedCategory<T> {
    let total = items.len();
    items.sort_by(|a, b| {
        let sa = serde_json::to_value(a).ok();
        let sb = serde_json::to_value(b).ok();
        sa.and_then(|va| {
            va.get("studioPath")
                .and_then(|v| v.as_str())
                .map(str::to_string)
        })
        .cmp(&sb.and_then(|vb| {
            vb.get("studioPath")
                .and_then(|v| v.as_str())
                .map(str::to_string)
        }))
    });
    let truncated = total > limit;
    let returned = total.min(limit);
    items.truncate(limit);
    BoundedCategory {
        total,
        returned,
        limit,
        truncated,
        items,
    }
}

pub fn diff_json_value(diff: &ProjectDiff) -> Value {
    serde_json::to_value(diff).unwrap_or(json!({ "ok": false }))
}
