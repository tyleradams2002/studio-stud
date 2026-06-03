use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::channels::{
    Channel, channel_update_available_seq, check_anti_rollback, fetch_manifest_with_fallback,
    verify_manifest_signature,
};
use super::config::StudioStudConfig;
use crate::update;

const CACHE_TTL: Duration = Duration::from_secs(86400);

struct CacheInner {
    fetched_at: Option<Instant>,
    fields: Value,
    refreshing: AtomicBool,
}

impl Default for CacheInner {
    fn default() -> Self {
        Self {
            fetched_at: None,
            fields: Value::Null,
            refreshing: AtomicBool::new(false),
        }
    }
}

pub struct ChannelUpdateCache {
    inner: Mutex<CacheInner>,
    cfg: StudioStudConfig,
    install_root: std::path::PathBuf,
}

impl ChannelUpdateCache {
    pub fn new(cfg: StudioStudConfig, install_root: std::path::PathBuf) -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(CacheInner::default()),
            cfg,
            install_root,
        })
    }

    pub fn ping_fields(self: &Arc<Self>) -> Value {
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let stale = inner
            .fetched_at
            .is_none_or(|t| t.elapsed() >= CACHE_TTL);
        if stale {
            if inner.fetched_at.is_none() {
                drop(inner);
                self.maybe_start_background_refresh();
                return json!({ "updateAvailable": false });
            }
            inner.fields = self.refresh_fields();
            inner.fetched_at = Some(Instant::now());
        }
        inner.fields.clone()
    }

    fn maybe_start_background_refresh(self: &Arc<Self>) {
        let inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        if inner.refreshing.swap(true, Ordering::AcqRel) {
            return;
        }
        drop(inner);
        let this = Arc::clone(self);
        std::thread::spawn(move || {
            let fields = this.refresh_fields();
            let mut inner = this.inner.lock().unwrap_or_else(|e| e.into_inner());
            inner.fields = fields;
            inner.fetched_at = Some(Instant::now());
            inner.refreshing.store(false, Ordering::Release);
        });
    }

    fn refresh_fields(&self) -> Value {
        let requested = Channel::from_str(&self.cfg.channel);
        let installed = installed_version_at(&self.install_root);
        let Ok((manifest, raw, resolved)) = fetch_manifest_with_fallback(requested) else {
            return json!({
                "updateAvailable": false,
            });
        };
        if verify_manifest_signature(&raw, &manifest).is_err() {
            return json!({ "updateAvailable": false });
        }
        if check_anti_rollback(resolved, &manifest, &self.cfg.last_channel_sequence).is_err() {
            return json!({ "updateAvailable": false });
        }
        let on_fallback = resolved != requested;
        let last_seen_seq = self
            .cfg
            .last_channel_sequence
            .get(resolved.as_str())
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let update_available = channel_update_available_seq(
            on_fallback,
            manifest.channel_sequence,
            last_seen_seq,
            &manifest.daemon_version,
            &installed,
        );
        json!({
            "latestDaemonVersion": manifest.daemon_version,
            "latestPluginVersion": manifest.plugin_version,
            "updateAvailable": update_available,
            "onFallback": on_fallback,
            "channel": resolved.as_str(),
        })
    }
}

fn installed_version_at(install_root: &Path) -> String {
    let path = install_root.join("version.json");
    if let Ok(text) = std::fs::read_to_string(path)
        && let Ok(v) = serde_json::from_str::<Value>(&text)
        && let Some(ver) = v.get("daemonVersion").and_then(Value::as_str)
        && !ver.is_empty()
    {
        return ver.to_string();
    }
    update::installed_version()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn installed_version_at_reads_install_root_version_json() {
        let dir = std::env::temp_dir().join(format!(
            "studio-stud-ver-test-{}",
            std::process::id()
        ));
        let _ = std::fs::create_dir_all(&dir);
        std::fs::write(
            dir.join("version.json"),
            r#"{"daemonVersion":"9.9.9"}"#,
        )
        .unwrap();
        assert_eq!(installed_version_at(&dir), "9.9.9");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn ping_fields_empty_cache_returns_immediately() {
        let cache = ChannelUpdateCache::new(StudioStudConfig::default(), PathBuf::from("."));
        let start = Instant::now();
        let fields = cache.ping_fields();
        assert!(start.elapsed() < Duration::from_millis(100));
        assert_eq!(fields["updateAvailable"], false);
    }
}
