use std::{fs, path::Path};

use crate::{
    policy::{self, CompiledPolicy},
    write::{BlockedReason, WriteMode, WriteOutcome, WriteRequest},
};

use super::safety::{atomic_write, normalize_newlines, sha256_hex, unified_diff};

pub fn execute(
    repo_root: &Path,
    compiled: &CompiledPolicy,
    req: &WriteRequest<'_>,
    mode: WriteMode,
) -> WriteOutcome {
    let normalized_path = policy::normalize_rel_path(req.path);
    if let Some(reason) = policy::check_path(
        repo_root,
        compiled,
        &normalized_path,
        req.content,
        req.place_id,
    ) {
        return WriteOutcome::blocked(reason, &normalized_path, None);
    }

    let content_text = std::str::from_utf8(req.content).expect("check_path validates utf8");
    let normalized_content = normalize_newlines(content_text);
    let normalized_bytes = normalized_content.as_bytes();

    let abs_path = match policy::resolve_write_target(repo_root, &normalized_path) {
        Ok(path) => path,
        Err(reason) => return WriteOutcome::blocked(reason, &normalized_path, None),
    };

    let (raw_on_disk, hash_before) = read_raw_and_hash(&abs_path);
    let hash_after = sha256_hex(normalized_bytes);
    let changed = raw_on_disk.as_deref() != Some(normalized_bytes);

    if mode == WriteMode::Apply {
        if let Some(expected) = req.expected_hash
            && expected != hash_before
        {
            return WriteOutcome::blocked(BlockedReason::HashMismatch, &normalized_path, None);
        }
        if changed && let Err(err) = atomic_write(&abs_path, normalized_bytes) {
            return WriteOutcome::blocked(
                BlockedReason::InternalError,
                &normalized_path,
                Some(err.to_string()),
            );
        }
    }

    let diff = if matches!(mode, WriteMode::Preview | WriteMode::Apply) {
        let old_text = raw_on_disk
            .and_then(|bytes| String::from_utf8(bytes).ok())
            .map(|text| normalize_newlines(&text))
            .unwrap_or_default();
        unified_diff(&old_text, &normalized_content, &normalized_path)
    } else {
        String::new()
    };

    WriteOutcome::success(
        &normalized_path,
        changed,
        diff,
        normalized_bytes.len() as u64,
        hash_before,
        hash_after,
        req.generated_by.map(str::to_string),
    )
}

fn read_raw_and_hash(abs_path: &Path) -> (Option<Vec<u8>>, String) {
    match fs::read(abs_path) {
        Ok(bytes) => {
            let normalized = normalize_newlines(&String::from_utf8_lossy(&bytes));
            (Some(bytes), sha256_hex(normalized.as_bytes()))
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => (None, sha256_hex(b"")),
        Err(_) => (None, sha256_hex(b"")),
    }
}
