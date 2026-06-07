use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
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
    let dir = std::env::temp_dir().join(format!(
        "studio_stud_serve_workers_{name}_{}",
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

fn http_request_fire(method: &str, port: u16, path: &str, body: Option<&str>) -> TcpStream {
    let mut stream = TcpStream::connect(format!("127.0.0.1:{port}")).expect("connect to daemon");
    stream.set_read_timeout(Some(Duration::from_secs(30))).ok();
    let body_str = body.unwrap_or("");
    let req = format!(
        "{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body_str}",
        body_str.len()
    );
    stream.write_all(req.as_bytes()).expect("write request");
    stream
}

fn read_http_response(mut stream: TcpStream) -> (u16, String) {
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
    lane_stats: Option<PathBuf>,
}

impl Drop for ServeGuard {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        if let Some(path) = self.lane_stats.as_ref() {
            let _ = fs::remove_file(path);
        }
    }
}

fn start_serve(storage: &PathBuf, extra_env: &[(&str, &str)]) -> ServeGuard {
    let port = pick_port();
    let repo = repo_root();
    let lane_stats = extra_env
        .iter()
        .find(|(k, _)| *k == "STUDIO_STUD_TEST_LANE_STATS")
        .map(|(_, v)| PathBuf::from(*v));

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
        .envs(extra_env.iter().copied())
        .current_dir(&repo)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn serve");

    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        let (status, body) = http_request("GET", port, "/studio-stud/ping", None);
        if status == 200 && body.contains("\"ok\":true") {
            return ServeGuard {
                child,
                port,
                lane_stats,
            };
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

fn ingest_baseline(storage: &Path) {
    run_cli(
        &[
            "ingest",
            "--raw",
            fixture("baseline.json").to_str().unwrap(),
        ],
        storage,
    );
}

fn ingest_baseline_place(storage: &Path, place_id: &str) {
    let raw = fs::read_to_string(fixture("baseline.json")).expect("read baseline");
    let mut value: Value = serde_json::from_str(&raw).expect("parse baseline");
    if let Some(place) = value.get_mut("place").and_then(Value::as_object_mut) {
        place.insert("placeId".into(), json!(place_id));
    }
    let tmp = std::env::temp_dir().join(format!(
        "ss_baseline_{place_id}_{}.json",
        std::process::id()
    ));
    fs::write(&tmp, value.to_string()).expect("write temp baseline");
    run_cli(&["ingest", "--raw", tmp.to_str().unwrap()], storage);
    let _ = fs::remove_file(tmp);
}

fn service_fps_from_cli(storage: &Path, place: &str) -> serde_json::Map<String, Value> {
    let dump = run_cli(&["live-services", place], storage);
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

fn tick_body(
    place_id: &str,
    base_revision: i64,
    fps: &serde_json::Map<String, Value>,
    inst_id: &str,
    inst_fp: &str,
) -> Value {
    json!({
        "placeId": place_id,
        "sessionMode": "edit",
        "baseRevision": base_revision,
        "serviceFingerprints": fps,
        "ops": {
            "upserted": [{
                "id": inst_id,
                "parentId": "ws",
                "path": format!("Workspace/{inst_id}"),
                "name": inst_id,
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
    })
}

fn post_tick(port: u16, place_id: &str, body: &Value) -> Value {
    let path = format!("/studio-stud/tick?placeId={place_id}");
    let (status, response) = http_request("POST", port, &path, Some(&body.to_string()));
    assert_eq!(status, 200, "tick failed: {response}");
    parse_json(&response)
}

#[test]
fn cross_place_ticks_parallel() {
    let storage = temp_storage("cross_place");
    ingest_baseline_place(&storage, "999001");
    ingest_baseline_place(&storage, "999002");

    let serve = start_serve(
        &storage,
        &[
            ("STUDIO_STUD_TEST_TICK_DELAY_MS", "2000"),
            ("STUDIO_STUD_TEST_TICK_DELAY_PLACE", "999001"),
        ],
    );
    let port = serve.port;
    let fps_a = service_fps_from_cli(&storage, "999001");
    let fps_b = service_fps_from_cli(&storage, "999002");

    let body_a = tick_body(
        "999001",
        0,
        &fps_a,
        "slow_a",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    let body_b = tick_body(
        "999002",
        0,
        &fps_b,
        "fast_b",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    );

    let (tx, rx) = mpsc::channel();
    let port_a = port;
    thread::spawn(move || {
        let started = Instant::now();
        let resp = post_tick(port_a, "999001", &body_a);
        let _ = tx.send((started.elapsed(), resp));
    });

    thread::sleep(Duration::from_millis(50));
    let fast_start = Instant::now();
    let resp_b = post_tick(port, "999002", &body_b);
    let fast_elapsed = fast_start.elapsed();

    assert_eq!(resp_b.get("ok").and_then(Value::as_bool), Some(true));
    assert!(
        fast_elapsed < Duration::from_millis(1500),
        "place B tick blocked by place A slow write ({fast_elapsed:?})"
    );

    let (slow_elapsed, resp_a) = rx.recv_timeout(Duration::from_secs(10)).expect("slow tick");
    assert_eq!(resp_a.get("ok").and_then(Value::as_bool), Some(true));
    assert!(slow_elapsed >= Duration::from_millis(1500));
}

#[test]
fn same_place_ticks_serialize() {
    let storage = temp_storage("same_place");
    ingest_baseline(&storage);
    let serve = start_serve(&storage, &[]);
    let port = serve.port;
    let mut fps = service_fps_from_cli(&storage, "999001");

    let mut streams = Vec::new();
    for i in 0..8 {
        let inst_id = format!("part_{i}");
        let fp = format!("{:0>64}", i + 1);
        let body = tick_body("999001", i, &fps, &inst_id, &fp);
        let path = "/studio-stud/tick?placeId=999001";
        streams.push(http_request_fire(
            "POST",
            port,
            path,
            Some(&body.to_string()),
        ));
        fps = service_fps_from_cli(&storage, "999001");
    }

    let mut last_revision = 0_i64;
    for (i, stream) in streams.into_iter().enumerate() {
        let (status, response) = read_http_response(stream);
        assert_eq!(status, 200, "tick {i} failed: {response}");
        let resp = parse_json(&response);
        assert_eq!(
            resp.get("ok").and_then(Value::as_bool),
            Some(true),
            "tick {i} not ok: {resp}"
        );
        let rev = resp.get("revision").and_then(Value::as_i64).expect("revision");
        assert_eq!(rev, (i + 1) as i64, "revision mismatch at tick {i}");
        assert!(rev > last_revision);
        last_revision = rev;
    }
}

#[test]
fn reads_not_blocked_by_writes() {
    let storage = temp_storage("reads_unblocked");
    ingest_baseline(&storage);
    let serve = start_serve(
        &storage,
        &[
            ("STUDIO_STUD_TEST_TICK_DELAY_MS", "2000"),
            ("STUDIO_STUD_TEST_TICK_DELAY_PLACE", "999001"),
        ],
    );
    let port = serve.port;
    let fps = service_fps_from_cli(&storage, "999001");
    let body = tick_body(
        "999001",
        0,
        &fps,
        "blocker",
        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    );

    thread::spawn(move || {
        post_tick(port, "999001", &body);
    });
    thread::sleep(Duration::from_millis(50));

    let ping_start = Instant::now();
    let (status, response) = http_request("GET", port, "/studio-stud/ping", None);
    let ping_elapsed = ping_start.elapsed();

    assert_eq!(status, 200);
    assert!(response.contains("\"ok\":true"));
    assert!(
        ping_elapsed < Duration::from_millis(500),
        "ping blocked by slow write ({ping_elapsed:?})"
    );
}

#[test]
fn lane_eviction() {
    let storage = temp_storage("lane_evict");
    ingest_baseline(&storage);
    let stats_path = std::env::temp_dir().join(format!(
        "ss_lane_stats_{}.txt",
        std::process::id()
    ));
    let _ = fs::remove_file(&stats_path);

    let serve = start_serve(
        &storage,
        &[
            ("STUDIO_STUD_WRITER_LANE_IDLE_MS", "200"),
            ("STUDIO_STUD_LANE_EVICT_INTERVAL_MS", "100"),
            (
                "STUDIO_STUD_TEST_LANE_STATS",
                stats_path.to_str().unwrap(),
            ),
        ],
    );
    let port = serve.port;
    let fps = service_fps_from_cli(&storage, "999001");
    let body = json!({
        "placeId": "999001",
        "sessionMode": "edit",
        "baseRevision": 0,
        "serviceFingerprints": fps,
        "ops": { "upserted": [], "removed": [] },
        "bulkRef": null
    });
    post_tick(port, "999001", &body);

    thread::sleep(Duration::from_millis(450));
    let count_after_evict = fs::read_to_string(&stats_path)
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(1);
    assert_eq!(
        count_after_evict, 0,
        "writer lane should be evicted after idle timeout"
    );

    let resp = post_tick(port, "999001", &body);
    assert_eq!(resp.get("ok").and_then(Value::as_bool), Some(true));
    let count_after_recreate = fs::read_to_string(&stats_path)
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(0);
    assert_eq!(
        count_after_recreate, 1,
        "writer lane should be recreated on next tick"
    );
}
