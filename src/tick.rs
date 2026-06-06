use std::collections::BTreeMap;
use std::path::PathBuf;

use anyhow::{Result, anyhow};
use rusqlite::{params, Transaction};
use serde_json::{Value, json};

use crate::capture::{
    decode_raw_snapshot, inject_sync_metadata, materialize_snapshot, parse_fp_hex,
};
use crate::conn_registry::ConnRegistry;
use crate::live::{apply_delta_tx, parse_delta_request, DeltaRequest};
use crate::storage::{read_live_state, resolve_place, set_active_place, Storage};
use crate::util::{hex_bytes, now_utc};

pub(crate) struct TickRequest {
    pub place_id: String,
    pub session_mode: String,
    pub base_revision: i64,
    pub service_fingerprints: BTreeMap<String, String>,
    pub delta: DeltaRequest,
    pub bulk_ref: Option<String>,
}

pub(crate) fn parse_tick_request(value: &Value) -> Result<TickRequest> {
    let delta = parse_delta_request(value)?;
    let session_mode = value
        .get("sessionMode")
        .and_then(Value::as_str)
        .unwrap_or("edit")
        .to_string();
    let service_fingerprints = value
        .get("serviceFingerprints")
        .and_then(Value::as_object)
        .map(|obj| {
            obj.iter()
                .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
                .collect()
        })
        .unwrap_or_default();
    let bulk_ref = value.get("bulkRef").and_then(|v| {
        if v.is_null() {
            None
        } else {
            v.as_str().map(str::to_string)
        }
    });

    Ok(TickRequest {
        place_id: delta.place_id.clone(),
        session_mode,
        base_revision: delta.base_revision,
        service_fingerprints,
        delta,
        bulk_ref,
    })
}

fn ops_empty(tick: &TickRequest) -> bool {
    tick.delta.upserted.is_empty() && tick.delta.removed.is_empty()
}

fn service_fps_match(
    conn: &rusqlite::Connection,
    capture_id: &str,
    request_fps: &BTreeMap<String, String>,
) -> Result<bool> {
    let stored = read_service_fps(conn, capture_id)?;
    Ok(stored == *request_fps)
}

fn read_service_fps(
    conn: &rusqlite::Connection,
    capture_id: &str,
) -> Result<BTreeMap<String, String>> {
    let mut stmt = conn.prepare(
        "SELECT service_name, fingerprint FROM service_fingerprints WHERE capture_id = ?",
    )?;
    let rows = stmt.query_map([capture_id], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    })?;
    let mut stored = BTreeMap::new();
    for row in rows {
        let (name, fp) = row?;
        stored.insert(name, fp);
    }
    Ok(stored)
}

pub(crate) fn compute_drift_services(
    conn: &rusqlite::Connection,
    capture_id: &str,
    request_fps: &BTreeMap<String, String>,
) -> Result<Vec<String>> {
    let stored = read_service_fps(conn, capture_id)?;
    let mut all: BTreeMap<String, ()> = BTreeMap::new();
    for k in stored.keys() {
        all.insert(k.clone(), ());
    }
    for k in request_fps.keys() {
        all.insert(k.clone(), ());
    }
    let mut drift = Vec::new();
    for service in all.keys() {
        match (stored.get(service), request_fps.get(service)) {
            (Some(a), Some(b)) if a == b => {}
            _ => drift.push(service.clone()),
        }
    }
    drift.sort();
    Ok(drift)
}

pub(crate) fn tick_response(
    revision: i64,
    instance_count: i64,
    drift_services: Vec<String>,
    request: Value,
) -> Value {
    json!({
        "ok": true,
        "revision": revision,
        "instanceCount": instance_count,
        "driftServices": drift_services,
        "request": request,
        "applyScripts": [],
    })
}

fn commit_staged_bulk(
    bytes: &[u8],
    sync_id: &str,
    storage_root: Option<PathBuf>,
    project_key: &str,
    registry: &ConnRegistry,
) -> Result<()> {
    let raw_json = decode_raw_snapshot(bytes)?;
    let mut snapshot: Value = serde_json::from_str(&raw_json)?;
    inject_sync_metadata(&mut snapshot, sync_id, None);
    let result = materialize_snapshot(&snapshot, storage_root.clone(), project_key, registry)?;
    if let Ok(storage) = Storage::new(storage_root, project_key)
        && let Some(place_id) = result.get("placeId").and_then(Value::as_str)
    {
        set_active_place(&storage, place_id);
    }
    Ok(())
}

fn update_live_after_ops(
    tx: &Transaction<'_>,
    capture_id: &str,
    live: &crate::storage::LiveState,
    acc: [u8; 32],
) -> Result<(i64, i64)> {
    let instance_count: i64 = tx.query_row(
        "SELECT COUNT(*) FROM instances WHERE capture_id = ?",
        [capture_id],
        |row| row.get(0),
    )?;
    let new_revision = live.revision + 1;
    let updated_at = now_utc();
    let fingerprint = hex_bytes(&acc);
    tx.execute(
        "UPDATE live_state SET revision = ?, updated_at_utc = ?, fingerprint = ?, instance_count = ? WHERE id = 1",
        params![new_revision, updated_at, fingerprint, instance_count],
    )?;
    Ok((new_revision, instance_count))
}

pub(crate) fn handle_tick(
    storage_root: Option<PathBuf>,
    project_key: &str,
    place: Option<&str>,
    tick: &TickRequest,
    staged_bulk: Option<&[u8]>,
    registry: &ConnRegistry,
    pending_request: Value,
    ignore_ops: bool,
) -> Result<Value> {
    let storage = Storage::new(storage_root.clone(), project_key)?;
    let place_storage = resolve_place(&storage, place)?;

    if ops_empty(tick) && tick.bulk_ref.is_none() {
        if ignore_ops {
            return Ok(tick_response(0, 0, vec![], pending_request));
        }
        if !place_storage.db_path.exists() {
            return Ok(json!({ "ok": false, "error": "no_baseline" }));
        }
        let quick = registry.with_reader(&place_storage.db_path, |conn| {
            let Some(live) = read_live_state(conn)? else {
                return Ok(json!({ "ok": false, "error": "no_baseline" }));
            };
            if service_fps_match(conn, &live.capture_id, &tick.service_fingerprints)? {
                return Ok(tick_response(
                    live.revision,
                    live.instance_count as i64,
                    vec![],
                    pending_request.clone(),
                ));
            }
            Ok(Value::Null)
        })?;
        if !quick.is_null() {
            return Ok(quick);
        }
    }

    if let Some(ref sync_id) = tick.bulk_ref {
        let bytes = staged_bulk.ok_or_else(|| anyhow!("unknown bulkRef: {sync_id}"))?;
        commit_staged_bulk(bytes, sync_id, storage_root.clone(), project_key, registry)?;
    }

    registry.with_writer(&place_storage.db_path, |conn| {
        let Some(live) = read_live_state(conn)? else {
            return Ok(json!({ "ok": false, "error": "no_baseline" }));
        };

        let mut acc = parse_fp_hex(&live.fingerprint)?;
        let mut revision = live.revision;
        let mut instance_count = live.instance_count as i64;

        if !ignore_ops && (!tick.delta.removed.is_empty() || !tick.delta.upserted.is_empty()) {
            if tick.base_revision != live.revision {
                return Ok(json!({
                    "ok": false,
                    "error": "revision_mismatch",
                    "revision": live.revision,
                }));
            }
            let tx = conn.transaction()?;
            apply_delta_tx(&tx, &live.capture_id, &tick.delta, &mut acc)?;
            (revision, instance_count) =
                update_live_after_ops(&tx, &live.capture_id, &live, acc)?;
            tx.commit()?;
        }

        let drift = compute_drift_services(conn, &live.capture_id, &tick.service_fingerprints)?;
        Ok(tick_response(
            revision,
            instance_count,
            drift,
            pending_request,
        ))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::capture::ingest_rows;
    use crate::storage::{init_schema, write_live_state, CaptureMeta, LiveState};
    use crate::util::open_db;
    use serde_json::json;

    fn seed_baseline(conn: &mut rusqlite::Connection) -> LiveState {
        init_schema(conn).unwrap();
        let snapshot = json!({
            "place": { "placeId": "999001", "placeKey": "T", "name": "T" },
            "sync": { "syncId": "s1" },
            "instances": [
                { "id": "ws", "parentId": null, "path": "Workspace", "name": "Workspace",
                  "className": "Workspace", "depth": 0, "childCount": 1, "siblingIndex": 0,
                  "duplicateSiblingName": false, "properties": {}, "attributes": {}, "tags": [] },
                { "id": "p1", "parentId": "ws", "path": "Workspace/Part", "name": "Part",
                  "className": "Part", "depth": 1, "childCount": 0, "siblingIndex": 0,
                  "duplicateSiblingName": false, "properties": {}, "attributes": {}, "tags": [] }
            ]
        });
        let meta = CaptureMeta {
            capture_id: "cap1".to_string(),
            place_id: "999001".to_string(),
            place_key: "T".to_string(),
            place_name: "T".to_string(),
            game_id: None,
            created_at_utc: "2020-01-01T00:00:00Z".to_string(),
            sync_started_at_utc: None,
            sync_finished_at_utc: None,
            plugin_version: None,
            raw_sha256: "abc".to_string(),
            instance_count: 2,
        };
        let tx = conn.transaction().unwrap();
        let fp = ingest_rows(&tx, &snapshot, &meta).unwrap();
        tx.commit().unwrap();
        let live = LiveState {
            capture_id: meta.capture_id,
            place_id: meta.place_id,
            place_key: meta.place_key,
            place_name: meta.place_name,
            game_id: None,
            revision: 0,
            baseline_at_utc: meta.created_at_utc.clone(),
            updated_at_utc: meta.created_at_utc,
            baseline_hash: meta.raw_sha256,
            fingerprint: fp,
            instance_count: 2,
        };
        write_live_state(conn, &live).unwrap();
        live
    }

    #[test]
    fn compute_drift_services_detects_mismatch() {
        let drift_db = std::env::temp_dir().join(format!("ss_tick_drift_{}.db", std::process::id()));
        let mut conn = open_db(&drift_db).unwrap();
        let live = seed_baseline(&mut conn);
        let mut wrong = read_service_fps(&conn, &live.capture_id).unwrap();
        if let Some(fp) = wrong.get_mut("Workspace") {
            *fp = "0".repeat(64);
        }
        let drift = compute_drift_services(&conn, &live.capture_id, &wrong).unwrap();
        assert!(drift.contains(&"Workspace".to_string()));
    }

    #[test]
    fn fp_xor_invariant_after_plugin_fps() {
        let xor_db = std::env::temp_dir().join(format!("ss_tick_xor_{}.db", std::process::id()));
        let mut conn = open_db(&xor_db).unwrap();
        let live = seed_baseline(&mut conn);
        let inst_fp = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let inst = json!({
            "id": "p2", "parentId": "ws", "path": "Workspace/New", "name": "New",
            "className": "Part", "depth": 1, "childCount": 0, "siblingIndex": 1,
            "duplicateSiblingName": false, "properties": {}, "attributes": {}, "tags": [],
            "fp": inst_fp
        });
        let mut acc = parse_fp_hex(&live.fingerprint).unwrap();
        let tx = conn.transaction().unwrap();
        apply_delta_tx(
            &tx,
            &live.capture_id,
            &DeltaRequest {
                place_id: "999001".to_string(),
                base_revision: 0,
                upserted: vec![inst.clone()],
                removed: vec![],
            },
            &mut acc,
        )
        .unwrap();
        update_live_after_ops(&tx, &live.capture_id, &live, acc).unwrap();
        tx.commit().unwrap();

        let row_fp: String = conn
            .query_row(
                "SELECT fingerprint FROM instances WHERE capture_id = ? AND instance_id = ?",
                params![live.capture_id, "p2"],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(row_fp, inst_fp);

        let stored = read_service_fps(&conn, &live.capture_id).unwrap();
        let mut xor_acc = [0u8; 32];
        for fp_hex in stored.values() {
            let d = parse_fp_hex(fp_hex).unwrap();
            for (i, b) in d.iter().enumerate() {
                xor_acc[i] ^= b;
            }
        }
        let global: String = conn
            .query_row(
                "SELECT fingerprint FROM live_state WHERE id = 1",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(global, hex_bytes(&xor_acc));
    }

    #[test]
    fn empty_tick_short_circuit_uses_reader_not_writer() {
        let storage_root =
            std::env::temp_dir().join(format!("ss_tick_empty_{}", std::process::id()));
        let place_dir = storage_root.join("default").join("places").join("999001");
        std::fs::create_dir_all(&place_dir).unwrap();
        let db = place_dir.join("syncs.db");
        let mut conn = open_db(&db).unwrap();
        let live = seed_baseline(&mut conn);
        drop(conn);

        let registry = ConnRegistry::new();
        let fps = read_service_fps(&open_db(&db).unwrap(), &live.capture_id).unwrap();
        let tick = TickRequest {
            place_id: "999001".to_string(),
            session_mode: "edit".to_string(),
            base_revision: 0,
            service_fingerprints: fps,
            delta: DeltaRequest {
                place_id: "999001".to_string(),
                base_revision: 0,
                upserted: vec![],
                removed: vec![],
            },
            bulk_ref: None,
        };
        let writers_before = registry.writer_acquire_count();
        let readers_before = registry.reader_acquire_count();
        let updated_before: String = open_db(&db)
            .unwrap()
            .query_row(
                "SELECT updated_at_utc FROM live_state WHERE id = 1",
                [],
                |row| row.get(0),
            )
            .unwrap();
        handle_tick(
            Some(storage_root),
            "default",
            Some("999001"),
            &tick,
            None,
            &registry,
            Value::Null,
            false,
        )
        .unwrap();
        assert_eq!(registry.writer_acquire_count(), writers_before);
        assert!(registry.reader_acquire_count() > readers_before);
        let updated_after: String = open_db(&db)
            .unwrap()
            .query_row(
                "SELECT updated_at_utc FROM live_state WHERE id = 1",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(updated_before, updated_after);
    }
}
