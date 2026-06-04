mod gui;
mod install_flow;
mod legacy_cleanup;
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
use studio_stud::setup_core::config::{
    load_config_or_default, read_install_version_channel, register_repo, resolve_update_channel,
    save_config,
};
use studio_stud::setup_core::health::{
    health_json, repo_health_checks, repo_health_json, user_health_checks,
};
use studio_stud::setup_core::install::{
    default_install_root, is_valid_repo_root, migrate_legacy_repo, write_starter_policy,
};
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
        /// Channel this bundle was built for (release|beta|dev). Threaded from the
        /// one-liner installer so a dev/beta install isn't recorded as release.
        /// Omit to preserve the already-installed channel.
        #[arg(long)]
        channel: Option<String>,
    },
    /// Register a repo (config entry + committed .studio-stud/ scaffold) without the GUI
    AddRepo {
        /// Repo root to add (defaults to the current directory)
        path: Option<PathBuf>,
    },
    /// Launch GUI uninstaller
    Uninstall,
    /// Check or apply updates
    Update {
        #[arg(long)]
        check: bool,
        /// Override channel for this check/apply (dev|beta|release)
        #[arg(long)]
        channel: Option<String>,
        /// Shorthand for `--channel dev`
        #[arg(long)]
        dev: bool,
    },
    /// Verify installation; runs repair on failure
    Health,
    /// Silent reinstall preserving config
    Repair,
    /// Repo-scoped health
    RepoHealth { path: PathBuf },
    /// Repo-scoped repair / migration
    RepoRepair { path: PathBuf },
    /// Remove legacy system32 / per-repo install shims and bundles
    CleanupLegacy {
        #[arg(long)]
        dry_run: bool,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command.unwrap_or(Commands::Install {
        silent: false,
        daemon: None,
        plugin: None,
        channel: None,
    }) {
        Commands::Install {
            silent: true,
            daemon,
            plugin,
            channel,
        } => cmd_install_silent(daemon, plugin, channel)?,
        Commands::Install {
            silent: false,
            channel,
            ..
        } => gui::run_install_gui(channel).map_err(|e| anyhow::anyhow!("{e}"))?,
        Commands::AddRepo { path } => cmd_add_repo(path, cli.json)?,
        Commands::Uninstall => gui::run_uninstall_gui().map_err(|e| anyhow::anyhow!("{e}"))?,
        Commands::Update {
            check,
            channel,
            dev,
        } => cmd_update(check, channel, dev, cli.json)?,
        Commands::Health => cmd_health(cli.json)?,
        Commands::Repair => cmd_repair(cli.json)?,
        Commands::RepoHealth { path } => cmd_repo_health(&path, cli.json)?,
        Commands::RepoRepair { path } => cmd_repo_repair(&path, cli.json)?,
        Commands::CleanupLegacy { dry_run } => cmd_cleanup_legacy(dry_run, cli.json)?,
    }
    Ok(())
}

fn cmd_cleanup_legacy(dry_run: bool, json: bool) -> Result<()> {
    let cfg = load_config_or_default();
    let install_root = if cfg.install_root.is_empty() {
        default_install_root()
    } else {
        PathBuf::from(&cfg.install_root)
    };
    let repo_paths: Vec<String> = cfg.repos.iter().map(|r| r.path.clone()).collect();
    let artifacts = legacy_cleanup::run_legacy_cleanup(dry_run, &install_root, &repo_paths)?;
    if json {
        let items: Vec<_> = artifacts
            .iter()
            .map(|a| {
                json!({
                    "path": a.path.display().to_string(),
                    "needsAdmin": a.needs_admin,
                })
            })
            .collect();
        println!(
            "{}",
            serde_json::to_string(&json!({
                "ok": true,
                "dryRun": dry_run,
                "artifacts": items,
            }))?
        );
    }
    Ok(())
}

fn cmd_install_silent(
    daemon: Option<PathBuf>,
    plugin: Option<PathBuf>,
    channel: Option<String>,
) -> Result<()> {
    let mut cfg = load_config_or_default();
    // Pre-apply an explicit channel so the bundle fetch targets it; when absent the
    // existing channel is preserved.
    if let Some(ch) = &channel {
        cfg.channel = ch.clone();
    }
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
        channel,
        daemon_version,
        plugin_version: String::new(),
        install_repos: false,
    })?;
    Ok(())
}

/// Register a repo and lay down its committed `.studio-stud/` scaffold without launching the
/// GUI — the headless equivalent of adding a folder on the installer's Repos screen. Pins the
/// repo's `targetChannel` to the machine's current channel and migrates any legacy per-repo shim.
fn cmd_add_repo(path: Option<PathBuf>, as_json: bool) -> Result<()> {
    let repo = match path {
        Some(p) => p,
        None => std::env::current_dir()?,
    };
    let repo = repo.canonicalize().unwrap_or(repo);
    if !is_valid_repo_root(&repo) {
        anyhow::bail!(
            "{} is not a project root (expected a .git folder or default.project.json)",
            repo.display()
        );
    }
    let mut cfg = load_config_or_default();
    let newly = register_repo(&mut cfg, &repo)?;
    write_starter_policy(&repo, &cfg.channel)?;
    let _ = migrate_legacy_repo(&repo, &mut cfg);
    save_config(&cfg)?;
    if as_json {
        println!(
            "{}",
            json!({
                "added": newly,
                "repo": repo.display().to_string(),
                "channel": cfg.channel,
            })
        );
    } else if newly {
        println!(
            "Added {} (channel: {}). Committed .studio-stud/policy.json pins targetChannel to '{}'.",
            repo.display(),
            cfg.channel,
            cfg.channel
        );
    } else {
        println!(
            "{} was already registered — refreshed its .studio-stud/ scaffold (channel: {}).",
            repo.display(),
            cfg.channel
        );
    }
    Ok(())
}

fn cmd_update(
    check: bool,
    channel_override: Option<String>,
    dev: bool,
    as_json: bool,
) -> Result<()> {
    let cfg = load_config_or_default();
    let explicit = channel_override.or_else(|| dev.then(|| "dev".to_string()));
    let version_json_channel = read_install_version_channel(&cfg);
    let resolved_channel = resolve_update_channel(
        explicit.as_deref(),
        &cfg,
        version_json_channel.as_deref(),
    );
    let requested = Channel::from_str(&resolved_channel);

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
        write_starter_policy(&p, &cfg.channel)?;
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
    write_starter_policy(path, &cfg.channel)?;
    migrate_legacy_repo(path, &mut cfg)?;
    save_config(&cfg)?;
    if !as_json {
        println!("Repo repair complete for {}", path.display());
    }
    Ok(())
}
