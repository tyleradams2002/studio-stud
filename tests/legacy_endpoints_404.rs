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
    let dir = std::env::temp_dir().join(format!("studio_stud_legacy_{name}_{}", std::process::id()));
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
    stream.set_read_timeout(Some(Duration::from_secs(10))).ok();
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
fn legacy_capture_and_live_endpoints_return_404() {
    let storage = temp_storage("404");
    let serve = start_serve(&storage);
    let port = serve.port;
    let paths = [
        ("POST", "/studio-stud/capture/start", r#"{}"#),
        ("POST", "/studio-stud/capture/complete", r#"{"syncId":"x"}"#),
        ("GET", "/studio-stud/capture/request", ""),
        ("POST", "/studio-stud/live/delta", r#"{"placeId":"1","baseRevision":0,"ops":{"upserted":[],"removed":[]}}"#),
        ("GET", "/studio-stud/live/fingerprint?placeId=1", ""),
        ("POST", "/studio-stud/live/verify/start", r#"{}"#),
        ("POST", "/studio-stud/live/verify/complete", r#"{"syncId":"x"}"#),
    ];
    for (method, path, body) in paths {
        let (status, response) = http_request(
            method,
            port,
            path,
            if body.is_empty() { None } else { Some(body) },
        );
        assert_eq!(status, 404, "expected 404 for {method} {path}, got {response}");
        let value = parse_json(&response);
        assert_eq!(value.get("error").and_then(Value::as_str), Some("not_found"));
    }
}

#[test]
fn ping_reports_protocol_v2() {
    let storage = temp_storage("ping_v2");
    let serve = start_serve(&storage);
    let (_, body) = http_request("GET", serve.port, "/studio-stud/ping", None);
    let value = parse_json(&body);
    assert_eq!(
        value.get("protocolVersion").and_then(Value::as_i64),
        Some(2)
    );
    assert_eq!(
        value.get("minPluginProtocolVersion").and_then(Value::as_i64),
        Some(2)
    );
}
