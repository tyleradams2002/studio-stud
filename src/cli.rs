use std::{
    fs,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    thread,
    time::{Duration, Instant},
};

use anyhow::{Context, Result, anyhow};
use clap::{CommandFactory, Parser, Subcommand, ValueEnum};
use serde_json::{Value, json};

use crate::analyze::cmd_analyze;
use crate::bench::cmd_bench;
use crate::capture::{decode_raw_snapshot, materialize_snapshot};
use crate::conn_registry::ConnRegistry;
use crate::http::{DaemonState, ServeConfig, daemon_json};
use crate::serve_workers::{ServeDispatcher, read_pool_size};
use crate::live::{
    apply_delta, live_dump, live_services, parse_delta_request, script_source, script_sources,
    verify_drift,
};
use crate::output::live_state_compact_json;
use crate::policy::resolve_repo_root;
use crate::query::cmd_query;
use crate::stage3_cli::{
    PolicyArgs, WriteApplyArgs, WritePreviewArgs, WriteValidateArgs, cmd_policy, cmd_write_apply,
    cmd_write_preview, cmd_write_validate, load_or_create_write_token,
};
use crate::stage4_cli::{ProjectArgs, cmd_project};
use crate::storage::{
    Storage, find_studio_stud_dir, init_schema, read_live_state, remove_if_exists,
};
use crate::util::{
    DEFAULT_HOST, DEFAULT_PORT, DEFAULT_PROJECT_KEY, DoctorCheck, PROTOCOL_VERSION, display_path,
    fail, make_id, open_db, pass, warn,
};

#[derive(Parser)]
#[command(name = "studio-stud")]
#[command(version = env!("CARGO_PKG_VERSION"))]
#[command(about = "AI-first Roblox Studio capture and analysis tool.")]
pub(crate) struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand)]
#[allow(clippy::large_enum_variant)]
pub(crate) enum Commands {
    Status {
        /// Accepted for CLI parity; status emits JSON unless `--markdown` is set.
        #[arg(long, hide = true)]
        json: bool,
        #[arg(long)]
        markdown: bool,
        #[arg(long)]
        paths: bool,
        #[command(flatten)]
        common: CommonArgs,
    },
    /// Check local setup requirements for Studio Stud.
    Doctor {
        #[arg(long, hide = true)]
        json: bool,
        #[arg(long)]
        markdown: bool,
        #[arg(long)]
        paths: bool,
        #[command(flatten)]
        common: CommonArgs,
    },
    /// Ingest an existing raw Studio Stud snapshot fixture.
    Ingest {
        #[arg(long)]
        raw: PathBuf,
        #[command(flatten)]
        common: CommonArgs,
    },
    /// Render bounded dynamic analysis views from SQLite.
    Analyze {
        #[arg(value_name = "PLACE_ID_OR_KEY")]
        place: Option<String>,
        #[arg(long = "report", value_enum)]
        reports: Vec<ReportView>,
        #[arg(long = "focus")]
        focus: Vec<String>,
        #[arg(long, default_value_t = 10)]
        limit: usize,
        #[arg(long)]
        json: bool,
        #[arg(long)]
        markdown: bool,
        #[command(flatten)]
        common: CommonArgs,
    },
    /// Drill into exact indexed objects.
    Query {
        #[arg(value_name = "PLACE_ID_OR_KEY")]
        place: Option<String>,
        #[arg(long = "class")]
        class_name: Option<String>,
        #[arg(long)]
        find: Option<String>,
        #[arg(long)]
        name: Option<String>,
        #[arg(long)]
        path: Option<String>,
        #[arg(long)]
        under: Option<String>,
        #[arg(long)]
        bulk: Option<String>,
        #[arg(long)]
        audit: Option<String>,
        #[arg(long)]
        detail: Option<String>,
        #[arg(long)]
        props: Option<String>,
        #[arg(long)]
        all: bool,
        #[arg(long)]
        tree: Option<String>,
        #[arg(long, default_value_t = 1)]
        depth: usize,
        #[arg(long = "limit-siblings", default_value_t = 25)]
        limit_siblings: usize,
        #[arg(long)]
        count_only: bool,
        #[arg(long)]
        full_paths: bool,
        #[arg(long, default_value_t = 25)]
        limit: usize,
        #[arg(long, hide = true)]
        json: bool,
        #[arg(long)]
        markdown: bool,
        #[command(flatten)]
        common: CommonArgs,
    },
    /// Queue a live Studio capture through the local daemon.
    Capture {
        #[arg(long, default_value_t = 300)]
        timeout: u64,
        #[arg(long)]
        no_wait: bool,
    },
    /// Serve local Studio Stud plugin capture requests.
    Serve {
        #[arg(long, default_value = DEFAULT_HOST)]
        host: String,
        #[arg(long, default_value_t = DEFAULT_PORT)]
        port: u16,
        /// Shared read-pool worker count (default 3; also `STUDIO_STUD_READ_POOL_SIZE`).
        #[arg(long)]
        read_pool_size: Option<usize>,
        /// Emit timing spans for daemon operations (also logs per-request latency).
        #[arg(long)]
        profile: bool,
        /// Print all daemon activity to the console. Without it the console stays quiet
        /// (startup + errors only); everything is still written to logs/daemon.log.
        #[arg(long)]
        verbose: bool,
        /// Deprecated no-op (update is owned by studio-stud-setup).
        #[arg(long, hide = true)]
        no_update: bool,
        #[command(flatten)]
        common: CommonArgs,
    },
    /// Deprecated alias for `serve`.
    #[command(hide = true)]
    Daemon {
        #[arg(long, default_value = DEFAULT_HOST)]
        host: String,
        #[arg(long, default_value_t = DEFAULT_PORT)]
        port: u16,
        /// Deprecated no-op (update is owned by studio-stud-setup).
        #[arg(long, hide = true)]
        no_update: bool,
        #[command(flatten)]
        common: CommonArgs,
    },
    /// Deprecated: update is owned by studio-stud-setup. Kept as a no-op alias.
    #[command(hide = true)]
    Update {
        /// Only report availability; do not download or stage.
        #[arg(long)]
        check: bool,
    },
    /// Benchmark daemon-side capture ingest stages (hidden).
    #[command(hide = true)]
    Bench {
        #[arg(long)]
        raw: PathBuf,
        #[arg(long)]
        baseline: Option<PathBuf>,
        #[arg(long)]
        delta: Option<PathBuf>,
        #[arg(long, default_value_t = 20)]
        iterations: usize,
        #[arg(long)]
        json: bool,
    },
    /// Apply a live delta fixture (hidden).
    #[command(name = "live-delta", hide = true)]
    LiveDelta {
        #[arg(long)]
        raw: PathBuf,
        #[arg(long)]
        place: Option<String>,
        #[command(flatten)]
        common: CommonArgs,
    },
    /// Verify drift against a full snapshot (hidden).
    #[command(name = "live-verify", hide = true)]
    LiveVerify {
        #[arg(long)]
        raw: PathBuf,
        #[arg(long)]
        place: Option<String>,
        #[command(flatten)]
        common: CommonArgs,
    },
    /// Dump canonical live state (hidden).
    #[command(name = "live-dump", hide = true)]
    LiveDump {
        #[arg(value_name = "PLACE_ID_OR_KEY")]
        place: Option<String>,
        #[command(flatten)]
        common: CommonArgs,
    },
    /// Dump per-service fingerprints (hidden).
    #[command(name = "live-services", hide = true)]
    LiveServices {
        #[arg(value_name = "PLACE_ID_OR_KEY")]
        place: Option<String>,
        #[command(flatten)]
        common: CommonArgs,
    },
    /// Read script source for one instance path (hidden).
    #[command(name = "script-source", hide = true)]
    ScriptSource {
        #[arg(value_name = "PLACE_ID_OR_KEY")]
        place: String,
        #[arg(value_name = "PATH")]
        path: String,
        #[command(flatten)]
        common: CommonArgs,
    },
    /// List all script sources for a place (hidden).
    #[command(name = "script-sources", hide = true)]
    ScriptSources {
        #[arg(value_name = "PLACE_ID_OR_KEY")]
        place: Option<String>,
        #[command(flatten)]
        common: CommonArgs,
    },
    /// Manage the repo write policy file.
    Policy {
        #[command(flatten)]
        args: PolicyArgs,
    },
    /// Read-only Rojo project index, projection, and diff.
    #[command(
        name = "project",
        about = "Read-only Rojo project index, projection, and diff"
    )]
    ProjectCmd {
        #[command(flatten)]
        args: ProjectArgs,
    },
    /// Validate a write without touching disk (hidden).
    #[command(name = "write-validate", hide = true)]
    WriteValidate {
        #[command(flatten)]
        args: WriteValidateArgs,
    },
    /// Preview a write diff without touching disk (hidden).
    #[command(name = "write-preview", hide = true)]
    WritePreview {
        #[command(flatten)]
        args: WritePreviewArgs,
    },
    /// Apply a write to disk (hidden).
    #[command(name = "write-apply", hide = true)]
    WriteApply {
        #[command(flatten)]
        args: WriteApplyArgs,
    },
    /// Generate the signature-only repo map (docs/repo-map.md).
    #[command(name = "repo-map")]
    RepoMap {
        /// Source dir to scan (default: src).
        #[arg(long)]
        root: Option<PathBuf>,
        /// Output file (defaults to docs/repo-map.md, or .jsonl with --json).
        #[arg(long)]
        out: Option<PathBuf>,
        /// Emit JSONL instead of the text map.
        #[arg(long)]
        json: bool,
        /// Print to stdout instead of writing a file.
        #[arg(long)]
        stdout: bool,
        /// Skip regeneration when no source file is newer than the map.
        #[arg(long = "if-stale")]
        if_stale: bool,
        /// Suppress the summary line (for hook/automation use).
        #[arg(long)]
        quiet: bool,
    },
}

#[derive(Clone, Debug, Default, Parser)]
pub(crate) struct CommonArgs {
    #[arg(long, default_value = DEFAULT_PROJECT_KEY)]
    pub(crate) project_key: String,
    #[arg(long)]
    pub(crate) storage_root: Option<PathBuf>,
}

#[derive(Clone, Debug, ValueEnum)]
pub(crate) enum ReportView {
    Context,
    Findings,
    Critical,
}
pub fn run_with_args<I, S>(args: I) -> Result<()>
where
    I: IntoIterator<Item = S>,
    S: Into<std::ffi::OsString> + Clone,
{
    let cli = Cli::parse_from(args);
    dispatch(cli)
}

pub fn run() -> Result<()> {
    run_with_args(std::env::args())
}

fn dispatch(cli: Cli) -> Result<()> {
    match cli.command {
        None => {
            let mut cmd = Cli::command();
            cmd.print_long_help()?;
            Ok(())
        }
        Some(Commands::Status {
            json: _,
            markdown,
            paths,
            common,
        }) => cmd_status(markdown, paths, &common),
        Some(Commands::Doctor {
            json: _,
            markdown,
            paths,
            common,
        }) => cmd_doctor(markdown, paths, &common),
        Some(Commands::Ingest { raw, common }) => cmd_ingest(&raw, &common),
        Some(Commands::Analyze {
            place,
            reports,
            focus,
            limit,
            json,
            markdown,
            common,
        }) => cmd_analyze(
            place.as_deref(),
            reports,
            focus,
            limit,
            json,
            markdown,
            &common,
        ),
        Some(Commands::Query {
            place,
            class_name,
            find,
            name,
            path,
            under,
            bulk,
            audit,
            detail,
            props,
            all,
            tree,
            depth,
            limit_siblings,
            count_only,
            full_paths,
            limit,
            json: _,
            markdown,
            common,
        }) => cmd_query(
            place.as_deref(),
            class_name,
            find,
            name,
            path,
            under,
            bulk,
            audit,
            detail,
            props,
            all,
            tree,
            depth,
            limit_siblings,
            count_only,
            full_paths,
            limit,
            markdown,
            &common,
        ),
        Some(Commands::Capture { timeout, no_wait }) => cmd_capture(timeout, no_wait),
        Some(Commands::Update { check }) => cmd_update(check),
        Some(Commands::Serve {
            host,
            port,
            read_pool_size,
            profile,
            verbose,
            no_update,
            common,
        }) => cmd_serve(
            &host,
            port,
            read_pool_size,
            &common,
            no_update,
            profile,
            verbose,
        ),
        Some(Commands::Daemon {
            host,
            port,
            no_update,
            common,
        }) => cmd_serve(&host, port, None, &common, no_update, false, false),
        Some(Commands::Bench {
            raw,
            baseline,
            delta,
            iterations,
            json,
        }) => cmd_bench(
            &raw,
            baseline.as_deref(),
            delta.as_deref(),
            iterations,
            json,
        ),
        Some(Commands::LiveDelta { raw, place, common }) => {
            cmd_live_delta(&raw, place.as_deref(), &common)
        }
        Some(Commands::LiveVerify { raw, place, common }) => {
            cmd_live_verify(&raw, place.as_deref(), &common)
        }
        Some(Commands::LiveDump { place, common }) => cmd_live_dump(place.as_deref(), &common),
        Some(Commands::LiveServices { place, common }) => {
            cmd_live_services(place.as_deref(), &common)
        }
        Some(Commands::ScriptSource { place, path, common }) => {
            cmd_script_source(Some(place.as_str()), &path, &common)
        }
        Some(Commands::ScriptSources { place, common }) => {
            cmd_script_sources(place.as_deref(), &common)
        }
        Some(Commands::Policy { args }) => cmd_policy(args),
        Some(Commands::ProjectCmd { args }) => cmd_project(args),
        Some(Commands::WriteValidate { args }) => cmd_write_validate(args),
        Some(Commands::WritePreview { args }) => cmd_write_preview(args),
        Some(Commands::WriteApply { args }) => cmd_write_apply(args),
        Some(Commands::RepoMap {
            root,
            out,
            json,
            stdout,
            if_stale,
            quiet,
        }) => crate::repomap::cmd_repo_map(
            root.as_deref(),
            out.as_deref(),
            json,
            stdout,
            if_stale,
            quiet,
        ),
    }
}
fn cmd_doctor(markdown: bool, include_paths: bool, common: &CommonArgs) -> Result<()> {
    let checks = doctor_checks(common, include_paths);
    let ready = checks.iter().all(|check| check.status != "fail");

    if markdown {
        println!("Studio Stud Doctor");
        println!();
        for check in &checks {
            println!(
                "[{}] {} - {}",
                check.status.to_ascii_uppercase(),
                check.name,
                check.detail
            );
        }
    } else {
        println!(
            "{}",
            serde_json::to_string(&json!({
                "service": "studio-stud",
                "ready": ready,
                "checks": checks,
            }))?
        );
    }

    if ready {
        Ok(())
    } else {
        Err(anyhow!("Studio Stud setup is not ready"))
    }
}

fn cmd_status(markdown: bool, include_paths: bool, common: &CommonArgs) -> Result<()> {
    let storage = Storage::new(common.storage_root.clone(), &common.project_key)?;
    let daemon = daemon_json("GET", "/studio-stud/ping", None)
        .map(|payload| {
            json!({
                "state": "running",
                "version": payload.get("version").and_then(Value::as_str),
                "protocolVersion": payload.get("protocolVersion").and_then(Value::as_i64),
                "sessionMode": payload
                    .get("sessionMode")
                    .and_then(Value::as_str)
                    .unwrap_or("edit"),
                "staleSince": payload.get("staleSince").cloned().unwrap_or(Value::Null),
            })
        })
        .unwrap_or_else(|_| json!({ "state": "not-running" }));
    let mut places = Vec::new();
    let places_dir = storage.root.join(&storage.project_key).join("places");
    if places_dir.is_dir() {
        for entry in fs::read_dir(&places_dir)? {
            let entry = entry?;
            if !entry.path().is_dir() {
                continue;
            }
            let db_path = entry.path().join("syncs.db");
            if !db_path.is_file() {
                continue;
            }
            let place_name = entry.file_name().to_string_lossy().to_string();
            let live_json = open_db(&db_path).ok().and_then(|conn| {
                init_schema(&conn).ok()?;
                read_live_state(&conn)
                    .ok()
                    .flatten()
                    .map(|state| live_state_compact_json(&state, include_paths, &place_name))
            });
            places.push(json!({
                "place": place_name,
                "liveState": live_json,
            }));
        }
    }
    if markdown {
        println!("# Studio Stud Status");
        println!();
        println!("- projectKey: `{}`", storage.project_key);
        println!(
            "- daemon: `{}`",
            daemon
                .get("state")
                .and_then(Value::as_str)
                .unwrap_or("unknown")
        );
        println!(
            "- sessionMode: `{}`",
            daemon
                .get("sessionMode")
                .and_then(Value::as_str)
                .unwrap_or("unknown")
        );
        println!("- capturedPlaces: `{}`", places.len());
        return Ok(());
    }
    let mut payload = serde_json::Map::new();
    payload.insert("service".into(), json!("studio-stud"));
    payload.insert("projectKey".into(), json!(storage.project_key));
    payload.insert("daemon".into(), daemon);
    payload.insert("places".into(), Value::Array(places));
    if include_paths {
        payload.insert("storageRoot".into(), json!(storage.root));
    }
    println!("{}", serde_json::to_string(&Value::Object(payload))?);
    Ok(())
}

fn doctor_checks(common: &CommonArgs, include_paths: bool) -> Vec<DoctorCheck> {
    let mut checks = Vec::new();

    let studio_stud_dir = find_studio_stud_dir();
    match &studio_stud_dir {
        Some(dir) => {
            let plugin_path = dir.join("plugin").join("StudioStud.plugin.lua");
            if plugin_path.is_file() {
                checks.push(pass(
                    "Plugin source",
                    if include_paths {
                        format!("found {}", display_path(&plugin_path))
                    } else {
                        "found".to_string()
                    },
                ));
            } else {
                checks.push(fail(
                    "Plugin source",
                    if include_paths {
                        format!("missing {}", display_path(&plugin_path))
                    } else {
                        "missing plugin source".to_string()
                    },
                ));
            }
        }
        None => {
            checks.push(fail(
                "Plugin source",
                "could not locate plugin/StudioStud.plugin.lua".to_string(),
            ));
        }
    }

    checks.push(storage_check(common, include_paths));
    checks.push(sqlite_check(common, include_paths));
    checks.push(server_manifest_check());

    checks.push(warn(
        "Roblox Studio HTTP",
        "verify Studio has HTTP requests enabled for this experience".to_string(),
    ));

    checks
}

fn storage_check(common: &CommonArgs, include_paths: bool) -> DoctorCheck {
    match Storage::new(common.storage_root.clone(), &common.project_key).and_then(|storage| {
        let root = storage.root.join(&storage.project_key);
        fs::create_dir_all(&root)?;
        let test_path = root.join(".doctor-write-test");
        fs::write(&test_path, b"studio-stud")?;
        fs::remove_file(&test_path)?;
        Ok(root)
    }) {
        Ok(root) => pass(
            "Storage root",
            if include_paths {
                format!("writable at {}", display_path(&root))
            } else {
                "writable".to_string()
            },
        ),
        Err(err) => fail("Storage root", err.to_string()),
    }
}

fn sqlite_check(common: &CommonArgs, include_paths: bool) -> DoctorCheck {
    let result =
        Storage::new(common.storage_root.clone(), &common.project_key).and_then(|storage| {
            let root = storage.root.join(&storage.project_key);
            fs::create_dir_all(&root)?;
            let db_path = root.join("doctor.sqlite");
            {
                let conn = open_db(&db_path)?;
                init_schema(&conn)?;
            }
            remove_if_exists(&db_path)?;
            remove_if_exists(&root.join("doctor.sqlite-wal"))?;
            remove_if_exists(&root.join("doctor.sqlite-shm"))?;
            Ok(db_path)
        });
    match result {
        Ok(db_path) => pass(
            "SQLite",
            if include_paths {
                format!("created and initialized {}", display_path(&db_path))
            } else {
                "created and initialized".to_string()
            },
        ),
        Err(err) => fail("SQLite", err.to_string()),
    }
}

fn server_manifest_check() -> DoctorCheck {
    match daemon_json("GET", "/studio-stud/manifest", None) {
        Ok(payload) => {
            let protocol = payload
                .get("protocolVersion")
                .and_then(Value::as_i64)
                .unwrap_or(0);
            if protocol == PROTOCOL_VERSION {
                pass(
                    "Local server manifest",
                    format!(
                        "reachable, version {}, protocol {}",
                        payload
                            .get("version")
                            .and_then(Value::as_str)
                            .unwrap_or("unknown"),
                        protocol
                    ),
                )
            } else {
                fail(
                    "Local server manifest",
                    format!("protocol mismatch: expected {PROTOCOL_VERSION}, got {protocol}"),
                )
            }
        }
        Err(_) => warn(
            "Local server manifest",
            "local server is not running; start it with `studio-stud serve` when ready to capture"
                .to_string(),
        ),
    }
}
fn cmd_capture(timeout: u64, no_wait: bool) -> Result<()> {
    let ping = daemon_json("GET", "/studio-stud/ping", None).with_context(|| {
        "Studio Stud daemon is not running. Start it in its own terminal with `studio-stud serve`, leave that terminal open, then rerun capture."
    })?;
    if ping.get("sessionMode").and_then(Value::as_str) == Some("play") {
        return Err(anyhow!(
            "Studio is in a play session; world state is frozen — retry the capture after the playtest."
        ));
    }
    let request_id = make_id("request");
    let payload = json!({
        "requestId": request_id,
        "options": {
            "requestId": request_id,
        }
    });
    let queued = daemon_json("POST", "/studio-stud/capture/request", Some(&payload))
        .with_context(|| "Studio Stud daemon is not reachable. Run `studio-stud serve` while Roblox Studio is open.")?;
    if no_wait {
        println!("{}", serde_json::to_string(&queued)?);
        return Ok(());
    }

    let started_at = Instant::now();
    loop {
        let status = daemon_json(
            "GET",
            &format!("/studio-stud/capture/status?requestId={request_id}"),
            None,
        )?;
        if status.get("status").and_then(Value::as_str) == Some("completed") {
            println!("{}", serde_json::to_string(&status)?);
            return Ok(());
        }
        if status.get("status").and_then(Value::as_str) == Some("failed") {
            return Err(anyhow!(
                "{}",
                status
                    .get("error")
                    .and_then(Value::as_str)
                    .unwrap_or("capture failed")
            ));
        }
        if started_at.elapsed() >= Duration::from_secs(timeout) {
            return Err(anyhow!(
                "timed out waiting for Studio capture request `{request_id}`"
            ));
        }
        thread::sleep(Duration::from_secs(1));
    }
}

fn cmd_update(check: bool) -> Result<()> {
    if check {
        let report = crate::update::check(crate::update::LATEST_URL)?;
        println!(
            "{}",
            serde_json::to_string(&json!({
                "installedDaemon": report.installed_daemon,
                "latestDaemon": report.latest_daemon,
                "latestPlugin": report.latest_plugin,
                "updateAvailable": report.update_available,
                "install": crate::update::INSTALL_CMD,
            }))?
        );
    } else {
        crate::update::run_on_serve(crate::update::LATEST_URL, true);
    }
    Ok(())
}

fn cmd_serve(
    host: &str,
    port: u16,
    read_pool_size_flag: Option<usize>,
    common: &CommonArgs,
    _no_update: bool,
    profile: bool,
    verbose: bool,
) -> Result<()> {
    crate::update::apply_staged_on_boot();
    if host != "127.0.0.1" && host != "localhost" {
        return Err(anyhow!(
            "Studio Stud daemon must bind to 127.0.0.1/localhost"
        ));
    }
    let address = format!("{host}:{port}");
    let server = tiny_http::Server::http(&address).map_err(|err| {
        anyhow!(
            "Could not bind Studio Stud daemon to {address}: {err}. Stop the terminal/process that owns that port, then rerun `studio-stud serve`."
        )
    })?;
    let storage = Storage::new(common.storage_root.clone(), &common.project_key)?;
    // Console stays quiet by default; --verbose, --profile, or STUDIO_STUD_VERBOSE=1
    // surfaces the full per-request stream. daemon.log always gets everything.
    let verbose = verbose
        || profile
        || std::env::var("STUDIO_STUD_VERBOSE")
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(false);
    crate::obs::init(&storage.root, profile, verbose);
    let mut user_cfg = crate::setup_core::load_config_or_default();
    if crate::setup_core::config::self_heal_config_on_serve(&mut user_cfg) {
        let _ = crate::setup_core::save_config(&user_cfg);
        crate::obs::event("config", "self-healed installRoot/channel on serve");
    }
    if let Ok(cwd_repo) = resolve_repo_root(None) {
        let _ = crate::setup_core::register_repo(&mut user_cfg, &cwd_repo);
    }
    let install_root = if user_cfg.install_root.is_empty() {
        crate::setup_core::install::default_install_root()
    } else {
        PathBuf::from(&user_cfg.install_root)
    };
    let plugins_dir = if user_cfg.plugins_dir.is_empty() {
        crate::setup_core::install::default_plugins_dir()
    } else {
        PathBuf::from(&user_cfg.plugins_dir)
    };
    let mut addons_changed = false;
    for entry in &mut user_cfg.repos {
        let repo_path = PathBuf::from(&entry.path);
        match crate::setup_core::install::reconcile_repo_addons(
            &install_root,
            &plugins_dir,
            &repo_path,
        ) {
            Ok(enabled) => {
                if entry.enabled_addons != enabled {
                    entry.enabled_addons = enabled;
                    addons_changed = true;
                }
            }
            Err(e) => {
                eprintln!(
                    "Studio Stud: addon reconcile failed for {}: {e:#}",
                    entry.path
                );
            }
        }
    }
    if addons_changed {
        let _ = crate::setup_core::save_config(&user_cfg);
    }
    let registry = crate::RepoResolver::from_config(user_cfg.clone());
    let write_token = load_or_create_write_token(&storage.root)?;
    let shutdown = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let channel_update =
        crate::setup_core::channel_update::ChannelUpdateCache::new(user_cfg.clone(), install_root.clone());
    let cu = std::sync::Arc::clone(&channel_update);
    std::thread::spawn(move || {
        let _ = cu.ping_fields();
    });
    let registry_conns = ConnRegistry::new();
    let allowlist = Arc::new(std::sync::RwLock::new(crate::reflection::generate_allowlist()));
    {
        // Background idle-eviction: close per-place connections left unused past
        // the registry's idle timeout so a long session over many places doesn't
        // leak handles. Detached; checks the shutdown flag each tick.
        let evict_registry = Arc::clone(&registry_conns);
        let evict_shutdown = Arc::clone(&shutdown);
        std::thread::spawn(move || {
            loop {
                std::thread::sleep(std::time::Duration::from_secs(60));
                if evict_shutdown.load(std::sync::atomic::Ordering::Relaxed) {
                    break;
                }
                evict_registry.evict_idle(std::time::Instant::now());
            }
        });
    }
    {
        let refresh_allowlist = Arc::clone(&allowlist);
        let refresh_root = Some(storage.root.clone());
        std::thread::spawn(move || {
            crate::reflection::refresh(&refresh_allowlist, refresh_root.as_deref());
        });
    }
    {
        let refresh_allowlist = Arc::clone(&allowlist);
        let refresh_root = Some(storage.root.clone());
        let refresh_shutdown = Arc::clone(&shutdown);
        std::thread::spawn(move || {
            loop {
                std::thread::sleep(std::time::Duration::from_secs(60 * 60));
                if refresh_shutdown.load(std::sync::atomic::Ordering::Relaxed) {
                    break;
                }
                crate::reflection::refresh(&refresh_allowlist, refresh_root.as_deref());
            }
        });
    }
    let config = ServeConfig {
        storage_root: common.storage_root.clone(),
        project_key: common.project_key.clone(),
        write_token: write_token.clone(),
        registry,
        install_root: install_root.clone(),
        plugins_dir: plugins_dir.clone(),
        port,
        shutdown: Arc::clone(&shutdown),
        channel_update,
        registry_conns,
        allowlist,
    };
    let _ = crate::setup_core::config::write_daemon_lock(std::process::id(), port);
    let state = Arc::new(Mutex::new(DaemonState::default()));
    let version = env!("CARGO_PKG_VERSION");
    crate::obs::event(
        "serve",
        &format!("Studio Stud v{version} on http://{address}"),
    );
    println!(
        "Studio Stud v{version} serving plugin capture requests on http://{address}"
    );
    println!("Storage root: {}", storage.root.display());
    println!(
        "Registry: {} repo(s); PlaceId resolves per request",
        config.registry.config_snapshot().repos.len()
    );
    println!("Install root: {}", install_root.display());
    println!("Write token issued");
    let pool_size = read_pool_size_flag
        .filter(|&n| n > 0)
        .unwrap_or_else(read_pool_size);
    let dispatcher = ServeDispatcher::start(Arc::clone(&state), config, pool_size);
    for request in server.incoming_requests() {
        dispatcher.route(request);
    }
    dispatcher.shutdown();
    Ok(())
}

fn cmd_ingest(raw_path: &Path, common: &CommonArgs) -> Result<()> {
    let raw_bytes = fs::read(raw_path).with_context(|| format!("read {}", raw_path.display()))?;
    let raw_json = decode_raw_snapshot(&raw_bytes)?;
    let snapshot: Value = serde_json::from_str(&raw_json)?;
    let registry = ConnRegistry::new();
    let result = materialize_snapshot(
        &snapshot,
        common.storage_root.clone(),
        &common.project_key,
        &registry,
    )?;
    println!("{}", serde_json::to_string(&result)?);
    Ok(())
}

fn cmd_live_delta(raw_path: &Path, place: Option<&str>, common: &CommonArgs) -> Result<()> {
    let raw_bytes = fs::read(raw_path).with_context(|| format!("read {}", raw_path.display()))?;
    let raw_json = decode_raw_snapshot(&raw_bytes)?;
    let value: Value = serde_json::from_str(&raw_json)?;
    let request = parse_delta_request(&value)?;
    let registry = ConnRegistry::new();
    let result = apply_delta(
        common.storage_root.clone(),
        &common.project_key,
        place,
        &request,
        &registry,
    )?;
    println!("{}", serde_json::to_string(&result)?);
    Ok(())
}

fn cmd_live_verify(raw_path: &Path, place: Option<&str>, common: &CommonArgs) -> Result<()> {
    let raw_bytes = fs::read(raw_path).with_context(|| format!("read {}", raw_path.display()))?;
    let raw_json = decode_raw_snapshot(&raw_bytes)?;
    let snapshot: Value = serde_json::from_str(&raw_json)?;
    let result = verify_drift(
        common.storage_root.clone(),
        &common.project_key,
        place,
        &snapshot,
        &raw_bytes,
    )?;
    println!("{}", serde_json::to_string(&result)?);
    Ok(())
}

fn cmd_live_dump(place: Option<&str>, common: &CommonArgs) -> Result<()> {
    let result = live_dump(common.storage_root.clone(), &common.project_key, place)?;
    println!("{}", serde_json::to_string(&result)?);
    Ok(())
}

fn cmd_live_services(place: Option<&str>, common: &CommonArgs) -> Result<()> {
    let result = live_services(common.storage_root.clone(), &common.project_key, place)?;
    println!("{}", serde_json::to_string(&result)?);
    Ok(())
}

fn cmd_script_source(place: Option<&str>, path: &str, common: &CommonArgs) -> Result<()> {
    let result = script_source(
        common.storage_root.clone(),
        &common.project_key,
        place,
        path,
    )?;
    println!("{}", serde_json::to_string(&result)?);
    Ok(())
}

fn cmd_script_sources(place: Option<&str>, common: &CommonArgs) -> Result<()> {
    let result = script_sources(common.storage_root.clone(), &common.project_key, place)?;
    println!("{}", serde_json::to_string(&result)?);
    Ok(())
}
