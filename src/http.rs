use std::{
    collections::{BTreeMap, HashMap, VecDeque},
    io::{Read, Write},
    net::TcpStream,
    path::PathBuf,
    sync::{
        Arc, Mutex, RwLock,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

use anyhow::{Result, anyhow};
use serde_json::{Value, json};

use crate::capture::{decode_raw_snapshot, inject_sync_metadata, materialize_snapshot};
use crate::conn_registry::ConnRegistry;
use crate::live::{apply_delta, live_fingerprint, parse_delta_request, verify_drift};
use crate::tick::{handle_tick, parse_tick_request};
use crate::stage3_cli::{run_write, write_outcome_to_json};
use crate::storage::set_active_place;
use crate::util::{
    DEFAULT_HOST, DEFAULT_PORT, MAX_CHUNK_BYTES, MIN_PLUGIN_PROTOCOL_VERSION, PROTOCOL_VERSION,
    make_id, now_utc, required_query, split_url,
};
use crate::setup_core::install::{disable_addon, enable_addon, list_bundled_addons};
use crate::setup_core::registry::RepoResolveError;
use crate::setup_core::RepoResolver;
use crate::write::WriteMode;

#[derive(Clone)]
pub struct ServeConfig {
    pub storage_root: Option<PathBuf>,
    pub project_key: String,
    pub write_token: String,
    pub registry: RepoResolver,
    pub install_root: PathBuf,
    pub plugins_dir: PathBuf,
    pub port: u16,
    pub shutdown: Arc<AtomicBool>,
    pub channel_update: Arc<crate::setup_core::channel_update::ChannelUpdateCache>,
    pub registry_conns: Arc<ConnRegistry>,
    pub(crate) allowlist: Arc<RwLock<crate::reflection::AllowList>>,
}

fn parse_place_id_query(query: &HashMap<String, String>) -> Option<i64> {
    query
        .get("placeId")
        .and_then(|s| s.parse::<i64>().ok())
        .or_else(|| query.get("place_id").and_then(|s| s.parse().ok()))
}

fn parse_place_id_payload(payload: &Value) -> Option<i64> {
    payload
        .get("placeId")
        .or_else(|| payload.get("place_id"))
        .and_then(Value::as_i64)
}

#[derive(Default)]
pub(crate) struct UploadState {
    body: Option<Vec<u8>>,
    chunks: BTreeMap<usize, Vec<u8>>,
}

#[derive(Clone)]
pub(crate) enum CaptureFinalizeState {
    Finalizing,
    Done(Value),
    Error(String),
}

/// How long a play-session heartbeat is trusted before the daemon assumes the plugin
/// is gone (heartbeats arrive every ~3 s) and reverts to treating the session as edit.
/// In-memory only: a daemon restart or a closed plugin must never leave writes frozen.
const SESSION_HEARTBEAT_TTL: Duration = Duration::from_secs(10);

#[derive(Default)]
pub(crate) struct DaemonState {
    pending_requests: VecDeque<Value>,
    active_request_id: Option<String>,
    uploads: HashMap<String, UploadState>,
    tick_uploads: HashMap<String, UploadState>,
    staged_tick_bulks: HashMap<String, Vec<u8>>,
    verify_uploads: HashMap<String, UploadState>,
    completions: HashMap<String, Value>,
    finalize_by_sync: HashMap<String, CaptureFinalizeState>,
    /// Last session mode the plugin reported on its heartbeat ("edit" | "play").
    session_mode: String,
    /// Monotonic timestamp of that heartbeat, for freshness checks.
    session_heartbeat_at: Option<Instant>,
    /// Wall-clock timestamp of that heartbeat, surfaced as `staleSince` when aged out.
    last_heartbeat_utc: Option<String>,
}

impl DaemonState {
    fn record_session_mode(&mut self, mode: &str, now_utc: String) {
        self.session_mode = if mode == "play" { "play" } else { "edit" }.to_string();
        self.session_heartbeat_at = Some(Instant::now());
        self.last_heartbeat_utc = Some(now_utc);
    }

    /// True only when the plugin reported a play session within the freshness window.
    fn in_play_session(&self) -> bool {
        self.session_mode == "play"
            && self
                .session_heartbeat_at
                .map(|at| at.elapsed() < SESSION_HEARTBEAT_TTL)
                .unwrap_or(false)
    }

    /// (effective session mode for ping/status, `staleSince` timestamp or null).
    /// A "play" report that has aged past the TTL is reported as edit but with
    /// `staleSince` set, so callers can see the plugin went quiet mid-play.
    fn session_report(&self) -> (&'static str, Value) {
        if self.in_play_session() {
            return ("play", Value::Null);
        }
        let stale_since = if self.session_mode == "play" {
            self.last_heartbeat_utc
                .clone()
                .map(Value::from)
                .unwrap_or(Value::Null)
        } else {
            Value::Null
        };
        ("edit", stale_since)
    }
}

/// Standard refusal returned for daemon operations that must not run while Studio is
/// mid-playtest (write-token issuance, write apply/validate/preview, live deltas).
fn play_session_block() -> Value {
    json!({
        "ok": false,
        "error": "studio_in_play_session",
        "detail": "Studio is in a play session; world state is frozen — retry after the playtest.",
    })
}

fn is_in_play(state: &Arc<Mutex<DaemonState>>) -> Result<bool> {
    Ok(state
        .lock()
        .map_err(|_| anyhow!("daemon state lock poisoned"))?
        .in_play_session())
}

/// Test-only delay hook (`STUDIO_STUD_TEST_TICK_DELAY_MS` + `_PLACE`).
fn apply_test_tick_delay(place_id: &str) {
    let Ok(ms) = std::env::var("STUDIO_STUD_TEST_TICK_DELAY_MS") else {
        return;
    };
    let Ok(delay_ms) = ms.parse::<u64>() else {
        return;
    };
    let Ok(delay_place) = std::env::var("STUDIO_STUD_TEST_TICK_DELAY_PLACE") else {
        return;
    };
    if delay_place == place_id {
        std::thread::sleep(Duration::from_millis(delay_ms));
    }
}

pub(crate) fn handle_daemon_request(
    mut request: tiny_http::Request,
    state: Arc<Mutex<DaemonState>>,
    config: &ServeConfig,
) -> Result<()> {
    let started = Instant::now();
    let storage_root = config.storage_root.clone();
    let project_key = config.project_key.as_str();
    let method = request.method().clone();
    let method_label = method.to_string();
    let url = request.url().to_string();
    let (path, query) = split_url(&url);
    let path_label = path.clone();
    let result = (|| -> Result<Value> {
        Ok(match (method, path.as_str()) {
            (tiny_http::Method::Get, "/studio-stud/allowlist") => {
                let al = config
                    .allowlist
                    .read()
                    .map_err(|_| anyhow!("allowlist lock poisoned"))?
                    .clone();
                json!({ "ok": true, "version": al.version, "classes": al.classes })
            }
            (tiny_http::Method::Get, "/ping") | (tiny_http::Method::Get, "/studio-stud/ping") => {
                let mut manifest = manifest_json_with_update(config);
                let (mode, stale_since) = {
                    let guard = state
                        .lock()
                        .map_err(|_| anyhow!("daemon state lock poisoned"))?;
                    guard.session_report()
                };
                if let Some(obj) = manifest.as_object_mut() {
                    obj.insert("sessionMode".to_string(), json!(mode));
                    obj.insert("staleSince".to_string(), stale_since);
                }
                manifest
            }
            (tiny_http::Method::Get, "/studio-stud/manifest") => manifest_json_with_update(config),
            (tiny_http::Method::Get, "/request-sync")
            | (tiny_http::Method::Get, "/studio-stud/capture/request") => {
                let mode = query.get("sessionMode").map(String::as_str).unwrap_or("edit");
                let mut guard = state
                    .lock()
                    .map_err(|_| anyhow!("daemon state lock poisoned"))?;
                guard.record_session_mode(mode, now_utc());
                if guard.in_play_session() {
                    // Studio is mid-playtest: heartbeat only, hand out no capture work.
                    json!({ "ok": true, "request": Value::Null, "sessionMode": "play" })
                } else {
                    let request = guard.pending_requests.pop_front();
                    if let Some(request) = &request {
                        guard.active_request_id = request
                            .get("id")
                            .and_then(Value::as_str)
                            .map(str::to_string);
                    }
                    json!({ "ok": true, "request": request })
                }
            }
            (tiny_http::Method::Get, "/studio-stud/capture/status") => {
                let guard = state
                    .lock()
                    .map_err(|_| anyhow!("daemon state lock poisoned"))?;
                if let Some(sync_id) = query.get("syncId") {
                    capture_finalize_status(&guard, sync_id)
                } else {
                    let request_id = query.get("requestId").cloned().unwrap_or_default();
                    if let Some(done) = guard.completions.get(&request_id) {
                        done.clone()
                    } else if guard.active_request_id.as_deref() == Some(request_id.as_str()) {
                        json!({ "ok": true, "requestId": request_id, "status": "in_progress" })
                    } else if guard.pending_requests.iter().any(|item| {
                        item.get("id").and_then(Value::as_str) == Some(request_id.as_str())
                    }) {
                        json!({ "ok": true, "requestId": request_id, "status": "queued" })
                    } else {
                        json!({ "ok": true, "requestId": request_id, "status": "unknown" })
                    }
                }
            }
            (tiny_http::Method::Post, "/request-sync")
            | (tiny_http::Method::Post, "/studio-stud/capture/request") => {
                let payload = read_request_json(&mut request)?;
                let request_id = payload
                    .get("requestId")
                    .and_then(Value::as_str)
                    .map(str::to_string)
                    .unwrap_or_else(|| make_id("request"));
                let options = payload.get("options").cloned().unwrap_or_else(|| json!({}));
                let request_payload = json!({
                    "id": request_id,
                    "reason": payload.get("reason").and_then(Value::as_str).unwrap_or("studio-stud-capture"),
                    "createdAtUtc": now_utc(),
                    "options": options,
                });
                state
                    .lock()
                    .map_err(|_| anyhow!("daemon state lock poisoned"))?
                    .pending_requests
                    .push_back(request_payload.clone());
                json!({ "ok": true, "request": request_payload, "status": "queued" })
            }
            (tiny_http::Method::Post, "/live-sync/start")
            | (tiny_http::Method::Post, "/studio-stud/capture/start") => {
                let metadata = read_request_json(&mut request)?;
                let plugin_protocol = metadata
                    .get("protocolVersion")
                    .and_then(Value::as_i64)
                    .unwrap_or(0);
                if plugin_protocol < MIN_PLUGIN_PROTOCOL_VERSION {
                    return Ok(json!({
                        "ok": false,
                        "error": "plugin protocol is too old for this daemon",
                        "protocolVersion": PROTOCOL_VERSION,
                        "minPluginProtocolVersion": MIN_PLUGIN_PROTOCOL_VERSION,
                    }));
                }
                let sync_id = metadata
                    .get("syncId")
                    .and_then(Value::as_str)
                    .map(str::to_string)
                    .unwrap_or_else(|| make_id("capture"));
                state
                    .lock()
                    .map_err(|_| anyhow!("daemon state lock poisoned"))?
                    .uploads
                    .insert(
                        sync_id.clone(),
                        UploadState {
                            body: None,
                            chunks: BTreeMap::new(),
                        },
                    );
                json!({
                    "ok": true,
                    "syncId": sync_id,
                    "maxChunkBytes": MAX_CHUNK_BYTES,
                    "protocol": "studio-stud-v1",
                    "protocolVersion": PROTOCOL_VERSION,
                })
            }
            (tiny_http::Method::Post, "/live-sync/body")
            | (tiny_http::Method::Post, "/studio-stud/capture/body") => {
                let sync_id = required_query(&query, "syncId")?;
                let body = read_request_bytes(&mut request)?;
                let received = body.len();
                let mut guard = state
                    .lock()
                    .map_err(|_| anyhow!("daemon state lock poisoned"))?;
                let Some(upload) = guard.uploads.get_mut(&sync_id) else {
                    return Ok(unknown_sync_id_response());
                };
                upload.body = Some(body);
                json!({ "ok": true, "syncId": sync_id, "receivedBytes": received })
            }
            (tiny_http::Method::Post, "/live-sync/chunk")
            | (tiny_http::Method::Post, "/studio-stud/capture/chunk") => {
                let sync_id = required_query(&query, "syncId")?;
                let index = required_query(&query, "index")?.parse::<usize>()?;
                let body = read_request_bytes(&mut request)?;
                let received = body.len();
                let mut guard = state
                    .lock()
                    .map_err(|_| anyhow!("daemon state lock poisoned"))?;
                let Some(upload) = guard.uploads.get_mut(&sync_id) else {
                    return Ok(unknown_sync_id_response());
                };
                upload.chunks.insert(index, body);
                json!({ "ok": true, "syncId": sync_id, "chunkIndex": index, "receivedBytes": received })
            }
            (tiny_http::Method::Post, "/live-sync/complete")
            | (tiny_http::Method::Post, "/studio-stud/capture/complete") => {
                let payload = read_request_json(&mut request)?;
                let sync_id = payload
                    .get("syncId")
                    .and_then(Value::as_str)
                    .ok_or_else(|| anyhow!("syncId is required"))?
                    .to_string();
                let expected_chunks = payload
                    .get("expectedChunks")
                    .and_then(Value::as_u64)
                    .map(|value| value as usize);
                complete_daemon_upload(
                    &sync_id,
                    expected_chunks,
                    state,
                    storage_root.clone(),
                    project_key,
                    Arc::clone(&config.registry_conns),
                )?
            }
            (tiny_http::Method::Post, "/studio-stud/tick") => {
                let payload = read_request_json(&mut request)?;
                let tick = parse_tick_request(&payload)?;
                apply_test_tick_delay(&tick.place_id);
                let mut guard = state
                    .lock()
                    .map_err(|_| anyhow!("daemon state lock poisoned"))?;
                guard.record_session_mode(&tick.session_mode, now_utc());
                let ignore_ops = guard.in_play_session();
                let pending_request = if ignore_ops {
                    Value::Null
                } else {
                    guard.pending_requests.pop_front().unwrap_or(Value::Null)
                };
                let bulk_ref = tick.bulk_ref.clone();
                let staged_bulk = bulk_ref
                    .as_ref()
                    .and_then(|id| guard.staged_tick_bulks.get(id).cloned());
                drop(guard);
                let storage = crate::storage::Storage::new(storage_root.clone(), project_key)?;
                set_active_place(&storage, &tick.place_id);
                let result = handle_tick(
                    storage_root.clone(),
                    project_key,
                    Some(tick.place_id.as_str()),
                    &tick,
                    staged_bulk.as_deref(),
                    &config.registry_conns,
                    pending_request,
                    ignore_ops,
                )?;
                if result.get("ok").and_then(Value::as_bool) == Some(true)
                    && let Some(sync_id) = bulk_ref
                {
                    let mut guard = state
                        .lock()
                        .map_err(|_| anyhow!("daemon state lock poisoned"))?;
                    guard.staged_tick_bulks.remove(&sync_id);
                }
                result
            }
            (tiny_http::Method::Post, "/studio-stud/tick/bulk/start") => {
                let metadata = read_request_json(&mut request)?;
                let plugin_protocol = metadata
                    .get("protocolVersion")
                    .and_then(Value::as_i64)
                    .unwrap_or(0);
                if plugin_protocol < MIN_PLUGIN_PROTOCOL_VERSION {
                    return Ok(json!({
                        "ok": false,
                        "error": "plugin protocol is too old for this daemon",
                        "protocolVersion": PROTOCOL_VERSION,
                        "minPluginProtocolVersion": MIN_PLUGIN_PROTOCOL_VERSION,
                    }));
                }
                let sync_id = metadata
                    .get("syncId")
                    .and_then(Value::as_str)
                    .map(str::to_string)
                    .unwrap_or_else(|| make_id("tickbulk"));
                state
                    .lock()
                    .map_err(|_| anyhow!("daemon state lock poisoned"))?
                    .tick_uploads
                    .insert(sync_id.clone(), UploadState::default());
                json!({
                    "ok": true,
                    "syncId": sync_id,
                    "maxChunkBytes": MAX_CHUNK_BYTES,
                    "protocol": "studio-stud-v1",
                    "protocolVersion": PROTOCOL_VERSION,
                })
            }
            (tiny_http::Method::Post, "/studio-stud/tick/bulk/chunk") => {
                let sync_id = required_query(&query, "syncId")?;
                let index = required_query(&query, "index")?.parse::<usize>()?;
                let body = read_request_bytes(&mut request)?;
                let received = body.len();
                let mut guard = state
                    .lock()
                    .map_err(|_| anyhow!("daemon state lock poisoned"))?;
                let Some(upload) = guard.tick_uploads.get_mut(&sync_id) else {
                    return Ok(unknown_sync_id_response());
                };
                upload.chunks.insert(index, body);
                json!({ "ok": true, "syncId": sync_id, "chunkIndex": index, "receivedBytes": received })
            }
            (tiny_http::Method::Post, "/studio-stud/tick/bulk/complete") => {
                let payload = read_request_json(&mut request)?;
                let sync_id = payload
                    .get("syncId")
                    .and_then(Value::as_str)
                    .ok_or_else(|| anyhow!("syncId is required"))?
                    .to_string();
                let expected_chunks = payload
                    .get("expectedChunks")
                    .and_then(Value::as_u64)
                    .map(|value| value as usize);
                let mut guard = state
                    .lock()
                    .map_err(|_| anyhow!("daemon state lock poisoned"))?;
                let Some(upload) = guard.tick_uploads.remove(&sync_id) else {
                    return Ok(unknown_sync_id_response());
                };
                let bytes = assemble_upload(upload, expected_chunks)?;
                guard.staged_tick_bulks.insert(sync_id.clone(), bytes);
                json!({ "ok": true, "syncId": sync_id, "status": "staged" })
            }
            (tiny_http::Method::Post, "/studio-stud/live/delta") => {
                if is_in_play(&state)? {
                    // Defense-in-depth: the plugin already gates deltas during play.
                    play_session_block()
                } else {
                    let payload = read_request_json(&mut request)?;
                    let delta = parse_delta_request(&payload)?;
                    crate::obs::event(
                        "live-delta",
                        &format!(
                            "RECV delta upserted={} removed={}",
                            delta.upserted.len(),
                            delta.removed.len()
                        ),
                    );
                    let storage = crate::storage::Storage::new(storage_root.clone(), project_key)?;
                    set_active_place(&storage, &delta.place_id);
                    apply_delta(
                        storage_root.clone(),
                        project_key,
                        Some(delta.place_id.as_str()),
                        &delta,
                        &config.registry_conns,
                    )?
                }
            }
            (tiny_http::Method::Get, "/studio-stud/live/fingerprint") => {
                let place_id = query.get("placeId").map(String::as_str);
                live_fingerprint(storage_root.clone(), project_key, place_id)?
            }
            (tiny_http::Method::Post, "/studio-stud/live/verify/start") => {
                let sync_id = make_id("verify");
                state
                    .lock()
                    .map_err(|_| anyhow!("daemon state lock poisoned"))?
                    .verify_uploads
                    .insert(sync_id.clone(), UploadState::default());
                json!({
                    "ok": true,
                    "syncId": sync_id,
                    "maxChunkBytes": MAX_CHUNK_BYTES,
                })
            }
            (tiny_http::Method::Post, "/studio-stud/live/verify/body") => {
                let sync_id = required_query(&query, "syncId")?;
                let body = read_request_bytes(&mut request)?;
                let received = body.len();
                let mut guard = state
                    .lock()
                    .map_err(|_| anyhow!("daemon state lock poisoned"))?;
                let Some(upload) = guard.verify_uploads.get_mut(&sync_id) else {
                    return Ok(unknown_sync_id_response());
                };
                upload.body = Some(body);
                json!({ "ok": true, "syncId": sync_id, "receivedBytes": received })
            }
            (tiny_http::Method::Post, "/studio-stud/live/verify/chunk") => {
                let sync_id = required_query(&query, "syncId")?;
                let index = required_query(&query, "index")?.parse::<usize>()?;
                let body = read_request_bytes(&mut request)?;
                let received = body.len();
                let mut guard = state
                    .lock()
                    .map_err(|_| anyhow!("daemon state lock poisoned"))?;
                let Some(upload) = guard.verify_uploads.get_mut(&sync_id) else {
                    return Ok(unknown_sync_id_response());
                };
                upload.chunks.insert(index, body);
                json!({ "ok": true, "syncId": sync_id, "chunkIndex": index, "receivedBytes": received })
            }
            (tiny_http::Method::Post, "/studio-stud/live/verify/complete") => {
                let payload = read_request_json(&mut request)?;
                let sync_id = payload
                    .get("syncId")
                    .and_then(Value::as_str)
                    .ok_or_else(|| anyhow!("syncId is required"))?
                    .to_string();
                let place_id = payload
                    .get("placeId")
                    .and_then(Value::as_str)
                    .map(str::to_string);
                let expected_chunks = payload
                    .get("expectedChunks")
                    .and_then(Value::as_u64)
                    .map(|value| value as usize);
                complete_verify_upload(
                    &sync_id,
                    expected_chunks,
                    place_id.as_deref(),
                    state,
                    storage_root.clone(),
                    project_key,
                )?
            }
            (tiny_http::Method::Get, "/studio-stud/write/token") => {
                if is_in_play(&state)? {
                    play_session_block()
                } else {
                    json!({ "ok": true, "token": config.write_token })
                }
            }
            (tiny_http::Method::Post, "/studio-stud/write/validate") => {
                if is_in_play(&state)? {
                    play_session_block()
                } else {
                    handle_write_route(&mut request, config, WriteMode::Validate)?
                }
            }
            (tiny_http::Method::Post, "/studio-stud/write/preview") => {
                if is_in_play(&state)? {
                    play_session_block()
                } else {
                    handle_write_route(&mut request, config, WriteMode::Preview)?
                }
            }
            (tiny_http::Method::Post, "/studio-stud/write/apply") => {
                if is_in_play(&state)? {
                    play_session_block()
                } else {
                    handle_write_route(&mut request, config, WriteMode::Apply)?
                }
            }
            (tiny_http::Method::Get, "/studio-stud/context") => {
                handle_context_route(&query, config)?
            }
            (tiny_http::Method::Post, "/studio-stud/context/bind") => {
                handle_context_bind(&mut request, config)?
            }
            (tiny_http::Method::Get, "/studio-stud/addons") => {
                handle_addons_list(&query, config)?
            }
            (tiny_http::Method::Post, "/studio-stud/addons/enable") => {
                handle_addons_enable(&mut request, config)?
            }
            (tiny_http::Method::Post, "/studio-stud/addons/disable") => {
                handle_addons_disable(&mut request, config)?
            }
            (tiny_http::Method::Post, "/studio-stud/admin/shutdown") => {
                handle_admin_shutdown(&mut request, config)?
            }
            _ => json!({ "ok": false, "error": "not_found" }),
        })
    })();
    let (status, payload) = match result {
        Ok(value) => (map_response_status(&value), value),
        Err(err) => {
            crate::obs::event("http-error", &format!("{method_label} {path_label}: {err:#}"));
            (503, json!({ "ok": false, "error": format!("{err:#}") }))
        }
    };
    let ms = started.elapsed().as_millis();
    crate::obs::event(
        "http",
        &format!("{method_label} {path_label} -> {status} ({ms} ms)"),
    );
    respond_json(request, status, &payload)
}

fn unknown_sync_id_response() -> Value {
    json!({
        "ok": false,
        "error": "unknownSyncId",
        "needsRebaseline": true,
    })
}

fn map_response_status(value: &Value) -> u16 {
    if value.get("needsRebaseline").and_then(Value::as_bool) == Some(true) {
        return 200;
    }
    if let Some(reason) = value.get("blockedReason").and_then(Value::as_str) {
        return match reason {
            "tokenInvalid" => 401,
            "badRequest" => 400,
            _ => 200,
        };
    }
    if value.get("error").and_then(Value::as_str)
        == Some("plugin protocol is too old for this daemon")
    {
        return 426;
    }
    if value.get("ok").and_then(Value::as_bool) == Some(false) {
        return 404;
    }
    200
}

fn handle_write_route(
    request: &mut tiny_http::Request,
    config: &ServeConfig,
    mode: WriteMode,
) -> Result<Value> {
    let header_token = request
        .headers()
        .iter()
        .find(|header| header.field.equiv("X-StudioStud-Token"))
        .map(|header| header.value.as_str().to_string());
    let payload = match read_request_json(request) {
        Ok(value) => value,
        Err(err) => {
            return Ok(json!({
                "ok": false,
                "blocked": true,
                "blockedReason": "badRequest",
                "detail": err.to_string(),
                "path": "",
                "changed": false,
                "diff": "",
                "bytes": 0,
                "hashBefore": "",
                "hashAfter": "",
            }));
        }
    };
    let token = header_token
        .or_else(|| {
            payload
                .get("token")
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .unwrap_or_default();
    if token != config.write_token {
        return Ok(json!({
            "ok": false,
            "blocked": true,
            "blockedReason": "tokenInvalid",
            "path": payload.get("path").and_then(Value::as_str).unwrap_or(""),
            "changed": false,
            "diff": "",
            "bytes": 0,
            "hashBefore": "",
            "hashAfter": "",
        }));
    }
    let path = payload.get("path").and_then(Value::as_str);
    let content = payload.get("content").and_then(Value::as_str);
    let (Some(path), Some(content)) = (path, content) else {
        return Ok(json!({
            "ok": false,
            "blocked": true,
            "blockedReason": "badRequest",
            "detail": "path and content are required",
            "path": path.unwrap_or(""),
            "changed": false,
            "diff": "",
            "bytes": 0,
            "hashBefore": "",
            "hashAfter": "",
        }));
    };
    let expected_hash = payload.get("expectedHash").and_then(Value::as_str);
    let generated_by = payload.get("generatedBy").and_then(Value::as_str);
    let place_id = parse_place_id_payload(&payload);
    let repo_root = match config.registry.resolve_repo_root(place_id) {
        Ok(p) => p,
        Err(e) => return Ok(e.to_json()),
    };
    let outcome = run_write(
        &repo_root,
        path,
        content.as_bytes(),
        place_id,
        expected_hash,
        generated_by,
        mode,
    );
    Ok(write_outcome_to_json(&outcome))
}

fn handle_context_route(query: &HashMap<String, String>, config: &ServeConfig) -> Result<Value> {
    let place_id = parse_place_id_query(query);
    match config.registry.resolve_repo_root(place_id) {
        Ok(repo) => Ok(json!({
            "ok": true,
            "status": "bound",
            "placeId": place_id,
            "repoRoot": repo.display().to_string(),
        })),
        Err(RepoResolveError::Unbound { place_id, registered }) => Ok(json!({
            "ok": true,
            "status": "unbound",
            "placeId": place_id,
            "registeredRepos": registered,
        })),
        Err(RepoResolveError::NoRegistry) => Ok(RepoResolveError::NoRegistry.to_json()),
    }
}

fn handle_context_bind(request: &mut tiny_http::Request, config: &ServeConfig) -> Result<Value> {
    let payload = read_request_json(request)?;
    let place_id = parse_place_id_payload(&payload)
        .ok_or_else(|| anyhow!("placeId is required"))?;
    let repo_path = payload
        .get("repoPath")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("repoPath is required"))?;
    let changed = config
        .registry
        .bind_place(place_id, std::path::Path::new(repo_path))
        .map_err(|e| anyhow!(e))?;
    Ok(json!({ "ok": true, "bound": changed, "placeId": place_id, "repoPath": repo_path }))
}

fn handle_addons_list(query: &HashMap<String, String>, config: &ServeConfig) -> Result<Value> {
    let place_id = parse_place_id_query(query);
    let snapshot = config.registry.config_snapshot();
    let repo_entry = match place_id {
        Some(pid) => snapshot.repos.iter().find(|r| r.place_id == Some(pid)),
        None => snapshot.repos.first(),
    };
    let enabled: Vec<String> = repo_entry
        .map(|r| r.enabled_addons.clone())
        .unwrap_or_default();
    let available = list_bundled_addons(&config.install_root)?
        .into_iter()
        .map(|(id, _)| {
            json!({
                "id": id,
                "enabled": enabled.iter().any(|e| e == &id),
            })
        })
        .collect::<Vec<_>>();
    Ok(json!({ "ok": true, "addons": available, "placeId": place_id }))
}

fn handle_addons_enable(request: &mut tiny_http::Request, config: &ServeConfig) -> Result<Value> {
    let payload = read_request_json(request)?;
    let token = payload.get("token").and_then(Value::as_str).unwrap_or_default();
    if token != config.write_token {
        return Ok(json!({ "ok": false, "blockedReason": "tokenInvalid" }));
    }
    let place_id = parse_place_id_payload(&payload)
        .ok_or_else(|| anyhow!("placeId required"))?;
    let addon_id = payload
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("id required"))?;
    let repo_root = match config.registry.resolve_repo_root(Some(place_id)) {
        Ok(p) => p,
        Err(e) => return Ok(e.to_json()),
    };
    enable_addon(
        &config.install_root,
        &config.plugins_dir,
        &repo_root,
        addon_id,
    )?;
    let mut cfg = config.registry.config_snapshot();
    if let Some(entry) = cfg
        .repos
        .iter_mut()
        .find(|r| r.place_id == Some(place_id))
    {
        if !entry.enabled_addons.iter().any(|a| a == addon_id) {
            entry.enabled_addons.push(addon_id.to_string());
            crate::setup_core::save_config(&cfg)?;
        }
    }
    Ok(json!({
        "ok": true,
        "enabled": addon_id,
        "reloadStudioHint": "If the addon panel does not appear, reload Studio.",
    }))
}

fn handle_addons_disable(request: &mut tiny_http::Request, config: &ServeConfig) -> Result<Value> {
    let payload = read_request_json(request)?;
    let token = payload.get("token").and_then(Value::as_str).unwrap_or_default();
    if token != config.write_token {
        return Ok(json!({ "ok": false, "blockedReason": "tokenInvalid" }));
    }
    let place_id = parse_place_id_payload(&payload)
        .ok_or_else(|| anyhow!("placeId required"))?;
    let addon_id = payload
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("id required"))?;
    let repo_root = config.registry.resolve_repo_root(Some(place_id)).map_err(|e| {
        anyhow!("{}", serde_json::to_string(&e.to_json()).unwrap_or_default())
    })?;
    disable_addon(&config.plugins_dir, &repo_root, addon_id)?;
    let mut cfg = config.registry.config_snapshot();
    if let Some(entry) = cfg
        .repos
        .iter_mut()
        .find(|r| r.place_id == Some(place_id))
    {
        entry.enabled_addons.retain(|a| a != addon_id);
        crate::setup_core::save_config(&cfg)?;
    }
    Ok(json!({ "ok": true, "disabled": addon_id }))
}

fn handle_admin_shutdown(request: &mut tiny_http::Request, config: &ServeConfig) -> Result<Value> {
    let payload = read_request_json(request)?;
    let token = payload.get("token").and_then(Value::as_str).unwrap_or_default();
    if token != config.write_token {
        return Ok(json!({ "ok": false, "blockedReason": "tokenInvalid" }));
    }
    let _ = crate::setup_core::config::remove_daemon_lock();
    config.shutdown.store(true, Ordering::SeqCst);
    std::thread::spawn(|| {
        std::thread::sleep(Duration::from_millis(100));
        std::process::exit(0);
    });
    Ok(json!({ "ok": true, "shuttingDown": true }))
}

fn capture_finalize_status(guard: &DaemonState, sync_id: &str) -> Value {
    match guard.finalize_by_sync.get(sync_id) {
        Some(CaptureFinalizeState::Finalizing) => {
            json!({ "ok": true, "syncId": sync_id, "status": "finalizing" })
        }
        Some(CaptureFinalizeState::Done(completion)) => {
            let mut out = completion.clone();
            if let Some(obj) = out.as_object_mut() {
                obj.entry("syncId".to_string())
                    .or_insert(json!(sync_id));
                obj.entry("status".to_string())
                    .or_insert(json!("done"));
            }
            out
        }
        Some(CaptureFinalizeState::Error(message)) => {
            json!({ "ok": false, "syncId": sync_id, "status": "error", "error": message })
        }
        None => json!({ "ok": false, "syncId": sync_id, "status": "unknown" }),
    }
}

fn materialize_capture_upload(
    bytes: &[u8],
    sync_id: &str,
    active_request_id: Option<String>,
    storage_root: Option<PathBuf>,
    project_key: &str,
    registry: Arc<ConnRegistry>,
) -> Result<Value> {
    let raw_json = decode_raw_snapshot(bytes)?;
    let mut snapshot: Value = serde_json::from_str(&raw_json)?;
    let request_id = snapshot
        .get("sync")
        .and_then(|sync| sync.get("requestId"))
        .and_then(Value::as_str)
        .map(str::to_string)
        .or(active_request_id);
    inject_sync_metadata(&mut snapshot, sync_id, request_id.as_deref());
    let _span = crate::obs::span("capture", "materialize_snapshot");
    let result = materialize_snapshot(&snapshot, storage_root.clone(), project_key, &registry)?;
    if let Ok(storage) = crate::storage::Storage::new(storage_root.clone(), project_key)
        && let Some(place_id) = result.get("placeId").and_then(Value::as_str)
    {
        set_active_place(&storage, place_id);
        if let Ok(pid) = place_id.parse::<i64>() {
            let resolver = crate::RepoResolver::load();
            let _ = resolver.learn_place_from_cwd(pid);
        }
    }
    Ok(json!({
        "ok": true,
        "status": "completed",
        "requestId": request_id,
        "result": result,
    }))
}

fn record_capture_completion(guard: &mut DaemonState, completion: &Value) {
    if let Some(request_id) = completion
        .get("requestId")
        .and_then(Value::as_str)
        .map(str::to_string)
    {
        guard
            .completions
            .insert(request_id.clone(), completion.clone());
        if guard.active_request_id.as_deref() == Some(request_id.as_str()) {
            guard.active_request_id = None;
        }
    }
}

pub(crate) fn complete_daemon_upload(
    sync_id: &str,
    expected_chunks: Option<usize>,
    state: Arc<Mutex<DaemonState>>,
    storage_root: Option<PathBuf>,
    project_key: &str,
    registry: Arc<ConnRegistry>,
) -> Result<Value> {
    let (upload, active_request_id) = {
        let mut guard = state
            .lock()
            .map_err(|_| anyhow!("daemon state lock poisoned"))?;
        let Some(upload) = guard.uploads.remove(sync_id) else {
            return Ok(unknown_sync_id_response());
        };
        (upload, guard.active_request_id.clone())
    };
    let bytes = assemble_upload(upload, expected_chunks)?;
    {
        let mut guard = state
            .lock()
            .map_err(|_| anyhow!("daemon state lock poisoned"))?;
        guard
            .finalize_by_sync
            .insert(sync_id.to_string(), CaptureFinalizeState::Finalizing);
    }
    let sync_id_owned = sync_id.to_string();
    let project_key_owned = project_key.to_string();
    let state_worker = Arc::clone(&state);
    std::thread::spawn(move || {
        let outcome = materialize_capture_upload(
            &bytes,
            &sync_id_owned,
            active_request_id,
            storage_root,
            &project_key_owned,
            registry,
        );
        let Ok(mut guard) = state_worker.lock() else {
            return;
        };
        match outcome {
            Ok(completion) => {
                record_capture_completion(&mut guard, &completion);
                guard
                    .finalize_by_sync
                    .insert(sync_id_owned, CaptureFinalizeState::Done(completion));
            }
            Err(err) => {
                guard.finalize_by_sync.insert(
                    sync_id_owned,
                    CaptureFinalizeState::Error(format!("{err:#}")),
                );
            }
        }
    });
    Ok(json!({
        "ok": true,
        "status": "finalizing",
        "syncId": sync_id,
    }))
}

pub(crate) fn complete_verify_upload(
    sync_id: &str,
    expected_chunks: Option<usize>,
    place_id: Option<&str>,
    state: Arc<Mutex<DaemonState>>,
    storage_root: Option<PathBuf>,
    project_key: &str,
) -> Result<Value> {
    let upload = {
        let mut guard = state
            .lock()
            .map_err(|_| anyhow!("daemon state lock poisoned"))?;
        guard.verify_uploads.remove(sync_id)
    };
    let Some(upload) = upload else {
        return Ok(unknown_sync_id_response());
    };
    let bytes = assemble_upload(upload, expected_chunks)?;
    let raw_json = decode_raw_snapshot(&bytes)?;
    let snapshot: Value = serde_json::from_str(&raw_json)?;
    verify_drift(storage_root, project_key, place_id, &snapshot, &bytes)
}

pub(crate) fn assemble_upload(
    upload: UploadState,
    expected_chunks: Option<usize>,
) -> Result<Vec<u8>> {
    if let Some(body) = upload.body {
        return Ok(body);
    }
    let expected = expected_chunks.unwrap_or(upload.chunks.len());
    if upload.chunks.len() != expected {
        return Err(anyhow!(
            "expected {expected} chunks but received {}",
            upload.chunks.len()
        ));
    }
    let mut bytes = Vec::new();
    for index in 0..expected {
        let chunk = upload
            .chunks
            .get(&index)
            .ok_or_else(|| anyhow!("missing chunk {index}"))?;
        bytes.extend_from_slice(chunk);
    }
    Ok(bytes)
}

pub(crate) fn read_request_bytes(request: &mut tiny_http::Request) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    request.as_reader().read_to_end(&mut bytes)?;
    Ok(bytes)
}

pub(crate) fn read_request_json(request: &mut tiny_http::Request) -> Result<Value> {
    let bytes = read_request_bytes(request)?;
    if bytes.is_empty() {
        return Ok(json!({}));
    }
    Ok(serde_json::from_slice(&bytes)?)
}

pub(crate) fn respond_json(
    request: tiny_http::Request,
    status: u16,
    payload: &Value,
) -> Result<()> {
    let body = serde_json::to_string(payload)?;
    let header = tiny_http::Header::from_bytes(&b"Content-Type"[..], &b"application/json"[..])
        .map_err(|_| anyhow!("failed to build content-type header"))?;
    request
        .respond(
            tiny_http::Response::from_string(body)
                .with_status_code(tiny_http::StatusCode(status))
                .with_header(header)
                .with_chunked_threshold(usize::MAX),
        )
        .map_err(|err| anyhow!("{err}"))
}
pub(crate) fn daemon_json(method: &str, path: &str, body: Option<&Value>) -> Result<Value> {
    let body_text = match body {
        Some(value) => serde_json::to_string(value)?,
        None => String::new(),
    };
    let mut stream = TcpStream::connect((DEFAULT_HOST, DEFAULT_PORT))?;
    stream.set_read_timeout(Some(Duration::from_secs(15)))?;
    stream.set_write_timeout(Some(Duration::from_secs(15)))?;
    let request = if body.is_some() {
        format!(
            "{method} {path} HTTP/1.1\r\nHost: {DEFAULT_HOST}:{DEFAULT_PORT}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body_text}",
            body_text.len()
        )
    } else {
        format!(
            "{method} {path} HTTP/1.1\r\nHost: {DEFAULT_HOST}:{DEFAULT_PORT}\r\nConnection: close\r\n\r\n"
        )
    };
    stream.write_all(request.as_bytes())?;
    let mut response = String::new();
    stream.read_to_string(&mut response)?;
    let (_, payload) = response
        .split_once("\r\n\r\n")
        .ok_or_else(|| anyhow!("invalid daemon HTTP response"))?;
    let value: Value = serde_json::from_str(payload.trim())?;
    if value.get("ok").and_then(Value::as_bool) == Some(false) {
        let error = value
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("daemon request failed");
        if error == "studio_in_play_session" {
            let detail = value.get("detail").and_then(Value::as_str).unwrap_or(
                "Studio is in a play session; world state is frozen — retry after the playtest.",
            );
            return Err(anyhow!("{detail}"));
        }
        return Err(anyhow!("{error}"));
    }
    Ok(value)
}

pub(crate) fn manifest_json_with_update(config: &ServeConfig) -> Value {
    let mut body = manifest_json();
    if let Some(obj) = body.as_object_mut() {
        for (k, v) in config.channel_update.ping_fields().as_object().into_iter().flatten() {
            obj.insert(k.clone(), v.clone());
        }
    }
    body
}

pub(crate) fn manifest_json() -> Value {
    json!({
        "ok": true,
        "service": "studio-stud",
        "version": env!("CARGO_PKG_VERSION"),
        "time": now_utc(),
        "protocol": "studio-stud-v1",
        "protocolVersion": PROTOCOL_VERSION,
        "minPluginProtocolVersion": MIN_PLUGIN_PROTOCOL_VERSION,
        "output": {
            "default": "compact-json",
            "human": "--markdown"
        }
    })
}
