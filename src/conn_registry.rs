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
    inner: Mutex<HashMap<String, PlaceHandle>>,
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

    pub fn with_writer<T, F>(&self, db_path: &Path, f: F) -> Result<T>
    where
        F: FnOnce(&mut Connection) -> Result<T>,
    {
        let key = Self::key(db_path);
        let mut map = self
            .inner
            .lock()
            .map_err(|_| anyhow!("connection registry lock poisoned"))?;
        if !map.contains_key(&key) {
            let handle = Self::open_handle(db_path)?;
            map.insert(key.clone(), handle);
        }
        let handle = map
            .get_mut(&key)
            .ok_or_else(|| anyhow!("connection registry missing handle"))?;
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
        let key = Self::key(db_path);
        let mut map = self
            .inner
            .lock()
            .map_err(|_| anyhow!("connection registry lock poisoned"))?;
        if !map.contains_key(&key) {
            let handle = Self::open_handle(db_path)?;
            map.insert(key.clone(), handle);
        }
        let handle = map
            .get_mut(&key)
            .ok_or_else(|| anyhow!("connection registry missing handle"))?;
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
}
