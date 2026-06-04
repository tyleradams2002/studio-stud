#[test]
fn version_flag_prints_version() {
    let out = std::process::Command::new(env!("CARGO_BIN_EXE_studio-stud"))
        .arg("--version")
        .output()
        .expect("run studio-stud --version");
    assert!(out.status.success(), "exit not success: {:?}", out);
    let s = String::from_utf8_lossy(&out.stdout);
    assert!(
        s.contains(env!("CARGO_PKG_VERSION")),
        "version missing: {s}"
    );
}
