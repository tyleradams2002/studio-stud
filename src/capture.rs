use std::{collections::BTreeMap, env, fs, io::{Read, Write}, path::PathBuf};



use anyhow::{Result, anyhow};

use flate2::{Compression, read::GzDecoder, write::GzEncoder};

use rusqlite::{Connection, Transaction, params};

use serde_json::{Value, json};

use sha2::{Digest, Sha256};



use crate::storage::{

    CaptureMeta, LiveState, Storage, delete_all_tables, init_schema, write_live_state,

};

use crate::util::{

    CRITICAL_NAMES, DEFAULT_PROJECT_KEY, build_search_text, hex_bytes, looks_like_invisible_helper,

    matches_keyword, normalize_query_path, now_utc, open_db, opt_str_field, path_root, safe_key,

    str_field, value_to_string,

};



pub(crate) fn materialize_snapshot(

    snapshot: &Value,

    storage_root: Option<PathBuf>,

    project_key: &str,

) -> Result<Value> {

    let storage = Storage::new(storage_root, project_key)?;

    let raw_bytes = encode_gzip_json(snapshot)?;

    let meta = capture_meta(snapshot, &raw_bytes)?;

    let place = storage.place(&meta.place_id);

    fs::create_dir_all(&place.place_dir)?;



    let mut conn = open_db(&place.db_path)?;

    init_schema(&conn)?;



    let now = now_utc();

    let tx = conn.transaction()?;

    delete_all_tables(&tx)?;

    ingest_rows(&tx, snapshot, &meta)?;

    tx.commit()?;



    let fingerprint = fingerprint_state(&conn, &meta.capture_id)?;

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

    write_live_state(&conn, &live_state)?;



    fs::write(&place.baseline_path, &raw_bytes)?;



    Ok(json!({

        "ok": true,

        "captureId": meta.capture_id,

        "placeId": meta.place_id,

        "placeKey": meta.place_key,

        "instances": meta.instance_count,

        "revision": live_state.revision,

        "stored": true,

    }))

}



pub(crate) fn decode_raw_snapshot(bytes: &[u8]) -> Result<String> {

    let mut decoder = GzDecoder::new(bytes);

    let mut text = String::new();

    match decoder.read_to_string(&mut text) {

        Ok(_) => Ok(text),

        Err(_) => Ok(String::from_utf8(bytes.to_vec())?),

    }

}



fn encode_gzip_json(value: &Value) -> Result<Vec<u8>> {

    let mut encoder = GzEncoder::new(Vec::new(), Compression::default());

    encoder.write_all(serde_json::to_string(value)?.as_bytes())?;

    Ok(encoder.finish()?)

}



pub(crate) fn inject_sync_metadata(snapshot: &mut Value, sync_id: &str, request_id: Option<&str>) {

    if !snapshot.get("sync").is_some_and(Value::is_object) {

        snapshot["sync"] = json!({});

    }

    if let Some(sync) = snapshot.get_mut("sync").and_then(Value::as_object_mut) {

        sync.insert("syncId".to_string(), json!(sync_id));

        sync.insert("finishedAtUtc".to_string(), json!(now_utc()));

        if let Some(request_id) = request_id {

            sync.insert("requestId".to_string(), json!(request_id));

        }

    }

}



pub(crate) fn capture_meta(snapshot: &Value, raw_bytes: &[u8]) -> Result<CaptureMeta> {

    let place = snapshot

        .get("place")

        .and_then(Value::as_object)

        .ok_or_else(|| anyhow!("snapshot.place missing"))?;

    let sync = snapshot.get("sync").and_then(Value::as_object);

    let place_id = value_to_string(place.get("placeId")).unwrap_or_else(|| "0".into());

    let place_key = place

        .get("placeKey")

        .and_then(Value::as_str)

        .map(str::to_string)

        .unwrap_or_else(|| format!("Place{place_id}"));

    let place_name = place

        .get("name")

        .and_then(Value::as_str)

        .unwrap_or(&place_key)

        .to_string();

    let mut hasher = Sha256::new();

    hasher.update(raw_bytes);

    let raw_sha256 = hex_bytes(&hasher.finalize());

    let now = now_utc();

    let capture_id = sync

        .and_then(|item| item.get("syncId"))

        .and_then(Value::as_str)

        .map(safe_key)

        .unwrap_or_else(|| {

            format!(

                "{}_{}",

                now.replace(['-', ':', 'T', 'Z'], ""),

                &raw_sha256[..12]

            )

        });

    let instance_count = snapshot

        .get("instances")

        .and_then(Value::as_array)

        .map(Vec::len)

        .unwrap_or_default();

    Ok(CaptureMeta {

        capture_id,

        place_id,

        place_key,

        place_name,

        game_id: place.get("gameId").and_then(Value::as_i64),

        created_at_utc: now,

        sync_started_at_utc: sync

            .and_then(|item| item.get("startedAtUtc"))

            .and_then(Value::as_str)

            .map(str::to_string),

        sync_finished_at_utc: sync

            .and_then(|item| item.get("finishedAtUtc"))

            .and_then(Value::as_str)

            .map(str::to_string),

        plugin_version: snapshot

            .get("pluginVersion")

            .and_then(Value::as_str)

            .map(str::to_string),

        raw_sha256,

        instance_count,

    })

}



/// Full ingest used by bench (in-memory) and baseline materialize.
pub(crate) fn ingest_sqlite(conn: &mut Connection, snapshot: &Value, meta: &CaptureMeta) -> Result<()> {

    let tx = conn.transaction()?;

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

            [&meta.capture_id],

        )?;

    }

    ingest_rows(&tx, snapshot, meta)?;

    tx.commit()?;

    Ok(())

}



pub(crate) fn ingest_rows(tx: &Transaction<'_>, snapshot: &Value, meta: &CaptureMeta) -> Result<()> {

    tx.execute(

        "INSERT INTO captures (

            capture_id, request_id, project_key, place_id, place_key, place_name, game_id,

            created_at_utc, sync_started_at_utc, sync_finished_at_utc, plugin_version,

            daemon_version, protocol_version, status, raw_sha256, instance_count

        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",

        params![

            meta.capture_id,

            Value::Null.to_string(),

            DEFAULT_PROJECT_KEY,

            meta.place_id,

            meta.place_key,

            meta.place_name,

            meta.game_id,

            meta.created_at_utc,

            meta.sync_started_at_utc,

            meta.sync_finished_at_utc,

            meta.plugin_version,

            env!("CARGO_PKG_VERSION"),

            crate::util::SCHEMA_VERSION,

            "completed",

            meta.raw_sha256,

            meta.instance_count as i64,

        ],

    )?;



    let instances = snapshot

        .get("instances")

        .and_then(Value::as_array)

        .ok_or_else(|| anyhow!("snapshot.instances missing"))?;

    let mut class_counts: BTreeMap<String, i64> = BTreeMap::new();

    let mut path_blob = String::new();

    let mut finding_state = FindingState::default();



    for inst in instances {

        let class_name = str_field(inst, "className");

        *class_counts.entry(class_name).or_default() += 1;

        let path = str_field(inst, "path");

        path_blob.push_str(&path);

        path_blob.push(' ');

        upsert_instance(tx, &meta.capture_id, inst)?;

        update_findings(&mut finding_state, inst);

    }



    for (class_name, count) in class_counts {

        tx.execute(

            "INSERT INTO class_counts (capture_id, class_name, count) VALUES (?, ?, ?)",

            params![meta.capture_id, class_name, count],

        )?;

    }

    recompute_critical_presence(tx, &meta.capture_id, &path_blob)?;

    insert_findings(tx, &meta.capture_id, finding_state)?;

    Ok(())

}



pub(crate) fn delete_instance_rows(tx: &Transaction<'_>, capture_id: &str, instance_id: &str) -> Result<()> {

    for table in [

        "finding_samples",

        "instance_tags",

        "instance_attributes",

        "instance_properties",

        "keyword_hits",

        "instances",

    ] {

        tx.execute(

            &format!("DELETE FROM {table} WHERE capture_id = ? AND instance_id = ?"),

            params![capture_id, instance_id],

        )?;

    }

    Ok(())

}



pub(crate) fn upsert_instance(tx: &Transaction<'_>, capture_id: &str, inst: &Value) -> Result<()> {

    let id = str_field(inst, "id");

    let path = str_field(inst, "path");

    if id.is_empty() || path.is_empty() {

        return Err(anyhow!("instance id and path required"));

    }

    delete_instance_rows(tx, capture_id, &id)?;



    let display_path = opt_str_field(inst, "displayPath");

    let name = str_field(inst, "name");

    let class_name = str_field(inst, "className");

    let parent_id = opt_str_field(inst, "parentId");

    let depth = inst.get("depth").and_then(Value::as_i64);

    let child_count = inst.get("childCount").and_then(Value::as_i64);

    let sibling_index = inst.get("siblingIndex").and_then(Value::as_i64);

    let duplicate = inst

        .get("duplicateSiblingName")

        .and_then(Value::as_bool)

        .unwrap_or(false);

    let properties = inst.get("properties").cloned().unwrap_or_else(|| json!({}));

    let attributes = inst.get("attributes").cloned().unwrap_or_else(|| json!({}));

    let tags = inst.get("tags").cloned().unwrap_or_else(|| json!([]));

    let path_norm = normalize_query_path(&path);

    let display_path_norm = display_path

        .as_deref()

        .map(normalize_query_path)

        .unwrap_or_default();

    let search_text = build_search_text(&path, display_path.as_deref(), &name, &class_name);



    tx.execute(

        "INSERT INTO instances (

            capture_id, instance_id, parent_id, path, path_norm, display_path, display_path_norm,

            name, class_name, search_text, depth, child_count, sibling_index,

            duplicate_sibling_name, property_json

        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",

        params![

            capture_id,

            id,

            parent_id,

            path,

            path_norm,

            display_path,

            display_path_norm,

            name,

            class_name,

            search_text,

            depth,

            child_count,

            sibling_index,

            duplicate as i64,

            serde_json::to_string(&properties)?,

        ],

    )?;



    if let Some(props) = properties.as_object() {

        for (prop_name, value) in props {

            tx.execute(

                "INSERT INTO instance_properties (capture_id, instance_id, property_name, value_json) VALUES (?, ?, ?, ?)",

                params![capture_id, id, prop_name, serde_json::to_string(value)?],

            )?;

        }

    }

    if let Some(attrs) = attributes.as_object() {

        for (attr_name, value) in attrs {

            tx.execute(

                "INSERT INTO instance_attributes (capture_id, instance_id, attribute_name, value_json) VALUES (?, ?, ?, ?)",

                params![capture_id, id, attr_name, serde_json::to_string(value)?],

            )?;

        }

    }

    if let Some(tag_values) = tags.as_array() {

        for tag in tag_values.iter().filter_map(Value::as_str) {

            tx.execute(

                "INSERT INTO instance_tags (capture_id, instance_id, tag) VALUES (?, ?, ?)",

                params![capture_id, id, tag],

            )?;

        }

    }

    if matches_keyword(&format!("{path} {name} {class_name}")) {

        tx.execute(

            "INSERT INTO keyword_hits (capture_id, instance_id, path, name, class_name) VALUES (?, ?, ?, ?, ?)",

            params![capture_id, id, path, name, class_name],

        )?;

    }

    Ok(())

}



pub(crate) fn recompute_critical_presence(

    tx: &Transaction<'_>,

    capture_id: &str,

    path_blob: &str,

) -> Result<()> {

    tx.execute(

        "DELETE FROM critical_presence WHERE capture_id = ?",

        [capture_id],

    )?;

    for critical in CRITICAL_NAMES {

        tx.execute(

            "INSERT INTO critical_presence (capture_id, critical_name, present) VALUES (?, ?, ?)",

            params![capture_id, *critical, path_blob.contains(critical) as i64],

        )?;

    }

    Ok(())

}



pub(crate) fn recompute_critical_presence_from_db(tx: &Transaction<'_>, capture_id: &str) -> Result<()> {

    let mut path_blob = String::new();

    let mut stmt = tx.prepare("SELECT path FROM instances WHERE capture_id = ?")?;

    let rows = stmt.query_map([capture_id], |row| row.get::<_, String>(0))?;

    for row in rows {

        path_blob.push_str(&row?);

        path_blob.push(' ');

    }

    recompute_critical_presence(tx, capture_id, &path_blob)

}



pub(crate) fn fingerprint_state(conn: &Connection, capture_id: &str) -> Result<String> {

    let mut stmt = conn.prepare(

        "SELECT instance_id FROM instances WHERE capture_id = ? ORDER BY instance_id",

    )?;

    let rows = stmt.query_map([capture_id], |row| row.get::<_, String>(0))?;

    let mut acc = [0u8; 32];

    for row in rows {

        let id = row?;

        let digest = fingerprint_instance(conn, capture_id, &id)?;

        for (i, byte) in digest.iter().enumerate() {

            acc[i] ^= byte;

        }

    }

    Ok(hex_bytes(&acc))

}



pub(crate) fn fingerprint_instance(

    conn: &Connection,

    capture_id: &str,

    instance_id: &str,

) -> Result<[u8; 32]> {

    let canonical = canonical_instance_value(conn, capture_id, instance_id)?;

    let mut hasher = Sha256::new();

    hasher.update(serde_json::to_string(&canonical)?);

    let bytes: [u8; 32] = hasher.finalize().into();

    Ok(bytes)

}



pub(crate) fn canonical_instance_value(

    conn: &Connection,

    capture_id: &str,

    instance_id: &str,

) -> Result<Value> {

    let row = conn.query_row(

        "SELECT parent_id, path, name, class_name, depth, child_count, sibling_index, duplicate_sibling_name

         FROM instances WHERE capture_id = ? AND instance_id = ?",

        params![capture_id, instance_id],

        |row| {

            Ok((

                row.get::<_, Option<String>>(0)?,

                row.get::<_, String>(1)?,

                row.get::<_, String>(2)?,

                row.get::<_, String>(3)?,

                row.get::<_, Option<i64>>(4)?,

                row.get::<_, Option<i64>>(5)?,

                row.get::<_, Option<i64>>(6)?,

                row.get::<_, Option<i64>>(7)?,

            ))

        },

    )?;



    let mut props: BTreeMap<String, Value> = BTreeMap::new();

    let mut prop_stmt = conn.prepare(

        "SELECT property_name, value_json FROM instance_properties WHERE capture_id = ? AND instance_id = ? ORDER BY property_name",

    )?;

    for prop_row in prop_stmt.query_map(params![capture_id, instance_id], |row| {

        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))

    })? {

        let (name, value_json) = prop_row?;

        props.insert(name, serde_json::from_str(&value_json)?);

    }



    let mut attrs: BTreeMap<String, Value> = BTreeMap::new();

    let mut attr_stmt = conn.prepare(

        "SELECT attribute_name, value_json FROM instance_attributes WHERE capture_id = ? AND instance_id = ? ORDER BY attribute_name",

    )?;

    for attr_row in attr_stmt.query_map(params![capture_id, instance_id], |row| {

        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))

    })? {

        let (name, value_json) = attr_row?;

        attrs.insert(name, serde_json::from_str(&value_json)?);

    }



    let mut tags: Vec<Value> = Vec::new();

    let mut tag_stmt = conn.prepare(

        "SELECT tag FROM instance_tags WHERE capture_id = ? AND instance_id = ? ORDER BY tag",

    )?;

    for tag_row in tag_stmt.query_map(params![capture_id, instance_id], |row| {

        row.get::<_, String>(0)

    })? {

        tags.push(json!(tag_row?));

    }



    let (parent_id, path, name, class_name, depth, child_count, sibling_index, duplicate) = row;

    Ok(json!({

        "attributes": attrs,

        "childCount": child_count,

        "className": class_name,

        "depth": depth,

        "duplicateSiblingName": duplicate.map(|v| v != 0),

        "id": instance_id,

        "name": name,

        "parentId": parent_id,

        "path": path,

        "properties": props,

        "siblingIndex": sibling_index,

        "tags": tags,

    }))

}



#[derive(Default)]

struct FindingState {

    prompt_missing_text: Vec<Value>,

    duplicate_names: Vec<Value>,

    replicated_geometry: Vec<Value>,

    invisible_collidable: Vec<Value>,

    invisible_helpers: i64,

    union_count: i64,

}



fn update_findings(state: &mut FindingState, inst: &Value) {

    let class_name = str_field(inst, "className");

    let id = str_field(inst, "id");

    let path = str_field(inst, "path");

    let props = inst.get("properties").and_then(Value::as_object);

    if class_name == "UnionOperation" {

        state.union_count += 1;

    }

    if class_name == "ProximityPrompt" {

        let action = props

            .and_then(|item| item.get("ActionText"))

            .and_then(Value::as_str)

            .unwrap_or("");

        let object = props

            .and_then(|item| item.get("ObjectText"))

            .and_then(Value::as_str)

            .unwrap_or("");

        if action.is_empty() || object.is_empty() {

            state.prompt_missing_text.push(json!({

                "id": id,

                "path": path,

                "missingActionText": action.is_empty(),

                "missingObjectText": object.is_empty(),

            }));

        }

    }

    if inst

        .get("duplicateSiblingName")

        .and_then(Value::as_bool)

        .unwrap_or(false)

    {

        state

            .duplicate_names

            .push(json!({ "id": id, "path": path, "name": str_field(inst, "name") }));

    }

    if path_root(&path) == "ReplicatedStorage"

        && matches!(class_name.as_str(), "MeshPart" | "UnionOperation")

    {

        state

            .replicated_geometry

            .push(json!({ "id": id, "path": path, "className": class_name }));

    }

    if matches!(class_name.as_str(), "Part" | "MeshPart" | "UnionOperation") {

        let can_collide = props

            .and_then(|item| item.get("CanCollide"))

            .and_then(Value::as_bool)

            .unwrap_or(false);

        let transparency = props

            .and_then(|item| item.get("Transparency"))

            .and_then(Value::as_f64)

            .unwrap_or(0.0);

        if can_collide && transparency >= 0.95 {

            if looks_like_invisible_helper(&path) {

                state.invisible_helpers += 1;

            } else {

                state

                    .invisible_collidable

                    .push(json!({ "id": id, "path": path }));

            }

        }

    }

}



pub(crate) fn recompute_findings(tx: &Transaction<'_>, capture_id: &str) -> Result<()> {

    tx.execute(

        "DELETE FROM finding_samples WHERE capture_id = ?",

        [capture_id],

    )?;

    tx.execute("DELETE FROM findings WHERE capture_id = ?", [capture_id])?;



    let mut finding_state = FindingState::default();

    let mut stmt = tx.prepare(

        "SELECT instance_id, path, name, class_name, duplicate_sibling_name, property_json

         FROM instances WHERE capture_id = ?",

    )?;

    let rows = stmt.query_map([capture_id], |row| {

        Ok((

            row.get::<_, String>(0)?,

            row.get::<_, String>(1)?,

            row.get::<_, String>(2)?,

            row.get::<_, String>(3)?,

            row.get::<_, i64>(4)?,

            row.get::<_, String>(5)?,

        ))

    })?;

    for row in rows {

        let (id, path, name, class_name, duplicate, property_json) = row?;

        let properties: Value = serde_json::from_str(&property_json).unwrap_or(json!({}));

        let inst = json!({

            "id": id,

            "path": path,

            "name": name,

            "className": class_name,

            "duplicateSiblingName": duplicate != 0,

            "properties": properties,

        });

        update_findings(&mut finding_state, &inst);

    }

    insert_findings(tx, capture_id, finding_state)

}



fn insert_findings(

    tx: &Transaction<'_>,

    capture_id: &str,

    state: FindingState,

) -> Result<()> {

    add_finding(

        tx,

        capture_id,

        "prompts.missingText",

        "warning",

        "Prompt",

        &format!(

            "{} ProximityPrompt instances are missing ActionText or ObjectText.",

            state.prompt_missing_text.len()

        ),

        &state.prompt_missing_text,

    )?;

    add_finding(

        tx,

        capture_id,

        "identity.duplicateSiblingNames",

        "info",

        "Identity",

        &format!(

            "{} instances have duplicate sibling names; duplicate-safe paths are being used.",

            state.duplicate_names.len()

        ),

        &state.duplicate_names,

    )?;

    add_finding(

        tx,

        capture_id,

        "replication.bulkAssets",

        "info",

        "Replication",

        &format!(

            "{} MeshPart/UnionOperation instances are under ReplicatedStorage.",

            state.replicated_geometry.len()

        ),

        &state.replicated_geometry,

    )?;

    add_finding(

        tx,

        capture_id,

        "collision.invisibleCollidable",

        "warning",

        "Collision",

        &format!(

            "{} nearly invisible BaseParts are collidable.",

            state.invisible_collidable.len()

        ),

        &state.invisible_collidable,

    )?;

    if state.invisible_helpers > 0 {

        add_finding_count(

            tx,

            capture_id,

            "collision.invisibleHelperParts",

            "info",

            "Collision",

            &format!(

                "{} invisible collidable helper parts were recognized and excluded from collision warnings.",

                state.invisible_helpers

            ),

            state.invisible_helpers,

        )?;

    }

    if state.union_count > 1000 {

        add_finding_count(

            tx,

            capture_id,

            "performance.unionCount",

            "info",

            "Performance",

            &format!(

                "Snapshot contains {} UnionOperation instances.",

                state.union_count

            ),

            state.union_count,

        )?;

    }

    Ok(())

}



fn add_finding(

    tx: &Transaction<'_>,

    capture_id: &str,

    id: &str,

    severity: &str,

    category: &str,

    message: &str,

    samples: &[Value],

) -> Result<()> {

    if samples.is_empty() {

        return Ok(());

    }

    add_finding_count(tx, capture_id, id, severity, category, message, samples.len() as i64)?;

    for sample in samples.iter().take(25) {

        tx.execute(

            "INSERT INTO finding_samples (capture_id, audit_id, instance_id, path, sample_json) VALUES (?, ?, ?, ?, ?)",

            params![

                capture_id,

                id,

                sample.get("id").and_then(Value::as_str),

                sample.get("path").and_then(Value::as_str),

                serde_json::to_string(sample)?,

            ],

        )?;

    }

    Ok(())

}



fn add_finding_count(

    tx: &Transaction<'_>,

    capture_id: &str,

    id: &str,

    severity: &str,

    category: &str,

    message: &str,

    count: i64,

) -> Result<()> {

    tx.execute(

        "INSERT INTO findings (capture_id, audit_id, severity, category, message, count) VALUES (?, ?, ?, ?, ?, ?)",

        params![capture_id, id, severity, category, message, count],

    )?;

    Ok(())

}



#[cfg(test)]
mod tests {
    use super::*;

    use rusqlite::Connection;

    use crate::storage::{init_schema, read_live_state};



    fn minimal_snapshot() -> Value {

        json!({

            "place": { "placeId": "123", "placeKey": "Place123", "name": "Test" },

            "sync": { "syncId": "test_cap" },

            "instances": [

                {

                    "id": "a",

                    "parentId": null,

                    "path": "Workspace",

                    "name": "Workspace",

                    "className": "Workspace",

                    "depth": 0,

                    "childCount": 1,

                    "siblingIndex": 0,

                    "duplicateSiblingName": false,

                    "properties": {},

                    "attributes": {},

                    "tags": []

                },

                {

                    "id": "b",

                    "parentId": "a",

                    "path": "Workspace/Part",

                    "name": "Part",

                    "className": "Part",

                    "depth": 1,

                    "childCount": 0,

                    "siblingIndex": 0,

                    "duplicateSiblingName": false,

                    "properties": { "Transparency": 0.0 },

                    "attributes": {},

                    "tags": ["Foo"]

                }

            ]

        })

    }



    #[test]

    fn fingerprint_is_deterministic_and_order_independent() {

        let mut conn = Connection::open_in_memory().unwrap();

        init_schema(&conn).unwrap();

        let meta = capture_meta(&minimal_snapshot(), b"{}").unwrap();

        ingest_sqlite(&mut conn, &minimal_snapshot(), &meta).unwrap();

        let fp1 = fingerprint_state(&conn, &meta.capture_id).unwrap();



        let mut shuffled = minimal_snapshot();

        let inst = shuffled["instances"].as_array_mut().unwrap();

        inst.reverse();

        let mut conn2 = Connection::open_in_memory().unwrap();

        init_schema(&conn2).unwrap();

        ingest_sqlite(&mut conn2, &shuffled, &meta).unwrap();

        let fp2 = fingerprint_state(&conn2, &meta.capture_id).unwrap();

        assert_eq!(fp1, fp2);

    }



    #[test]

    fn baseline_replace_clears_old_rows() {

        let dir = std::env::temp_dir().join(format!("stud_test_{}", std::process::id()));

        let _ = fs::remove_dir_all(&dir);

        let snap1 = minimal_snapshot();

        materialize_snapshot(&snap1, Some(dir.clone()), DEFAULT_PROJECT_KEY).unwrap();



        let mut snap2 = minimal_snapshot();

        snap2["sync"]["syncId"] = json!("test_cap2");

        snap2["instances"] = json!([snap1["instances"][0].clone()]);

        materialize_snapshot(&snap2, Some(dir.clone()), DEFAULT_PROJECT_KEY).unwrap();



        let place = Storage::new(Some(dir.clone()), DEFAULT_PROJECT_KEY)

            .unwrap()

            .place("123");

        let conn = open_db(&place.db_path).unwrap();

        let state = read_live_state(&conn).unwrap().unwrap();

        assert_eq!(state.capture_id, "test_cap2");

        assert_eq!(state.instance_count, 1);

        let count: i64 = conn

            .query_row("SELECT COUNT(*) FROM instances", [], |r| r.get(0))

            .unwrap();

        assert_eq!(count, 1);

        let _ = fs::remove_dir_all(&dir);

    }

}


