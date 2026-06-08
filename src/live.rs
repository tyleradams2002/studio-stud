use std::collections::BTreeSet;

use std::path::PathBuf;
use std::time::Instant;

use anyhow::{Result, anyhow};

use rusqlite::{Connection, OptionalExtension, Transaction, params, types::ValueRef};

use serde_json::{Value, json};

use crate::conn_registry::ConnRegistry;
use crate::capture::{
    canonical_instance_value, capture_meta, delete_instance_rows, fingerprint_state,
    fp_digest_from_entry, ingest_rows, parse_fp_hex, read_stored_fp,
    recompute_critical_presence_from_db, recompute_findings, service_of, upsert_instance,
};

use crate::storage::{
    LiveState, Storage, current_state, delete_all_tables, init_schema, read_live_state,
    resolve_place, write_live_state,
};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as B64;

use crate::util::{hex_bytes, make_id, normalize_query_path, now_utc, open_db, open_db_readonly, str_field};

pub(crate) struct DeltaRequest {
    pub place_id: String,

    pub base_revision: i64,

    pub upserted: Vec<Value>,

    pub removed: Vec<String>,
}

pub(crate) fn parse_delta_request(value: &Value) -> Result<DeltaRequest> {
    let place_id = value
        .get("placeId")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("placeId required"))?
        .to_string();

    let base_revision = value
        .get("baseRevision")
        .and_then(Value::as_i64)
        .ok_or_else(|| anyhow!("baseRevision required"))?;

    let ops = value
        .get("ops")
        .and_then(Value::as_object)
        .ok_or_else(|| anyhow!("ops required"))?;

    let upserted = ops
        .get("upserted")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    let removed = ops
        .get("removed")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();

    Ok(DeltaRequest {
        place_id,

        base_revision,

        upserted,

        removed,
    })
}

fn parse_fingerprint_hex(hex: &str) -> Result<[u8; 32]> {
    parse_fp_hex(hex)
}

fn fingerprint_hex(acc: [u8; 32]) -> String {
    hex_bytes(&acc)
}

pub(crate) fn apply_delta(
    storage_root: Option<PathBuf>,

    project_key: &str,

    place: Option<&str>,

    request: &DeltaRequest,

    registry: &ConnRegistry,
) -> Result<Value> {
    let storage = Storage::new(storage_root, project_key)?;

    let place_storage = resolve_place(&storage, place)?;

    registry.with_writer(&place_storage.db_path, |conn| {
        let live = read_live_state(conn)?;

        let Some(live) = live else {
            return Ok(json!({ "ok": false, "error": "no_baseline" }));
        };

        if request.base_revision != live.revision {
            crate::obs::event(
                "live-delta",
                &format!(
                    "REJECT revision_mismatch place={} base={} live={}",
                    request.place_id, request.base_revision, live.revision
                ),
            );

            return Ok(json!({

                "ok": false,

                "error": "revision_mismatch",

                "revision": live.revision,

            }));
        }

        let capture_id = live.capture_id.clone();

        let mut acc = parse_fingerprint_hex(&live.fingerprint)?;

        let tx = conn.transaction()?;

        let delta_started = Instant::now();
        apply_delta_tx(&tx, &capture_id, request, &mut acc)?;
        crate::obs::event(
            "telemetry",
            &crate::telemetry::format_delta(
                request.upserted.len(),
                request.removed.len(),
                delta_started.elapsed().as_millis(),
            ),
        );

        if !request.removed.is_empty() || !request.upserted.is_empty() {
            crate::obs::event(
                "live-delta",
                &format!(
                    "APPLY place={} rev {}->{} removed={} upserted={}",
                    request.place_id,
                    live.revision,
                    live.revision + 1,
                    request.removed.len(),
                    request.upserted.len()
                ),
            );
            for id in &request.removed {
                crate::obs::event("live-delta", &format!("removed id={id}"));
            }
        }

        let instance_count: i64 = tx.query_row(
            "SELECT COUNT(*) FROM instances WHERE capture_id = ?",
            [&capture_id],
            |row| row.get(0),
        )?;

        let new_revision = live.revision + 1;

        let updated_at = now_utc();

        let fingerprint = fingerprint_hex(acc);

        tx.execute(

            "UPDATE live_state SET revision = ?, updated_at_utc = ?, fingerprint = ?, instance_count = ? WHERE id = 1",

            params![new_revision, updated_at, fingerprint, instance_count],

        )?;

        tx.commit()?;

        Ok(json!({

            "ok": true,

            "revision": new_revision,

            "fingerprint": fingerprint,

            "instanceCount": instance_count,

        }))
    })
}

pub(crate) fn apply_delta_tx(
    tx: &Transaction<'_>,

    capture_id: &str,

    request: &DeltaRequest,

    acc: &mut [u8; 32],
) -> Result<()> {
    for removed_id in &request.removed {
        let old_path: Option<String> = tx
            .query_row(
                "SELECT path FROM instances WHERE capture_id = ? AND instance_id = ?",
                params![capture_id, removed_id],
                |row| row.get(0),
            )
            .optional()?;

        if let Some(digest) = read_stored_fp(tx, capture_id, removed_id)? {
            for (i, byte) in digest.iter().enumerate() {
                acc[i] ^= byte;
            }
            if let Some(ref path) = old_path {
                xor_service(tx, capture_id, service_of(path), &digest, -1)?;
            }
        }

        let old_class: Option<String> = tx
            .query_row(
                "SELECT class_name FROM instances WHERE capture_id = ? AND instance_id = ?",
                params![capture_id, removed_id],
                |row| row.get(0),
            )
            .optional()?;

        if let Some(class_name) = old_class {
            adjust_class_count(tx, capture_id, &class_name, -1)?;
        }

        delete_instance_rows(tx, capture_id, removed_id)?;
    }

    for inst in &request.upserted {
        let id = str_field(inst, "id");

        let new_class = str_field(inst, "className");

        let new_path = str_field(inst, "path");

        let old_path: Option<String> = tx
            .query_row(
                "SELECT path FROM instances WHERE capture_id = ? AND instance_id = ?",
                params![capture_id, id],
                |row| row.get(0),
            )
            .optional()?;

        let old_class: Option<String> = tx
            .query_row(
                "SELECT class_name FROM instances WHERE capture_id = ? AND instance_id = ?",
                params![capture_id, id],
                |row| row.get(0),
            )
            .optional()?;

        if let Some(digest) = read_stored_fp(tx, capture_id, &id)? {
            for (i, byte) in digest.iter().enumerate() {
                acc[i] ^= byte;
            }
            if let Some(ref path) = old_path {
                xor_service_fp(tx, capture_id, service_of(path), &digest)?;
            }
        }

        if let Some(ref old) = old_class {
            if old != &new_class {
                adjust_class_count(tx, capture_id, old, -1)?;

                adjust_class_count(tx, capture_id, &new_class, 1)?;
            }
        } else {
            adjust_class_count(tx, capture_id, &new_class, 1)?;
        }

        upsert_instance(tx, capture_id, inst)?;

        let digest = fp_digest_from_entry(inst)?;

        for (i, byte) in digest.iter().enumerate() {
            acc[i] ^= byte;
        }

        xor_service_fp(tx, capture_id, service_of(&new_path), &digest)?;

        match old_path.as_deref() {
            None => {
                xor_service_count(tx, capture_id, service_of(&new_path), 1)?;
            }
            Some(old) => {
                let old_svc = service_of(old);
                let new_svc = service_of(&new_path);
                if old_svc != new_svc {
                    xor_service_count(tx, capture_id, old_svc, -1)?;
                    xor_service_count(tx, capture_id, new_svc, 1)?;
                }
            }
        }
    }

    recompute_critical_presence_from_db(tx, capture_id)?;

    recompute_findings(tx, capture_id)?;

    Ok(())
}

fn xor_service_fp(
    tx: &Transaction<'_>,
    capture_id: &str,
    service: &str,
    digest: &[u8; 32],
) -> Result<()> {
    let row: Option<String> = tx
        .query_row(
            "SELECT fingerprint FROM service_fingerprints WHERE capture_id = ? AND service_name = ?",
            params![capture_id, service],
            |row| row.get(0),
        )
        .optional()?;

    let Some(fp_hex) = row else {
        tx.prepare_cached(
            "INSERT INTO service_fingerprints (capture_id, service_name, fingerprint, instance_count) VALUES (?, ?, ?, ?)",
        )?
        .execute(params![capture_id, service, hex_bytes(digest), 0i64])?;
        return Ok(());
    };

    let mut acc = parse_fingerprint_hex(&fp_hex)?;
    for (i, byte) in digest.iter().enumerate() {
        acc[i] ^= byte;
    }

    tx.prepare_cached(
        "UPDATE service_fingerprints SET fingerprint = ? WHERE capture_id = ? AND service_name = ?",
    )?
    .execute(params![hex_bytes(&acc), capture_id, service])?;

    Ok(())
}

fn xor_service_count(
    tx: &Transaction<'_>,
    capture_id: &str,
    service: &str,
    count_delta: i64,
) -> Result<()> {
    let row: Option<i64> = tx
        .query_row(
            "SELECT instance_count FROM service_fingerprints WHERE capture_id = ? AND service_name = ?",
            params![capture_id, service],
            |row| row.get(0),
        )
        .optional()?;

    let Some(count) = row else {
        if count_delta > 0 {
            tx.prepare_cached(
                "INSERT INTO service_fingerprints (capture_id, service_name, fingerprint, instance_count) VALUES (?, ?, ?, ?)",
            )?
            .execute(params![capture_id, service, hex_bytes(&[0u8; 32]), count_delta])?;
        }
        return Ok(());
    };

    let next = count + count_delta;
    if next <= 0 {
        tx.prepare_cached(
            "DELETE FROM service_fingerprints WHERE capture_id = ? AND service_name = ?",
        )?
        .execute(params![capture_id, service])?;
    } else {
        tx.prepare_cached(
            "UPDATE service_fingerprints SET instance_count = ? WHERE capture_id = ? AND service_name = ?",
        )?
        .execute(params![next, capture_id, service])?;
    }
    Ok(())
}

fn xor_service(
    tx: &Transaction<'_>,
    capture_id: &str,
    service: &str,
    digest: &[u8; 32],
    count_delta: i64,
) -> Result<()> {
    xor_service_fp(tx, capture_id, service, digest)?;
    xor_service_count(tx, capture_id, service, count_delta)
}

fn adjust_class_count(
    tx: &Transaction<'_>,

    capture_id: &str,

    class_name: &str,

    delta: i64,
) -> Result<()> {
    let current: Option<i64> = tx
        .query_row(
            "SELECT count FROM class_counts WHERE capture_id = ? AND class_name = ?",
            params![capture_id, class_name],
            |row| row.get(0),
        )
        .optional()?;

    match current {
        Some(count) => {
            let next = count + delta;

            if next <= 0 {
                tx.execute(
                    "DELETE FROM class_counts WHERE capture_id = ? AND class_name = ?",
                    params![capture_id, class_name],
                )?;
            } else {
                tx.execute(
                    "UPDATE class_counts SET count = ? WHERE capture_id = ? AND class_name = ?",
                    params![next, capture_id, class_name],
                )?;
            }
        }

        None if delta > 0 => {
            tx.execute(
                "INSERT INTO class_counts (capture_id, class_name, count) VALUES (?, ?, ?)",
                params![capture_id, class_name, delta],
            )?;
        }

        None => {}
    }

    Ok(())
}

pub(crate) fn delete_capture_partition(tx: &Transaction<'_>, capture_id: &str) -> Result<()> {
    for table in [
        "finding_samples",
        "findings",
        "critical_presence",
        "keyword_hits",
        "class_counts",
        "instance_tags",
        "instance_attributes",
        "instance_properties",
        "instances",
        "captures",
    ] {
        tx.execute(
            &format!("DELETE FROM {table} WHERE capture_id = ?"),
            [capture_id],
        )?;
    }

    Ok(())
}

pub(crate) fn verify_drift(
    storage_root: Option<PathBuf>,

    project_key: &str,

    place: Option<&str>,

    snapshot: &Value,

    raw_bytes: &[u8],
) -> Result<Value> {
    let storage = Storage::new(storage_root, project_key)?;

    let place_storage = resolve_place(&storage, place)?;

    let mut conn = open_db(&place_storage.db_path)?;

    init_schema(&conn)?;

    let live = read_live_state(&conn)?;

    let Some(live) = live else {
        return Ok(json!({ "ok": false, "error": "no_baseline" }));
    };

    let mut staging_meta = capture_meta(snapshot, raw_bytes)?;

    staging_meta.capture_id = make_id("verify");

    let tx = conn.transaction()?;

    ingest_rows(&tx, snapshot, &staging_meta)?;

    let staging_fp = fingerprint_state(&tx, &staging_meta.capture_id)?;

    if staging_fp == live.fingerprint {
        delete_capture_partition(&tx, &staging_meta.capture_id)?;

        tx.commit()?;

        return Ok(json!({

            "ok": true,

            "drift": [],

            "corrected": 0,

            "revision": live.revision,

        }));
    }

    let drift = compute_drift_ids(&tx, &live.capture_id, &staging_meta.capture_id)?;

    let corrected = drift.len();

    delete_capture_partition(&tx, &live.capture_id)?;

    let instance_count: i64 = tx.query_row(
        "SELECT COUNT(*) FROM instances WHERE capture_id = ?",
        [&staging_meta.capture_id],
        |row| row.get(0),
    )?;

    let new_revision = live.revision + 1;

    let updated_at = now_utc();

    tx.execute(

        "UPDATE live_state SET capture_id = ?, revision = ?, updated_at_utc = ?, fingerprint = ?, instance_count = ?, baseline_hash = ? WHERE id = 1",

        params![

            staging_meta.capture_id,

            new_revision,

            updated_at,

            staging_fp,

            instance_count,

            staging_meta.raw_sha256,

        ],

    )?;

    tx.commit()?;

    Ok(json!({

        "ok": true,

        "drift": drift,

        "corrected": corrected,

        "revision": new_revision,

    }))
}

fn compute_drift_ids(conn: &Connection, current_id: &str, staging_id: &str) -> Result<Vec<String>> {
    let current_ids = instance_ids(conn, current_id)?;

    let staging_ids = instance_ids(conn, staging_id)?;

    let mut drift = BTreeSet::new();

    for id in current_ids.union(&staging_ids) {
        let in_current = current_ids.contains(id);

        let in_staging = staging_ids.contains(id);

        if in_current != in_staging {
            drift.insert(id.clone());

            continue;
        }

        let current_val = canonical_instance_value(conn, current_id, id)?;

        let staging_val = canonical_instance_value(conn, staging_id, id)?;

        if current_val != staging_val {
            drift.insert(id.clone());
        }
    }

    Ok(drift.into_iter().collect())
}

fn instance_ids(conn: &Connection, capture_id: &str) -> Result<BTreeSet<String>> {
    let mut stmt = conn.prepare("SELECT instance_id FROM instances WHERE capture_id = ?")?;

    let rows = stmt.query_map([capture_id], |row| row.get::<_, String>(0))?;

    let mut ids = BTreeSet::new();

    for row in rows {
        ids.insert(row?);
    }

    Ok(ids)
}

pub(crate) fn live_dump(
    storage_root: Option<PathBuf>,

    project_key: &str,

    place: Option<&str>,
) -> Result<Value> {
    let storage = Storage::new(storage_root, project_key)?;

    let place_storage = resolve_place(&storage, place)?;

    let conn = open_db(&place_storage.db_path)?;

    init_schema(&conn)?;

    let live = current_state(&conn)?;

    let capture_id = live.capture_id.clone();

    let mut stmt = conn
        .prepare("SELECT instance_id FROM instances WHERE capture_id = ? ORDER BY instance_id")?;

    let rows = stmt.query_map([&capture_id], |row| row.get::<_, String>(0))?;

    let mut state = Vec::new();

    for row in rows {
        state.push(canonical_instance_value(&conn, &capture_id, &row?)?);
    }

    Ok(json!({

        "meta": {

            "captureId": live.capture_id,

            "baselineHash": live.baseline_hash,

            "revision": live.revision,

            "baselineAtUtc": live.baseline_at_utc,

            "updatedAtUtc": live.updated_at_utc,

        },

        "state": state,

        "fingerprint": live.fingerprint,

    }))
}

pub(crate) fn live_services(
    storage_root: Option<PathBuf>,
    project_key: &str,
    place: Option<&str>,
) -> Result<Value> {
    let storage = Storage::new(storage_root, project_key)?;
    let place_storage = resolve_place(&storage, place)?;
    let conn = open_db(&place_storage.db_path)?;
    init_schema(&conn)?;

    let live = current_state(&conn)?;
    let capture_id = live.capture_id.clone();
    let global = live.fingerprint.clone();

    let mut stmt = conn.prepare(
        "SELECT service_name, fingerprint, instance_count FROM service_fingerprints WHERE capture_id = ? ORDER BY service_name",
    )?;
    let rows = stmt.query_map([&capture_id], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, i64>(2)?,
        ))
    })?;

    let mut services = serde_json::Map::new();
    let mut xor_acc = [0u8; 32];
    for row in rows {
        let (name, fp_hex, count) = row?;
        for (i, chunk) in fp_hex.as_bytes().chunks(2).enumerate() {
            if i < 32 {
                let s = std::str::from_utf8(chunk)?;
                xor_acc[i] ^= u8::from_str_radix(s, 16)?;
            }
        }
        services.insert(
            name,
            json!({ "fingerprint": fp_hex, "count": count }),
        );
    }

    Ok(json!({
        "ok": true,
        "global": global,
        "services": services,
        "xorOfServices": hex_bytes(&xor_acc),
    }))
}

fn read_source_bytes(row: &rusqlite::Row<'_>, idx: usize) -> rusqlite::Result<Vec<u8>> {
    match row.get_ref(idx)? {
        ValueRef::Blob(b) => Ok(b.to_vec()),
        ValueRef::Text(t) => Ok(t.to_vec()),
        other => Err(rusqlite::Error::InvalidColumnType(
            idx,
            "source_text".to_string(),
            other.data_type(),
        )),
    }
}

fn script_source_text_json(bytes: &[u8], encoding: &str) -> Value {
    if encoding == "base64" {
        Value::from(B64.encode(bytes))
    } else {
        Value::from(String::from_utf8_lossy(bytes).into_owned())
    }
}

pub(crate) fn script_source(
    storage_root: Option<PathBuf>,
    project_key: &str,
    place: Option<&str>,
    path: &str,
) -> Result<Value> {
    let storage = Storage::new(storage_root, project_key)?;
    let place_storage = resolve_place(&storage, place)?;
    let conn = open_db_readonly(&place_storage.db_path)?;

    let live = current_state(&conn)?;
    let capture_id = live.capture_id.clone();
    let path_norm = normalize_query_path(path);

    let instance_id: Option<String> = conn
        .query_row(
            "SELECT instance_id FROM instances WHERE capture_id = ? AND path_norm = ?",
            params![capture_id, path_norm],
            |row| row.get(0),
        )
        .optional()?;

    let Some(instance_id) = instance_id else {
        return Ok(json!({ "ok": false, "error": "not_found" }));
    };

    let row: Option<(Vec<u8>, String, String)> = conn
        .query_row(
            "SELECT source_text, source_hash, COALESCE(source_encoding, 'utf8')
             FROM script_sources WHERE capture_id = ? AND instance_id = ?",
            params![capture_id, instance_id],
            |row| {
                Ok((
                    read_source_bytes(row, 0)?,
                    row.get(1)?,
                    row.get(2)?,
                ))
            },
        )
        .optional()?;

    let Some((source_bytes, source_hash, source_encoding)) = row else {
        return Ok(json!({ "ok": false, "error": "no_source" }));
    };

    Ok(json!({
        "ok": true,
        "path": path,
        "instanceId": instance_id,
        "sourceText": script_source_text_json(&source_bytes, &source_encoding),
        "sourceHash": source_hash,
        "sourceEncoding": source_encoding,
    }))
}

pub(crate) fn script_sources(
    storage_root: Option<PathBuf>,
    project_key: &str,
    place: Option<&str>,
) -> Result<Value> {
    let storage = Storage::new(storage_root, project_key)?;
    let place_storage = resolve_place(&storage, place)?;
    let conn = open_db_readonly(&place_storage.db_path)?;

    let live = current_state(&conn)?;
    let capture_id = live.capture_id.clone();

    let mut stmt = conn.prepare(
        "SELECT i.path, s.instance_id, s.source_hash
         FROM script_sources s
         JOIN instances i ON i.capture_id = s.capture_id AND i.instance_id = s.instance_id
         WHERE s.capture_id = ?
         ORDER BY i.path",
    )?;
    let rows = stmt.query_map([&capture_id], |row| {
        Ok(json!({
            "path": row.get::<_, String>(0)?,
            "instanceId": row.get::<_, String>(1)?,
            "sourceHash": row.get::<_, String>(2)?,
        }))
    })?;

    let mut entries = Vec::new();
    for row in rows {
        entries.push(row?);
    }

    Ok(json!({
        "ok": true,
        "count": entries.len(),
        "entries": entries,
    }))
}

#[allow(dead_code)]
pub(crate) fn live_fingerprint(
    storage_root: Option<PathBuf>,

    project_key: &str,

    place: Option<&str>,
) -> Result<Value> {
    let storage = Storage::new(storage_root, project_key)?;

    let place_storage = resolve_place(&storage, place)?;

    let conn = open_db(&place_storage.db_path)?;

    init_schema(&conn)?;

    let live = current_state(&conn)?;

    Ok(json!({

        "ok": true,

        "revision": live.revision,

        "fingerprint": live.fingerprint,

        "instanceCount": live.instance_count,

    }))
}

#[allow(dead_code)]
pub(crate) fn promote_staging_baseline(
    conn: &mut Connection,

    snapshot: &Value,

    meta: &crate::storage::CaptureMeta,

    raw_bytes: &[u8],
) -> Result<LiveState> {
    let now = now_utc();

    let tx = conn.transaction()?;

    delete_all_tables(&tx)?;

    ingest_rows(&tx, snapshot, meta)?;

    tx.commit()?;

    let fingerprint = fingerprint_state(conn, &meta.capture_id)?;

    let live_state = LiveState {
        capture_id: meta.capture_id.clone(),

        place_id: meta.place_id.clone(),

        place_key: meta.place_key.clone(),

        place_name: meta.place_name.clone(),

        game_id: meta.game_id,

        revision: 0,

        baseline_at_utc: meta.created_at_utc.clone(),

        updated_at_utc: now.clone(),

        baseline_hash: meta.raw_sha256.clone(),

        fingerprint,

        instance_count: meta.instance_count,
    };

    write_live_state(conn, &live_state)?;

    let _ = raw_bytes;

    Ok(live_state)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::{init_schema, upsert_script_source, upsert_script_source_bytes};
    use crate::util::open_db;
    use serde_json::json;

    #[test]
    fn script_sources_readonly_on_wal_secondary_connection() {
        let dir = std::env::temp_dir().join(format!("ss_script_ro_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let db_path = dir.join("place.db");
        let mut writer = open_db(&db_path).unwrap();
        init_schema(&writer).unwrap();
        let tx = writer.transaction().unwrap();
        upsert_script_source(&tx, "cap1", "utf8mod", "return 1\n", "hash_utf8", "utf8").unwrap();
        let raw = vec![1u8, 2, 3, 4, 5];
        upsert_script_source_bytes(&tx, "cap1", "binmod", &raw, "hash_bin", "base64").unwrap();
        tx.commit().unwrap();
        // Writer stays open (simulates serve holding WAL).
        let reader = open_db_readonly(&db_path).unwrap();
        let utf8: (Vec<u8>, String, String) = reader
            .query_row(
                "SELECT source_text, source_hash, COALESCE(source_encoding, 'utf8')
                 FROM script_sources WHERE capture_id = ? AND instance_id = ?",
                params!["cap1", "utf8mod"],
                |row| {
                    Ok((
                        read_source_bytes(row, 0)?,
                        row.get(1)?,
                        row.get(2)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(utf8.0, b"return 1\n");
        assert_eq!(utf8.1, "hash_utf8");
        assert_eq!(utf8.2, "utf8");
        let bin: (Vec<u8>, String, String) = reader
            .query_row(
                "SELECT source_text, source_hash, COALESCE(source_encoding, 'utf8')
                 FROM script_sources WHERE capture_id = ? AND instance_id = ?",
                params!["cap1", "binmod"],
                |row| {
                    Ok((
                        read_source_bytes(row, 0)?,
                        row.get(1)?,
                        row.get(2)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(bin.0, raw);
        assert_eq!(bin.1, "hash_bin");
        assert_eq!(bin.2, "base64");
        assert_eq!(
            script_source_text_json(&utf8.0, &utf8.2),
            json!("return 1\n")
        );
        assert_eq!(
            script_source_text_json(&bin.0, &bin.2),
            json!(B64.encode(&raw))
        );
    }

    #[test]
    fn xor_fingerprint_fold_is_commutative() {
        let a = [1u8; 32];

        let b = [2u8; 32];

        let mut ab = a;

        for (i, byte) in b.iter().enumerate() {
            ab[i] ^= byte;
        }

        let mut ba = b;

        for (i, byte) in a.iter().enumerate() {
            ba[i] ^= byte;
        }

        assert_eq!(ab, ba);
    }
}
