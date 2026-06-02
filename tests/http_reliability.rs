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
        "studio_stud_http_reliability_{name}_{}",
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
    stream.set_read_timeout(Some(Duration::from_secs(5))).ok();
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

#[test]
fn verify_complete_unknown_sync_id_returns_soft_rebaseline() {
    let storage = temp_storage("unknown_sync");
    let serve = start_serve(&storage);
    let port = serve.port;
    let body = r#"{"syncId":"verify_nonexistent_000","placeId":"123"}"#;
    let (status, response) = http_request(
        "POST",
        port,
        "/studio-stud/live/verify/complete",
        Some(body),
    );
    assert_eq!(status, 200);
    let value = parse_json(&response);
    assert_eq!(value.get("ok").and_then(Value::as_bool), Some(false));
    assert_eq!(
        value.get("error").and_then(Value::as_str),
        Some("unknownSyncId")
    );
    assert_eq!(
        value.get("needsRebaseline").and_then(Value::as_bool),
        Some(true)
    );
}

#[test]
fn concurrent_pings_while_serve_is_running() {
    let storage = temp_storage("concurrent_ping");
    let serve = start_serve(&storage);
    let port = serve.port;
    let mut handles = Vec::new();
    for _ in 0..8 {
        handles.push(thread::spawn(move || {
            let (status, body) = http_request("GET", port, "/studio-stud/ping", None);
            (status, body.contains("\"ok\":true"))
        }));
    }
    for handle in handles {
        let (status, ok) = handle.join().expect("ping thread");
        assert_eq!(status, 200);
        assert!(ok);
    }
}
