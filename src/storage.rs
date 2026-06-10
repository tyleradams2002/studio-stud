use std::{
    env, fs,
    path::{Path, PathBuf},
};

use anyhow::{Result, anyhow};

use rusqlite::{Connection, OptionalExtension, params};

use serde::{Deserialize, Serialize};

use crate::util::{
    APP_NAME, DEFAULT_PROJECT_KEY, SCHEMA_VERSION, build_search_text, normalize_query_path,
    open_db, safe_key,
};

#[derive(Debug, Clone, Serialize, Deserialize)]

pub(crate) struct LiveState {
    pub(crate) capture_id: String,

    pub(crate) place_id: String,

    pub(crate) place_key: String,

    pub(crate) place_name: String,

    pub(crate) game_id: Option<i64>,

    pub(crate) revision: i64,

    pub(crate) baseline_at_utc: String,

    pub(crate) updated_at_utc: String,

    pub(crate) baseline_hash: String,

    pub(crate) fingerprint: String,

    pub(crate) instance_count: usize,
}

#[derive(Debug)]

pub(crate) struct Storage {
    pub(crate) root: PathBuf,

    pub(crate) project_key: String,
}

#[derive(Debug)]

pub(crate) struct PlaceStorage {
    pub(crate) place_dir: PathBuf,

    pub(crate) db_path: PathBuf,

    pub(crate) baseline_path: PathBuf,
}

#[derive(Debug, Clone)]

pub(crate) struct CaptureMeta {
    pub(crate) capture_id: String,

    pub(crate) place_id: String,

    pub(crate) place_key: String,

    pub(crate) place_name: String,

    pub(crate) game_id: Option<i64>,

    pub(crate) created_at_utc: String,

    pub(crate) sync_started_at_utc: Option<String>,

    pub(crate) sync_finished_at_utc: Option<String>,

    pub(crate) plugin_version: Option<String>,

    pub(crate) raw_sha256: String,

    pub(crate) instance_count: usize,
}

pub(crate) const NO_BASELINE_MSG: &str = "no baseline — run studio-stud capture";

impl LiveState {
    pub(crate) fn as_capture_meta(&self) -> CaptureMeta {
        CaptureMeta {
            capture_id: self.capture_id.clone(),

            place_id: self.place_id.clone(),

            place_key: self.place_key.clone(),

            place_name: self.place_name.clone(),

            game_id: self.game_id,

            created_at_utc: self.baseline_at_utc.clone(),

            sync_started_at_utc: None,

            sync_finished_at_utc: None,

            plugin_version: None,

            raw_sha256: self.baseline_hash.clone(),

            instance_count: self.instance_count,
        }
    }
}

impl Storage {
    pub(crate) fn new(storage_root: Option<PathBuf>, project_key: &str) -> Result<Self> {
        let root = match storage_root {
            Some(path) => path,

            None => dirs::data_local_dir()
                .or_else(dirs::home_dir)
                .ok_or_else(|| anyhow!("could not resolve local data directory"))?
                .join(APP_NAME),
        };

        Ok(Self {
            root,

            project_key: safe_key(project_key),
        })
    }

    /// Directory that holds this project's data. The default placeholder project
    /// key (`ExampleProject`) is collapsed away, so a normal install lays out as
    /// `<root>/places/<id>/...` instead of `<root>/ExampleProject/places/<id>/...`.
    /// A real, explicitly-set project key still gets its own namespace folder.
    pub(crate) fn project_root(&self) -> PathBuf {
        if self.project_key == DEFAULT_PROJECT_KEY {
            self.root.clone()
        } else {
            self.root.join(&self.project_key)
        }
    }

    pub(crate) fn place(&self, place_id: &str) -> PlaceStorage {
        let place_dir = self
            .project_root()
            .join("places")
            .join(safe_key(place_id));

        PlaceStorage {
            db_path: place_dir.join("syncs.db"),

            baseline_path: place_dir.join("baseline.json.gz"),

            place_dir,
        }
    }
}

pub(crate) fn resolve_place(storage: &Storage, place: Option<&str>) -> Result<PlaceStorage> {
    if let Some(place) = place {
        return Ok(storage.place(place));
    }

    // 1. Check the active_place file written by the daemon on every successful
    //    baseline or delta. This is the place the plugin is currently connected to.
    let active_path = storage.project_root().join("active_place");
    if let Ok(key) = fs::read_to_string(&active_path) {
        let key = key.trim().to_string();
        if !key.is_empty() {
            let ps = storage.place(&key);
            if ps.db_path.exists() {
                return Ok(ps);
            }
        }
    }

    // 2. Fallback: pick the place whose live_state.updated_at_utc is most recent.
    let places_dir = storage.project_root().join("places");

    let mut candidates = Vec::new();

    if places_dir.is_dir() {
        for entry in fs::read_dir(&places_dir)? {
            let entry = entry?;

            if entry.path().join("syncs.db").is_file() {
                candidates.push(entry.file_name().to_string_lossy().to_string());
            }
        }
    }

    let mut best: Option<(String, String)> = None; // (updated_at_utc, place_key)
    for candidate in &candidates {
        let place_storage = storage.place(candidate);
        if let Ok(conn) = open_db(&place_storage.db_path)
            && let Ok(Some(live)) = read_live_state(&conn)
        {
            let ts = live.updated_at_utc.clone();
            if best.as_ref().is_none_or(|(prev_ts, _)| ts > *prev_ts) {
                best = Some((ts, candidate.clone()));
            }
        }
    }

    let place = if let Some((_, key)) = best {
        key
    } else {
        candidates.sort();
        candidates
            .into_iter()
            .next()
            .ok_or_else(|| anyhow!("no captured places found"))?
    };

    Ok(storage.place(&place))
}

/// Write the given place key as the currently active place so that CLI
/// commands default to it without requiring an explicit place argument.
pub(crate) fn set_active_place(storage: &Storage, place_key: &str) {
    let path = storage.project_root().join("active_place");
    let _ = fs::write(&path, place_key);
}

pub(crate) fn read_live_state(conn: &Connection) -> Result<Option<LiveState>> {
    conn.query_row(
        "SELECT capture_id, place_id, place_key, place_name, game_id, revision,

                baseline_at_utc, updated_at_utc, baseline_hash, fingerprint, instance_count

         FROM live_state WHERE id = 1",
        [],
        |row| {
            Ok(LiveState {
                capture_id: row.get(0)?,

                place_id: row.get(1)?,

                place_key: row.get(2)?,

                place_name: row.get(3)?,

                game_id: row.get(4)?,

                revision: row.get(5)?,

                baseline_at_utc: row.get(6)?,

                updated_at_utc: row.get(7)?,

                baseline_hash: row.get(8)?,

                fingerprint: row.get(9)?,

                instance_count: row.get::<_, i64>(10)? as usize,
            })
        },
    )
    .optional()
    .map_err(Into::into)
}

pub(crate) fn write_live_state(conn: &Connection, state: &LiveState) -> Result<()> {
    conn.execute(
        "INSERT INTO live_state (

            id, capture_id, place_id, place_key, place_name, game_id, revision,

            baseline_at_utc, updated_at_utc, baseline_hash, fingerprint, instance_count

        ) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)

        ON CONFLICT(id) DO UPDATE SET

            capture_id = excluded.capture_id,

            place_id = excluded.place_id,

            place_key = excluded.place_key,

            place_name = excluded.place_name,

            game_id = excluded.game_id,

            revision = excluded.revision,

            baseline_at_utc = excluded.baseline_at_utc,

            updated_at_utc = excluded.updated_at_utc,

            baseline_hash = excluded.baseline_hash,

            fingerprint = excluded.fingerprint,

            instance_count = excluded.instance_count",
        params![
            state.capture_id,
            state.place_id,
            state.place_key,
            state.place_name,
            state.game_id,
            state.revision,
            state.baseline_at_utc,
            state.updated_at_utc,
            state.baseline_hash,
            state.fingerprint,
            state.instance_count as i64,
        ],
    )?;

    Ok(())
}

pub(crate) fn current_state(conn: &Connection) -> Result<LiveState> {
    read_live_state(conn)?.ok_or_else(|| anyhow!(NO_BASELINE_MSG))
}

#[allow(dead_code)]
pub(crate) fn capture_by_id(conn: &Connection, capture_id: &str) -> Result<CaptureMeta> {
    conn.query_row(

        "SELECT capture_id, place_id, place_key, place_name, game_id, created_at_utc, sync_started_at_utc, sync_finished_at_utc, plugin_version, raw_sha256, instance_count

         FROM captures WHERE status = 'completed' AND capture_id = ?",

        [capture_id],

        |row| {

            Ok(CaptureMeta {

                capture_id: row.get(0)?,

                place_id: row.get(1)?,

                place_key: row.get(2)?,

                place_name: row.get(3)?,

                game_id: row.get(4)?,

                created_at_utc: row.get(5)?,

                sync_started_at_utc: row.get(6)?,

                sync_finished_at_utc: row.get(7)?,

                plugin_version: row.get(8)?,

                raw_sha256: row.get(9)?,

                instance_count: row.get::<_, i64>(10)? as usize,

            })

        },

    )

    .optional()?

    .ok_or_else(|| anyhow!("capture `{capture_id}` is missing from SQLite"))
}

pub(crate) fn remove_if_exists(path: &Path) -> Result<()> {
    if path.exists() {
        fs::remove_file(path)?;
    }

    Ok(())
}

pub(crate) fn find_studio_stud_dir() -> Option<PathBuf> {
    if let Ok(exe) = env::current_exe() {
        let mut dir = exe.parent().map(Path::to_path_buf);

        for _ in 0..4 {
            let current = dir?;

            if current
                .join("plugin")
                .join("StudioStud.plugin.lua")
                .is_file()
            {
                return Some(current);
            }

            dir = current.parent().map(Path::to_path_buf);
        }
    }

    let mut dir = env::current_dir().ok()?;

    for _ in 0..6 {
        if dir.join("plugin").join("StudioStud.plugin.lua").is_file() {
            return Some(dir);
        }

        let nested = dir.join(".studio-stud-tool");

        if nested
            .join("plugin")
            .join("StudioStud.plugin.lua")
            .is_file()
        {
            return Some(nested);
        }

        if !dir.pop() {
            break;
        }
    }

    None
}

pub(crate) fn init_schema(conn: &Connection) -> Result<()> {
    conn.execute_batch(&format!(
        r#"

        PRAGMA journal_mode = WAL;

        PRAGMA foreign_keys = ON;

        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);

        INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', '{SCHEMA_VERSION}');

        CREATE TABLE IF NOT EXISTS captures (

            capture_id TEXT PRIMARY KEY,

            request_id TEXT,

            project_key TEXT NOT NULL,

            place_id TEXT NOT NULL,

            place_key TEXT NOT NULL,

            place_name TEXT NOT NULL,

            game_id INTEGER,

            created_at_utc TEXT NOT NULL,

            sync_started_at_utc TEXT,

            sync_finished_at_utc TEXT,

            plugin_version TEXT,

            daemon_version TEXT,

            protocol_version INTEGER,

            status TEXT NOT NULL,

            raw_sha256 TEXT NOT NULL,

            instance_count INTEGER NOT NULL

        );

        CREATE TABLE IF NOT EXISTS instances (

            capture_id TEXT NOT NULL,

            instance_id TEXT NOT NULL,

            parent_id TEXT,

            path TEXT NOT NULL,

            path_norm TEXT,

            display_path TEXT,

            display_path_norm TEXT,

            name TEXT NOT NULL,

            class_name TEXT NOT NULL,

            search_text TEXT,

            depth INTEGER,

            child_count INTEGER,

            sibling_index INTEGER,

            duplicate_sibling_name INTEGER,

            property_json TEXT,

            PRIMARY KEY (capture_id, instance_id)

        );

        CREATE TABLE IF NOT EXISTS instance_properties (

            capture_id TEXT NOT NULL,

            instance_id TEXT NOT NULL,

            property_name TEXT NOT NULL,

            value_json TEXT NOT NULL,

            PRIMARY KEY (capture_id, instance_id, property_name)

        );

        CREATE TABLE IF NOT EXISTS instance_attributes (

            capture_id TEXT NOT NULL,

            instance_id TEXT NOT NULL,

            attribute_name TEXT NOT NULL,

            value_json TEXT NOT NULL,

            PRIMARY KEY (capture_id, instance_id, attribute_name)

        );

        CREATE TABLE IF NOT EXISTS instance_tags (

            capture_id TEXT NOT NULL,

            instance_id TEXT NOT NULL,

            tag TEXT NOT NULL

        );

        CREATE TABLE IF NOT EXISTS class_counts (

            capture_id TEXT NOT NULL,

            class_name TEXT NOT NULL,

            count INTEGER NOT NULL,

            PRIMARY KEY (capture_id, class_name)

        );

        CREATE TABLE IF NOT EXISTS service_fingerprints (

            capture_id TEXT NOT NULL,

            service_name TEXT NOT NULL,

            fingerprint TEXT NOT NULL,

            instance_count INTEGER NOT NULL,

            PRIMARY KEY (capture_id, service_name)

        );

        CREATE TABLE IF NOT EXISTS keyword_hits (

            capture_id TEXT NOT NULL,

            instance_id TEXT NOT NULL,

            path TEXT NOT NULL,

            name TEXT NOT NULL,

            class_name TEXT NOT NULL

        );

        CREATE TABLE IF NOT EXISTS critical_presence (

            capture_id TEXT NOT NULL,

            critical_name TEXT NOT NULL,

            present INTEGER NOT NULL,

            PRIMARY KEY (capture_id, critical_name)

        );

        CREATE TABLE IF NOT EXISTS findings (

            capture_id TEXT NOT NULL,

            audit_id TEXT NOT NULL,

            severity TEXT NOT NULL,

            category TEXT NOT NULL,

            message TEXT NOT NULL,

            count INTEGER NOT NULL,

            PRIMARY KEY (capture_id, audit_id)

        );

        CREATE TABLE IF NOT EXISTS finding_samples (

            capture_id TEXT NOT NULL,

            audit_id TEXT NOT NULL,

            instance_id TEXT,

            path TEXT,

            sample_json TEXT NOT NULL

        );

        CREATE TABLE IF NOT EXISTS script_sources (

            capture_id TEXT NOT NULL,

            instance_id TEXT NOT NULL,

            source_text TEXT NOT NULL,

            source_hash TEXT NOT NULL,

            last_synced_hash TEXT,

            PRIMARY KEY (capture_id, instance_id)

        );

        CREATE TABLE IF NOT EXISTS live_state (

            id INTEGER PRIMARY KEY CHECK (id = 1),

            capture_id TEXT NOT NULL,

            place_id TEXT NOT NULL,

            place_key TEXT NOT NULL,

            place_name TEXT NOT NULL,

            game_id INTEGER,

            revision INTEGER NOT NULL,

            baseline_at_utc TEXT NOT NULL,

            updated_at_utc TEXT NOT NULL,

            baseline_hash TEXT NOT NULL,

            fingerprint TEXT NOT NULL,

            instance_count INTEGER NOT NULL

        );

        CREATE INDEX IF NOT EXISTS idx_instances_class ON instances(capture_id, class_name);

        CREATE INDEX IF NOT EXISTS idx_instances_path ON instances(capture_id, path);

        CREATE INDEX IF NOT EXISTS idx_instances_name ON instances(capture_id, name);

        CREATE INDEX IF NOT EXISTS idx_instances_parent ON instances(capture_id, parent_id);

        CREATE INDEX IF NOT EXISTS idx_findings ON findings(capture_id, audit_id);

        "#
    ))?;

    ensure_column(conn, "instances", "path_norm", "TEXT")?;

    ensure_column(conn, "instances", "display_path_norm", "TEXT")?;

    ensure_column(conn, "instances", "search_text", "TEXT")?;

    ensure_column(conn, "instances", "fingerprint", "TEXT")?;

    ensure_column(conn, "script_sources", "source_encoding", "TEXT")?;

    conn.execute_batch(

        r#"

        CREATE INDEX IF NOT EXISTS idx_instances_path_norm ON instances(capture_id, path_norm);

        CREATE INDEX IF NOT EXISTS idx_instances_display_path_norm ON instances(capture_id, display_path_norm);

        CREATE INDEX IF NOT EXISTS idx_instances_search_text ON instances(capture_id, search_text);

        "#,

    )?;

    Ok(())
}

pub(crate) fn ensure_column(
    conn: &Connection,
    table: &str,
    column: &str,
    column_type: &str,
) -> Result<()> {
    let mut stmt = conn.prepare(&format!("PRAGMA table_info({table})"))?;

    let rows = stmt.query_map([], |row| row.get::<_, String>(1))?;

    for row in rows {
        if row? == column {
            return Ok(());
        }
    }

    conn.execute(
        &format!("ALTER TABLE {table} ADD COLUMN {column} {column_type}"),
        [],
    )?;

    Ok(())
}

#[allow(dead_code)]
pub(crate) fn backfill_normalized_columns(conn: &mut Connection) -> Result<()> {
    let rows = {
        let mut stmt = conn.prepare(
            "SELECT capture_id, instance_id, path, display_path, name, class_name

             FROM instances

             WHERE path_norm IS NULL OR display_path_norm IS NULL OR search_text IS NULL",
        )?;

        let mapped = stmt.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, Option<String>>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, String>(5)?,
            ))
        })?;

        let mut rows = Vec::new();

        for row in mapped {
            rows.push(row?);
        }

        rows
    };

    if rows.is_empty() {
        return Ok(());
    }

    let tx = conn.transaction()?;

    for (capture_id, instance_id, path, display_path, name, class_name) in rows {
        let path_norm = normalize_query_path(&path);

        let display_path_norm = display_path
            .as_deref()
            .map(normalize_query_path)
            .unwrap_or_default();

        let search_text = build_search_text(&path, display_path.as_deref(), &name, &class_name);

        tx.execute(
            "UPDATE instances

             SET path_norm = ?, display_path_norm = ?, search_text = ?

             WHERE capture_id = ? AND instance_id = ?",
            params![
                path_norm,
                display_path_norm,
                search_text,
                capture_id,
                instance_id
            ],
        )?;
    }

    tx.commit()?;

    Ok(())
}

#[allow(dead_code)]
pub(crate) fn read_reflection_version(conn: &Connection) -> Result<Option<String>> {
    conn.query_row(
        "SELECT value FROM meta WHERE key = 'reflection_version'",
        [],
        |row| row.get(0),
    )
    .optional()
    .map_err(Into::into)
}

#[allow(dead_code)]
pub(crate) fn write_reflection_version(conn: &Connection, version: &str) -> Result<()> {
    conn.execute(
        "INSERT OR REPLACE INTO meta (key, value) VALUES ('reflection_version', ?)",
        params![version],
    )?;
    Ok(())
}

pub(crate) fn upsert_script_source(
    conn: &Connection,
    capture_id: &str,
    instance_id: &str,
    source_text: &str,
    source_hash: &str,
    source_encoding: &str,
) -> Result<()> {
    conn.execute(
        "INSERT OR REPLACE INTO script_sources (capture_id, instance_id, source_text, source_hash, last_synced_hash, source_encoding)
         VALUES (?, ?, ?, ?, NULL, ?)",
        params![
            capture_id,
            instance_id,
            source_text,
            source_hash,
            source_encoding
        ],
    )?;
    Ok(())
}

pub(crate) fn upsert_script_source_bytes(
    conn: &Connection,
    capture_id: &str,
    instance_id: &str,
    source_bytes: &[u8],
    source_hash: &str,
    source_encoding: &str,
) -> Result<()> {
    conn.execute(
        "INSERT OR REPLACE INTO script_sources (capture_id, instance_id, source_text, source_hash, last_synced_hash, source_encoding)
         VALUES (?, ?, ?, ?, NULL, ?)",
        params![
            capture_id,
            instance_id,
            source_bytes,
            source_hash,
            source_encoding
        ],
    )?;
    Ok(())
}

pub(crate) fn delete_all_tables(tx: &rusqlite::Transaction<'_>) -> Result<()> {
    for table in [
        "finding_samples",
        "findings",
        "critical_presence",
        "keyword_hits",
        "class_counts",
        "service_fingerprints",
        "script_sources",
        "instance_tags",
        "instance_attributes",
        "instance_properties",
        "instances",
        "captures",
    ] {
        tx.execute(&format!("DELETE FROM {table}"), [])?;
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    use rusqlite::Connection;

    #[test]
    fn default_project_key_collapses_out_of_path() {
        let root = PathBuf::from("/data");
        // Default placeholder key -> no project folder: /data/places/<id>/syncs.db
        let s = Storage::new(Some(root.clone()), DEFAULT_PROJECT_KEY).unwrap();
        assert_eq!(s.project_root(), root);
        assert_eq!(
            s.place("139581542512435").db_path,
            root.join("places").join("139581542512435").join("syncs.db")
        );
    }

    #[test]
    fn real_project_key_keeps_its_namespace() {
        let root = PathBuf::from("/data");
        let s = Storage::new(Some(root.clone()), "fisherslife").unwrap();
        assert_eq!(s.project_root(), root.join("fisherslife"));
        assert_eq!(
            s.place("42").db_path,
            root.join("fisherslife").join("places").join("42").join("syncs.db")
        );
    }

    #[test]

    fn live_state_round_trip() {
        let conn = Connection::open_in_memory().unwrap();

        init_schema(&conn).unwrap();

        let state = LiveState {
            capture_id: "cap1".into(),

            place_id: "123".into(),

            place_key: "Place123".into(),

            place_name: "Test".into(),

            game_id: Some(1),

            revision: 0,

            baseline_at_utc: "2026-01-01T00:00:00Z".into(),

            updated_at_utc: "2026-01-01T00:00:00Z".into(),

            baseline_hash: "abc".into(),

            fingerprint: "def".into(),

            instance_count: 5,
        };

        write_live_state(&conn, &state).unwrap();

        let read = read_live_state(&conn).unwrap().unwrap();

        assert_eq!(read.capture_id, "cap1");

        assert_eq!(read.revision, 0);

        assert_eq!(read.instance_count, 5);
    }

    #[test]

    fn current_state_errors_without_baseline() {
        let conn = Connection::open_in_memory().unwrap();

        init_schema(&conn).unwrap();

        assert!(current_state(&conn).is_err());
    }

    #[test]
    fn script_sources_table_and_reflection_version_round_trip() {
        let conn = Connection::open_in_memory().unwrap();
        init_schema(&conn).unwrap();

        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='script_sources'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 1);

        write_reflection_version(&conn, "0.659").unwrap();
        assert_eq!(
            read_reflection_version(&conn).unwrap().as_deref(),
            Some("0.659")
        );

        upsert_script_source(&conn, "cap1", "inst1", "print('hi')", "abc123", "utf8").unwrap();
        let hash: String = conn
            .query_row(
                "SELECT source_hash FROM script_sources WHERE capture_id = ? AND instance_id = ?",
                params!["cap1", "inst1"],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(hash, "abc123");
    }
}
