use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{Result, anyhow};
use rusqlite::Connection;

use crate::storage::init_schema;
use crate::util::open_db;

const DEFAULT_IDLE_TIMEOUT: Duration = Duration::from_secs(300);

struct PlaceHandle {
    writer: Mutex<Connection>,
    reader: Mutex<Connection>,
    last_used: Mutex<Instant>,
}

pub struct ConnRegistry {
    inner: Mutex<HashMap<String, Arc<PlaceHandle>>>,
    idle_timeout: Duration,
}

impl ConnRegistry {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(HashMap::new()),
            idle_timeout: DEFAULT_IDLE_TIMEOUT,
        })
    }

    fn key(db_path: &Path) -> String {
        db_path.to_string_lossy().into_owned()
    }

    fn open_handle(db_path: &Path) -> Result<PlaceHandle> {
        let writer = open_db(db_path)?;
        init_schema(&writer)?;
        let reader = open_db(db_path)?;
        init_schema(&reader)?;
        Ok(PlaceHandle {
            writer: Mutex::new(writer),
            reader: Mutex::new(reader),
            last_used: Mutex::new(Instant::now()),
        })
    }

    /// Resolve (lazily opening) the handle for a place and return a clone of its
    /// `Arc`, so the outer map lock is released *before* the caller locks the
    /// per-place connection. This is what keeps one place's long operation — or a
    /// long read — from blocking every other place behind the global map mutex.
    fn handle(&self, db_path: &Path) -> Result<Arc<PlaceHandle>> {
        let key = Self::key(db_path);
        let mut map = self
            .inner
            .lock()
            .map_err(|_| anyhow!("connection registry lock poisoned"))?;
        if let Some(handle) = map.get(&key) {
            return Ok(Arc::clone(handle));
        }
        let handle = Arc::new(Self::open_handle(db_path)?);
        map.insert(key, Arc::clone(&handle));
        Ok(handle)
        // map lock released here, before the caller touches the connection
    }

    pub fn with_writer<T, F>(&self, db_path: &Path, f: F) -> Result<T>
    where
        F: FnOnce(&mut Connection) -> Result<T>,
    {
        let handle = self.handle(db_path)?;
        *handle
            .last_used
            .lock()
            .map_err(|_| anyhow!("connection registry last_used lock poisoned"))? =
            Instant::now();
        let mut conn = handle
            .writer
            .lock()
            .map_err(|_| anyhow!("connection registry writer lock poisoned"))?;
        f(&mut conn)
    }

    pub fn with_reader<T, F>(&self, db_path: &Path, f: F) -> Result<T>
    where
        F: FnOnce(&Connection) -> Result<T>,
    {
        let handle = self.handle(db_path)?;
        *handle
            .last_used
            .lock()
            .map_err(|_| anyhow!("connection registry last_used lock poisoned"))? =
            Instant::now();
        let conn = handle
            .reader
            .lock()
            .map_err(|_| anyhow!("connection registry reader lock poisoned"))?;
        f(&conn)
    }

    pub fn evict_idle(&self, now: Instant) {
        let Ok(mut map) = self.inner.lock() else {
            return;
        };
        map.retain(|_, handle| {
            let Ok(last) = handle.last_used.lock() else {
                return false;
            };
            now.duration_since(*last) < self.idle_timeout
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registry_reuses_writer_connection() {
        let dir = std::env::temp_dir().join(format!("ss_conn_reg_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("t.db");
        let registry = ConnRegistry::new();

        registry
            .with_writer(&db, |conn| {
                conn.execute_batch(
                    "CREATE TEMP TABLE reg_test(x INTEGER); INSERT INTO reg_test VALUES (1);",
                )?;
                Ok(())
            })
            .unwrap();

        registry
            .with_writer(&db, |conn| {
                let v: i64 = conn
                    .query_row("SELECT x FROM reg_test", [], |r| r.get(0))
                    .unwrap();
                assert_eq!(v, 1);
                Ok(())
            })
            .unwrap();
    }

    #[test]
    fn registry_evict_opens_fresh_connection() {
        let dir =
            std::env::temp_dir().join(format!("ss_conn_evict_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("t.db");
        let registry = ConnRegistry::new();

        registry
            .with_writer(&db, |conn| {
                conn.execute_batch("CREATE TEMP TABLE reg_evict(x INTEGER);")?;
                Ok(())
            })
            .unwrap();

        registry.evict_idle(Instant::now() + Duration::from_secs(600));

        registry
            .with_writer(&db, |conn| {
                let err = conn.query_row::<i64, _, _>("SELECT x FROM reg_evict", [], |r| {
                    r.get(0)
                });
                assert!(err.is_err(), "temp table must not survive eviction");
                Ok(())
            })
            .unwrap();
    }

    #[test]
    fn writer_releases_map_lock_during_closure() {
        // Regression guard for the global-map-lock serialization bug: with the
        // old impl the map lock was held across the closure, so a nested
        // with_writer on a DIFFERENT place would deadlock on the (non-reentrant)
        // map mutex. The timeout makes a re-introduced bug fail cleanly instead
        // of hanging the suite.
        let dir =
            std::env::temp_dir().join(format!("ss_conn_reentry_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let db_a = dir.join("a.db");
        let db_b = dir.join("b.db");
        let registry = ConnRegistry::new();

        let (tx, rx) = std::sync::mpsc::channel();
        let reg = Arc::clone(&registry);
        let worker = std::thread::spawn(move || {
            let result = reg.with_writer(&db_a, |_conn_a| {
                // nested access to another place must not deadlock on the map lock
                reg.with_writer(&db_b, |conn_b| {
                    conn_b.execute_batch("CREATE TEMP TABLE t(x INTEGER);")?;
                    Ok(())
                })
            });
            let _ = tx.send(result.is_ok());
        });

        let ok = rx
            .recv_timeout(Duration::from_secs(5))
            .expect("nested with_writer deadlocked: map lock held across the closure");
        assert!(ok, "nested with_writer should succeed");
        worker.join().unwrap();
    }
}
