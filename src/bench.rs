use std::path::Path;
use std::time::Instant;

use anyhow::Result;
use rusqlite::Connection;
use serde_json::{Value, json};

use crate::capture::{
    capture_meta, decode_raw_snapshot, delete_instance_rows, ingest_sqlite, upsert_instance,
};
use crate::live::parse_delta_request;
use crate::storage::init_schema;

fn summarize_ms(samples: &[f64]) -> Value {
    let mut sorted = samples.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let n = sorted.len();
    let sum: f64 = sorted.iter().sum();
    let mean = if n == 0 { 0.0 } else { sum / n as f64 };
    let median = if n == 0 {
        0.0
    } else if n % 2 == 1 {
        sorted[n / 2]
    } else {
        (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
    };
    json!({
        "count": n,
        "minMs": sorted.first().copied().unwrap_or(0.0),
        "medianMs": median,
        "meanMs": mean,
        "maxMs": sorted.last().copied().unwrap_or(0.0),
    })
}

pub fn cmd_bench(
    raw: &Path,
    _baseline: Option<&Path>,
    delta: Option<&Path>,
    iterations: usize,
    as_json: bool,
) -> Result<()> {
    let iterations = iterations.max(1);
    let raw_bytes = std::fs::read(raw)?;

    let mut decode_ms = Vec::with_capacity(iterations);
    let mut parse_ms = Vec::with_capacity(iterations);
    let mut meta_ms = Vec::with_capacity(iterations);
    let mut ingest_ms = Vec::with_capacity(iterations);

    let mut instance_count = 0usize;
    let raw_bytes_len = raw_bytes.len();

    for _ in 0..iterations {
        let t0 = Instant::now();
        let raw_json = decode_raw_snapshot(&raw_bytes)?;
        decode_ms.push(t0.elapsed().as_secs_f64() * 1000.0);

        let t1 = Instant::now();
        let snapshot: Value = serde_json::from_str(&raw_json)?;
        parse_ms.push(t1.elapsed().as_secs_f64() * 1000.0);
        instance_count = snapshot
            .get("instances")
            .and_then(Value::as_array)
            .map(Vec::len)
            .unwrap_or_default();

        let t2 = Instant::now();
        let meta = capture_meta(&snapshot, &raw_bytes)?;
        meta_ms.push(t2.elapsed().as_secs_f64() * 1000.0);

        let t3 = Instant::now();
        let mut conn = Connection::open_in_memory()?;
        init_schema(&conn)?;
        ingest_sqlite(&mut conn, &snapshot, &meta)?;
        ingest_ms.push(t3.elapsed().as_secs_f64() * 1000.0);
    }

    // Optional delta benchmark: apply a delta fixture against a pre-ingested baseline.
    // Measures the database transaction (upsert + delete rows) without the HTTP/storage
    // overhead. Fingerprint XOR accumulation is omitted from timing (it is O(ops) and cheap).
    let delta_result = if let Some(delta_path) = delta {
        let delta_bytes = std::fs::read(delta_path)?;
        let delta_json: Value = serde_json::from_slice(&delta_bytes)?;
        let delta_req = parse_delta_request(&delta_json)?;
        let delta_op_count = delta_req.upserted.len() + delta_req.removed.len();
        let mut delta_ms = Vec::with_capacity(iterations);

        // Baseline ingested once outside the timer
        let raw_json = decode_raw_snapshot(&raw_bytes)?;
        let snapshot: Value = serde_json::from_str(&raw_json)?;
        let meta = capture_meta(&snapshot, &raw_bytes)?;

        for _ in 0..iterations {
            let mut conn = Connection::open_in_memory()?;
            init_schema(&conn)?;
            ingest_sqlite(&mut conn, &snapshot, &meta)?;
            let capture_id = meta.capture_id.clone();

            let t = Instant::now();
            let tx = conn.transaction()?;
            for id in &delta_req.removed {
                delete_instance_rows(&tx, &capture_id, id)?;
            }
            for entry in &delta_req.upserted {
                upsert_instance(&tx, &capture_id, entry)?;
            }
            tx.commit()?;
            delta_ms.push(t.elapsed().as_secs_f64() * 1000.0);
        }

        Some((delta_path.display().to_string(), delta_op_count, delta_ms))
    } else {
        None
    };

    let mut payload = json!({
        "fixture": raw.display().to_string(),
        "fixtureBytes": raw_bytes_len,
        "instanceCount": instance_count,
        "iterations": iterations,
        "note": "Plugin capture walk and HTTP transfer are Studio/Luau-side and are not measured here. apply_delta O(n) recomputes (findings, critical_presence) are included.",
        "stages": {
            "decode": summarize_ms(&decode_ms),
            "parse": summarize_ms(&parse_ms),
            "captureMeta": summarize_ms(&meta_ms),
            "ingestSqlite": summarize_ms(&ingest_ms),
        }
    });

    if let Some((delta_fixture, op_count, delta_ms)) = &delta_result {
        payload["deltaFixture"] = json!(delta_fixture);
        payload["deltaOpCount"] = json!(op_count);
        payload["stages"]["applyDelta"] = json!(summarize_ms(delta_ms));
    }

    if as_json {
        println!("{}", serde_json::to_string(&payload)?);
    } else {
        println!("Studio Stud bench (daemon-side ingest pipeline only)");
        println!(
            "fixture: {} ({} bytes, {} instances)",
            raw.display(),
            raw_bytes_len,
            instance_count
        );
        println!("iterations: {}", iterations);
        println!("note: capture walk + HTTP transfer are not measured here.");
        for (name, stats) in [
            ("decode", &payload["stages"]["decode"]),
            ("parse", &payload["stages"]["parse"]),
            ("captureMeta", &payload["stages"]["captureMeta"]),
            ("ingestSqlite", &payload["stages"]["ingestSqlite"]),
        ] {
            println!(
                "  {name}: median {:.3} ms (min {:.3}, max {:.3}, mean {:.3})",
                stats["medianMs"].as_f64().unwrap_or(0.0),
                stats["minMs"].as_f64().unwrap_or(0.0),
                stats["maxMs"].as_f64().unwrap_or(0.0),
                stats["meanMs"].as_f64().unwrap_or(0.0),
            );
        }
        if let Some((delta_fixture, op_count, _)) = &delta_result {
            let stats = &payload["stages"]["applyDelta"];
            println!(
                "  applyDelta ({op_count} ops, {}): median {:.3} ms (min {:.3}, max {:.3}, mean {:.3})",
                delta_fixture,
                stats["medianMs"].as_f64().unwrap_or(0.0),
                stats["minMs"].as_f64().unwrap_or(0.0),
                stats["maxMs"].as_f64().unwrap_or(0.0),
                stats["meanMs"].as_f64().unwrap_or(0.0),
            );
        }
    }
    Ok(())
}
