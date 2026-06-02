use std::{fs, io::Read};

use anyhow::{Context, Result, anyhow};
use rusqlite::{Connection, OptionalExtension, params, params_from_iter};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::cli::CommonArgs;
use crate::storage::{NO_BASELINE_MSG, Storage, current_state, resolve_place};
use crate::util::{
    STALE_DB_SCHEMA_MSG, escape_like, is_empty_json, normalize_query_path, open_db_readonly,
    prune_empty_json, scalar_i64_dynamic,
};

#[allow(clippy::too_many_arguments)]
pub(crate) fn cmd_query(
    place: Option<&str>,
    class_name: Option<String>,
    find: Option<String>,
    name: Option<String>,
    path: Option<String>,
    under: Option<String>,
    bulk: Option<String>,
    audit: Option<String>,
    detail: Option<String>,
    props: Option<String>,
    all: bool,
    tree: Option<String>,
    depth: usize,
    limit_siblings: usize,
    count_only: bool,
    full_paths: bool,
    limit: usize,
    markdown: bool,
    common: &CommonArgs,
) -> Result<()> {
    let storage = Storage::new(common.storage_root.clone(), &common.project_key)?;
    let place = resolve_place(&storage, place)?;
    let conn = open_db_readonly(&place.db_path)?;
    ensure_readonly_query_schema(&conn)?;
    let live = current_state(&conn).map_err(|err| {
        if err.to_string().contains(NO_BASELINE_MSG) {
            anyhow!(STALE_DB_SCHEMA_MSG)
        } else {
            err
        }
    })?;
    let latest = live.as_capture_meta();
    let filters = QueryFilters {
        class_name: class_name.as_deref(),
        find: find.as_deref(),
        name: name.as_deref(),
        path: path.as_deref(),
        under: under.as_deref(),
    };
    if bulk.is_some()
        && (filters.has_any()
            || audit.is_some()
            || detail.is_some()
            || tree.is_some()
            || props.is_some()
            || all
            || count_only
            || full_paths)
    {
        return Err(anyhow!(
            "use --bulk separately from --class, --find, --name, --path, --under, --audit, --detail, --tree, --props, --all, --count-only, or --full-paths"
        ));
    }
    let detail_selector = DetailSelector::from_cli(all, props.as_deref());
    let output = QueryOutputOptions { full_paths };
    let payload = if let Some(bulk) = bulk {
        query_bulk(&conn, &latest.capture_id, &bulk, limit)?
    } else {
        run_query_request(
            &conn,
            &latest.capture_id,
            filters,
            audit.as_deref(),
            detail.as_deref(),
            detail_selector,
            tree.as_deref(),
            depth,
            limit_siblings,
            count_only,
            output,
            limit,
        )?
    };
    if markdown {
        println!(
            "# Studio Stud Query\n\n```json\n{}\n```",
            serde_json::to_string_pretty(&payload)?
        );
    } else {
        println!("{}", serde_json::to_string(&payload)?);
    }
    Ok(())
}
struct QueryFilters<'a> {
    class_name: Option<&'a str>,
    find: Option<&'a str>,
    name: Option<&'a str>,
    path: Option<&'a str>,
    under: Option<&'a str>,
}

struct UnderScope {
    path: String,
    norm: String,
}

impl QueryFilters<'_> {
    fn has_any(&self) -> bool {
        self.class_name.is_some()
            || self.find.is_some()
            || self.name.is_some()
            || self.path.is_some()
            || self.under.is_some()
    }
}

#[derive(Clone, Copy)]
struct QueryOutputOptions {
    full_paths: bool,
}

#[derive(Clone, Debug)]
enum DetailSelector {
    Missing,
    All,
    Props(Vec<String>),
}

impl DetailSelector {
    fn from_cli(all: bool, props: Option<&str>) -> Self {
        if all {
            return Self::All;
        }
        let props = props.map(parse_prop_list).filter(|items| !items.is_empty());
        match props {
            Some(props) => Self::Props(props),
            None => Self::Missing,
        }
    }

    fn from_bulk(all: Option<bool>, props: Option<&[String]>) -> Self {
        if all.unwrap_or(false) {
            return Self::All;
        }
        match props {
            Some(props) if !props.is_empty() => Self::Props(props.to_vec()),
            _ => Self::Missing,
        }
    }

    fn is_missing(&self) -> bool {
        matches!(self, Self::Missing)
    }
}

fn parse_prop_list(value: &str) -> Vec<String> {
    value
        .split(',')
        .map(str::trim)
        .filter(|item| !item.is_empty())
        .map(str::to_string)
        .collect()
}

#[derive(Debug, Deserialize, Serialize)]
struct BulkQuerySpec {
    key: Option<String>,
    #[serde(rename = "class")]
    class_name: Option<String>,
    find: Option<String>,
    name: Option<String>,
    path: Option<String>,
    under: Option<String>,
    audit: Option<String>,
    detail: Option<String>,
    props: Option<Vec<String>>,
    all: Option<bool>,
    tree: Option<String>,
    depth: Option<usize>,
    #[serde(rename = "limitSiblings")]
    limit_siblings: Option<usize>,
    #[serde(rename = "countOnly")]
    count_only: Option<bool>,
    #[serde(rename = "fullPaths")]
    full_paths: Option<bool>,
    limit: Option<usize>,
}

pub(crate) fn query_find(
    conn: &Connection,
    capture_id: &str,
    pattern: &str,
    limit: usize,
) -> Result<Value> {
    query_filtered(
        conn,
        capture_id,
        QueryFilters {
            class_name: None,
            find: Some(pattern),
            name: None,
            path: None,
            under: None,
        },
        limit,
        false,
        QueryOutputOptions { full_paths: false },
    )
}

#[allow(clippy::too_many_arguments)]
fn run_query_request(
    conn: &Connection,
    capture_id: &str,
    filters: QueryFilters<'_>,
    audit: Option<&str>,
    detail: Option<&str>,
    detail_selector: DetailSelector,
    tree: Option<&str>,
    depth: usize,
    limit_siblings: usize,
    count_only: bool,
    output: QueryOutputOptions,
    limit: usize,
) -> Result<Value> {
    if filters.has_any() && (audit.is_some() || detail.is_some() || tree.is_some()) {
        return Err(anyhow!(
            "use filter options (--class, --find, --name, --path, --under) separately from audit, detail, or tree"
        ));
    }
    if count_only && !filters.has_any() {
        return Err(anyhow!("--count-only requires a filter"));
    }
    if filters.has_any() {
        query_filtered(conn, capture_id, filters, limit, count_only, output)
    } else if let Some(audit_id) = audit {
        query_audit(conn, capture_id, audit_id, limit)
    } else if let Some(instance_id) = detail {
        query_detail(conn, capture_id, instance_id, detail_selector, output)
    } else if let Some(root) = tree {
        query_tree(conn, capture_id, root, depth, limit_siblings, output)
    } else {
        Err(anyhow!(
            "provide at least one of class, find, name, path, under, audit, detail, or tree"
        ))
    }
}

fn query_bulk(
    conn: &Connection,
    capture_id: &str,
    source: &str,
    default_limit: usize,
) -> Result<Value> {
    let input = read_bulk_query_input(source)?;
    let specs = parse_bulk_query_specs(&input)?;
    if specs.is_empty() {
        return Err(anyhow!("bulk query JSON must include at least one query"));
    }
    let mut results = serde_json::Map::new();
    for (index, spec) in specs.iter().enumerate() {
        let key = spec
            .key
            .clone()
            .unwrap_or_else(|| format!("query{}", index + 1));
        let limit = spec.limit.unwrap_or(default_limit);
        let detail_selector = DetailSelector::from_bulk(spec.all, spec.props.as_deref());
        let output = QueryOutputOptions {
            full_paths: spec.full_paths.unwrap_or(false),
        };
        let payload = run_query_request(
            conn,
            capture_id,
            QueryFilters {
                class_name: spec.class_name.as_deref(),
                find: spec.find.as_deref(),
                name: spec.name.as_deref(),
                path: spec.path.as_deref(),
                under: spec.under.as_deref(),
            },
            spec.audit.as_deref(),
            spec.detail.as_deref(),
            detail_selector,
            spec.tree.as_deref(),
            spec.depth.unwrap_or(1),
            spec.limit_siblings.unwrap_or(limit),
            spec.count_only.unwrap_or(false),
            output,
            limit,
        );
        let value = match payload {
            Ok(result) => result,
            Err(err) => json!({ "error": err.to_string() }),
        };
        results.insert(key, value);
    }
    Ok(Value::Object(results))
}

pub(crate) fn ensure_readonly_query_schema(conn: &Connection) -> Result<()> {
    let has_path_norm: i64 = conn.query_row(
        "SELECT COUNT(*) FROM pragma_table_info('instances') WHERE name = 'path_norm'",
        [],
        |row| row.get(0),
    )?;
    if has_path_norm == 0 {
        return Err(anyhow!(STALE_DB_SCHEMA_MSG));
    }
    Ok(())
}

fn read_bulk_query_input(source: &str) -> Result<String> {
    let trimmed = source.trim();
    if trimmed == "-" {
        let mut input = String::new();
        std::io::stdin()
            .read_to_string(&mut input)
            .context("failed to read bulk query JSON from stdin")?;
        if input.trim().is_empty() {
            return Err(anyhow!(
                "--bulk - received empty stdin (on Windows prefer --bulk '<json>' or --bulk @file.json)"
            ));
        }
        return Ok(input);
    }
    if trimmed.starts_with('{') || trimmed.starts_with('[') {
        return Ok(source.to_string());
    }
    let path = trimmed.strip_prefix('@').unwrap_or(trimmed);
    fs::read_to_string(path).with_context(|| format!("failed to read bulk query JSON from {path}"))
}

fn parse_bulk_query_specs(input: &str) -> Result<Vec<BulkQuerySpec>> {
    let value: Value = serde_json::from_str(input).context("failed to parse bulk query JSON")?;
    match value {
        Value::Array(_) => serde_json::from_value(value).context("bulk query array is invalid"),
        Value::Object(mut map) => {
            if let Some(queries) = map.remove("queries") {
                serde_json::from_value(queries)
                    .context("bulk query object must contain a queries array")
            } else {
                let spec: BulkQuerySpec = serde_json::from_value(Value::Object(map))
                    .context("bulk query object is invalid")?;
                Ok(vec![spec])
            }
        }
        _ => Err(anyhow!(
            "bulk query JSON must be an array, a single query object, or an object with a queries array"
        )),
    }
}

fn query_filtered(
    conn: &Connection,
    capture_id: &str,
    filters: QueryFilters<'_>,
    limit: usize,
    count_only: bool,
    output: QueryOutputOptions,
) -> Result<Value> {
    let normalized_path = filters.path.map(normalize_query_path);
    let under_scope = match filters.under {
        Some(value) => Some(resolve_under_scope(conn, capture_id, value)?),
        None => None,
    };
    let find = filters.find.map(str::to_ascii_lowercase);
    let name = filters.name.map(str::to_ascii_lowercase);
    let class_name = filters.class_name.map(str::to_ascii_lowercase);
    let mut clauses = vec!["capture_id = ?".to_string()];
    let mut values = vec![capture_id.to_string()];

    if let Some(expected) = &class_name {
        clauses.push("lower(class_name) = ?".to_string());
        values.push(expected.clone());
    }
    if let Some(expected) = &name {
        clauses.push("lower(name) = ?".to_string());
        values.push(expected.clone());
    }
    if let Some(pattern) = &find {
        clauses.push("search_text LIKE ?".to_string());
        values.push(format!("%{}%", escape_like(pattern)));
    }
    if let Some(expected_path) = &normalized_path {
        clauses.push("(path_norm = ? OR display_path_norm = ?)".to_string());
        values.push(expected_path.clone());
        values.push(expected_path.clone());
    }
    if let Some(scope) = &under_scope {
        clauses.push(
            "(path_norm = ? OR path_norm LIKE ? OR display_path_norm = ? OR display_path_norm LIKE ?)"
                .to_string(),
        );
        values.push(scope.norm.clone());
        values.push(format!("{}/%", escape_like(&scope.norm)));
        values.push(scope.norm.clone());
        values.push(format!("{}/%", escape_like(&scope.norm)));
    }

    let where_sql = clauses.join(" AND ");
    let total = scalar_i64_dynamic(
        conn,
        &format!("SELECT COUNT(*) FROM instances WHERE {where_sql}"),
        &values,
    )?;
    if count_only {
        return Ok(json!({
            "returned": 0,
            "total": total,
            "limit": limit,
            "truncated": total > 0,
            "items": [],
        }));
    }

    let mut query_values = values.clone();
    query_values.push(limit.to_string());
    let mut stmt = conn.prepare(&format!(
        "SELECT instance_id, path, display_path, name, class_name, parent_id, child_count
         FROM instances
         WHERE {where_sql}
         ORDER BY path
         LIMIT ?"
    ))?;
    let rows = stmt.query_map(params_from_iter(query_values.iter()), instance_filter_row)?;
    let mut results = Vec::new();
    let base = under_scope.as_ref().map(|scope| scope.path.as_str());
    for row in rows {
        results.push(row?.to_compact_json(output, base));
    }

    let mut payload = serde_json::Map::new();
    payload.insert("returned".into(), json!(results.len()));
    payload.insert("total".into(), json!(total));
    payload.insert("limit".into(), json!(limit));
    payload.insert("truncated".into(), json!(total > results.len() as i64));
    if let Some(scope) = under_scope {
        payload.insert("base".into(), json!(scope.path));
    }
    payload.insert("items".into(), Value::Array(results));
    Ok(Value::Object(payload))
}

fn query_audit(conn: &Connection, capture_id: &str, audit_id: &str, limit: usize) -> Result<Value> {
    let finding = conn.query_row(
        "SELECT audit_id, severity, category, message, count FROM findings WHERE capture_id = ? AND audit_id = ?",
        params![capture_id, audit_id],
        |row| {
            Ok(json!({
                "id": row.get::<_, String>(0)?,
                "severity": row.get::<_, String>(1)?,
                "category": row.get::<_, String>(2)?,
                "message": row.get::<_, String>(3)?,
                "count": row.get::<_, i64>(4)?,
            }))
        },
    ).optional()?;
    let mut samples = Vec::new();
    let total = scalar_i64_dynamic(
        conn,
        "SELECT COUNT(*) FROM finding_samples WHERE capture_id = ? AND audit_id = ?",
        &[capture_id.to_string(), audit_id.to_string()],
    )?;
    let mut stmt = conn.prepare(
        "SELECT sample_json FROM finding_samples WHERE capture_id = ? AND audit_id = ? LIMIT ?",
    )?;
    let rows = stmt.query_map(params![capture_id, audit_id, limit as i64], |row| {
        row.get::<_, String>(0)
    })?;
    for row in rows {
        samples.push(serde_json::from_str::<Value>(&row?)?);
    }
    Ok(json!({
        "finding": finding,
        "returned": samples.len(),
        "total": total,
        "limit": limit,
        "truncated": total > samples.len() as i64,
        "sample": samples
    }))
}

fn query_detail(
    conn: &Connection,
    capture_id: &str,
    locator: &str,
    selector: DetailSelector,
    output: QueryOutputOptions,
) -> Result<Value> {
    if selector.is_missing() {
        return Ok(json!({
            "ok": false,
            "error": "detail_requires_selector",
            "message": "Use --props <comma-separated-properties> or --all with --detail.",
        }));
    }
    let instance_id = resolve_instance_locator(conn, capture_id, locator)?;
    let instance = conn.query_row(
        "SELECT instance_id, path, display_path, name, class_name, parent_id, child_count, property_json FROM instances WHERE capture_id = ? AND instance_id = ?",
        params![capture_id, instance_id],
        |row| {
            let property_json: String = row.get(7)?;
            let result = InstanceResult {
                id: row.get(0)?,
                path: row.get(1)?,
                display_path: row.get(2)?,
                name: row.get(3)?,
                class_name: row.get(4)?,
                parent_id: row.get(5)?,
                child_count: row.get(6)?,
            };
            let mut item = match result.to_compact_json(output, None) {
                Value::Object(map) => map,
                _ => serde_json::Map::new(),
            };
            if let Some(parent_id) = result.parent_id {
                item.insert("parentId".into(), json!(parent_id));
            }
            let properties =
                serde_json::from_str::<Value>(&property_json).unwrap_or_else(|_| json!({}));
            let properties = prune_empty_json(properties);
            let selected = select_properties(properties, &selector);
            if !is_empty_json(&selected) {
                item.insert("props".into(), selected);
            }
            Ok(Value::Object(item))
        },
    ).optional()?;
    Ok(json!({ "item": instance }))
}

fn resolve_instance_locator(conn: &Connection, capture_id: &str, locator: &str) -> Result<String> {
    if let Some(found) = conn
        .query_row(
            "SELECT instance_id FROM instances WHERE capture_id = ? AND instance_id = ?",
            params![capture_id, locator],
            |row| row.get::<_, String>(0),
        )
        .optional()?
    {
        return Ok(found);
    }
    let normalized = normalize_query_path(locator);
    conn.query_row(
        "SELECT instance_id FROM instances
         WHERE capture_id = ? AND (path_norm = ? OR display_path_norm = ?)
         ORDER BY path
         LIMIT 1",
        params![capture_id, normalized, normalized],
        |row| row.get::<_, String>(0),
    )
    .optional()?
    .ok_or_else(|| anyhow!("instance `{locator}` was not found"))
}

fn select_properties(properties: Value, selector: &DetailSelector) -> Value {
    match selector {
        DetailSelector::All => properties,
        DetailSelector::Props(names) => {
            let Some(map) = properties.as_object() else {
                return json!({});
            };
            let mut selected = serde_json::Map::new();
            for name in names {
                if let Some(value) = map.get(name) {
                    selected.insert(name.clone(), value.clone());
                }
            }
            Value::Object(selected)
        }
        DetailSelector::Missing => json!({}),
    }
}

fn query_tree(
    conn: &Connection,
    capture_id: &str,
    root: &str,
    depth: usize,
    limit_siblings: usize,
    output: QueryOutputOptions,
) -> Result<Value> {
    let root_id = resolve_instance_locator(conn, capture_id, root)?;
    let root_result = instance_by_id(conn, capture_id, &root_id)?;
    let base_value = if output.full_paths {
        root_result
            .display_path
            .as_deref()
            .unwrap_or(&root_result.path)
            .to_string()
    } else {
        root_result.path.clone()
    };
    let root_item = root_result.to_compact_json(output, None);
    let children = tree_children(
        conn,
        capture_id,
        &root_id,
        depth,
        limit_siblings,
        output,
        &root_result.path,
    )?;
    Ok(json!({
        "base": base_value,
        "depth": depth,
        "limitSiblings": limit_siblings,
        "root": root_item,
        "children": children,
    }))
}

fn tree_children(
    conn: &Connection,
    capture_id: &str,
    parent_id: &str,
    depth: usize,
    limit_siblings: usize,
    output: QueryOutputOptions,
    base_path: &str,
) -> Result<Value> {
    if depth == 0 {
        return Ok(json!({ "returned": 0, "total": 0, "truncated": false, "items": [] }));
    }
    let total = scalar_i64_dynamic(
        conn,
        "SELECT COUNT(*) FROM instances WHERE capture_id = ? AND parent_id = ?",
        &[capture_id.to_string(), parent_id.to_string()],
    )?;
    let mut stmt = conn.prepare(
        "SELECT instance_id, path, display_path, name, class_name, parent_id, child_count
         FROM instances
         WHERE capture_id = ? AND parent_id = ?
         ORDER BY path
         LIMIT ?",
    )?;
    let rows = stmt.query_map(
        params![capture_id, parent_id, limit_siblings as i64],
        instance_filter_row,
    )?;
    let mut items = Vec::new();
    for row in rows {
        let child = row?;
        let mut item = match child.to_compact_json(output, Some(base_path)) {
            Value::Object(map) => map,
            _ => serde_json::Map::new(),
        };
        if depth > 1 && child.child_count.unwrap_or(0) > 0 {
            item.insert(
                "children".into(),
                tree_children(
                    conn,
                    capture_id,
                    &child.id,
                    depth - 1,
                    limit_siblings,
                    output,
                    base_path,
                )?,
            );
        }
        items.push(Value::Object(item));
    }
    Ok(json!({
        "returned": items.len(),
        "total": total,
        "limit": limit_siblings,
        "truncated": total > items.len() as i64,
        "items": items,
    }))
}

fn instance_by_id(
    conn: &Connection,
    capture_id: &str,
    instance_id: &str,
) -> Result<InstanceResult> {
    conn.query_row(
        "SELECT instance_id, path, display_path, name, class_name, parent_id, child_count
         FROM instances
         WHERE capture_id = ? AND instance_id = ?",
        params![capture_id, instance_id],
        instance_filter_row,
    )
    .optional()?
    .ok_or_else(|| anyhow!("instance `{instance_id}` was not found"))
}

#[derive(Debug)]
struct InstanceResult {
    id: String,
    path: String,
    display_path: Option<String>,
    name: String,
    class_name: String,
    parent_id: Option<String>,
    child_count: Option<i64>,
}

impl InstanceResult {
    fn to_compact_json(&self, output: QueryOutputOptions, base_path: Option<&str>) -> Value {
        let mut item = serde_json::Map::new();
        item.insert("id".into(), json!(&self.id));
        item.insert("path".into(), json!(self.output_path(output, base_path)));
        item.insert("name".into(), json!(&self.name));
        item.insert("class".into(), json!(&self.class_name));
        if let Some(child_count) = self.child_count.filter(|count| *count > 0) {
            item.insert("childCount".into(), json!(child_count));
        }
        Value::Object(item)
    }

    fn output_path(&self, output: QueryOutputOptions, base_path: Option<&str>) -> String {
        if output.full_paths {
            return self
                .display_path
                .as_deref()
                .unwrap_or(&self.path)
                .to_string();
        }
        if let Some(base) = base_path {
            if self.path == base {
                return ".".to_string();
            }
            if let Some(relative) = self
                .path
                .strip_prefix(base)
                .and_then(|suffix| suffix.strip_prefix('/'))
            {
                return relative.to_string();
            }
            let normalized = normalize_query_path(&self.path);
            let base_norm = normalize_query_path(base);
            if normalized == base_norm {
                return ".".to_string();
            }
            if let Some(relative) = normalized
                .strip_prefix(&base_norm)
                .and_then(|suffix| suffix.strip_prefix('/'))
            {
                return relative.to_string();
            }
        }
        self.path.clone()
    }
}

fn instance_filter_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<InstanceResult> {
    Ok(InstanceResult {
        id: row.get(0)?,
        path: row.get(1)?,
        display_path: row.get(2)?,
        name: row.get(3)?,
        class_name: row.get(4)?,
        parent_id: row.get(5)?,
        child_count: row.get(6)?,
    })
}

fn resolve_under_scope(conn: &Connection, capture_id: &str, value: &str) -> Result<UnderScope> {
    let found_by_id = conn
        .query_row(
            "SELECT path FROM instances WHERE capture_id = ? AND instance_id = ?",
            params![capture_id, value],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    if let Some(path) = found_by_id {
        return Ok(UnderScope {
            norm: normalize_query_path(&path),
            path,
        });
    }
    let normalized = normalize_query_path(value);
    let found_by_path = conn
        .query_row(
            "SELECT path FROM instances
             WHERE capture_id = ? AND (path_norm = ? OR display_path_norm = ?)
             ORDER BY path
             LIMIT 1",
            params![capture_id, normalized, normalized],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    let path = found_by_path.unwrap_or_else(|| value.to_string());
    Ok(UnderScope {
        norm: normalize_query_path(&path),
        path,
    })
}
