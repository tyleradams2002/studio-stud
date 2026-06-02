use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    time::SystemTime,
};

use serde_json::Value;

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn fixture(name: &str) -> PathBuf {
    repo_root().join("tests/fixtures/write").join(name)
}

fn temp_repo(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "studio_stud_write_{name}_{}",
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
    fs::create_dir_all(dir.join("generated")).ok();
    dir
}

fn run_cli_repo(args: &[&str], repo_root: &Path) -> Value {
    let exe = env!("CARGO_BIN_EXE_studio-stud");
    let output = Command::new(exe)
        .args(args)
        .arg("--repo-root")
        .arg(repo_root)
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

fn run_cli_repo_allow_fail(args: &[&str], repo_root: &Path) -> (bool, Value) {
    let exe = env!("CARGO_BIN_EXE_studio-stud");
    let output = Command::new(exe)
        .args(args)
        .arg("--repo-root")
        .arg(repo_root)
        .output()
        .expect("studio-stud should run");
    let value = serde_json::from_slice(&output.stdout).unwrap_or(Value::Null);
    (output.status.success(), value)
}

fn read_golden_json(name: &str) -> Value {
    let raw = fs::read_to_string(repo_root().join("tests/golden").join(name))
        .unwrap_or_else(|_| panic!("golden file {name}"));
    let trimmed = raw.trim_start_matches('\u{feff}').trim();
    serde_json::from_str(trimmed).unwrap_or_else(|err| panic!("golden json {name}: {err}"))
}

#[test]
fn write_safety_happy_path_and_noop() {
    let repo = temp_repo("happy");
    let target = repo.join("synced/foo.luau");
    let content = fixture("target_clean.luau");
    let first = run_cli_repo(
        &[
            "write-apply",
            "--path",
            "synced/foo.luau",
            "--content-file",
            content.to_str().unwrap(),
        ],
        &repo,
    );
    assert_eq!(first.get("ok").and_then(Value::as_bool), Some(true));
    assert_eq!(first.get("blocked").and_then(Value::as_bool), Some(false));
    assert_eq!(first.get("changed").and_then(Value::as_bool), Some(true));
    assert!(target.is_file());

    let mtime_before = fs::metadata(&target).unwrap().modified().unwrap();
    std::thread::sleep(std::time::Duration::from_millis(20));
    let second = run_cli_repo(
        &[
            "write-apply",
            "--path",
            "synced/foo.luau",
            "--content-file",
            content.to_str().unwrap(),
        ],
        &repo,
    );
    assert_eq!(second.get("changed").and_then(Value::as_bool), Some(false));
    let mtime_after = fs::metadata(&target).unwrap().modified().unwrap();
    assert_eq!(mtime_before, mtime_after);
}

#[test]
fn write_safety_crlf_to_lf_rewrite() {
    let repo = temp_repo("crlf");
    let target = repo.join("synced/foo.luau");
    let content = fixture("target_clean.luau");
    let lf_text = fs::read_to_string(&content)
        .unwrap()
        .replace("\r\n", "\n")
        .replace('\r', "\n");
    let crlf_bytes = lf_text.replace('\n', "\r\n").into_bytes();
    fs::write(&target, crlf_bytes).unwrap();

    let outcome = run_cli_repo(
        &[
            "write-apply",
            "--path",
            "synced/foo.luau",
            "--content-file",
            content.to_str().unwrap(),
        ],
        &repo,
    );
    assert_eq!(outcome.get("changed").and_then(Value::as_bool), Some(true));
    assert_eq!(
        outcome.get("hashBefore").and_then(Value::as_str),
        outcome.get("hashAfter").and_then(Value::as_str)
    );
    assert_eq!(fs::read(&target).unwrap(), lf_text.as_bytes());
}

#[test]
fn write_safety_preview_no_write() {
    let repo = temp_repo("preview");
    let target = repo.join("synced/foo.luau");
    let content = fixture("target_clean.luau");
    let preview = run_cli_repo(
        &[
            "write-preview",
            "--path",
            "synced/foo.luau",
            "--content-file",
            content.to_str().unwrap(),
        ],
        &repo,
    );
    assert_eq!(preview.get("blocked").and_then(Value::as_bool), Some(false));
    assert!(!preview.get("diff").and_then(Value::as_str).unwrap_or("").is_empty());
    assert!(!target.exists());
}

#[test]
fn write_safety_blocks_forbidden_path() {
    let repo = temp_repo("forbidden");
    let (ok, value) = run_cli_repo_allow_fail(
        &[
            "write-apply",
            "--path",
            "forbidden/bar.luau",
            "--content-file",
            fixture("target_clean.luau").to_str().unwrap(),
        ],
        &repo,
    );
    assert!(!ok);
    assert_eq!(
        value.get("blockedReason").and_then(Value::as_str),
        Some("pathNotAllowed")
    );
}

#[test]
fn write_safety_blocks_traversal_and_absolute_paths() {
    let repo = temp_repo("traversal");
    let content_path = fixture("target_clean.luau");
    let content = content_path.to_str().unwrap();
    for path in ["../escape.luau", "/absolute.luau", "C:foo.luau", "\\rooted.luau"] {
        let (ok, value) = run_cli_repo_allow_fail(
            &["write-apply", "--path", path, "--content-file", content],
            &repo,
        );
        assert!(!ok, "expected block for {path}");
        assert_eq!(
            value.get("blockedReason").and_then(Value::as_str),
            Some("pathNotAllowed")
        );
    }
}

#[test]
fn write_safety_blocks_oversize_header_parse_and_hash_mismatch() {
    let repo = temp_repo("gates");
    let clean = fixture("target_clean.luau");
    let big = repo.join("big.txt");
    fs::write(&big, vec![b'a'; 512]).unwrap();
    let (ok, value) = run_cli_repo_allow_fail(
        &[
            "write-apply",
            "--path",
            "synced/foo.luau",
            "--content-file",
            big.to_str().unwrap(),
        ],
        &repo,
    );
    assert!(!ok);
    assert_eq!(
        value.get("blockedReason").and_then(Value::as_str),
        Some("oversize")
    );

    let (ok, value) = run_cli_repo_allow_fail(
        &[
            "write-apply",
            "--path",
            "generated/missing-header.luau",
            "--content-file",
            fixture("target_generated_no_header.luau")
                .to_str()
                .unwrap(),
        ],
        &repo,
    );
    assert!(!ok);
    assert_eq!(
        value.get("blockedReason").and_then(Value::as_str),
        Some("headerMissing")
    );

    let (ok, value) = run_cli_repo_allow_fail(
        &[
            "write-apply",
            "--path",
            "synced/bad.luau",
            "--content-file",
            fixture("target_malformed.luau").to_str().unwrap(),
        ],
        &repo,
    );
    assert!(!ok);
    assert_eq!(
        value.get("blockedReason").and_then(Value::as_str),
        Some("parseError")
    );

    let first = run_cli_repo(
        &[
            "write-apply",
            "--path",
            "synced/cas.luau",
            "--content-file",
            clean.to_str().unwrap(),
        ],
        &repo,
    );
    let hash_after_first = first
        .get("hashAfter")
        .and_then(Value::as_str)
        .unwrap()
        .to_string();
    let (ok, value) = run_cli_repo_allow_fail(
        &[
            "write-apply",
            "--path",
            "synced/cas.luau",
            "--content-file",
            clean.to_str().unwrap(),
            "--expected-hash",
            "deadbeef",
        ],
        &repo,
    );
    assert!(!ok);
    assert_eq!(
        value.get("blockedReason").and_then(Value::as_str),
        Some("hashMismatch")
    );

    let second = run_cli_repo(
        &[
            "write-apply",
            "--path",
            "synced/cas.luau",
            "--content-file",
            clean.to_str().unwrap(),
            "--expected-hash",
            &hash_after_first,
        ],
        &repo,
    );
    assert_eq!(second.get("blocked").and_then(Value::as_bool), Some(false));
}

#[test]
fn write_safety_no_policy_blocks() {
    let repo = std::env::temp_dir().join(format!(
        "studio_stud_write_nopolicy_{}",
        SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir_all(&repo).unwrap();
    let (ok, value) = run_cli_repo_allow_fail(
        &[
            "write-apply",
            "--path",
            "synced/foo.luau",
            "--content-file",
            fixture("target_clean.luau").to_str().unwrap(),
        ],
        &repo,
    );
    assert!(!ok);
    assert_eq!(
        value.get("blockedReason").and_then(Value::as_str),
        Some("noPolicy")
    );
    fs::remove_dir_all(repo).ok();
}

#[test]
fn write_safety_internal_error_on_invalid_policy_glob() {
    let repo = temp_repo("internal");
    fs::write(
        repo.join(".studio-stud/policy.json"),
        r#"{"version":1,"allowedWritePaths":["["],"maxPatchBytes":256}"#,
    )
    .unwrap();
    let (ok, value) = run_cli_repo_allow_fail(
        &[
            "write-apply",
            "--path",
            "synced/foo.luau",
            "--content-file",
            fixture("target_clean.luau").to_str().unwrap(),
        ],
        &repo,
    );
    assert!(!ok);
    assert_eq!(
        value.get("blockedReason").and_then(Value::as_str),
        Some("internalError")
    );
}

#[test]
fn write_safety_deterministic_hash_after() {
    let repo_a = temp_repo("determinism_a");
    let repo_b = temp_repo("determinism_b");
    let content = fixture("target_clean.luau");
    let first = run_cli_repo(
        &[
            "write-apply",
            "--path",
            "synced/foo.luau",
            "--content-file",
            content.to_str().unwrap(),
        ],
        &repo_a,
    );
    let second = run_cli_repo(
        &[
            "write-apply",
            "--path",
            "synced/foo.luau",
            "--content-file",
            content.to_str().unwrap(),
        ],
        &repo_b,
    );
    assert_eq!(
        first.get("hashAfter").and_then(Value::as_str),
        second.get("hashAfter").and_then(Value::as_str)
    );
    assert_eq!(
        fs::read(repo_a.join("synced/foo.luau")).unwrap(),
        fs::read(repo_b.join("synced/foo.luau")).unwrap()
    );
}

#[test]
fn policy_init_check_explain_smoke() {
    let repo = temp_repo("policy_cli");
    fs::remove_file(repo.join(".studio-stud/policy.json")).unwrap();
    let init = run_cli_repo(&["policy", "init"], &repo);
    assert_eq!(init.get("ok").and_then(Value::as_bool), Some(true));
    let check = run_cli_repo(&["policy", "check"], &repo);
    assert_eq!(check.get("valid").and_then(Value::as_bool), Some(true));
    let explain = run_cli_repo(
        &["policy", "explain", "--path", "synced/foo.luau"],
        &repo,
    );
    assert_eq!(explain.get("allowed").and_then(Value::as_bool), Some(false));
}

#[test]
fn write_apply_outcome_matches_golden() {
    let repo = temp_repo("golden_apply");
    let content = fixture("target_clean.luau");
    let actual = run_cli_repo(
        &[
            "write-apply",
            "--path",
            "synced/foo.luau",
            "--content-file",
            content.to_str().unwrap(),
        ],
        &repo,
    );
    let golden = read_golden_json("write_apply_outcome.txt");
    assert_eq!(actual, golden);
}

#[test]
fn write_preview_diff_matches_golden() {
    let repo = temp_repo("golden_preview_full");
    let content = fixture("target_clean.luau");
    let actual = run_cli_repo(
        &[
            "write-preview",
            "--path",
            "synced/bar.luau",
            "--content-file",
            content.to_str().unwrap(),
        ],
        &repo,
    );
    let golden = read_golden_json("write_preview_diff.txt");
    assert_eq!(actual, golden);
}
