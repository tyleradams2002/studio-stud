use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::Value;

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn fixture(name: &str) -> PathBuf {
    repo_root().join("tests/fixtures/write").join(name)
}

fn temp_repo(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "studio_stud_write_http_{name}_{}",
        std::process::id()
    ));
    if dir.exists() {
        fs::remove_dir_all(&dir).ok();
    }
    fs::create_dir_all(dir.join(".studio-stud")).unwrap();
    fs::copy(
        fixture("policy.json"),
        dir.join(".studio-stud/policy.json"),
    )
    .unwrap();
    fs::create_dir_all(dir.join("synced")).ok();
    dir
}

fn temp_storage(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "studio_stud_write_http_storage_{name}_{}",
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

fn http_request(
    method: &str,
    port: u16,
    path: &str,
    body: Option<&str>,
    headers: &[(&str, &str)],
) -> (u16, String) {
    let mut stream =
        TcpStream::connect(format!("127.0.0.1:{port}")).expect("connect to daemon");
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .ok();
    let body_str = body.unwrap_or("");
    let mut req = format!(
        "{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n",
        body_str.len()
    );
    for (key, value) in headers {
        req.push_str(&format!("{key}: {value}\r\n"));
    }
    req.push_str("\r\n");
    req.push_str(body_str);
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

fn start_serve(repo: &Path, storage: &Path) -> ServeGuard {
    let port = pick_port();
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
        .current_dir(repo)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn serve");
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        let (status, body) = http_request("GET", port, "/studio-stud/ping", None, &[]);
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

fn sample_content() -> String {
    fs::read_to_string(fixture("target_clean.luau"))
        .unwrap()
        .replace("\r\n", "\n")
        .replace('\r', "\n")
}

#[test]
fn write_http_token_matrix_and_status_codes() {
    let repo = temp_repo("http");
    let storage = temp_storage("http");
    let serve = start_serve(&repo, &storage);
    let port = serve.port;

    let (_, token_body) = http_request(
        "GET",
        port,
        "/studio-stud/write/token",
        None,
        &[],
    );
    let token = parse_json(&token_body)
        .get("token")
        .and_then(Value::as_str)
        .expect("token response")
        .to_string();
    assert!(!token.is_empty());

    let validate_body = format!(
        r#"{{"path":"synced/foo.luau","content":{}}}"#,
        serde_json::to_string(&sample_content()).unwrap()
    );

    let (status, body) = http_request(
        "POST",
        port,
        "/studio-stud/write/validate",
        Some(&validate_body),
        &[("X-StudioStud-Token", &token)],
    );
    assert_eq!(status, 200);
    let value = parse_json(&body);
    assert_eq!(value.get("blocked").and_then(Value::as_bool), Some(false));

    let (status, body) = http_request(
        "POST",
        port,
        "/studio-stud/write/validate",
        Some(&format!(r#"{{"path":"synced/foo.luau","content":{},"token":"{token}"}}"#, serde_json::to_string(&sample_content()).unwrap())),
        &[],
    );
    assert_eq!(status, 200);
    assert_eq!(
        parse_json(&body).get("blocked").and_then(Value::as_bool),
        Some(false)
    );

    let (status, body) = http_request(
        "POST",
        port,
        "/studio-stud/write/validate",
        Some(&format!(
            r#"{{"path":"synced/foo.luau","content":{},"token":"{token}"}}"#,
            serde_json::to_string(&sample_content()).unwrap()
        )),
        &[("X-StudioStud-Token", &token)],
    );
    assert_eq!(status, 200);
    assert_eq!(
        parse_json(&body).get("blocked").and_then(Value::as_bool),
        Some(false)
    );

    let (status, body) = http_request(
        "POST",
        port,
        "/studio-stud/write/validate",
        Some(&validate_body),
        &[],
    );
    assert_eq!(status, 401);
    assert_eq!(
        parse_json(&body).get("blockedReason").and_then(Value::as_str),
        Some("tokenInvalid")
    );

    let (status, body) = http_request(
        "POST",
        port,
        "/studio-stud/write/validate",
        Some("{not-json"),
        &[("X-StudioStud-Token", &token)],
    );
    assert_eq!(status, 400);
    assert_eq!(
        parse_json(&body).get("blockedReason").and_then(Value::as_str),
        Some("badRequest")
    );

    let forbidden_body = format!(
        r#"{{"path":"forbidden/bar.luau","content":{},"token":"{token}"}}"#,
        serde_json::to_string(&sample_content()).unwrap()
    );
    let (status, body) = http_request(
        "POST",
        port,
        "/studio-stud/write/validate",
        Some(&forbidden_body),
        &[],
    );
    assert_eq!(status, 200);
    assert_eq!(
        parse_json(&body).get("blockedReason").and_then(Value::as_str),
        Some("pathNotAllowed")
    );
}

#[test]
fn write_http_capture_ping_still_reachable() {
    let repo = temp_repo("capture");
    let storage = temp_storage("capture");
    let serve = start_serve(&repo, &storage);
    let (status, body) = http_request(
        "GET",
        serve.port,
        "/studio-stud/ping",
        None,
        &[],
    );
    assert_eq!(status, 200);
    assert_eq!(parse_json(&body).get("ok").and_then(Value::as_bool), Some(true));
}
