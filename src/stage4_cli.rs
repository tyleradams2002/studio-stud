use std::path::PathBuf;

use anyhow::{Result, anyhow};
use clap::{Parser, Subcommand};
use serde_json::json;

use crate::{
    cli::CommonArgs,
    diff::{compute_diff, diff_json_value},
    policy::resolve_repo_root,
    project::{build_index, build_projection, parse_manifest},
    storage::Storage,
};

#[derive(Parser)]
pub(crate) struct ProjectArgs {
    #[arg(long, global = true)]
    pub repo_root: Option<PathBuf>,
    #[command(subcommand)]
    pub action: ProjectAction,
}

#[derive(Subcommand)]
pub(crate) enum ProjectAction {
    Index {
        #[arg(long)]
        full: bool,
        #[arg(long)]
        markdown: bool,
    },
    Projection {
        #[arg(long)]
        full: bool,
        #[arg(long)]
        markdown: bool,
    },
    Diff {
        #[arg(value_name = "PLACE_ID_OR_KEY")]
        place: Option<String>,
        #[arg(long)]
        under: Option<String>,
        #[arg(long, default_value_t = 25)]
        limit: usize,
        #[arg(long)]
        markdown: bool,
        #[arg(long)]
        verbose: bool,
        #[command(flatten)]
        common: CommonArgs,
    },
    Check {
        #[arg(long)]
        markdown: bool,
    },
}

pub(crate) fn cmd_project(args: ProjectArgs) -> Result<()> {
    let repo_root = resolve_repo_root(args.repo_root.as_deref())
        .map_err(|reason| anyhow!("{}", reason.as_str()))?;
    match args.action {
        ProjectAction::Index { full, markdown } => cmd_project_index(&repo_root, full, markdown),
        ProjectAction::Projection { full, markdown } => {
            cmd_project_projection(&repo_root, full, markdown)
        }
        ProjectAction::Diff {
            place,
            under,
            limit,
            markdown,
            verbose,
            common,
        } => {
            let storage = Storage::new(common.storage_root.clone(), &common.project_key)?;
            cmd_project_diff(
                &repo_root,
                &storage,
                place.as_deref(),
                under.as_deref(),
                limit,
                markdown,
                verbose,
            )
        }
        ProjectAction::Check { markdown } => cmd_project_check(&repo_root, markdown),
    }
}

fn cmd_project_index(repo_root: &PathBuf, full: bool, markdown: bool) -> Result<()> {
    let manifest = parse_manifest(repo_root).map_err(|e| project_err(&e))?;
    let index = build_index(&manifest, repo_root)?;
    let mut role_counts = std::collections::BTreeMap::new();
    let mut projected = 0usize;
    let mut unprojected = 0usize;
    for entry in &index.entries {
        let role_key = serde_json::to_string(&entry.role)
            .unwrap_or_else(|_| "\"Unknown\"".to_string());
        *role_counts.entry(role_key).or_insert(0) += 1;
        if entry.projected {
            projected += 1;
        } else {
            unprojected += 1;
        }
    }
    let mut payload = json!({
        "ok": true,
        "entryCount": index.entries.len(),
        "roleCounts": role_counts,
        "projected": projected,
        "unprojected": unprojected,
    });
    if full {
        let limit = 500usize;
        let truncated = index.entries.len() > limit;
        let entries: Vec<_> = index.entries.iter().take(limit).collect();
        payload["entries"] = json!(entries);
        payload["truncated"] = json!(truncated);
        payload["limit"] = json!(limit);
    }
    emit(payload, markdown)
}

fn cmd_project_projection(repo_root: &PathBuf, full: bool, markdown: bool) -> Result<()> {
    let manifest = parse_manifest(repo_root).map_err(|e| project_err(&e))?;
    let index = build_index(&manifest, repo_root)?;
    let projection = build_projection(&manifest, repo_root, &index);
    let mut class_counts = std::collections::BTreeMap::new();
    for inst in projection.by_key.values() {
        *class_counts.entry(inst.class_name.clone()).or_insert(0) += 1;
    }
    let mut payload = json!({
        "ok": projection.errors.is_empty(),
        "instanceCount": projection.by_key.len(),
        "classCounts": class_counts,
        "projectionErrors": projection.errors.len(),
        "projectionWarnings": projection.warnings.len(),
        "errors": projection.errors,
        "warnings": projection.warnings,
    });
    if full {
        let limit = 500usize;
        let mut items: Vec<_> = projection.by_key.values().collect();
        items.sort_by(|a, b| a.studio_path.cmp(&b.studio_path));
        let truncated = items.len() > limit;
        items.truncate(limit);
        payload["instances"] = json!(items);
        payload["truncated"] = json!(truncated);
        payload["limit"] = json!(limit);
    }
    if !projection.errors.is_empty() {
        emit(payload, markdown)?;
        return Err(anyhow!("projection has errors"));
    }
    emit(payload, markdown)
}

fn cmd_project_diff(
    repo_root: &PathBuf,
    storage: &Storage,
    place: Option<&str>,
    under: Option<&str>,
    limit: usize,
    markdown: bool,
    verbose: bool,
) -> Result<()> {
    let diff = compute_diff(repo_root, storage, place, under, limit, verbose)?;
    emit(diff_json_value(&diff), markdown)
}

fn cmd_project_check(repo_root: &PathBuf, markdown: bool) -> Result<()> {
    let manifest = parse_manifest(repo_root).map_err(|e| project_err(&e))?;
    let index = build_index(&manifest, repo_root)?;
    let projection = build_projection(&manifest, repo_root, &index);
    let policy = crate::policy::load_compiled_policy(repo_root).ok().flatten();
    let mut synced = 0usize;
    let mut blocked = 0usize;
    for inst in projection.by_key.values() {
        if inst.source_repo_path.is_none() {
            continue;
        }
        synced += 1;
        if let Some(ref compiled) = policy {
            let path = crate::policy::normalize_rel_path(inst.source_repo_path.as_ref().unwrap());
            if crate::policy::check_path(repo_root, compiled, &path, b"", None).is_some() {
                blocked += 1;
            }
        } else {
            blocked += 1;
        }
    }
    let ok = projection.errors.is_empty();
    let payload = json!({
        "ok": ok,
        "projectionErrors": projection.errors.len(),
        "projectionWarnings": projection.warnings.len(),
        "projectedInstances": projection.by_key.len(),
        "policyReadiness": {
            "syncedPaths": synced,
            "blockedPaths": blocked,
        },
        "errors": projection.errors,
    });
    if !ok {
        emit(payload, markdown)?;
        return Err(anyhow!("project check failed"));
    }
    emit(payload, markdown)
}

fn emit(value: serde_json::Value, markdown: bool) -> Result<()> {
    if markdown {
        println!("```json\n{}\n```", serde_json::to_string_pretty(&value)?);
    } else {
        println!("{}", serde_json::to_string(&value)?);
    }
    Ok(())
}

fn project_err(e: &crate::project::ProjectError) -> anyhow::Error {
    anyhow!(
        "{}",
        serde_json::to_string(&json!({ "ok": false, "error": e.message, "detail": e.detail })).unwrap()
    )
}
