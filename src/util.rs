use std::collections::HashMap;
use std::path::Path;
use std::time::Duration;

use anyhow::{Result, anyhow};
use chrono::Utc;
use rusqlite::{Connection, OpenFlags, params_from_iter};
use serde::Serialize;
use serde_json::Value;

pub(crate) const APP_NAME: &str = "StudioStud";
pub(crate) const DEFAULT_PROJECT_KEY: &str = "ExampleProject";
pub(crate) const DEFAULT_HOST: &str = "127.0.0.1";
pub(crate) const DEFAULT_PORT: u16 = 31878;
pub(crate) const MAX_CHUNK_BYTES: usize = 900_000;
pub(crate) const SCHEMA_VERSION: i64 = 2;
pub(crate) const PROTOCOL_VERSION: i64 = 1;
pub(crate) const MIN_PLUGIN_PROTOCOL_VERSION: i64 = 1;
pub(crate) const KEYWORDS: &[&str] = &[
    "Spawn",
    "Prompt",
    "Shop",
    "Trader",
    "Zone",
    "Dock",
    "Teleporter",
    "Travel",
    "NPC",
    "Quest",
];
pub(crate) const CRITICAL_NAMES: &[&str] = &[
    "BoatSpawnPoints",
    "FishingHabitatZones",
    "HousingPlots",
    "TraderNPC_Mike",
    "RodShop",
    "AdditionAnchors",
    "LocationZones",
    "QuestMarkers",
];

#[derive(Serialize)]
pub(crate) struct Finding {
    pub(crate) id: String,
    pub(crate) severity: String,
    pub(crate) category: String,
    pub(crate) message: String,
    pub(crate) count: i64,
}

#[derive(Debug, Serialize)]
pub struct DoctorCheck {
    pub name: String,
    pub status: String,
    pub detail: String,
}

pub(crate) fn pass(name: &str, detail: String) -> DoctorCheck {
    DoctorCheck {
        name: name.to_string(),
        status: "pass".to_string(),
        detail,
    }
}

pub(crate) fn warn(name: &str, detail: String) -> DoctorCheck {
    DoctorCheck {
        name: name.to_string(),
        status: "warn".to_string(),
        detail,
    }
}

pub(crate) fn fail(name: &str, detail: String) -> DoctorCheck {
    DoctorCheck {
        name: name.to_string(),
        status: "fail".to_string(),
        detail,
    }
}

pub(crate) fn display_path(path: &Path) -> String {
    path.to_string_lossy().to_string()
}
pub(crate) fn split_url(url: &str) -> (String, HashMap<String, String>) {
    let (path, query_text) = url.split_once('?').unwrap_or((url, ""));
    let mut query = HashMap::new();
    for pair in query_text.split('&').filter(|item| !item.is_empty()) {
        let (key, value) = pair.split_once('=').unwrap_or((pair, ""));
        query.insert(percent_decode(key), percent_decode(value));
    }
    (path.to_string(), query)
}

pub(crate) fn percent_decode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%'
            && index + 2 < bytes.len()
            && let Ok(hex) = std::str::from_utf8(&bytes[index + 1..index + 3])
            && let Ok(byte) = u8::from_str_radix(hex, 16)
        {
            decoded.push(byte);
            index += 3;
            continue;
        }
        decoded.push(if bytes[index] == b'+' {
            b' '
        } else {
            bytes[index]
        });
        index += 1;
    }
    String::from_utf8_lossy(&decoded).into_owned()
}

pub(crate) fn required_query(query: &HashMap<String, String>, key: &str) -> Result<String> {
    query
        .get(key)
        .filter(|value| !value.is_empty())
        .cloned()
        .ok_or_else(|| anyhow!("{key} is required"))
}
/// Open a SQLite database file with WAL and a 60-second busy timeout.
/// CLI queries and the daemon can touch the same place DB concurrently;
/// busy_timeout waits for long verify/capture writes instead of SQLITE_BUSY.
/// Enable incremental auto-vacuum on existing DBs (one-time `VACUUM` when mode was off).
pub(crate) fn ensure_incremental_auto_vacuum(conn: &Connection) -> Result<()> {
    let mode: i64 = conn.query_row("PRAGMA auto_vacuum", [], |row| row.get(0))?;
    if mode != 2 {
        conn.execute_batch("PRAGMA auto_vacuum = INCREMENTAL; VACUUM;")?;
    }
    Ok(())
}

/// Reclaim space after a full re-ingest (capture materialize or similar bulk rewrite).
pub(crate) fn compact_db_after_bulk_write(conn: &Connection) -> Result<()> {
    // PASSIVE checkpoint: much faster than TRUNCATE after a full table rewrite.
    conn.execute_batch("PRAGMA wal_checkpoint(PASSIVE); PRAGMA incremental_vacuum;")?;
    Ok(())
}

pub(crate) fn open_db(path: &Path) -> Result<Connection> {
    let conn = Connection::open(path)?;
    conn.busy_timeout(Duration::from_secs(60))?;
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA synchronous = NORMAL;
         PRAGMA foreign_keys = ON;",
    )?;
    ensure_incremental_auto_vacuum(&conn)?;
    Ok(conn)
}

/// Read-only SQLite handle for CLI query/analyze. Does not run migrations or backfill.
pub(crate) fn open_db_readonly(path: &Path) -> Result<Connection> {
    let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    conn.busy_timeout(Duration::from_secs(60))?;
    conn.execute_batch("PRAGMA foreign_keys = ON; PRAGMA query_only = ON;")?;
    Ok(conn)
}

pub(crate) const STALE_DB_SCHEMA_MSG: &str =
    "DB schema is stale — run `studio-stud capture` to re-baseline.";

pub(crate) fn safe_key(value: &str) -> String {
    let key: String = value
        .chars()
        .filter(|ch| ch.is_ascii_alphanumeric() || *ch == '-' || *ch == '_')
        .collect();
    if key.is_empty() {
        "Unknown".to_string()
    } else {
        key
    }
}
pub(crate) fn make_id(prefix: &str) -> String {
    format!(
        "{}_{}",
        safe_key(prefix),
        Utc::now()
            .to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
            .replace(['-', ':', '.', 'T', 'Z'], "")
    )
}
pub(crate) fn value_to_string(value: Option<&Value>) -> Option<String> {
    match value {
        Some(Value::String(value)) => Some(value.clone()),
        Some(Value::Number(value)) => Some(value.to_string()),
        _ => None,
    }
}

pub fn now_utc() -> String {
    Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}
pub(crate) fn str_field(value: &Value, key: &str) -> String {
    opt_str_field(value, key).unwrap_or_default()
}

pub(crate) fn opt_str_field(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).map(str::to_string)
}

pub(crate) fn matches_keyword(value: &str) -> bool {
    let lower = value.to_ascii_lowercase();
    KEYWORDS
        .iter()
        .any(|keyword| lower.contains(&keyword.to_ascii_lowercase()))
}

pub(crate) fn build_search_text(
    path: &str,
    display_path: Option<&str>,
    name: &str,
    class_name: &str,
) -> String {
    format!(
        "{} {} {} {}",
        path,
        display_path.unwrap_or(""),
        name,
        class_name
    )
    .to_ascii_lowercase()
}
pub(crate) fn path_root(path: &str) -> &str {
    path.split('/')
        .next()
        .unwrap_or("")
        .split('[')
        .next()
        .unwrap_or("")
}

pub(crate) fn looks_like_invisible_helper(path: &str) -> bool {
    let lower = path.to_ascii_lowercase();
    [
        "anchor",
        "arrival",
        "barrier",
        "boundary",
        "hitbox",
        "humanoidrootpart",
        "marker",
        "spawn",
        "trigger",
        "zone",
    ]
    .iter()
    .any(|token| lower.contains(token))
}
pub(crate) fn normalize_query_path(value: &str) -> String {
    let mut out = String::new();
    let mut chars = value.trim().chars().peekable();
    let mut last_was_separator = false;
    while let Some(ch) = chars.next() {
        if ch == '[' {
            let mut digits = String::new();
            while let Some(next) = chars.peek().copied() {
                chars.next();
                if next == ']' {
                    break;
                }
                digits.push(next);
            }
            if !digits.is_empty() && digits.chars().all(|item| item.is_ascii_digit()) {
                continue;
            }
            out.push('[');
            out.push_str(&digits);
            out.push(']');
            last_was_separator = false;
            continue;
        }
        let normalized = if matches!(ch, '/' | '\\' | '.') {
            '/'
        } else {
            ch
        };
        if normalized == '/' {
            if !last_was_separator && !out.is_empty() {
                out.push('/');
                last_was_separator = true;
            }
        } else {
            out.push(normalized.to_ascii_lowercase());
            last_was_separator = false;
        }
    }
    out.trim_matches('/').to_string()
}

pub(crate) fn escape_like(value: &str) -> String {
    value.to_string()
}

pub(crate) fn prune_empty_json(value: Value) -> Value {
    match value {
        Value::Object(map) => {
            let mut cleaned = serde_json::Map::new();
            for (key, value) in map {
                let value = prune_empty_json(value);
                if !value.is_null() {
                    cleaned.insert(key, value);
                }
            }
            Value::Object(cleaned)
        }
        Value::Array(items) => Value::Array(
            items
                .into_iter()
                .map(prune_empty_json)
                .filter(|value| !value.is_null())
                .collect(),
        ),
        other => other,
    }
}

pub(crate) fn is_empty_json(value: &Value) -> bool {
    match value {
        Value::Null => true,
        Value::Object(map) => map.is_empty(),
        Value::Array(items) => items.is_empty(),
        _ => false,
    }
}

pub(crate) fn hex_bytes(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{:02x}", byte)).collect()
}

pub(crate) fn scalar_i64(conn: &Connection, sql: &str, capture_id: &str) -> Result<i64> {
    Ok(conn.query_row(sql, [capture_id], |row| row.get(0))?)
}

pub(crate) fn scalar_i64_dynamic(conn: &Connection, sql: &str, values: &[String]) -> Result<i64> {
    Ok(conn.query_row(sql, params_from_iter(values.iter()), |row| row.get(0))?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn safe_key_strips_invalid_chars() {
        assert_eq!(safe_key("Place 139/581"), "Place139581");
    }

    #[test]
    fn percent_decode_handles_plus_and_percent() {
        assert_eq!(percent_decode("a+b%20c"), "a b c");
    }

    #[test]
    fn split_url_parses_query() {
        let (path, query) = split_url("/studio-stud/capture/status?requestId=abc");
        assert_eq!(path, "/studio-stud/capture/status");
        assert_eq!(query.get("requestId").map(String::as_str), Some("abc"));
    }

    #[test]
    fn path_root_returns_first_segment() {
        assert_eq!(path_root("Workspace/BoatSpawnPoints"), "Workspace");
    }

    #[test]
    fn matches_keyword_finds_spawn() {
        assert!(matches_keyword("BoatSpawnPoints"));
        assert!(!matches_keyword("RandomFolder"));
    }

    #[test]
    fn ensure_incremental_auto_vacuum_sets_mode() {
        let path = std::env::temp_dir().join(format!(
            "ss_vacuum_test_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        let conn = Connection::open(&path).unwrap();
        conn.execute_batch("CREATE TABLE t(x INTEGER);").unwrap();
        let mode: i64 = conn
            .query_row("PRAGMA auto_vacuum", [], |row| row.get(0))
            .unwrap();
        assert_eq!(mode, 0);
        ensure_incremental_auto_vacuum(&conn).unwrap();
        let mode: i64 = conn
            .query_row("PRAGMA auto_vacuum", [], |row| row.get(0))
            .unwrap();
        assert_eq!(mode, 2);
        let _ = std::fs::remove_file(path);
    }
}
