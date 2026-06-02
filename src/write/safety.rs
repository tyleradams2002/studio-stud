use std::{
    fs,
    io::Write,
    path::Path,
    sync::atomic::{AtomicU64, Ordering},
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::Result;
use sha2::{Digest, Sha256};
use similar::TextDiff;

use crate::util::hex_bytes;

static ATOMIC_WRITE_COUNTER: AtomicU64 = AtomicU64::new(0);

pub fn normalize_newlines(input: &str) -> String {
    input.replace("\r\n", "\n").replace('\r', "\n")
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex_bytes(&hasher.finalize())
}

pub fn unified_diff(old: &str, new: &str, path: &str) -> String {
    if old == new {
        return String::new();
    }
    let old_label = format!("a/{path}");
    let new_label = format!("b/{path}");
    TextDiff::from_lines(old, new)
        .unified_diff()
        .context_radius(3)
        .header(&old_label, &new_label)
        .to_string()
}

pub fn atomic_write(abs_path: &Path, bytes: &[u8]) -> Result<()> {
    let parent = abs_path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("write path has no parent directory"))?;
    fs::create_dir_all(parent)?;

    let file_name = abs_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("target");
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    let counter = ATOMIC_WRITE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let tmp_path = parent.join(format!(
        "{}.{}-{}-{}.tmp",
        file_name,
        std::process::id(),
        nanos,
        counter
    ));

    {
        let mut file = fs::File::create(&tmp_path)?;
        file.write_all(bytes)?;
        file.sync_all()?;
    }

    match fs::rename(&tmp_path, abs_path) {
        Ok(()) => Ok(()),
        Err(err) => {
            let _ = fs::remove_file(&tmp_path);
            Err(err.into())
        }
    }
}

pub fn parse_luau(source: &str) -> Result<(), String> {
    match full_moon::parse(source) {
        Ok(_) => Ok(()),
        Err(errors) => {
            let first = errors
                .first()
                .map(|error| format!("{error}"))
                .unwrap_or_else(|| "parse failed".to_string());
            Err(first)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn normalize_newlines_collapses_crlf_and_cr() {
        assert_eq!(normalize_newlines("a\r\nb\rc"), "a\nb\nc");
        assert_eq!(normalize_newlines("already\nlf"), "already\nlf");
        assert_eq!(normalize_newlines("a\r\nb\rc"), normalize_newlines("a\nb\nc"));
    }

    #[test]
    fn sha256_hex_is_stable() {
        let first = sha256_hex(b"hello");
        let second = sha256_hex(b"hello");
        assert_eq!(first, second);
        assert_eq!(first.len(), 64);
    }

    #[test]
    fn unified_diff_empty_when_equal() {
        assert!(unified_diff("same", "same", "x.luau").is_empty());
    }

    #[test]
    fn unified_diff_one_line_change_is_deterministic() {
        let diff = unified_diff("old\n", "new\n", "synced/foo.luau");
        assert!(diff.contains("--- a/synced/foo.luau"));
        assert!(diff.contains("+++ b/synced/foo.luau"));
        assert_eq!(diff, unified_diff("old\n", "new\n", "synced/foo.luau"));
    }

    #[test]
    fn atomic_write_round_trip_and_no_temp_left() {
        let dir = std::env::temp_dir().join(format!(
            "studio_stud_atomic_{}_{}",
            std::process::id(),
            nanos_suffix()
        ));
        fs::create_dir_all(&dir).unwrap();
        let target = dir.join("sample.luau");
        atomic_write(&target, b"hello").unwrap();
        assert_eq!(fs::read(&target).unwrap(), b"hello");
        assert!(fs::read_dir(&dir).unwrap().find(|entry| {
            entry.as_ref().ok().is_some_and(|item| {
                item.file_name()
                    .to_str()
                    .is_some_and(|name| name.ends_with(".tmp"))
            })
        }).is_none());
        fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn parse_luau_accepts_strict_typed_luau() {
        let source = "--!strict\nlocal x: number = 1\nlocal msg = `hello {x}`\n";
        parse_luau(source).expect("typed luau should parse");
    }

    #[test]
    fn parse_luau_rejects_malformed_source() {
        assert!(parse_luau("local x = \n").is_err());
    }

    fn nanos_suffix() -> u128 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or(0)
    }
}
