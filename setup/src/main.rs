mod gui;
mod install_flow;
mod theme;
mod update_apply;

use std::path::PathBuf;

use anyhow::Result;
use clap::{Parser, Subcommand};
use serde_json::json;
use studio_stud::setup_core::channels::{
    Channel, channel_update_available_seq, check_anti_rollback, fetch_manifest_with_fallback,
    verify_manifest_signature,
};
use studio_stud::setup_core::config::{load_config_or_default, save_config};
use studio_stud::setup_core::health::{
    health_json, repo_health_checks, repo_health_json, user_health_checks,
};
use studio_stud::setup_core::install::{default_install_root, migrate_legacy_repo, write_starter_policy};
use studio_stud::update;

use install_flow::{HeadlessInstallParams, resolve_daemon_src, resolve_plugin_src, run_install_headless};

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
    Install {
        #[arg(long)]
        silent: bool,
        #[arg(long)]
        daemon: Option<PathBuf>,
        #[arg(long)]
        plugin: Option<PathBuf>,
    },
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
    match cli.command.unwrap_or(Commands::Install {
        silent: false,
        daemon: None,
        plugin: None,
    }) {
        Commands::Install {
            silent: true,
            daemon,
            plugin,
        } => cmd_install_silent(daemon, plugin)?,
        Commands::Install {
            silent: false,
            ..
        } => gui::run_install_gui().map_err(|e| anyhow::anyhow!("{e}"))?,
        Commands::Uninstall => gui::run_uninstall_gui().map_err(|e| anyhow::anyhow!("{e}"))?,
        Commands::Update { check } => cmd_update(check, cli.json)?,
        Commands::Health => cmd_health(cli.json)?,
        Commands::Repair => cmd_repair(cli.json)?,
        Commands::RepoHealth { path } => cmd_repo_health(&path, cli.json)?,
        Commands::RepoRepair { path } => cmd_repo_repair(&path, cli.json)?,
    }
    Ok(())
}

fn cmd_install_silent(daemon: Option<PathBuf>, plugin: Option<PathBuf>) -> Result<()> {
    let cfg = load_config_or_default();
    let install_root = if cfg.install_root.is_empty() {
        default_install_root()
    } else {
        PathBuf::from(&cfg.install_root)
    };
    let plugins_dir = if cfg.plugins_dir.is_empty() {
        studio_stud::setup_core::install::default_plugins_dir()
    } else {
        PathBuf::from(&cfg.plugins_dir)
    };
    let (daemon_src, plugin_src) = match (
        daemon.or_else(resolve_daemon_src),
        plugin.or_else(resolve_plugin_src),
    ) {
        (Some(d), Some(p)) => (d, p),
        _ => update_apply::fetch_channel_bundle(&cfg)?,
    };
    let repo_paths: Vec<String> = cfg.repos.iter().map(|r| r.path.clone()).collect();
    let daemon_version = update::installed_version();
    run_install_headless(&HeadlessInstallParams {
        install_root,
        plugins_dir,
        daemon_src,
        plugin_src,
        repo_paths,
        channel: None,
        daemon_version,
        plugin_version: String::new(),
        install_repos: false,
    })?;
    Ok(())
}

fn cmd_update(check: bool, as_json: bool) -> Result<()> {
    let cfg = load_config_or_default();
    let requested = Channel::from_str(&cfg.channel);

    let (manifest, raw, resolved) = fetch_manifest_with_fallback(requested)?;
    verify_manifest_signature(&raw, &manifest)?;
    check_anti_rollback(resolved, &manifest, &cfg.last_channel_sequence)?;

    let installed = update::installed_version();
    let on_fallback = resolved != requested;
    let last_seen_seq = cfg
        .last_channel_sequence
        .get(resolved.as_str())
        .and_then(serde_json::Value::as_u64)
        .unwrap_or(0);
    let update_available = channel_update_available_seq(
        on_fallback,
        manifest.channel_sequence,
        last_seen_seq,
        &manifest.daemon_version,
        &installed,
    );
    let switching_down =
        !on_fallback && update_available && update::is_newer(&installed, &manifest.daemon_version);

    if as_json {
        println!(
            "{}",
            json!({
                "updateAvailable": update_available,
                "installed": installed,
                "latest": manifest.daemon_version,
                "checkOnly": check,
                "channel": resolved.as_str(),
                "requestedChannel": requested.as_str(),
                "onFallback": on_fallback,
            })
        );
    } else {
        if on_fallback {
            println!(
                "note: channel '{}' not yet published — running on '{}' fallback (will switch back automatically when '{}' publishes)",
                requested.as_str(),
                resolved.as_str(),
                requested.as_str(),
            );
        } else if switching_down {
            println!(
                "note: switching to {} v{} (was v{}) — matching your channel's current build",
                resolved.as_str(),
                manifest.daemon_version,
                installed,
            );
        }
        println!(
            "installed={} latest={} update={}",
            installed, manifest.daemon_version, update_available
        );
    }
    if !check && update_available {
        update_apply::apply_channel_update(&cfg, &manifest, resolved)?;
    }
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
    let install_root = PathBuf::from(&cfg.install_root);
    let plugins_dir = if cfg.plugins_dir.is_empty() {
        studio_stud::setup_core::install::default_plugins_dir()
    } else {
        PathBuf::from(&cfg.plugins_dir)
    };
    let daemon_src = resolve_daemon_src().ok_or_else(|| {
        anyhow::anyhow!("repair: could not locate studio-stud.exe next to setup or in the repo")
    })?;
    let plugin_src = resolve_plugin_src().ok_or_else(|| {
        anyhow::anyhow!("repair: could not locate StudioStud.plugin.lua next to setup or in the repo")
    })?;
    let repo_paths: Vec<String> = cfg.repos.iter().map(|r| r.path.clone()).collect();
    run_install_headless(&HeadlessInstallParams {
        install_root,
        plugins_dir,
        daemon_src,
        plugin_src,
        repo_paths,
        channel: None,
        daemon_version: update::installed_version(),
        plugin_version: String::new(),
        install_repos: true,
    })?;
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
