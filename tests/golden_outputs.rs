use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Mutex, OnceLock};

static GOLDEN_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn fixture_path() -> PathBuf {
    repo_root().join("tests/fixtures/baseline_capture.json")
}

fn golden_path(name: &str) -> PathBuf {
    repo_root().join("tests/golden").join(format!("{name}.txt"))
}

fn normalize_output(stdout: &str) -> String {
    let trimmed = stdout.trim();
    if trimmed.starts_with('{') || trimmed.starts_with('[') {
        let mut value: serde_json::Value =
            serde_json::from_str(trimmed).expect("golden output should be JSON");
        normalize_json(&mut value);
        return serde_json::to_string(&value).expect("re-serialize normalized JSON");
    }
    trimmed.to_string()
}

fn normalize_json(value: &mut serde_json::Value) {
    match value {
        serde_json::Value::Object(map) => {
            // Normalize the "Local server manifest" doctor check — its detail and status
            // change depending on whether `studio-stud serve` is running during the test.
            let is_local_server_check =
                map.get("name").and_then(|v| v.as_str()) == Some("Local server manifest");
            if is_local_server_check {
                map.insert(
                    "detail".into(),
                    serde_json::Value::String("DAEMON_STATE".into()),
                );
                map.insert(
                    "status".into(),
                    serde_json::Value::String("DAEMON_STATE".into()),
                );
                return;
            }
            for (key, item) in map.iter_mut() {
                if key == "generatedAtUtc" || key == "createdAtUtc" || key == "updatedAtUtc" {
                    *item = serde_json::Value::String("TIMESTAMP".into());
                } else if key == "daemon" {
                    *item = serde_json::json!({ "state": "not-running" });
                } else {
                    normalize_json(item);
                }
            }
        }
        serde_json::Value::Array(items) => {
            for item in items {
                normalize_json(item);
            }
        }
        _ => {}
    }
}

fn run_cli(args: &[&str], storage_root: &Path) -> String {
    let exe = env!("CARGO_BIN_EXE_studio-stud");
    let output = Command::new(exe)
        .args(args)
        .arg("--storage-root")
        .arg(storage_root)
        .output()
        .expect("studio-stud command should run");
    assert!(
        output.status.success(),
        "command failed: {:?}\nstderr={}",
        args,
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).expect("stdout utf-8")
}

fn prepare_storage() -> PathBuf {
    let tmp = std::env::temp_dir().join(format!("studio_stud_golden_test_{}", std::process::id()));
    if tmp.exists() {
        fs::remove_dir_all(&tmp).ok();
    }
    fs::create_dir_all(&tmp).expect("temp storage dir");
    let fixture = fixture_path();
    let ingest = run_cli(
        &["ingest", "--raw", fixture.to_str().expect("fixture path")],
        &tmp,
    );
    assert!(ingest.contains("\"ok\":true"));
    tmp
}

#[test]
fn golden_outputs_match_fixture_ingest() {
    let _lock = GOLDEN_LOCK.get_or_init(|| Mutex::new(())).lock().unwrap();
    let storage = prepare_storage();
    let place = "139581542512435";

    let cases = [
        (
            "analyze_context_findings_critical",
            vec![
                "analyze", place, "--report", "context", "--report", "findings", "--report",
                "critical",
            ],
        ),
        (
            "query_class_part",
            vec!["query", place, "--class", "Part", "--limit", "25"],
        ),
        (
            "query_name_boat_spawn",
            vec!["query", place, "--name", "BoatSpawnPoints"],
        ),
        (
            "query_tree_boat_spawn",
            vec![
                "query",
                place,
                "--tree",
                "Workspace/BoatSpawnPoints",
                "--depth",
                "1",
            ],
        ),
        (
            "query_detail_boat_spawn",
            vec![
                "query",
                place,
                "--detail",
                "Workspace/BoatSpawnPoints",
                "--props",
                "Position,Size",
            ],
        ),
        ("status_json", vec!["status"]),
        ("doctor_json", vec!["doctor"]),
    ];

    for (name, args) in cases {
        let actual = normalize_output(&run_cli(&args, &storage));
        let expected =
            normalize_output(&fs::read_to_string(golden_path(name)).expect("golden file"));
        assert_eq!(actual, expected, "golden mismatch for {name}");
    }
}

#[test]
fn bench_json_shape_is_stable() {
    let fixture = fixture_path();
    let output = Command::new(env!("CARGO_BIN_EXE_studio-stud"))
        .args([
            "bench",
            "--raw",
            fixture.to_str().expect("fixture"),
            "--iterations",
            "3",
            "--json",
        ])
        .output()
        .expect("bench should run");
    assert!(output.status.success());
    let value: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("bench --json should be valid JSON");
    assert!(value.get("stages").is_some());
    assert!(value["stages"]["decode"].get("medianMs").is_some());
    assert!(value["stages"]["ingestSqlite"].get("medianMs").is_some());
}
