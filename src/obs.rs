//! Daemon observability: stderr + rotating `logs/daemon.log` under the storage root.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::Instant;

const ROTATE_BYTES: u64 = 8 * 1024 * 1024;

struct ObsConfig {
    log_path: PathBuf,
    profile: bool,
}

static CONFIG: OnceLock<ObsConfig> = OnceLock::new();

/// Initialize logging for the daemon. Safe to call once per process; later calls are ignored.
pub fn init(storage_root: &Path, profile: bool) {
    let _ = CONFIG.get_or_init(|| {
        let logs_dir = storage_root.join("logs");
        let _ = std::fs::create_dir_all(&logs_dir);
        let log_path = logs_dir.join("daemon.log");
        ObsConfig { log_path, profile }
    });
}

fn config() -> Option<&'static ObsConfig> {
    CONFIG.get()
}

/// Emit a timestamped line to stderr and append to `daemon.log` when initialized.
pub fn event(category: &str, msg: &str) {
    let line = format!(
        "{} [{}] {}",
        chrono::Utc::now().to_rfc3339(),
        category,
        msg
    );
    eprintln!("{line}");
    let Some(cfg) = config() else {
        return;
    };
    rotate_if_needed(&cfg.log_path);
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&cfg.log_path)
    {
        let _ = writeln!(file, "{line}");
    }
}

fn rotate_if_needed(log_path: &Path) {
    let Ok(meta) = std::fs::metadata(log_path) else {
        return;
    };
    if meta.len() < ROTATE_BYTES {
        return;
    }
    let backup = log_path.with_file_name("daemon.log.1");
    let _ = std::fs::remove_file(&backup);
    let _ = std::fs::rename(log_path, backup);
}

pub struct Span {
    category: String,
    label: String,
    started: Instant,
    finished: bool,
}

impl Span {
    pub fn finish(mut self) {
        self.finished = true;
        self.emit_elapsed();
    }

    fn emit_elapsed(&self) {
        let ms = self.started.elapsed().as_millis();
        let always = self.category == "capture";
        let profile = config().is_some_and(|c| c.profile);
        if always || profile {
            event(
                &self.category,
                &format!("{} took {ms} ms", self.label),
            );
        }
    }
}

impl Drop for Span {
    fn drop(&mut self) {
        if !self.finished {
            self.emit_elapsed();
        }
    }
}

/// Start a timing span; elapsed time is logged on drop or `finish()` when profiling is on
/// (always for category `"capture"`).
pub fn span(category: &str, label: &str) -> Span {
    Span {
        category: category.to_string(),
        label: label.to_string(),
        started: Instant::now(),
        finished: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn event_writes_line_to_log_file() {
        let dir = std::env::temp_dir().join(format!("ss_obs_test_{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        init(&dir, false);
        event("test", "hello world");
        let log = fs::read_to_string(dir.join("logs").join("daemon.log")).unwrap();
        assert!(log.contains("[test]"), "category missing: {log}");
        assert!(log.contains("hello world"), "message missing: {log}");
        let _ = fs::remove_dir_all(&dir);
    }
}
