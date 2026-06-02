---
name: ""
overview: ""
todos: []
isProject: false
---

# Studio Stud Reliability Fixes

Live-test feedback from Clayton (daemon v0.1.0 / plugin v0.3.4) surfaced three
problems: random disconnect requiring a manual reconnect, contention when the AI
runs multiple lookups at once, and a failure returning bulk JSON. This plan fixes
all three plus a docs/guidance gap. Each item is independently shippable.

All paths are relative to the workspace root (the ExampleProject repo root). Tool
APIs that require absolute paths are the only exception.

## Component map

| Thing | Path |
| --- | --- |
| Daemon serve loop | `tools/studio_stud/src/cli.rs` (`cmd_serve`) |
| HTTP request router | `tools/studio_stud/src/http.rs` (`handle_daemon_request`, `map_response_status`) |
| Query command | `tools/studio_stud/src/query.rs` (`cmd_query`, `read_bulk_query_input`) |
| DB open helpers / consts | `tools/studio_stud/src/util.rs` (`open_db`) |
| Schema/migration | `tools/studio_stud/src/storage.rs` (`init_schema`, `backfill_normalized_columns`) |
| Plugin | `tools/studio_stud/plugin/StudioStud.plugin.lua` (`PLUGIN_VERSION`, `Transport.requestJson`, `Live.sendVerify`, poll loop) |
| Crate version | `tools/studio_stud/Cargo.toml` (`version`) |
| Checked-in binary | `tools/studio_stud/bin/studio-stud.exe` |
| Docs | `docs/studio-stud.md` |
| Rule | `.cursor/rules/studio-stud.mdc` |

## Pre-work

- **Proceed directly with implementation — the rebuild/re-test gate is skipped by
  decision.** (Clayton tested daemon `0.1.0` / plugin `0.3.4`; current source is
  `0.2.0` / `0.3.5`. The fixes below are written against current source and are valid
  regardless of which symptoms survived the older builds.)
- The working tree has uncommitted Stage 3 write changes (`write.rs`, `policy.rs`,
  etc.). These fixes are independent — keep their commits separate from Stage 3.

---

## Fix 1 — Multi-thread the daemon (highest value)

**Problem.** The serve loop is single-threaded:

```650:654:tools/studio_stud/src/cli.rs
    for request in server.incoming_requests() {
        if let Err(err) = handle_daemon_request(request, Arc::clone(&state), &config) {
            eprintln!("request failed: {err:#}");
        }
    }
```

A full verify/capture ingest (gzip decode + JSON parse + full SQLite ingest) holds the
one thread for seconds, queuing the plugin's 3 s `GET /capture/request` poll behind it.
If the poll exceeds the plugin's `RequestAsync` timeout, the plugin declares the daemon
unreachable and runs `Live.teardown()` → the "pausing live" disconnect Clayton saw.

**Change — `cmd_serve` in `tools/studio_stud/src/cli.rs`:**
- Wrap the server in `Arc<tiny_http::Server>` (`tiny_http`'s `recv()` and the shared
  iterator are thread-safe).
- Spawn a small fixed worker pool (start with **4 threads**). Each worker loops on the
  shared server, calling `handle_daemon_request(request, Arc::clone(&state), &config)`.
- `DaemonState` is already `Arc<Mutex<…>>`. `ServeConfig` is `Clone` — clone per worker
  or wrap in `Arc`.
- Keep the main thread alive (join workers, or block on a worker).

**Safety to confirm while implementing:**
- The state mutex is only held for short critical sections. `complete_daemon_upload` /
  `complete_verify_upload` already do heavy work **outside** the lock and re-lock only to
  insert completions — do not regress this.
- Delta/verify handlers each open their own short-lived SQLite connection; WAL +
  `busy_timeout(60s)` (already in `open_db`) handles concurrent writers. Deltas come from
  one plugin sequentially, so write-write collisions are rare and bounded.

**Risk:** low-medium (interleaved writes; mitigated by WAL + busy_timeout).

**Test:** `cargo build`; add a smoke test that fires several concurrent `GET /ping` plus
one slow POST and asserts pings still return promptly. Manual: trigger a large-place
verify and confirm the poll never stalls.

---

## Fix 2 — Make `query` read-only (removes real lock contention)

**Problem.** `cmd_query` writes before every read:

```40:43:tools/studio_stud/src/query.rs
    let mut conn = open_db(&place.db_path)?;
    init_schema(&conn)?;
    backfill_normalized_columns(&mut conn)?;
    let live = current_state(&conn)?;
```

`init_schema` (CREATE INDEX / INSERT OR REPLACE / ALTER) and `backfill` are writes that
fight the daemon's 300 ms delta writer and each other when the AI runs parallel queries.
This is the real contention behind the "SQLite lock" symptom (the 30 s timeout the AI saw
was actually Cursor's shell backgrounding default, but the write-lock fight is genuine).
The daemon already owns schema creation/migration on ingest, so query must not write.

**Changes:**
- Add `open_db_readonly(path)` in `tools/studio_stud/src/util.rs` using
  `rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY`. Do **not** run `PRAGMA journal_mode=WAL`
  (it fails on a read-only handle); set `busy_timeout` and `PRAGMA query_only=ON`.
- In `cmd_query`: use `open_db_readonly`, and **remove** the `init_schema` and
  `backfill_normalized_columns` calls.
- Safety net: if `current_state` fails (no baseline) or a normalized column is missing
  (DB predates normalization), return a clear, actionable error such as
  `"DB schema is stale — run `studio-stud capture` to re-baseline."` instead of crashing.
- Check `tools/studio_stud/src/analyze.rs` for the same write-on-read pattern; apply the
  same read-only treatment if present.

**Bulk note:** `--bulk` already runs N queries in one process on one connection — it is the
canonical "look up multiple things at once" path. Do **not** add daemon sub-process
spawning; concurrency belongs in the thread pool (Fix 1) plus `--bulk`.

**Risk:** low. Only edge is an old DB missing `path_norm`/`search_text`; daemon backfills
on ingest and the safety-net error covers it.

**Test:** existing query tests pass against a pre-built DB fixture; add a check that a
query succeeds while a writer holds the DB and that it does not grow `-wal`/`-shm`.

---

## Fix 3 — Soft re-baseline on unknown syncId (resilient reconnect)

**Problem.** When the daemon restarts mid-verify, the plugin's `syncId` is orphaned
(daemon upload/verify state is in-memory in `DaemonState`) and `/verify/complete` returns a
hard **503** via the error path, printing `unknown verify syncId …` (screenshots 1 & 2):

```301:311:tools/studio_stud/src/http.rs
    let (status, payload) = match result {
        Ok(value) => (map_response_status(&value), value),
        Err(err) => {
            eprintln!("request failed: {err:#}");
            (
                503,
                json!({ "ok": false, "error": format!("{err:#}") }),
            )
```

The plugin only sets `verifyNeeded = true` and retries the same broken handshake instead of
re-baselining.

**Daemon changes — `tools/studio_stud/src/http.rs`:**
- For the 6 "unknown syncId" spots (`/capture/body`, `/capture/chunk`, `/capture/complete`,
  `/verify/body`, `/verify/chunk`, `/verify/complete`), return a **soft 200** body instead
  of `Err`: `{ "ok": false, "error": "unknownSyncId", "needsRebaseline": true }`.
- In `map_response_status`, add an explicit branch so `ok:false` + `needsRebaseline` maps to
  **200** (so it is not downgraded to 404/503).

**Plugin changes — `tools/studio_stud/plugin/StudioStud.plugin.lua`:**
- In `Live.sendVerify` complete-failure branch (~line 2383): if
  `completeResult.needsRebaseline` or `error == "unknownSyncId"`, trigger the existing
  re-baseline path (retry/backoff machinery already at ~lines 2243-2268) instead of only
  setting `verifyNeeded = true`.
- Bump `PLUGIN_VERSION` to `0.3.6` and update the version note in `docs/studio-stud.md`.

**Risk:** low (error-path hardening; happy path unchanged).

**Test:** HTTP test posting `/verify/complete` with a bogus syncId asserts `200` +
`needsRebaseline:true`. Manual: restart daemon mid-session and confirm the plugin
auto-re-baselines with no manual Connect.

---

## Fix 4 — Bulk input + output guidance (quick AI-reliability win)

**Problem.** The bulk failure (`failed to parse bulk query JSON — EOF … line 1 column 0`)
was **empty stdin** — PowerShell's `'…' | exe --bulk -` did not deliver the body. The code
already supports inline JSON and `@file`, but the docs/rule recommend the fragile stdin
form:

```297:311:tools/studio_stud/src/query.rs
fn read_bulk_query_input(source: &str) -> Result<String> {
    let trimmed = source.trim();
    if trimmed == "-" {
        let mut input = String::new();
        std::io::stdin()
            .read_to_string(&mut input)
            .context("failed to read bulk query JSON from stdin")?;
        return Ok(input);
    }
    if trimmed.starts_with('{') || trimmed.starts_with('[') {
        return Ok(source.to_string());
    }
    let path = trimmed.strip_prefix('@').unwrap_or(trimmed);
    fs::read_to_string(path).with_context(|| format!("failed to read bulk query JSON from {path}"))
}
```

**Changes:**
- `docs/studio-stud.md` (the bulk example around line 178) and
  `.cursor/rules/studio-stud.mdc` (bulk example): replace the `--bulk -` stdin form with:
  - `.\studio-stud query <PLACE> --bulk '{"queries":[…]}'` (single quotes preserve JSON
    verbatim in PowerShell)
  - `.\studio-stud query <PLACE> --bulk @bulk.json`
- Add a one-line output note: **stdout is already compact JSON** — parse it directly or pipe
  to `ConvertFrom-Json`. Do **not** wrap it in `ConvertTo-Json` (that double-encodes; this
  was the intent behind the "convertojson" feedback, but the correct direction is
  `ConvertFrom-Json`).
- Optional code hardening: in `read_bulk_query_input`, if stdin is empty after reading `-`,
  return `"--bulk - received empty stdin (on Windows prefer --bulk '<json>' or --bulk @file.json)"`
  instead of the opaque serde EOF.

**Risk:** negligible (docs + one error string).

---

## Versioning & sequencing

- Daemon: bump `tools/studio_stud/Cargo.toml` `version` to `0.3.0` (threading + read-only
  query + soft errors), then rebuild the checked-in `tools/studio_stud/bin/studio-stud.exe`.
- Plugin: `PLUGIN_VERSION = "0.3.6"`.
- Suggested commit order (each independently shippable):
  1. Fix 4 (docs/quick-win)
  2. Fix 2 (read-only query)
  3. Fix 1 (multi-thread daemon)
  4. Fix 3 (soft re-baseline)
- Fixes 1 + 3 together fully address the disconnect.

## Residual risks / watch items (second-pass review)

These are not blockers and are not part of the four fixes, but they are the things
most likely to surface during continued live testing. Watch for them; address only if
they actually appear.

- **Concurrent writers after Fix 1.** With the daemon multi-threaded, a delta write
  (one thread) and a verify-complete ingest (another) can target the same SQLite file.
  WAL allows one writer at a time; the second waits on `busy_timeout(60s)`. A very large
  verify ingest could therefore stall a delta for its duration. The existing
  `revision_mismatch` guard in `apply_delta` (`live.rs`) preserves ordering, so this is a
  latency concern, not corruption. If verify ingests approach tens of seconds, consider
  a single dedicated DB-writer thread (channel/queue) instead of per-request writes.
- **Capture-upload orphan parity.** The baseline capture upload path
  (`/capture/body`, `/capture/chunk`, `/capture/complete`) uses the same in-memory
  `DaemonState.uploads` as verify, so a daemon restart mid-baseline orphans its syncId
  too. Fix 3 already covers these three endpoints — keep them in the same soft-error
  change, do not limit Fix 3 to the verify endpoints.
- **Auto-reconnect depends on the poll loop.** The "had to manually connect" symptom is
  most likely the older plugin (`0.3.4`) lacking the poll auto-reconnect block at
  `StudioStud.plugin.lua` ~lines 2606-2614. Shipping plugin `0.3.6` should resolve it.
  If a manual reconnect is still needed after `0.3.6`, the bug is in the
  `not ctx.isConnected()` reconnect condition, not the daemon — investigate there.
- **`ConvertFrom-Json` depth limit.** Windows PowerShell 5.1 caps `ConvertFrom-Json`
  nesting (~default depth) and can truncate deep `--tree` output. The AI should parse the
  tool's raw stdout JSON directly; only use `ConvertFrom-Json` for shallow payloads. Note
  this in the Fix 4 docs change.
- **Large `--bulk` output size.** A bulk call with several `--all`/deep-`--tree` queries
  can emit a large JSON blob and bloat AI context. Not a correctness issue; keep bulk
  queries bounded (the existing `limit`/`count-only` guidance still applies).
- **`active_place` staleness on island switch.** `resolve_place` falls back to the
  `active_place` file; immediately after switching islands (e.g. ExamplePlaceA →
  ExamplePlaceB) a query without an explicit `<PLACE>` may briefly resolve the previous
  place until the next baseline/delta rewrites `active_place`. Pass the explicit PlaceId
  when switching islands.

**Honest confidence statement:** the four fixes address the three reported symptoms and
their root causes, and this second pass found no additional defects of the same severity.
I can't guarantee zero further issues in live testing — the items above are the realistic
watch list. Daemon multi-threading (Fix 1) is the change with the most new surface area
and deserves the closest manual verification.

## Out of scope

- Daemon spawning query **sub-processes** — rejected; would re-introduce cold-start +
  write-lock contention. Use the thread pool + `--bulk` instead.
- Routing all queries through the daemon over HTTP — a possible future step once the daemon
  is multi-threaded, not needed for these reports.

## Build & verify

```powershell
cd tools/studio_stud
cargo build --release
cargo test
copy /Y target\release\studio-stud.exe bin\studio-stud.exe
```

Manual live test with Clayton: large-place verify (poll must not stall), daemon restart
mid-session (auto re-baseline, no manual Connect), parallel `query` calls and a `--bulk`
call (no lock contention, valid JSON returned).