mod gui;

use std::path::PathBuf;

use anyhow::Result;
use clap::{Parser, Subcommand};
use serde_json::json;
use studio_stud::setup_core::channels::{Channel, check_anti_rollback, fetch_manifest, verify_manifest_signature};
use studio_stud::setup_core::config::{load_config_or_default, save_config};
use studio_stud::setup_core::health::{
    health_json, repo_health_checks, repo_health_json, user_health_checks,
};
use studio_stud::setup_core::install::{
    default_install_root, install_core_plugin, lay_tool_payload, migrate_legacy_repo,
    read_daemon_lock_port, stop_daemon_graceful, write_starter_policy,
};
use studio_stud::update;

#[derive(Parser)]
#[command(name = "studio-stud-setup", version, about = "Studio Stud install / update / health")]
struct Cli {
    #[arg(long, global = true)]
    json: bool,
    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand)]
enum Commands {
    /// Launch GUI installer (default)
    Install,
    /// Launch GUI uninstaller
    Uninstall,
    /// Check or apply updates
    Update {
        #[arg(long)]
        check: bool,
    },
    /// Verify installation; runs repair on failure
    Health,
    /// Silent reinstall preserving config
    Repair,
    /// Repo-scoped health
    RepoHealth { path: PathBuf },
    /// Repo-scoped repair / migration
    RepoRepair { path: PathBuf },
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command.unwrap_or(Commands::Install) {
        Commands::Install => gui::run_install_gui().map_err(|e| anyhow::anyhow!("{e}"))?,
        Commands::Uninstall => gui::run_uninstall_gui().map_err(|e| anyhow::anyhow!("{e}"))?,
        Commands::Update { check } => cmd_update(check, cli.json)?,
        Commands::Health => cmd_health(cli.json)?,
        Commands::Repair => cmd_repair(cli.json)?,
        Commands::RepoHealth { path } => cmd_repo_health(&path, cli.json)?,
        Commands::RepoRepair { path } => cmd_repo_repair(&path, cli.json)?,
    }
    Ok(())
}

fn cmd_update(check: bool, as_json: bool) -> Result<()> {
    let cfg = load_config_or_default();
    let channel = Channel::from_str(&cfg.channel);
    let (manifest, raw) = fetch_manifest(channel)?;
    verify_manifest_signature(&raw, &manifest)?;
    check_anti_rollback(channel, &manifest, &cfg.last_channel_sequence)?;
    let report = update::check(studio_stud::update::LATEST_URL)?;
    if as_json {
        println!(
            "{}",
            json!({
                "updateAvailable": report.update_available,
                "installed": report.installed_daemon,
                "latest": report.latest_daemon,
                "checkOnly": check,
            })
        );
    } else {
        println!(
            "installed={} latest={} update={}",
            report.installed_daemon, report.latest_daemon, report.update_available
        );
    }
    if !check && report.update_available {
        apply_user_update(&cfg)?;
    }
    Ok(())
}

fn apply_user_update(cfg: &studio_stud::setup_core::StudioStudConfig) -> Result<()> {
    let install_root = PathBuf::from(&cfg.install_root);
    let exe = install_root.join("bin").join("studio-stud.exe");
    if let Some(port) = read_daemon_lock_port() {
        let token_path = studio_stud::setup_core::config::write_token_path();
        if token_path.is_file()
            && let Ok(tok) = std::fs::read_to_string(&token_path)
        {
            let _ = stop_daemon_graceful(tok.trim(), port);
        }
    }
    let daemon_src = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("bin")
        .join("studio-stud.exe");
    let plugin_src = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("plugin")
        .join("StudioStud.plugin.lua");
    lay_tool_payload(&install_root, &daemon_src, &plugin_src)?;
    install_core_plugin(PathBuf::from(&cfg.plugins_dir).as_path(), &plugin_src)?;
    update::apply_staged_on_boot();
    Ok(())
}

fn cmd_health(as_json: bool) -> Result<()> {
    let cfg = load_config_or_default();
    let checks = user_health_checks(&cfg);
    let failed = checks.iter().any(|c| c.status == "fail");
    if as_json {
        println!("{}", health_json());
    } else {
        for c in &checks {
            println!("{}: {} — {}", c.name, c.status, c.detail);
        }
    }
    if failed {
        cmd_repair(as_json)?;
    }
    Ok(())
}

fn cmd_repair(as_json: bool) -> Result<()> {
    let mut cfg = load_config_or_default();
    if cfg.install_root.is_empty() {
        cfg.install_root = default_install_root().display().to_string();
    }
    apply_user_update(&cfg)?;
    for repo in cfg.repos.clone() {
        let p = PathBuf::from(&repo.path);
        write_starter_policy(&p)?;
        let _ = migrate_legacy_repo(&p, &mut cfg);
    }
    save_config(&cfg)?;
    if !as_json {
        println!("Repair complete (config preserved).");
    }
    Ok(())
}

fn cmd_repo_health(path: &PathBuf, as_json: bool) -> Result<()> {
    if as_json {
        println!("{}", repo_health_json(path));
    } else {
        let checks = repo_health_checks(path);
        for c in &checks {
            println!("{}: {} — {}", c.name, c.status, c.detail);
        }
    }
    Ok(())
}

fn cmd_repo_repair(path: &PathBuf, as_json: bool) -> Result<()> {
    let mut cfg = load_config_or_default();
    write_starter_policy(path)?;
    migrate_legacy_repo(path, &mut cfg)?;
    save_config(&cfg)?;
    if !as_json {
        println!("Repo repair complete for {}", path.display());
    }
    Ok(())
}
