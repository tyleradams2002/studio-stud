use serde_json::{Value, json};

use crate::storage::LiveState;

pub(crate) fn live_state_compact_json(state: &LiveState, include_paths: bool, place_dir: &str) -> Value {
    let mut item = serde_json::Map::new();
    item.insert("captureId".into(), json!(state.capture_id));
    item.insert("placeId".into(), json!(state.place_id));
    item.insert("placeKey".into(), json!(state.place_key));
    item.insert("revision".into(), json!(state.revision));
    item.insert("updatedAtUtc".into(), json!(state.updated_at_utc));
    item.insert("instanceCount".into(), json!(state.instance_count));
    if include_paths {
        item.insert("db".into(), json!(format!("{place_dir}/syncs.db")));
        item.insert("baseline".into(), json!(format!("{place_dir}/baseline.json.gz")));
    }
    Value::Object(item)
}
