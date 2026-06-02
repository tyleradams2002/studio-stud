use anyhow::Result;
use rusqlite::{Connection, params};
use serde_json::{Value, json};

use crate::cli::CommonArgs;
use crate::cli::ReportView;
use crate::query::ensure_readonly_query_schema;
use crate::query::query_find;
use crate::storage::{CaptureMeta, NO_BASELINE_MSG, Storage, current_state, resolve_place};
use crate::util::{Finding, STALE_DB_SCHEMA_MSG, open_db_readonly, scalar_i64};

pub(crate) fn cmd_analyze(
    place: Option<&str>,
    reports: Vec<ReportView>,
    focus: Vec<String>,
    limit: usize,
    _as_json: bool,
    markdown: bool,
    common: &CommonArgs,
) -> Result<()> {
    let storage = Storage::new(common.storage_root.clone(), &common.project_key)?;
    let place = resolve_place(&storage, place)?;
    let conn = open_db_readonly(&place.db_path)?;
    ensure_readonly_query_schema(&conn)?;
    let live = current_state(&conn).map_err(|err| {
        if err.to_string().contains(NO_BASELINE_MSG) {
            anyhow::anyhow!(STALE_DB_SCHEMA_MSG)
        } else {
            err
        }
    })?;
    let latest = live.as_capture_meta();
    let requested = if reports.is_empty() {
        vec![ReportView::Context]
    } else {
        reports
    };

    if !markdown {
        let mut payload = serde_json::Map::new();
        payload.insert("placeId".into(), json!(latest.place_id));
        payload.insert("captureId".into(), json!(latest.capture_id));
        for view in requested {
            match view {
                ReportView::Context => {
                    payload.insert("context".into(), context_json(&conn, &latest, limit)?)
                }
                ReportView::Findings => {
                    payload.insert("findings".into(), findings_json(&conn, &latest, limit)?)
                }
                ReportView::Critical => {
                    payload.insert("critical".into(), critical_json(&conn, &latest)?)
                }
            };
        }
        if !focus.is_empty() {
            payload.insert("focus".into(), focus_json(&conn, &latest, &focus, limit)?);
        }
        println!("{}", serde_json::to_string(&Value::Object(payload))?);
        return Ok(());
    }

    let mut sections = Vec::new();
    for view in requested {
        sections.push(match view {
            ReportView::Context => render_context(&conn, &latest, limit)?,
            ReportView::Findings => render_findings(&conn, &latest, limit)?,
            ReportView::Critical => render_critical(&conn, &latest)?,
        });
    }
    if !focus.is_empty() {
        sections.push(render_focus(&conn, &latest, &focus, limit)?);
    }
    println!("{}", sections.join("\n\n---\n\n"));
    Ok(())
}

fn context_json(conn: &Connection, capture: &CaptureMeta, limit: usize) -> Result<Value> {
    Ok(json!({
        "placeKey": capture.place_key,
        "placeId": capture.place_id,
        "generatedAtUtc": capture.created_at_utc,
        "totalItems": capture.instance_count,
        "findings": findings_json(conn, capture, limit)?,
        "recommendedQueries": recommended_queries(conn, capture, limit)?,
    }))
}

fn findings_json(conn: &Connection, capture: &CaptureMeta, limit: usize) -> Result<Value> {
    let total = scalar_i64(
        conn,
        "SELECT COUNT(*) FROM findings WHERE capture_id = ?",
        &capture.capture_id,
    )?;
    let mut stmt = conn.prepare("SELECT audit_id, severity, category, message, count FROM findings WHERE capture_id = ? ORDER BY CASE severity WHEN 'warning' THEN 0 WHEN 'info' THEN 1 ELSE 2 END, audit_id LIMIT ?")?;
    let rows = stmt.query_map(params![capture.capture_id, limit as i64], |row| {
        Ok(Finding {
            id: row.get(0)?,
            severity: row.get(1)?,
            category: row.get(2)?,
            message: row.get(3)?,
            count: row.get(4)?,
        })
    })?;
    let mut findings = Vec::new();
    for row in rows {
        findings.push(json!(row?));
    }
    Ok(json!({
        "returned": findings.len(),
        "total": total,
        "limit": limit,
        "truncated": total > findings.len() as i64,
        "items": findings,
    }))
}

fn critical_json(conn: &Connection, capture: &CaptureMeta) -> Result<Value> {
    let mut stmt = conn.prepare("SELECT critical_name, present FROM critical_presence WHERE capture_id = ? ORDER BY critical_name")?;
    let rows = stmt.query_map([&capture.capture_id], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)? != 0))
    })?;
    let mut values = serde_json::Map::new();
    for row in rows {
        let (name, present) = row?;
        values.insert(name, json!(present));
    }
    Ok(Value::Object(values))
}

fn focus_json(
    conn: &Connection,
    capture: &CaptureMeta,
    terms: &[String],
    limit: usize,
) -> Result<Value> {
    let mut results = Vec::new();
    for term in terms {
        let mut matches = query_find(conn, &capture.capture_id, term, limit)?;
        if let Some(items) = matches.get_mut("items").and_then(Value::as_array_mut) {
            results.append(items);
        }
    }
    results.truncate(limit);
    Ok(json!({
        "terms": terms,
        "returned": results.len(),
        "limit": limit,
        "truncated": results.len() >= limit,
        "items": results
    }))
}

fn recommended_queries(conn: &Connection, capture: &CaptureMeta, limit: usize) -> Result<Value> {
    let findings = findings_json(conn, capture, limit)?;
    let mut queries = Vec::new();
    for finding in findings
        .get("items")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        if let Some(id) = finding.get("id").and_then(Value::as_str) {
            queries.push(json!({
                "reason": finding.get("message"),
                "query": {
                    "audit": id,
                    "limit": 25,
                },
            }));
        }
    }
    Ok(Value::Array(queries))
}

fn render_context(conn: &Connection, capture: &CaptureMeta, limit: usize) -> Result<String> {
    let findings = findings_json(conn, capture, limit)?;
    let mut lines = vec![
        "# Studio Stud Context".to_string(),
        String::new(),
        format!("- place: `{}`", capture.place_key),
        format!("- placeId: `{}`", capture.place_id),
        format!("- captureId: `{}`", capture.capture_id),
        format!("- capturedAtUtc: `{}`", capture.created_at_utc),
        format!("- totalItems: `{}`", capture.instance_count),
        String::new(),
        "## Findings".to_string(),
    ];
    for finding in findings
        .get("items")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        lines.push(format!(
            "- {}: {} (`{}`)",
            finding
                .get("severity")
                .and_then(Value::as_str)
                .unwrap_or("info"),
            finding.get("message").and_then(Value::as_str).unwrap_or(""),
            finding.get("id").and_then(Value::as_str).unwrap_or("")
        ));
    }
    lines.push(String::new());
    lines.push(
        "Use `studio-stud query` for bounded drilldowns. Do not load raw snapshots into chat."
            .to_string(),
    );
    Ok(lines.join("\n"))
}

fn render_findings(conn: &Connection, capture: &CaptureMeta, limit: usize) -> Result<String> {
    Ok(format!(
        "# Findings\n\n```json\n{}\n```",
        serde_json::to_string_pretty(&findings_json(conn, capture, limit)?)?
    ))
}

fn render_critical(conn: &Connection, capture: &CaptureMeta) -> Result<String> {
    Ok(format!(
        "# Critical Names\n\n```json\n{}\n```",
        serde_json::to_string_pretty(&critical_json(conn, capture)?)?
    ))
}

fn render_focus(
    conn: &Connection,
    capture: &CaptureMeta,
    terms: &[String],
    limit: usize,
) -> Result<String> {
    Ok(format!(
        "# Focus\n\n```json\n{}\n```",
        serde_json::to_string_pretty(&focus_json(conn, capture, terms, limit)?)?
    ))
}
