use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::Value;

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

fn upload_fixture_capture(port: u16) -> String {
    let fixture = fs::read_to_string(repo_root().join("tests/fixtures/baseline_capture.json"))
        .expect("read baseline_capture.json");
    let start_body = r#"{"protocolVersion":1,"place":{"placeId":"100000000000001","placeKey":"Place100000000000001"}}"#;
    let (status, response) = http_request(
        "POST",
        port,
        "/studio-stud/capture/start",
        Some(start_body),
    );
    assert_eq!(status, 200, "capture/start failed: {response}");
    let start_json = parse_json(&response);
    let sync_id = start_json
        .get("syncId")
        .and_then(Value::as_str)
        .expect("syncId in start response")
        .to_string();

    let path = format!("/studio-stud/capture/body?syncId={sync_id}");
    let (status, response) = http_request("POST", port, &path, Some(&fixture));
    assert_eq!(status, 200, "capture/body failed: {response}");
    sync_id
}

#[test]
fn capture_complete_returns_finalizing_then_status_done() {
    let storage = temp_storage("async_complete");
    let serve = start_serve(&storage);
    let port = serve.port;
    let sync_id = upload_fixture_capture(port);

    let complete_body = format!(r#"{{"syncId":"{sync_id}"}}"#);
    let started = Instant::now();
    let (status, response) = http_request(
        "POST",
        port,
        "/studio-stud/capture/complete",
        Some(&complete_body),
    );
    let ack_ms = started.elapsed().as_millis();
    assert_eq!(status, 200, "capture/complete failed: {response}");
    assert!(
        ack_ms < 3000,
        "capture/complete should ack quickly, took {ack_ms} ms"
    );
    let ack = parse_json(&response);
    assert_eq!(ack.get("ok").and_then(Value::as_bool), Some(true));
    assert_eq!(
        ack.get("status").and_then(Value::as_str),
        Some("finalizing"),
        "expected async ack: {ack}"
    );
    assert_eq!(
        ack.get("syncId").and_then(Value::as_str),
        Some(sync_id.as_str())
    );

    let status_path = format!("/studio-stud/capture/status?syncId={sync_id}");
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut saw_finalizing = false;
    let mut final_value = None;
    while Instant::now() < deadline {
        let (status, response) = http_request("GET", port, &status_path, None);
        assert_eq!(status, 200);
        let value = parse_json(&response);
        match value.get("status").and_then(Value::as_str) {
            Some("finalizing") => saw_finalizing = true,
            Some("done") | Some("completed") => {
                assert_eq!(value.get("ok").and_then(Value::as_bool), Some(true));
                assert!(value.get("result").is_some(), "done payload needs result: {value}");
                final_value = Some(value);
                break;
            }
            Some("error") => panic!("finalize error: {value}"),
            _ => {}
        }
        thread::sleep(Duration::from_millis(100));
    }
    let done = final_value.expect("timed out waiting for capture finalize");
    assert!(
        saw_finalizing
            || ack.get("status").and_then(Value::as_str) == Some("finalizing"),
        "expected finalizing status at least once"
    );
    assert!(
        done.get("result")
            .and_then(|r| r.get("captureId"))
            .and_then(Value::as_str)
            .is_some(),
        "materialized capture should include captureId: {done}"
    );
}
