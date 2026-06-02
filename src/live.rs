use std::collections::BTreeSet;

use std::path::PathBuf;

use anyhow::{Result, anyhow};

use rusqlite::{Connection, OptionalExtension, Transaction, params};

use serde_json::{Value, json};

use crate::capture::{
    canonical_instance_value, capture_meta, delete_instance_rows, fingerprint_instance,
    fingerprint_state, ingest_rows, recompute_critical_presence_from_db, recompute_findings,
    upsert_instance,
};

use crate::storage::{
    LiveState, Storage, current_state, delete_all_tables, init_schema, read_live_state,
    resolve_place, write_live_state,
};

use crate::util::{hex_bytes, make_id, now_utc, open_db, str_field};

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
    if hex.len() != 64 {
        return Err(anyhow!("invalid fingerprint hex length"));
    }

    let mut out = [0u8; 32];

    for (i, chunk) in hex.as_bytes().chunks(2).enumerate() {
        let s = std::str::from_utf8(chunk)?;

        out[i] = u8::from_str_radix(s, 16)?;
    }

    Ok(out)
}

fn fingerprint_hex(acc: [u8; 32]) -> String {
    hex_bytes(&acc)
}

pub(crate) fn apply_delta(
    storage_root: Option<PathBuf>,

    project_key: &str,

    place: Option<&str>,

    request: &DeltaRequest,
) -> Result<Value> {
    let storage = Storage::new(storage_root, project_key)?;

    let place_storage = resolve_place(&storage, place)?;

    let mut conn = open_db(&place_storage.db_path)?;

    init_schema(&conn)?;

    let live = read_live_state(&conn)?;

    let Some(live) = live else {
        return Ok(json!({ "ok": false, "error": "no_baseline" }));
    };

    if request.base_revision != live.revision {
        eprintln!(
            "[studio-stud] delta rejected: revision_mismatch place={} base={} live={}",
            request.place_id, request.base_revision, live.revision
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

    apply_delta_tx(&tx, &capture_id, request, &mut acc)?;

    if !request.removed.is_empty() || !request.upserted.is_empty() {
        eprintln!(
            "[studio-stud] delta applied: place={} rev {}→{} removed={} upserted={}",
            request.place_id,
            live.revision,
            live.revision + 1,
            request.removed.len(),
            request.upserted.len()
        );
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
}

fn apply_delta_tx(
    tx: &Transaction<'_>,

    capture_id: &str,

    request: &DeltaRequest,

    acc: &mut [u8; 32],
) -> Result<()> {
    for removed_id in &request.removed {
        if let Ok(digest) = fingerprint_instance(tx, capture_id, removed_id) {
            for (i, byte) in digest.iter().enumerate() {
                acc[i] ^= byte;
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

        let old_class: Option<String> = tx
            .query_row(
                "SELECT class_name FROM instances WHERE capture_id = ? AND instance_id = ?",
                params![capture_id, id],
                |row| row.get(0),
            )
            .optional()?;

        if let Ok(digest) = fingerprint_instance(tx, capture_id, &id) {
            for (i, byte) in digest.iter().enumerate() {
                acc[i] ^= byte;
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

        let digest = fingerprint_instance(tx, capture_id, &id)?;

        for (i, byte) in digest.iter().enumerate() {
            acc[i] ^= byte;
        }
    }

    recompute_critical_presence_from_db(tx, capture_id)?;

    recompute_findings(tx, capture_id)?;

    Ok(())
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
