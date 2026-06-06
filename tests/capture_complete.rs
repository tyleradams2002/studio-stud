// Legacy capture/* HTTP flow removed at protocol v2; baseline commit is via /tick/bulk + /tick.
// This file keeps a smoke test that the tick bulk path materializes a fixture capture.

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

fn temp_storage(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "studio_stud_capture_complete_{name}_{}",
        std::process::id()
    ));
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

#[test]
fn tick_bulk_baseline_materializes_fixture_capture() {
    let storage = temp_storage("tick_baseline");
    let serve = start_serve(&storage);
    let port = serve.port;
    let fixture =
        fs::read_to_string(repo_root().join("tests/fixtures/baseline_capture.json")).expect("read");

    let start_body = r#"{"protocolVersion":2,"place":{"placeId":"100000000000001","placeKey":"Place100000000000001"}}"#;
    let (status, response) = http_request(
        "POST",
        port,
        "/studio-stud/tick/bulk/start?placeId=100000000000001",
        Some(start_body),
    );
    assert_eq!(status, 200, "bulk start failed: {response}");
    let sync_id = parse_json(&response)
        .get("syncId")
        .and_then(Value::as_str)
        .expect("syncId")
        .to_string();

    let path = format!(
        "/studio-stud/tick/bulk/chunk?placeId=100000000000001&syncId={sync_id}&index=0"
    );
    let (status, response) = http_request("POST", port, &path, Some(&fixture));
    assert_eq!(status, 200, "bulk chunk failed: {response}");

    let complete_body = format!(r#"{{"syncId":"{sync_id}","expectedChunks":1}}"#);
    let (status, response) = http_request(
        "POST",
        port,
        "/studio-stud/tick/bulk/complete?placeId=100000000000001",
        Some(&complete_body),
    );
    assert_eq!(status, 200, "bulk complete failed: {response}");

    let tick_body = json!({
        "placeId": "100000000000001",
        "sessionMode": "edit",
        "baseRevision": 0,
        "serviceFingerprints": {},
        "ops": { "upserted": [], "removed": [] },
        "bulkRef": sync_id
    });
    let (status, response) = http_request(
        "POST",
        port,
        "/studio-stud/tick?placeId=100000000000001",
        Some(&tick_body.to_string()),
    );
    assert_eq!(status, 200, "tick commit failed: {response}");
    let committed = parse_json(&response);
    assert_eq!(committed.get("ok").and_then(Value::as_bool), Some(true));
    assert!(
        committed
            .get("instanceCount")
            .and_then(Value::as_i64)
            .unwrap_or(0)
            > 0
    );

    let dump = run_cli(&["live-dump", "100000000000001"], &storage);
    assert_eq!(
        dump.get("meta")
            .and_then(|m| m.get("captureId"))
            .and_then(Value::as_str)
            .is_some(),
        true
    );
}
