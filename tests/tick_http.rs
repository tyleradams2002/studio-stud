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
    run_cli(
        &[
            "ingest",
            "--raw",
            fixture("baseline.json").to_str().unwrap(),
        ],
        storage,
    )
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
