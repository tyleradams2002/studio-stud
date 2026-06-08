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
    let dir = std::env::temp_dir().join(format!("studio_stud_live_{name}_{}", std::process::id()));
    if dir.exists() {
        fs::remove_dir_all(&dir).ok();
    }
    fs::create_dir_all(&dir).expect("create temp storage");
    dir
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

fn run_cli_allow_fail(args: &[&str], storage_root: &Path) -> (bool, String) {
    let exe = env!("CARGO_BIN_EXE_studio-stud");
    let output = Command::new(exe)
        .args(args)
        .arg("--storage-root")
        .arg(storage_root)
        .output()
        .expect("studio-stud should run");
    (
        output.status.success(),
        String::from_utf8_lossy(&output.stderr).to_string(),
    )
}

fn dump_compare_parts(dump: &Value) -> (Value, String) {
    (
        dump.get("state").cloned().expect("state"),
        dump.get("fingerprint")
            .and_then(Value::as_str)
            .expect("fingerprint")
            .to_string(),
    )
}

fn pick_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .expect("bind ephemeral port")
        .local_addr()
        .expect("local addr")
        .port()
}

fn http_post_tick(port: u16, body: &Value) -> Value {
    let body_str = body.to_string();
    let mut stream = TcpStream::connect(format!("127.0.0.1:{port}")).expect("connect");
    stream.set_read_timeout(Some(Duration::from_secs(30))).ok();
    let req = format!(
        "POST /studio-stud/tick?placeId=999001 HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body_str}",
        body_str.len()
    );
    stream.write_all(req.as_bytes()).expect("write");
    let mut buf = Vec::new();
    stream.read_to_end(&mut buf).expect("read");
    let response = String::from_utf8_lossy(&buf);
    let body_json = response.split("\r\n\r\n").nth(1).unwrap_or("");
    serde_json::from_str(body_json.trim()).expect("tick json")
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

fn start_serve(storage: &Path) -> ServeGuard {
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
        .current_dir(repo_root())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn serve");
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        let mut stream = TcpStream::connect(format!("127.0.0.1:{port}")).expect("connect");
        let req = format!(
            "GET /studio-stud/ping HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n"
        );
        stream.write_all(req.as_bytes()).ok();
        let mut buf = Vec::new();
        stream.read_to_end(&mut buf).ok();
        if String::from_utf8_lossy(&buf).contains("\"ok\":true") {
            return ServeGuard { child, port };
        }
        thread::sleep(Duration::from_millis(100));
    }
    let _ = child.kill();
    panic!("serve did not become ready");
}

fn service_fps(storage: &Path) -> serde_json::Map<String, Value> {
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
            .expect("fingerprint");
        out.insert(name.clone(), json!(fp));
    }
    out
}

#[test]
fn structural_convergence_via_tick() {
    let storage = temp_storage("tick_convergence");
    run_cli(
        &[
            "ingest",
            "--raw",
            fixture("baseline.json").to_str().unwrap(),
        ],
        &storage,
    );
    let serve = start_serve(&storage);
    let delta: Value =
        serde_json::from_slice(&fs::read(fixture("delta_struct.json")).unwrap()).unwrap();
    let ops = delta.get("ops").cloned().expect("ops");
    let inst_fp = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
    let mut upserted = ops
        .get("upserted")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    for entry in &mut upserted {
        if let Some(obj) = entry.as_object_mut() {
            obj.insert("fp".to_string(), json!(inst_fp));
        }
    }
    let fps = service_fps(&storage);
    let body = json!({
        "placeId": "999001",
        "sessionMode": "edit",
        "baseRevision": 0,
        "serviceFingerprints": fps,
        "ops": { "upserted": upserted, "removed": ops.get("removed").cloned().unwrap_or(json!([])) },
        "bulkRef": null
    });
    let resp = http_post_tick(serve.port, &body);
    assert_eq!(resp.get("ok").and_then(Value::as_bool), Some(true));
    assert_eq!(resp.get("revision").and_then(Value::as_i64), Some(1));

    let dump_delta = run_cli(&["live-dump", "999001"], &storage);
    let storage_full = temp_storage("tick_convergence_full");
    run_cli(
        &[
            "ingest",
            "--raw",
            fixture("full_after.json").to_str().unwrap(),
        ],
        &storage_full,
    );
    let dump_full = run_cli(&["live-dump", "999001"], &storage_full);
    let (state_delta, _) = dump_compare_parts(&dump_delta);
    let (state_full, _) = dump_compare_parts(&dump_full);
    assert_eq!(
        state_delta, state_full,
        "tick delta must converge to full ingest (instance rows)"
    );
}

#[test]
fn structural_convergence_without_verify() {
    let storage_delta = temp_storage("convergence_delta");
    let storage_full = temp_storage("convergence_full");
    let baseline = fixture("baseline.json");
    let delta = fixture("delta_struct.json");
    let full_after = fixture("full_after.json");

    run_cli(
        &["ingest", "--raw", baseline.to_str().unwrap()],
        &storage_delta,
    );
    run_cli(
        &[
            "live-delta",
            "--raw",
            delta.to_str().unwrap(),
            "--place",
            "999001",
        ],
        &storage_delta,
    );
    let dump_delta = run_cli(&["live-dump", "999001"], &storage_delta);

    run_cli(
        &["ingest", "--raw", full_after.to_str().unwrap()],
        &storage_full,
    );
    let dump_full = run_cli(&["live-dump", "999001"], &storage_full);

    let (state_delta, fp_delta) = dump_compare_parts(&dump_delta);
    let (state_full, fp_full) = dump_compare_parts(&dump_full);
    assert_eq!(
        state_delta, state_full,
        "state must converge without verify"
    );
    assert_eq!(
        fp_delta, fp_full,
        "fingerprint must converge without verify"
    );
}

#[test]
fn ingest_baseline_is_deterministic_and_complete() {
    let storage = temp_storage("ingest_det");
    let out = run_cli(
        &[
            "ingest",
            "--raw",
            fixture("baseline.json").to_str().unwrap(),
        ],
        &storage,
    );
    assert_eq!(out.get("ok").and_then(Value::as_bool), Some(true));
    let count = out.get("instances").and_then(Value::as_i64).expect("instances");
    assert!(count > 0);
    let fp1 = out
        .get("fingerprint")
        .and_then(Value::as_str)
        .map(str::to_string);
    assert!(fp1.is_some(), "ingest must surface fingerprint (Step 0)");

    let out2 = run_cli(
        &[
            "ingest",
            "--raw",
            fixture("baseline.json").to_str().unwrap(),
        ],
        &storage,
    );
    let fp2 = out2
        .get("fingerprint")
        .and_then(Value::as_str)
        .map(str::to_string);
    assert_eq!(fp1, fp2, "fingerprint must be stable across identical ingests");
}

#[test]
fn service_fingerprints_xor_to_global() {
    let storage = temp_storage("svc_fp");
    run_cli(
        &[
            "ingest",
            "--raw",
            fixture("baseline.json").to_str().unwrap(),
        ],
        &storage,
    );
    let dump = run_cli(&["live-services", "999001"], &storage);
    let global = dump.get("global").and_then(Value::as_str).unwrap();
    let xored = dump.get("xorOfServices").and_then(Value::as_str).unwrap();
    assert_eq!(
        global, xored,
        "XOR of per-service fingerprints must equal the global fingerprint"
    );

    run_cli(
        &[
            "live-delta",
            "--raw",
            fixture("delta_struct.json").to_str().unwrap(),
            "--place",
            "999001",
        ],
        &storage,
    );
    let dump2 = run_cli(&["live-services", "999001"], &storage);
    assert_eq!(
        dump2.get("global").and_then(Value::as_str),
        dump2.get("xorOfServices").and_then(Value::as_str)
    );
}

#[test]
fn revision_guard_rejects_stale_base_revision() {
    let storage = temp_storage("revision");
    run_cli(
        &[
            "ingest",
            "--raw",
            fixture("baseline.json").to_str().unwrap(),
        ],
        &storage,
    );
    let stale_path = storage.join("stale_delta.json");
    fs::write(
        &stale_path,
        br#"{"placeId":"999001","baseRevision":99,"ops":{"upserted":[],"removed":[]}}"#,
    )
    .unwrap();
    let result = run_cli(
        &[
            "live-delta",
            "--raw",
            stale_path.to_str().unwrap(),
            "--place",
            "999001",
        ],
        &storage,
    );
    assert_eq!(
        result.get("error").and_then(Value::as_str),
        Some("revision_mismatch")
    );
}

#[test]
fn verify_fast_path_when_state_matches() {
    let storage = temp_storage("verify_fast");
    run_cli(
        &[
            "ingest",
            "--raw",
            fixture("baseline.json").to_str().unwrap(),
        ],
        &storage,
    );
    let result = run_cli(
        &[
            "live-verify",
            "--raw",
            fixture("baseline.json").to_str().unwrap(),
            "--place",
            "999001",
        ],
        &storage,
    );
    assert_eq!(result.get("ok").and_then(Value::as_bool), Some(true));
    assert_eq!(
        result.get("drift").and_then(Value::as_array).map(Vec::len),
        Some(0)
    );
}

#[test]
fn verify_recovers_missed_signal() {
    let storage = temp_storage("verify_miss");
    run_cli(
        &[
            "ingest",
            "--raw",
            fixture("baseline.json").to_str().unwrap(),
        ],
        &storage,
    );
    let partial = fixture("partial_delta.json");
    run_cli(
        &[
            "live-delta",
            "--raw",
            partial.to_str().unwrap(),
            "--place",
            "999001",
        ],
        &storage,
    );
    let verify = run_cli(
        &[
            "live-verify",
            "--raw",
            fixture("full_after.json").to_str().unwrap(),
            "--place",
            "999001",
        ],
        &storage,
    );
    assert!(
        verify
            .get("drift")
            .and_then(Value::as_array)
            .is_some_and(|d| !d.is_empty())
    );

    let dump = run_cli(&["live-dump", "999001"], &storage);
    let storage_full = temp_storage("verify_miss_full");
    run_cli(
        &[
            "ingest",
            "--raw",
            fixture("full_after.json").to_str().unwrap(),
        ],
        &storage_full,
    );
    let dump_full = run_cli(&["live-dump", "999001"], &storage_full);
    let (state_a, fp_a) = dump_compare_parts(&dump);
    let (state_b, fp_b) = dump_compare_parts(&dump_full);
    assert_eq!(state_a, state_b);
    assert_eq!(fp_a, fp_b);
}

#[test]
fn fingerprint_cross_representation_baseline_verify() {
    let storage = temp_storage("fp_cross");
    run_cli(
        &[
            "ingest",
            "--raw",
            fixture("baseline.json").to_str().unwrap(),
        ],
        &storage,
    );
    let dump = run_cli(&["live-dump", "999001"], &storage);
    let fp_baseline = dump.get("fingerprint").and_then(Value::as_str).expect("fp");

    let verify = run_cli(
        &[
            "live-verify",
            "--raw",
            fixture("baseline.json").to_str().unwrap(),
            "--place",
            "999001",
        ],
        &storage,
    );
    assert_eq!(
        verify.get("drift").and_then(Value::as_array).map(Vec::len),
        Some(0)
    );
    let dump2 = run_cli(&["live-dump", "999001"], &storage);
    assert_eq!(
        dump2.get("fingerprint").and_then(Value::as_str),
        Some(fp_baseline)
    );
}

#[test]
fn malformed_delta_rolls_back() {
    let storage = temp_storage("rollback");
    run_cli(
        &[
            "ingest",
            "--raw",
            fixture("baseline.json").to_str().unwrap(),
        ],
        &storage,
    );
    let before = run_cli(&["live-dump", "999001"], &storage);
    let bad_path = storage.join("bad_delta.json");
    fs::write(
        &bad_path,
        br#"{"placeId":"999001","baseRevision":0,"ops":{"upserted":[{"id":"broken","parentId":"ws","path":"","className":"Part"}],"removed":[]}}"#,
    )
    .unwrap();
    let (ok, _) = run_cli_allow_fail(
        &[
            "live-delta",
            "--raw",
            bad_path.to_str().unwrap(),
            "--place",
            "999001",
        ],
        &storage,
    );
    assert!(!ok);
    let after = run_cli(&["live-dump", "999001"], &storage);
    assert_eq!(
        before.get("fingerprint").and_then(Value::as_str),
        after.get("fingerprint").and_then(Value::as_str)
    );
}

#[test]
fn script_source_round_trip() {
    let storage = temp_storage("script_rt");
    run_cli(
        &[
            "ingest",
            "--raw",
            fixture("baseline_script.json").to_str().unwrap(),
        ],
        &storage,
    );
    let raw_crlf = "local x = 1\r\nreturn x\r\n";
    let expected_text = raw_crlf.replace("\r\n", "\n").replace('\r', "\n");
    let expected_hash = {
        use sha2::{Digest, Sha256};
        let mut hasher = Sha256::new();
        hasher.update(expected_text.as_bytes());
        hasher
            .finalize()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>()
    };
    let row = run_cli(
        &["script-source", "999001", "Workspace/Folder/MyModule"],
        &storage,
    );
    assert_eq!(row.get("ok").and_then(Value::as_bool), Some(true));
    assert_eq!(
        row.get("sourceText").and_then(Value::as_str),
        Some(expected_text.as_str())
    );
    assert_eq!(
        row.get("sourceHash").and_then(Value::as_str),
        Some(expected_hash.as_str())
    );
}

#[test]
fn delta_updates_script_source() {
    let storage = temp_storage("script_delta");
    run_cli(
        &[
            "ingest",
            "--raw",
            fixture("baseline_script.json").to_str().unwrap(),
        ],
        &storage,
    );
    run_cli(
        &[
            "live-delta",
            "--raw",
            fixture("delta_script_source.json").to_str().unwrap(),
            "--place",
            "999001",
        ],
        &storage,
    );
    let updated = run_cli(
        &["script-source", "999001", "Workspace/Folder/MyModule"],
        &storage,
    );
    assert_eq!(updated.get("ok").and_then(Value::as_bool), Some(true));
    assert_eq!(
        updated.get("sourceText").and_then(Value::as_str),
        Some("print('updated')\n")
    );
    run_cli(
        &[
            "live-delta",
            "--raw",
            fixture("delta_remove_mod1.json").to_str().unwrap(),
            "--place",
            "999001",
        ],
        &storage,
    );
    let gone = run_cli(
        &["script-source", "999001", "Workspace/Folder/MyModule"],
        &storage,
    );
    assert_eq!(gone.get("ok").and_then(Value::as_bool), Some(false));
    assert_eq!(
        gone.get("error").and_then(Value::as_str),
        Some("not_found"),
        "removed instance should be gone from instances and script_sources"
    );
    let list = run_cli(&["script-sources", "999001"], &storage);
    assert_eq!(list.get("count").and_then(Value::as_i64), Some(0));
}

#[test]
fn source_excluded_from_fingerprint() {
    let storage = temp_storage("fp_source");
    run_cli(
        &[
            "ingest",
            "--raw",
            fixture("baseline.json").to_str().unwrap(),
        ],
        &storage,
    );
    let before = run_cli(&["live-dump", "999001"], &storage);
    let fp_before = before
        .get("fingerprint")
        .and_then(Value::as_str)
        .expect("fingerprint");
    run_cli(
        &[
            "live-delta",
            "--raw",
            fixture("delta_part_with_source.json").to_str().unwrap(),
            "--place",
            "999001",
        ],
        &storage,
    );
    let after = run_cli(&["live-dump", "999001"], &storage);
    let fp_after = after
        .get("fingerprint")
        .and_then(Value::as_str)
        .expect("fingerprint");
    assert_eq!(
        fp_before, fp_after,
        "source field on upsert must not change global fingerprint"
    );
    let services = run_cli(&["live-services", "999001"], &storage);
    assert_eq!(
        services.get("global").and_then(Value::as_str),
        services.get("xorOfServices").and_then(Value::as_str)
    );
}

#[test]
fn non_script_no_source_row() {
    let storage = temp_storage("no_script_src");
    run_cli(
        &[
            "ingest",
            "--raw",
            fixture("baseline.json").to_str().unwrap(),
        ],
        &storage,
    );
    let list = run_cli(&["script-sources", "999001"], &storage);
    assert_eq!(list.get("ok").and_then(Value::as_bool), Some(true));
    assert_eq!(list.get("count").and_then(Value::as_i64), Some(0));
}

#[test]
fn script_source_binary_round_trip() {
    let storage = temp_storage("script_bin");
    run_cli(
        &[
            "ingest",
            "--raw",
            fixture("baseline_script_binary.json").to_str().unwrap(),
        ],
        &storage,
    );
    let utf8 = run_cli(
        &["script-source", "999001", "Workspace/Folder/Utf8Module"],
        &storage,
    );
    assert_eq!(utf8.get("ok").and_then(Value::as_bool), Some(true));
    assert_eq!(
        utf8.get("sourceEncoding").and_then(Value::as_str),
        Some("utf8")
    );
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

    let list = run_cli(&["script-sources", "999001"], &storage);
    assert_eq!(list.get("ok").and_then(Value::as_bool), Some(true));
    assert_eq!(list.get("count").and_then(Value::as_i64), Some(2));
}

#[test]
fn ingest_stamps_reflection_version() {
    let storage = temp_storage("refl_ver");
    let out = run_cli(
        &[
            "ingest",
            "--raw",
            fixture("baseline.json").to_str().unwrap(),
        ],
        &storage,
    );
    let v = out
        .get("reflectionVersion")
        .and_then(Value::as_str)
        .expect("reflectionVersion");
    assert!(!v.is_empty());
    // version must be persisted into meta
    let dump = run_cli(&["live-services", "999001"], &storage);
    assert_eq!(dump.get("ok").and_then(Value::as_bool), Some(true)); // place db exists
}
