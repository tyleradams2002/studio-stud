use std::{
    collections::{BTreeMap, HashMap, VecDeque},
    io::{Read, Write},
    net::TcpStream,
    path::PathBuf,
    sync::{Arc, Mutex},
    time::Duration,
};

use anyhow::{Result, anyhow};
use serde_json::{Value, json};

use crate::capture::{decode_raw_snapshot, inject_sync_metadata, materialize_snapshot};
use crate::live::{apply_delta, live_fingerprint, parse_delta_request, verify_drift};
use crate::stage3_cli::{run_write, write_outcome_to_json};
use crate::storage::set_active_place;
use crate::util::{
    DEFAULT_HOST, DEFAULT_PORT, MAX_CHUNK_BYTES, MIN_PLUGIN_PROTOCOL_VERSION, PROTOCOL_VERSION,
    make_id, now_utc, required_query, split_url,
};
use crate::write::WriteMode;

#[derive(Clone, Debug)]
pub struct ServeConfig {
    pub storage_root: Option<PathBuf>,
    pub project_key: String,
    pub repo_root: PathBuf,
    pub write_token: String,
}

#[derive(Default)]
pub(crate) struct UploadState {
    body: Option<Vec<u8>>,
    chunks: BTreeMap<usize, Vec<u8>>,
}

#[derive(Default)]
pub(crate) struct DaemonState {
    pending_requests: VecDeque<Value>,
    active_request_id: Option<String>,
    uploads: HashMap<String, UploadState>,
    verify_uploads: HashMap<String, UploadState>,
    completions: HashMap<String, Value>,
}

pub(crate) fn handle_daemon_request(
    mut request: tiny_http::Request,
    state: Arc<Mutex<DaemonState>>,
    config: &ServeConfig,
) -> Result<()> {
    let storage_root = config.storage_root.clone();
    let project_key = config.project_key.as_str();
    let method = request.method().clone();
    let url = request.url().to_string();
    let (path, query) = split_url(&url);
    let result = (|| -> Result<Value> {
        Ok(match (method, path.as_str()) {
            (tiny_http::Method::Get, "/ping") | (tiny_http::Method::Get, "/studio-stud/ping") => {
                manifest_json()
            }
            (tiny_http::Method::Get, "/studio-stud/manifest") => manifest_json(),
            (tiny_http::Method::Get, "/request-sync")
            | (tiny_http::Method::Get, "/studio-stud/capture/request") => {
                let mut guard = state
                    .lock()
                    .map_err(|_| anyhow!("daemon state lock poisoned"))?;
                let request = guard.pending_requests.pop_front();
                if let Some(request) = &request {
                    guard.active_request_id = request
                        .get("id")
                        .and_then(Value::as_str)
                        .map(str::to_string);
                }
                json!({ "ok": true, "request": request })
            }
            (tiny_http::Method::Get, "/studio-stud/capture/status") => {
                let request_id = query.get("requestId").cloned().unwrap_or_default();
                let guard = state
                    .lock()
                    .map_err(|_| anyhow!("daemon state lock poisoned"))?;
                if let Some(done) = guard.completions.get(&request_id) {
                    done.clone()
                } else if guard.active_request_id.as_deref() == Some(request_id.as_str()) {
                    json!({ "ok": true, "requestId": request_id, "status": "in_progress" })
                } else if guard
                    .pending_requests
                    .iter()
                    .any(|item| item.get("id").and_then(Value::as_str) == Some(request_id.as_str()))
                {
                    json!({ "ok": true, "requestId": request_id, "status": "queued" })
                } else {
                    json!({ "ok": true, "requestId": request_id, "status": "unknown" })
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
                )?
            }
            (tiny_http::Method::Post, "/studio-stud/live/delta") => {
                let payload = read_request_json(&mut request)?;
                let delta = parse_delta_request(&payload)?;
                let storage = crate::storage::Storage::new(storage_root.clone(), project_key)?;
                set_active_place(&storage, &delta.place_id);
                apply_delta(
                    storage_root.clone(),
                    project_key,
                    Some(delta.place_id.as_str()),
                    &delta,
                )?
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
                json!({ "ok": true, "token": config.write_token })
            }
            (tiny_http::Method::Post, "/studio-stud/write/validate") => {
                handle_write_route(&mut request, config, WriteMode::Validate)?
            }
            (tiny_http::Method::Post, "/studio-stud/write/preview") => {
                handle_write_route(&mut request, config, WriteMode::Preview)?
            }
            (tiny_http::Method::Post, "/studio-stud/write/apply") => {
                handle_write_route(&mut request, config, WriteMode::Apply)?
            }
            _ => json!({ "ok": false, "error": "not_found" }),
        })
    })();
    let (status, payload) = match result {
        Ok(value) => (map_response_status(&value), value),
        Err(err) => {
            eprintln!("request failed: {err:#}");
            (503, json!({ "ok": false, "error": format!("{err:#}") }))
        }
    };
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
    let place_id = payload.get("placeId").and_then(Value::as_i64);
    let outcome = run_write(
        &config.repo_root,
        path,
        content.as_bytes(),
        place_id,
        expected_hash,
        generated_by,
        mode,
    );
    Ok(write_outcome_to_json(&outcome))
}

pub(crate) fn complete_daemon_upload(
    sync_id: &str,
    expected_chunks: Option<usize>,
    state: Arc<Mutex<DaemonState>>,
    storage_root: Option<PathBuf>,
    project_key: &str,
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
    let raw_json = decode_raw_snapshot(&bytes)?;
    let mut snapshot: Value = serde_json::from_str(&raw_json)?;
    let request_id = snapshot
        .get("sync")
        .and_then(|sync| sync.get("requestId"))
        .and_then(Value::as_str)
        .map(str::to_string)
        .or(active_request_id);
    inject_sync_metadata(&mut snapshot, sync_id, request_id.as_deref());
    let result = materialize_snapshot(&snapshot, storage_root.clone(), project_key)?;
    if let Ok(storage) = crate::storage::Storage::new(storage_root.clone(), project_key)
        && let Some(place_id) = result.get("placeId").and_then(Value::as_str)
    {
        set_active_place(&storage, place_id);
    }
    let completion = json!({
        "ok": true,
        "status": "completed",
        "requestId": request_id,
        "result": result,
    });
    if let Some(request_id) = request_id {
        let mut guard = state
            .lock()
            .map_err(|_| anyhow!("daemon state lock poisoned"))?;
        guard
            .completions
            .insert(request_id.clone(), completion.clone());
        if guard.active_request_id.as_deref() == Some(request_id.as_str()) {
            guard.active_request_id = None;
        }
    }
    Ok(completion)
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
                .with_header(header),
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
        return Err(anyhow!(
            "{}",
            value
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or("daemon request failed")
        ));
    }
    Ok(value)
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
