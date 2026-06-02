use std::{
    fs,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, anyhow};
use clap::{Parser, Subcommand};
use serde_json::{Value, json};
use uuid::Uuid;

use crate::{
    policy::{
        default_policy, explain_path, load_compiled_policy, load_policy, policy_path,
        resolve_repo_root,
    },
    write::{
        BlockedReason, WriteMode, WriteOutcome, WriteRequest, file::execute as execute_write,
        safety::atomic_write,
    },
};

#[derive(Parser)]
pub(crate) struct PolicyArgs {
    #[arg(long, global = true)]
    repo_root: Option<PathBuf>,
    #[command(subcommand)]
    action: PolicyAction,
}

#[derive(Subcommand)]
pub(crate) enum PolicyAction {
    Init {
        #[arg(long)]
        force: bool,
    },
    Check,
    Explain {
        #[arg(long)]
        path: String,
        #[arg(long)]
        place: Option<i64>,
    },
}

#[derive(Parser)]
pub(crate) struct WriteValidateArgs {
    #[arg(long)]
    repo_root: PathBuf,
    #[arg(long)]
    path: String,
    #[arg(long)]
    content_file: PathBuf,
    #[arg(long)]
    place: Option<i64>,
}

#[derive(Parser)]
pub(crate) struct WritePreviewArgs {
    #[arg(long)]
    repo_root: PathBuf,
    #[arg(long)]
    path: String,
    #[arg(long)]
    content_file: PathBuf,
}

#[derive(Parser)]
pub(crate) struct WriteApplyArgs {
    #[arg(long)]
    repo_root: PathBuf,
    #[arg(long)]
    path: String,
    #[arg(long)]
    content_file: PathBuf,
    #[arg(long)]
    expected_hash: Option<String>,
    #[arg(long)]
    generated_by: Option<String>,
    #[arg(long)]
    place: Option<i64>,
}

pub(crate) fn cmd_policy(args: PolicyArgs) -> Result<()> {
    let repo_root =
        resolve_repo_root(args.repo_root.as_deref()).map_err(|reason| anyhow!(reason.as_str()))?;
    match args.action {
        PolicyAction::Init { force } => cmd_policy_init(&repo_root, force),
        PolicyAction::Check => cmd_policy_check(&repo_root),
        PolicyAction::Explain { path, place } => cmd_policy_explain(&repo_root, &path, place),
    }
}

fn cmd_policy_init(repo_root: &Path, force: bool) -> Result<()> {
    fs::create_dir_all(repo_root.join(".studio-stud"))?;
    let path = policy_path(repo_root);
    if path.is_file() && !force {
        return Err(anyhow!(
            "policy file already exists at {}; pass --force to overwrite",
            path.display()
        ));
    }
    let policy = default_policy();
    let bytes = serde_json::to_vec_pretty(&policy)?;
    atomic_write(&path, &bytes)?;
    println!(
        "{}",
        serde_json::to_string(&json!({
            "ok": true,
            "path": path,
            "created": true,
        }))?
    );
    Ok(())
}

fn cmd_policy_check(repo_root: &Path) -> Result<()> {
    let path = policy_path(repo_root);
    let Some(policy) = load_policy(repo_root).map_err(|detail| anyhow!(detail))? else {
        println!(
            "{}",
            serde_json::to_string(&json!({
                "ok": false,
                "valid": false,
                "errors": ["noPolicy"],
                "path": path,
            }))?
        );
        return Err(anyhow!("policy file missing"));
    };
    let errors = policy.validate();
    let valid = errors.is_empty();
    println!(
        "{}",
        serde_json::to_string(&json!({
            "ok": valid,
            "valid": valid,
            "errors": errors,
            "path": path,
        }))?
    );
    if valid {
        Ok(())
    } else {
        Err(anyhow!("policy validation failed"))
    }
}

fn cmd_policy_explain(repo_root: &Path, rel_path: &str, place_id: Option<i64>) -> Result<()> {
    let Some(compiled) = load_compiled_policy(repo_root).map_err(|(reason, detail)| {
        anyhow!(detail.unwrap_or_else(|| reason.as_str().to_string()))
    })?
    else {
        return Err(anyhow!("noPolicy"));
    };
    let explain = explain_path(repo_root, &compiled, rel_path, place_id);
    println!("{}", serde_json::to_string(&explain)?);
    Ok(())
}

pub(crate) fn cmd_write_validate(args: WriteValidateArgs) -> Result<()> {
    run_write_command(
        &args.repo_root,
        &args.path,
        &args.content_file,
        args.place,
        None,
        None,
        WriteMode::Validate,
    )
}

pub(crate) fn cmd_write_preview(args: WritePreviewArgs) -> Result<()> {
    run_write_command(
        &args.repo_root,
        &args.path,
        &args.content_file,
        None,
        None,
        None,
        WriteMode::Preview,
    )
}

pub(crate) fn cmd_write_apply(args: WriteApplyArgs) -> Result<()> {
    run_write_command(
        &args.repo_root,
        &args.path,
        &args.content_file,
        args.place,
        args.expected_hash.as_deref(),
        args.generated_by.as_deref(),
        WriteMode::Apply,
    )
}

fn run_write_command(
    repo_root: &Path,
    rel_path: &str,
    content_file: &Path,
    place_id: Option<i64>,
    expected_hash: Option<&str>,
    generated_by: Option<&str>,
    mode: WriteMode,
) -> Result<()> {
    let content =
        fs::read(content_file).with_context(|| format!("read {}", content_file.display()))?;
    let outcome = run_write(
        repo_root,
        rel_path,
        &content,
        place_id,
        expected_hash,
        generated_by,
        mode,
    );
    print_write_outcome(&outcome)
}

pub(crate) fn run_write(
    repo_root: &Path,
    rel_path: &str,
    content: &[u8],
    place_id: Option<i64>,
    expected_hash: Option<&str>,
    generated_by: Option<&str>,
    mode: WriteMode,
) -> WriteOutcome {
    let req = WriteRequest {
        path: rel_path,
        content,
        expected_hash,
        generated_by,
        place_id,
    };
    match load_compiled_policy(repo_root) {
        Ok(Some(compiled)) => execute_write(repo_root, &compiled, &req, mode),
        Ok(None) => WriteOutcome::blocked(BlockedReason::NoPolicy, rel_path, None),
        Err((reason, detail)) => WriteOutcome::blocked(reason, rel_path, detail),
    }
}

pub(crate) fn print_write_outcome(outcome: &WriteOutcome) -> Result<()> {
    println!("{}", serde_json::to_string(outcome)?);
    if outcome.blocked {
        Err(anyhow!(
            outcome
                .blocked_reason
                .clone()
                .unwrap_or_else(|| "blocked".to_string())
        ))
    } else {
        Ok(())
    }
}

pub(crate) fn load_or_create_write_token(storage_root: &Path) -> Result<String> {
    fs::create_dir_all(storage_root)?;
    let path = storage_root.join("write.token");
    if path.is_file() {
        let token = fs::read_to_string(&path)?.trim().to_string();
        if !token.is_empty() {
            return Ok(token);
        }
    }
    let token = Uuid::new_v4().to_string();
    atomic_write(&path, token.as_bytes())?;
    Ok(token)
}

pub(crate) fn write_outcome_to_json(outcome: &WriteOutcome) -> Value {
    serde_json::to_value(outcome).unwrap_or_else(|_| json!({ "ok": false, "blocked": true }))
}
