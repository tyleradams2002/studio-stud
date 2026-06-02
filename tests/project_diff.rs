use std::{
    fs,
    path::PathBuf,
    process::Command,
};

use serde_json::Value;

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/project/repo")
}

fn fixture_actual() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/project/actual.json")
}

fn run_cli(args: &[&str], storage_root: Option<&PathBuf>) -> (String, bool) {
    let exe = env!("CARGO_BIN_EXE_studio-stud");
    let mut cmd = Command::new(exe);
    cmd.args(args);
    if let Some(root) = storage_root {
        cmd.arg("--storage-root").arg(root);
    }
    let output = cmd.output().expect("studio-stud should run");
    let ok = output.status.success();
    let stdout = String::from_utf8(output.stdout).expect("utf8 stdout");
    (stdout, ok)
}

fn prepare_storage() -> PathBuf {
    static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let tmp = std::env::temp_dir().join(format!(
        "studio_stud_project_diff_{}_{}",
        std::process::id(),
        n
    ));
    if tmp.exists() {
        fs::remove_dir_all(&tmp).ok();
    }
    fs::create_dir_all(&tmp).expect("temp dir");
    let raw = fixture_actual();
    let (_, ok) = run_cli(
        &["ingest", "--raw", raw.to_str().unwrap()],
        Some(&tmp),
    );
    assert!(ok, "ingest fixture actual.json");
    tmp
}

fn parse_json(stdout: &str) -> Value {
    serde_json::from_str(stdout.trim()).expect("json stdout")
}

#[test]
fn project_diff_fixture_counts_and_ownership() {
    let storage = prepare_storage();
    let repo = repo_root();
    let (stdout, ok) = run_cli(
        &[
            "project",
            "diff",
            "90000000000001",
            "--repo-root",
            repo.to_str().unwrap(),
            "--limit",
            "50",
        ],
        Some(&storage),
    );
    assert!(ok, "project diff failed: {stdout}");
    let v = parse_json(&stdout);
    let summary = &v["summary"];
    assert_eq!(summary["matched"].as_u64(), Some(5));
    assert_eq!(summary["classMismatch"].as_u64(), Some(1));
    assert_eq!(summary["missingInStudio"].as_u64(), Some(1));
    assert_eq!(summary["extraInStudio"].as_u64(), Some(2));
    assert_eq!(summary["studioOwned"].as_u64(), Some(2));

    let five: u64 = ["matched", "classMismatch", "extraInStudio", "studioOwned"]
        .iter()
        .map(|k| summary[k].as_u64().unwrap())
        .sum();
    assert_eq!(five, 10, "five DB category counts should equal instance rows");

    let extras: Vec<_> = v["categories"]["extraInStudio"]["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["studioPath"].as_str().unwrap().to_ascii_lowercase())
        .collect();
    assert!(extras.iter().any(|p| p.contains("datamanager")));
    assert!(extras.iter().any(|p| p.contains("studioonlyincore")));
    assert!(!extras.iter().any(|p| p.contains("studioonlyatroot")));

    let missing = &v["categories"]["missingInStudio"]["items"][0];
    assert!(missing["sourceHash"].as_str().is_some());
    assert!(missing["studioPath"]
        .as_str()
        .unwrap()
        .to_ascii_lowercase()
        .contains("combat"));
}

#[test]
fn project_diff_deterministic() {
    let storage = prepare_storage();
    let repo = repo_root();
    let args = [
        "project",
        "diff",
        "90000000000001",
        "--repo-root",
        repo.to_str().unwrap(),
    ];
    let (a, ok_a) = run_cli(&args, Some(&storage));
    let (b, ok_b) = run_cli(&args, Some(&storage));
    assert!(ok_a && ok_b);
    assert_eq!(a.trim(), b.trim());
}

#[test]
fn project_diff_under_filter() {
    let storage = prepare_storage();
    let repo = repo_root();
    let (stdout, ok) = run_cli(
        &[
            "project",
            "diff",
            "90000000000001",
            "--repo-root",
            repo.to_str().unwrap(),
            "--under",
            "ServerScriptService/Core",
        ],
        Some(&storage),
    );
    assert!(ok);
    let v = parse_json(&stdout);
    let summary = &v["summary"];
    assert_eq!(summary["matched"].as_u64(), Some(2));
    assert_eq!(summary["extraInStudio"].as_u64(), Some(2));
}

#[test]
fn project_diff_stale_db() {
    let tmp = std::env::temp_dir().join(format!(
        "studio_stud_project_diff_empty_{}",
        std::process::id()
    ));
    fs::create_dir_all(&tmp).ok();
    let repo = repo_root();
    let (_, ok) = run_cli(
        &[
            "project",
            "diff",
            "90000000000001",
            "--repo-root",
            repo.to_str().unwrap(),
        ],
        Some(&tmp),
    );
    assert!(!ok);
}

#[test]
fn project_projection_golden() {
    let repo = repo_root();
    let (stdout, ok) = run_cli(
        &[
            "project",
            "projection",
            "--full",
            "--repo-root",
            repo.to_str().unwrap(),
        ],
        None,
    );
    assert!(ok);
    let normalized = normalize_projection_output(&stdout);
    let golden_path =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/golden/project_projection_fixture.txt");
    if std::env::var("UPDATE_GOLDENS").is_ok() {
        fs::write(&golden_path, &normalized).expect("write golden");
    } else if golden_path.is_file() {
        let expected = fs::read_to_string(&golden_path).expect("read golden");
        assert_eq!(expected.trim(), normalized.trim());
    } else {
        fs::write(&golden_path, &normalized).expect("seed golden");
    }
}

#[test]
fn effective_ignore_unknown_unit() {
    use studio_stud::project::{ProjectNode, PathNode, effective_ignore_unknown};
    use std::{collections::BTreeMap, path::PathBuf};

    let with_path = ProjectNode {
        class_name: None,
        path: Some(PathNode::Required(PathBuf::from("server"))),
        properties: serde_json::Map::new(),
        attributes: serde_json::Map::new(),
        ignore_unknown: None,
        id: None,
        children: BTreeMap::new(),
    };
    assert!(!effective_ignore_unknown(&with_path));

    let without = ProjectNode {
        class_name: Some("Workspace".to_string()),
        path: None,
        properties: serde_json::Map::new(),
        attributes: serde_json::Map::new(),
        ignore_unknown: None,
        id: None,
        children: BTreeMap::new(),
    };
    assert!(effective_ignore_unknown(&without));
}

fn normalize_projection_output(stdout: &str) -> String {
    let mut v: Value = serde_json::from_str(stdout.trim()).expect("json");
    if let Some(instances) = v.get_mut("instances").and_then(Value::as_array_mut) {
        for item in instances {
            if let Some(obj) = item.as_object_mut() {
                obj.remove("sourceHash");
                obj.remove("parseOk");
            }
        }
    }
    serde_json::to_string_pretty(&v).expect("re-serialize")
}

#[test]
fn project_diff_bounded_large_fixture() {
    let storage = prepare_storage();
    let repo = repo_root();
    let (stdout, ok) = run_cli(
        &[
            "project",
            "diff",
            "90000000000001",
            "--repo-root",
            repo.to_str().unwrap(),
            "--limit",
            "3",
        ],
        Some(&storage),
    );
    assert!(ok);
    let v = parse_json(&stdout);
    for key in ["missingInStudio", "extraInStudio", "classMismatch"] {
        if let Some(cat) = v["categories"].get(key) {
            let returned = cat["returned"].as_u64().unwrap();
            let limit = cat["limit"].as_u64().unwrap();
            assert!(returned <= limit);
        }
    }
}
