use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn fixture(name: &str) -> PathBuf {
    repo_root().join("tests/fixtures/live").join(name)
}

fn temp_storage(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("studio_stud_tick_{name}_{}", std::process::id()));
    if dir.exists() {
        fs::remove_dir_all(&dir).ok();
    }
    fs::create_dir_all(&dir).expect("create temp storage");
    dir
}

fn pick_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .expect("bind ephemeral port")
        .local_addr()
        .expect("local addr")
        .port()
}

fn http_request(method: &str, port: u16, path: &str, body: Option<&str>) -> (u16, String) {
    let mut stream = TcpStream::connect(format!("127.0.0.1:{port}")).expect("connect to daemon");
    stream.set_read_timeout(Some(Duration::from_secs(30))).ok();
    let body_str = body.unwrap_or("");
    let req = format!(
        "{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body_str}",
        body_str.len()
    );
    stream.write_all(req.as_bytes()).expect("write request");
    let mut buf = Vec::new();
    stream.read_to_end(&mut buf).expect("read response");
    let response = String::from_utf8_lossy(&buf);
    let status = response
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|code| code.parse().ok())
        .unwrap_or(0);
    let body_json = response.split("\r\n\r\n").nth(1).unwrap_or("").to_string();
    (status, body_json)
}

struct ServeGuard {
    child: Child,
    port: u16,
}

impl Drop for ServeGuard {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn start_serve(storage: &PathBuf) -> ServeGuard {
    let port = pick_port();
    let repo = repo_root();
    let mut child = Command::new(env!("CARGO_BIN_EXE_studio-stud"))
        .args([
            "serve",
            "--host",
            "127.0.0.1",
            "--port",
            &port.to_string(),
            "--storage-root",
        ])
        .arg(storage)
        .current_dir(&repo)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn serve");
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        let (status, body) = http_request("GET", port, "/studio-stud/ping", None);
        if status == 200 && body.contains("\"ok\":true") {
            return ServeGuard { child, port };
        }
        thread::sleep(Duration::from_millis(100));
    }
    let _ = child.kill();
    let _ = child.wait();
    panic!("serve did not become ready");
}

fn parse_json(body: &str) -> Value {
    serde_json::from_str(body.trim()).expect("response json")
}

fn run_cli(args: &[&str], storage_root: &Path) -> Value {
    let exe = env!("CARGO_BIN_EXE_studio-stud");
    let output = Command::new(exe)
        .args(args)
        .arg("--storage-root")
        .arg(storage_root)
        .output()
        .expect("studio-stud should run");
    assert!(
        output.status.success(),
        "command failed: {:?}\nstderr={}",
        args,
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("stdout json")
}

fn service_fps_from_cli(storage: &Path) -> serde_json::Map<String, Value> {
    let dump = run_cli(&["live-services", "999001"], storage);
    let services = dump
        .get("services")
        .and_then(Value::as_object)
        .expect("services");
    let mut out = serde_json::Map::new();
    for (name, entry) in services {
        let fp = entry
            .get("fingerprint")
            .and_then(Value::as_str)
            .expect("service fingerprint");
        out.insert(name.clone(), json!(fp));
    }
    out
}

fn ingest_baseline(storage: &Path) -> Value {
    ingest_fixture("baseline.json", storage)
}

fn ingest_fixture(name: &str, storage: &Path) -> Value {
    run_cli(
        &[
            "ingest",
            "--raw",
            fixture(name).to_str().unwrap(),
        ],
        storage,
    )
}

fn stage_tick_bulk(port: u16, snapshot_json: &str) -> String {
    let start_body = r#"{"protocolVersion":2,"place":{"placeId":"999001","placeKey":"LiveTest"}}"#;
    let (status, response) = http_request(
        "POST",
        port,
        "/studio-stud/tick/bulk/start",
        Some(start_body),
    );
    assert_eq!(status, 200, "bulk start failed: {response}");
    let sync_id = parse_json(&response)
        .get("syncId")
        .and_then(Value::as_str)
        .expect("syncId")
        .to_string();

    let path = format!("/studio-stud/tick/bulk/chunk?syncId={sync_id}&index=0");
    let (status, response) = http_request("POST", port, &path, Some(snapshot_json));
    assert_eq!(status, 200, "bulk chunk failed: {response}");

    let complete_body = format!(r#"{{"syncId":"{sync_id}","expectedChunks":1}}"#);
    let (status, response) = http_request(
        "POST",
        port,
        "/studio-stud/tick/bulk/complete",
        Some(&complete_body),
    );
    assert_eq!(status, 200, "bulk complete failed: {response}");
    sync_id
}

fn post_tick(port: u16, body: &Value) -> Value {
    let (status, response) = http_request(
        "POST",
        port,
        "/studio-stud/tick?placeId=999001",
        Some(&body.to_string()),
    );
    assert_eq!(status, 200, "tick failed: {response}");
    parse_json(&response)
}

#[test]
fn tick_empty_keepalive() {
    let storage = temp_storage("empty");
    ingest_baseline(&storage);
    let dump_before = run_cli(&["live-dump", "999001"], &storage);
    let rev_before = dump_before
        .get("meta")
        .and_then(|m| m.get("revision"))
        .and_then(Value::as_i64)
        .expect("revision");
    let updated_before = dump_before
        .get("meta")
        .and_then(|m| m.get("updatedAtUtc"))
        .and_then(Value::as_str)
        .expect("updatedAtUtc");

    let serve = start_serve(&storage);
    let fps = service_fps_from_cli(&storage);
    let body = json!({
        "placeId": "999001",
        "sessionMode": "edit",
        "baseRevision": rev_before,
        "serviceFingerprints": fps,
        "ops": { "upserted": [], "removed": [] },
        "bulkRef": null
    });
    let resp = post_tick(serve.port, &body);
    assert_eq!(resp.get("ok").and_then(Value::as_bool), Some(true));
    assert_eq!(
        resp.get("driftServices").and_then(Value::as_array).map(Vec::len),
        Some(0)
    );
    assert_eq!(
        resp.get("revision").and_then(Value::as_i64),
        Some(rev_before)
    );

    let dump_after = run_cli(&["live-dump", "999001"], &storage);
    assert_eq!(
        dump_after
            .get("meta")
            .and_then(|m| m.get("updatedAtUtc"))
            .and_then(Value::as_str),
        Some(updated_before)
    );
}

#[test]
fn tick_applies_ops() {
    let storage = temp_storage("ops");
    ingest_baseline(&storage);
    let serve = start_serve(&storage);
    let fps = service_fps_from_cli(&storage);
    let inst_fp = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    let body = json!({
        "placeId": "999001",
        "sessionMode": "edit",
        "baseRevision": 0,
        "serviceFingerprints": fps,
        "ops": {
            "upserted": [{
                "id": "newpart",
                "parentId": "ws",
                "path": "Workspace/TickPart",
                "name": "TickPart",
                "className": "Part",
                "depth": 1,
                "childCount": 0,
                "siblingIndex": 9,
                "duplicateSiblingName": false,
                "properties": {},
                "attributes": {},
                "tags": [],
                "fp": inst_fp
            }],
            "removed": []
        },
        "bulkRef": null
    });
    let resp = post_tick(serve.port, &body);
    assert_eq!(resp.get("ok").and_then(Value::as_bool), Some(true));
    assert_eq!(resp.get("revision").and_then(Value::as_i64), Some(1));

    let dump = run_cli(&["live-services", "999001"], &storage);
    assert_eq!(
        dump.get("global").and_then(Value::as_str),
        dump.get("xorOfServices").and_then(Value::as_str)
    );
}

#[test]
fn tick_reports_drift() {
    let storage = temp_storage("drift");
    ingest_baseline(&storage);
    let serve = start_serve(&storage);
    let mut fps = service_fps_from_cli(&storage);
    if let Some(ws) = fps.get_mut("Workspace") {
        *ws = json!("0".repeat(64));
    }
    let body = json!({
        "placeId": "999001",
        "sessionMode": "edit",
        "baseRevision": 0,
        "serviceFingerprints": fps,
        "ops": { "upserted": [], "removed": [] },
        "bulkRef": null
    });
    let resp = post_tick(serve.port, &body);
    let drift = resp
        .get("driftServices")
        .and_then(Value::as_array)
        .expect("driftServices");
    assert!(drift.iter().any(|v| v.as_str() == Some("Workspace")));
}

#[test]
fn tick_play_ignores_ops() {
    let storage = temp_storage("play");
    ingest_baseline(&storage);
    let serve = start_serve(&storage);
    let fps = service_fps_from_cli(&storage);
    let body = json!({
        "placeId": "999001",
        "sessionMode": "play",
        "baseRevision": 0,
        "serviceFingerprints": fps,
        "ops": {
            "upserted": [{
                "id": "ignored",
                "parentId": "ws",
                "path": "Workspace/Ignored",
                "name": "Ignored",
                "className": "Part",
                "depth": 1,
                "childCount": 0,
                "siblingIndex": 0,
                "duplicateSiblingName": false,
                "properties": {},
                "attributes": {},
                "tags": [],
                "fp": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
            }],
            "removed": []
        },
        "bulkRef": null
    });
    let resp = post_tick(serve.port, &body);
    assert_eq!(resp.get("ok").and_then(Value::as_bool), Some(true));
    assert_eq!(resp.get("revision").and_then(Value::as_i64), Some(0));
    let dump = run_cli(&["live-dump", "999001"], &storage);
    assert_eq!(
        dump.get("state")
            .and_then(Value::as_array)
            .map(|a| a.len()),
        Some(9)
    );
}

#[test]
fn tick_bulk_round_trip() {
    let storage = temp_storage("bulk");
    let serve = start_serve(&storage);
    let port = serve.port;
    let baseline = fs::read_to_string(fixture("baseline.json")).expect("read baseline");

    let start_body = r#"{"protocolVersion":2,"place":{"placeId":"999001","placeKey":"LiveTest"}}"#;
    let (status, response) = http_request(
        "POST",
        port,
        "/studio-stud/tick/bulk/start",
        Some(start_body),
    );
    assert_eq!(status, 200, "bulk start failed: {response}");
    let sync_id = parse_json(&response)
        .get("syncId")
        .and_then(Value::as_str)
        .expect("syncId")
        .to_string();

    let path = format!("/studio-stud/tick/bulk/chunk?syncId={sync_id}&index=0");
    let (status, response) = http_request("POST", port, &path, Some(&baseline));
    assert_eq!(status, 200, "bulk chunk failed: {response}");

    let complete_body = format!(r#"{{"syncId":"{sync_id}","expectedChunks":1}}"#);
    let (status, response) = http_request(
        "POST",
        port,
        "/studio-stud/tick/bulk/complete",
        Some(&complete_body),
    );
    assert_eq!(status, 200, "bulk complete failed: {response}");
    assert_eq!(
        parse_json(&response).get("status").and_then(Value::as_str),
        Some("staged")
    );

    let tick_body = json!({
        "placeId": "999001",
        "sessionMode": "edit",
        "baseRevision": 0,
        "serviceFingerprints": {},
        "ops": { "upserted": [], "removed": [] },
        "bulkRef": sync_id
    });
    let resp = post_tick(port, &tick_body);
    assert_eq!(resp.get("ok").and_then(Value::as_bool), Some(true));
    assert_eq!(resp.get("revision").and_then(Value::as_i64), Some(0));
    assert!(
        resp.get("instanceCount").and_then(Value::as_i64).unwrap_or(0) > 0
    );

    let dump = run_cli(&["live-services", "999001"], &storage);
    assert_eq!(dump.get("ok").and_then(Value::as_bool), Some(true));
    let services = dump
        .get("services")
        .and_then(Value::as_object)
        .expect("services");
    assert!(services.contains_key("Workspace"));
    assert_eq!(
        dump.get("global").and_then(Value::as_str),
        dump.get("xorOfServices").and_then(Value::as_str)
    );
}

#[test]
fn fp_xor_invariant_via_tick() {
    let storage = temp_storage("xor");
    ingest_baseline(&storage);
    let serve = start_serve(&storage);
    let mut fps = service_fps_from_cli(&storage);
    let inst_fp = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
    let body = json!({
        "placeId": "999001",
        "sessionMode": "edit",
        "baseRevision": 0,
        "serviceFingerprints": fps.clone(),
        "ops": {
            "upserted": [{
                "id": "xorpart",
                "parentId": "ws",
                "path": "Workspace/XorPart",
                "name": "XorPart",
                "className": "Part",
                "depth": 1,
                "childCount": 0,
                "siblingIndex": 0,
                "duplicateSiblingName": false,
                "properties": {},
                "attributes": {},
                "tags": [],
                "fp": inst_fp
            }],
            "removed": []
        },
        "bulkRef": null
    });
    post_tick(serve.port, &body);

    let dump = run_cli(&["live-services", "999001"], &storage);
    assert_eq!(
        dump.get("global").and_then(Value::as_str),
        dump.get("xorOfServices").and_then(Value::as_str)
    );

    fps = service_fps_from_cli(&storage);
    let keepalive = json!({
        "placeId": "999001",
        "sessionMode": "edit",
        "baseRevision": 1,
        "serviceFingerprints": fps,
        "ops": { "upserted": [], "removed": [] },
        "bulkRef": null
    });
    let resp = post_tick(serve.port, &keepalive);
    assert_eq!(
        resp.get("driftServices").and_then(Value::as_array).map(Vec::len),
        Some(0)
    );
}

fn xor_fp_hex(a: &str, b: &str) -> String {
    let mut out = [0u8; 32];
    for i in 0..32 {
        out[i] = u8::from_str_radix(&a[i * 2..i * 2 + 2], 16).expect("hex digit")
            ^ u8::from_str_radix(&b[i * 2..i * 2 + 2], 16).expect("hex digit");
    }
    out.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn post_apply_service_fps(
    storage: &Path,
    batch: &[Value],
) -> serde_json::Map<String, Value> {
    let mut fps = service_fps_from_cli(storage);
    for entry in batch {
        let fp = entry.get("fp").and_then(Value::as_str).expect("fp");
        let path = entry.get("path").and_then(Value::as_str).expect("path");
        let service = path.split('/').next().expect("service segment");
        let current = fps
            .get(service)
            .and_then(Value::as_str)
            .unwrap_or("0000000000000000000000000000000000000000000000000000000000000000");
        fps.insert(service.to_string(), json!(xor_fp_hex(current, fp)));
    }
    fps
}

fn current_revision(storage: &Path) -> i64 {
    run_cli(&["live-dump", "999001"], storage)
        .get("meta")
        .and_then(|m| m.get("revision"))
        .and_then(Value::as_i64)
        .expect("revision")
}

fn make_fat_upsert(id: &str, sibling_index: i64, pad_bytes: usize) -> Value {
    let pad = "x".repeat(pad_bytes);
    json!({
        "id": id,
        "parentId": "ws",
        "path": format!("Workspace/{id}"),
        "name": id,
        "className": "Part",
        "depth": 1,
        "childCount": 0,
        "siblingIndex": sibling_index,
        "duplicateSiblingName": false,
        "properties": { "pad": pad },
        "attributes": {},
        "tags": [],
        "fp": format!("{:064x}", sibling_index as u64)
    })
}

#[test]
fn tick_large_inline_delta_preserves_baseline() {
    let storage = temp_storage("large_inline");
    let baseline = ingest_baseline(&storage);
    let baseline_count = baseline
        .get("instances")
        .and_then(Value::as_u64)
        .expect("baseline instances") as i64;
    let serve = start_serve(&storage);

    let mut batch: Vec<Value> = Vec::new();
    let mut batch_bytes = 0usize;
    let pad_per_inst = 3500usize;
    let mut inst_index = 0i64;
    let send_batch = |batch: &[Value]| {
        let fps = post_apply_service_fps(&storage, batch);
        let body = json!({
            "placeId": "999001",
            "sessionMode": "edit",
            "baseRevision": current_revision(&storage),
            "serviceFingerprints": fps,
            "ops": { "upserted": batch, "removed": [] },
            "bulkRef": null
        });
        let resp = post_tick(serve.port, &body);
        assert_eq!(resp.get("ok").and_then(Value::as_bool), Some(true));
        assert_eq!(
            resp.get("driftServices").and_then(Value::as_array).map(Vec::len),
            Some(0),
            "inline capped batch should not drift when fingerprints are post-ops"
        );
    };

    loop {
        let inst_id = format!("bulk_{inst_index}");
        let entry = make_fat_upsert(&inst_id, inst_index + 10, pad_per_inst);
        let entry_len = entry.to_string().len();
        if !batch.is_empty() && batch_bytes + entry_len > 240_000 {
            send_batch(&batch);
            batch = Vec::new();
            batch_bytes = 0;
        }
        batch.push(entry);
        batch_bytes += entry_len;
        inst_index += 1;
        if inst_index >= 80 {
            break;
        }
    }

    if !batch.is_empty() {
        let fps = post_apply_service_fps(&storage, &batch);
        let body = json!({
            "placeId": "999001",
            "sessionMode": "edit",
            "baseRevision": current_revision(&storage),
            "serviceFingerprints": fps,
            "ops": { "upserted": batch, "removed": [] },
            "bulkRef": null
        });
        let resp = post_tick(serve.port, &body);
        assert_eq!(resp.get("ok").and_then(Value::as_bool), Some(true));
        assert_eq!(
            resp.get("driftServices").and_then(Value::as_array).map(Vec::len),
            Some(0)
        );
    }

    let dump = run_cli(&["live-dump", "999001"], &storage);
    let final_count = dump
        .get("state")
        .and_then(Value::as_array)
        .map(|rows| rows.len() as i64)
        .expect("state rows");
    assert_eq!(
        final_count,
        baseline_count + inst_index,
        "large inline deltas must add instances, not replace the place"
    );

    let state = dump
        .get("state")
        .and_then(Value::as_array)
        .expect("state rows");
    assert!(
        state.iter().any(|row| {
            row.get("id")
                .and_then(Value::as_str)
                .is_some_and(|id| id == "dup_a")
        }),
        "baseline instance dup_a must survive large inline delta batches"
    );
}

#[test]
fn script_sources_while_serve_holds_wal() {
    let storage = temp_storage("script_serve_wal");
    ingest_fixture("baseline_script_binary.json", &storage);
    let _serve = start_serve(&storage);
    let list = run_cli(&["script-sources", "999001"], &storage);
    assert_eq!(list.get("ok").and_then(Value::as_bool), Some(true));
    assert_eq!(list.get("count").and_then(Value::as_i64), Some(2));

    let utf8 = run_cli(
        &["script-source", "999001", "Workspace/Folder/Utf8Module"],
        &storage,
    );
    assert_eq!(utf8.get("ok").and_then(Value::as_bool), Some(true));
    assert_eq!(
        utf8.get("sourceText").and_then(Value::as_str),
        Some("return 1\n")
    );

    let binary = run_cli(
        &["script-source", "999001", "Workspace/Folder/BinModule"],
        &storage,
    );
    assert_eq!(binary.get("ok").and_then(Value::as_bool), Some(true));
    assert_eq!(
        binary.get("sourceEncoding").and_then(Value::as_str),
        Some("base64")
    );
    assert_eq!(
        binary.get("sourceText").and_then(Value::as_str),
        Some("AQIDBAU=")
    );
}

#[test]
fn play_edit_transition() {
    let storage = temp_storage("play_edit");
    ingest_baseline(&storage);
    let serve = start_serve(&storage);
    let fps = service_fps_from_cli(&storage);
    let inst_fp = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";

    let play_body = json!({
        "placeId": "999001",
        "sessionMode": "play",
        "baseRevision": 0,
        "serviceFingerprints": fps,
        "ops": {
            "upserted": [{
                "id": "playonly",
                "parentId": "ws",
                "path": "Workspace/PlayOnly",
                "name": "PlayOnly",
                "className": "Part",
                "depth": 1,
                "childCount": 0,
                "siblingIndex": 0,
                "duplicateSiblingName": false,
                "properties": {},
                "attributes": {},
                "tags": [],
                "fp": inst_fp
            }],
            "removed": []
        },
        "bulkRef": null
    });
    let play_resp = post_tick(serve.port, &play_body);
    assert_eq!(play_resp.get("ok").and_then(Value::as_bool), Some(true));
    assert_eq!(play_resp.get("revision").and_then(Value::as_i64), Some(0));

    let mut drift_fps = service_fps_from_cli(&storage);
    drift_fps.insert("Workspace".to_string(), json!("0".repeat(64)));
    let drift_play = json!({
        "placeId": "999001",
        "sessionMode": "play",
        "baseRevision": 0,
        "serviceFingerprints": drift_fps,
        "ops": { "upserted": [], "removed": [] },
        "bulkRef": null
    });
    let drift_resp = post_tick(serve.port, &drift_play);
    let drift = drift_resp
        .get("driftServices")
        .and_then(Value::as_array)
        .expect("driftServices");
    assert!(drift.iter().any(|v| v.as_str() == Some("Workspace")));

    let mut edit_fps = service_fps_from_cli(&storage);
    let ws_fp = edit_fps
        .get("Workspace")
        .and_then(Value::as_str)
        .unwrap_or("0000000000000000000000000000000000000000000000000000000000000000");
    edit_fps.insert("Workspace".to_string(), json!(xor_fp_hex(ws_fp, inst_fp)));
    let edit_body = json!({
        "placeId": "999001",
        "sessionMode": "edit",
        "baseRevision": 0,
        "serviceFingerprints": edit_fps,
        "ops": {
            "upserted": [{
                "id": "editpart",
                "parentId": "ws",
                "path": "Workspace/EditPart",
                "name": "EditPart",
                "className": "Part",
                "depth": 1,
                "childCount": 0,
                "siblingIndex": 11,
                "duplicateSiblingName": false,
                "properties": {},
                "attributes": {},
                "tags": [],
                "fp": inst_fp
            }],
            "removed": []
        },
        "bulkRef": null
    });
    let edit_resp = post_tick(serve.port, &edit_body);
    assert_eq!(edit_resp.get("ok").and_then(Value::as_bool), Some(true));
    assert_eq!(edit_resp.get("revision").and_then(Value::as_i64), Some(1));

    let dump = run_cli(&["live-dump", "999001"], &storage);
    let state = dump
        .get("state")
        .and_then(Value::as_array)
        .expect("state");
    assert!(
        state.iter().any(|row| {
            row.get("id")
                .and_then(Value::as_str)
                .is_some_and(|id| id == "editpart")
        }),
        "edit tick must apply ops after play session"
    );
    assert!(
        !state.iter().any(|row| {
            row.get("id")
                .and_then(Value::as_str)
                .is_some_and(|id| id == "playonly")
        }),
        "play-session op must not persist"
    );
}

#[test]
fn daemon_restart_reconnect() {
    let storage = temp_storage("daemon_restart");
    ingest_baseline(&storage);
    let serve1 = start_serve(&storage);
    let fps = service_fps_from_cli(&storage);
    let keepalive = json!({
        "placeId": "999001",
        "sessionMode": "edit",
        "baseRevision": 0,
        "serviceFingerprints": fps.clone(),
        "ops": { "upserted": [], "removed": [] },
        "bulkRef": null
    });
    let resp1 = post_tick(serve1.port, &keepalive);
    assert_eq!(resp1.get("ok").and_then(Value::as_bool), Some(true));
    drop(serve1);

    let serve2 = start_serve(&storage);
    let resp2 = post_tick(serve2.port, &keepalive);
    assert_eq!(resp2.get("ok").and_then(Value::as_bool), Some(true));
    assert_eq!(
        resp2.get("driftServices").and_then(Value::as_array).map(Vec::len),
        Some(0)
    );
}

#[test]
fn drift_injection_converges() {
    drift_recovery_full_baseline_preserves_other_services();
}

fn drift_recovery_full_baseline_preserves_other_services() {
    let storage = temp_storage("drift_recovery");
    ingest_fixture("two_service_baseline.json", &storage);
    let serve = start_serve(&storage);

    let services_before = run_cli(&["live-services", "999001"], &storage);
    let rs_fp_before = services_before
        .get("services")
        .and_then(|s| s.get("ReplicatedStorage"))
        .and_then(|e| e.get("fingerprint"))
        .and_then(Value::as_str)
        .expect("ReplicatedStorage fingerprint")
        .to_string();
    let ws_fp_before = services_before
        .get("services")
        .and_then(|s| s.get("Workspace"))
        .and_then(|e| e.get("fingerprint"))
        .and_then(Value::as_str)
        .expect("Workspace fingerprint")
        .to_string();

    let mut drift_fps = service_fps_from_cli(&storage);
    drift_fps.insert("Workspace".to_string(), json!("0".repeat(64)));
    let drift_body = json!({
        "placeId": "999001",
        "sessionMode": "edit",
        "baseRevision": 0,
        "serviceFingerprints": drift_fps,
        "ops": { "upserted": [], "removed": [] },
        "bulkRef": null
    });
    let drift_resp = post_tick(serve.port, &drift_body);
    let drift = drift_resp
        .get("driftServices")
        .and_then(Value::as_array)
        .expect("driftServices");
    assert!(drift.iter().any(|v| v.as_str() == Some("Workspace")));
    assert!(!drift.iter().any(|v| v.as_str() == Some("ReplicatedStorage")));

    let full_snapshot =
        fs::read_to_string(fixture("two_service_baseline.json")).expect("read two-service baseline");
    let sync_id = stage_tick_bulk(serve.port, &full_snapshot);
    let recovery_tick = json!({
        "placeId": "999001",
        "sessionMode": "edit",
        "baseRevision": current_revision(&storage),
        "serviceFingerprints": {},
        "ops": { "upserted": [], "removed": [] },
        "bulkRef": sync_id
    });
    let recovery_resp = post_tick(serve.port, &recovery_tick);
    assert_eq!(recovery_resp.get("ok").and_then(Value::as_bool), Some(true));

    let dump = run_cli(&["live-dump", "999001"], &storage);
    let state = dump
        .get("state")
        .and_then(Value::as_array)
        .expect("state rows");
    assert_eq!(state.len(), 4, "full recovery must keep all four instances");
    assert!(
        state.iter().any(|row| {
            row.get("id")
                .and_then(Value::as_str)
                .is_some_and(|id| id == "rs_beta")
        }),
        "ReplicatedStorage/Beta must survive drift recovery"
    );
    assert!(
        state.iter().any(|row| {
            row.get("id")
                .and_then(Value::as_str)
                .is_some_and(|id| id == "ws_alpha")
        }),
        "drifted Workspace/Alpha must be re-synced by full recovery"
    );

    let services_after = run_cli(&["live-services", "999001"], &storage);
    let rs_fp_after = services_after
        .get("services")
        .and_then(|s| s.get("ReplicatedStorage"))
        .and_then(|e| e.get("fingerprint"))
        .and_then(Value::as_str)
        .expect("ReplicatedStorage fingerprint after recovery");
    let ws_fp_after = services_after
        .get("services")
        .and_then(|s| s.get("Workspace"))
        .and_then(|e| e.get("fingerprint"))
        .and_then(Value::as_str)
        .expect("Workspace fingerprint after recovery");
    assert_eq!(
        rs_fp_after, rs_fp_before,
        "non-drifted ReplicatedStorage fingerprint must be unchanged"
    );
    assert_eq!(
        ws_fp_after, ws_fp_before,
        "drifted Workspace must match full-baseline fingerprint"
    );

    let fps = service_fps_from_cli(&storage);
    let keepalive = json!({
        "placeId": "999001",
        "sessionMode": "edit",
        "baseRevision": recovery_resp.get("revision").and_then(Value::as_i64).unwrap_or(0),
        "serviceFingerprints": fps,
        "ops": { "upserted": [], "removed": [] },
        "bulkRef": null
    });
    let keepalive_resp = post_tick(serve.port, &keepalive);
    assert_eq!(
        keepalive_resp
            .get("driftServices")
            .and_then(Value::as_array)
            .map(Vec::len),
        Some(0),
        "post-recovery keepalive must not report drift"
    );
}
