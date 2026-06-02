use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::Value;

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
