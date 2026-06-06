# Phase 4 — Non-blocking baseline + script-Source capture

**Branch:** `feature/tick-phase4-baseline-source` (off `development` @ 0.4.16)
**Decisions:** D6 (non-blocking baseline), §9 seam #1 (script Source ingest).
**Master plan:** `docs/superpowers/plans/2026-06-05-tick-protocol-implementation.md` → "PHASE 4".

This is a **mixed phase**: the daemon Source-ingest is fully CI-testable; the yielding walk +
Source capture need a Studio capture test (the user's gate). Land plugin + daemon together so a
baseline produced by the new plugin populates `script_sources` end-to-end.

---

## Grounding facts (verified in code 2026-06-06, current line numbers)

### Plugin (`plugin/StudioStud.plugin.lua`)
- `Capture.readProperties(inst)` — **1685**. One `pcall` **per property** (1689). Used by BOTH the
  baseline (`buildSnapshot` 1841) and live delta (`buildUpsertedEntry` 2444).
- `Capture.collectBaseInstances()` — **1773**; recursive `walk()` at **1779** (synchronous DFS, no
  yield).
- `Capture.buildSnapshot(options)` — **1829**; the second heavy loop reading props per instance is
  `for inst, id in pairs(instanceIdByRef)` at **1837**.
- `buildUpsertedEntry(inst)` — **2402**; returns the per-instance live-delta entry, calls
  `readProperties` at 2444.
- `Capture.getPropertyNames(inst)` — **1649**; allow-list driven (`AllowList.namesFor`).
- `Live.classifyChangedProp(prop, curatedSet)` — **2200**; the Changed handler that uses it is the
  `inst.Changed:Connect` at **2293** (in `Live.registerInstance`, 2231).

### Daemon
- `normalize_newlines` — `src/write/safety.rs:17` = `input.replace("\r\n","\n").replace('\r',"\n")`.
- `sha256_hex` — `src/write/safety.rs:21` = Sha256(bytes) → hex.
  → **Source hash recipe = `sha256_hex(normalize_newlines(src).as_bytes())`** (must match projection).
- `insert_instance(tx, capture_id, inst)` — `src/capture.rs:440`. **Single funnel**: baseline
  (`ingest_rows` 363) AND live delta (`apply_delta` → `upsert_instance` 437) both call it.
  Serializes only `inst.get("properties")` into `property_json` (468/505).
- `upsert_instance` — `src/capture.rs:428` = `delete_instance_rows` + `insert_instance`.
- `delete_instance_rows` — `src/capture.rs:406`; deletes from `finding_samples, instance_tags,
  instance_attributes, instance_properties, keyword_hits, instances`. **Does NOT delete
  `script_sources`** (yet).
- `upsert_script_source(conn, capture_id, instance_id, source_text, source_hash)` —
  `src/storage.rs:808` (Phase 1 seam, currently `#[allow(dead_code)]`, unused). `INSERT OR REPLACE`,
  `last_synced_hash=NULL`. (`&Transaction` coerces to `&Connection` via Deref at the call site.)
- `canonical_instance_value` — `src/capture.rs:679`; reads `instances` columns + `instance_properties`
  + attributes + tags. **Never reads `script_sources`.** `fingerprint_instance` (661) hashes only
  the canonical value.

---

## CRITICAL discoveries (drive the design — NOT in the master plan)

1. **`Script.Source` is `Read=PluginSecurity, Write=PluginSecurity, CanSave=true`.**
   - `Read != "None"` → it is **excluded from the allow-list** → NOT returned by `getPropertyNames`
     → NOT captured by the generic property path. (Confirmed against the live API dump.)
   - But the plugin runs with PluginSecurity, so `inst.Source` **is readable** by us. → Source must
     be captured **specially** (read `inst.Source` for `LuaSourceContainer`), not via the allow-list.

2. **Live Source edits would be SILENTLY DROPPED today.** Because `"Source"` is not in the curated
   set, `Live.classifyChangedProp("Source", curated)` returns `"gap"` (2206) → the Changed handler
   calls `recordPropGap` and **does not dirty the instance** → no upsert → Source never ships.
   → Phase 4 MUST special-case `prop == "Source"` → `"dirty"` so a script edit dirties the instance
   and `buildUpsertedEntry` re-reads + ships Source.

3. **Fingerprint isolation is automatic** — only if we keep Source OUT of `properties`. `source` goes
   to the `script_sources` table (separate) and rides as a **top-level entry field** `source`, NOT
   inside `entry.properties`. `insert_instance` only serializes `properties` into `property_json`, and
   `canonical_instance_value` never reads `script_sources`, so the per-service XOR fingerprint and the
   `XOR(services)==global` invariant are untouched. (Locked with a regression test, Task G.)

4. **Hash authority = daemon (Rust).** The plugin ships the **raw** `Source` string; the daemon
   normalizes + hashes. One source of truth for the hash → guaranteed to equal the projection hash.
   Store the **normalized** text in `source_text` (idempotent: `sha256_hex(stored)` == stored hash).

---

## Tasks

### Plugin

**A. Yield the baseline walk (D6).**
- Add a module-scope constant near the other Capture constants: `local BASELINE_YIELD_EVERY = 500`.
- Add a pure helper `function Capture.shouldYield(processedCount, yieldEvery)` →
  `return yieldEvery > 0 and processedCount > 0 and (processedCount % yieldEvery) == 0`.
- In `collectBaseInstances.walk` (1779): increment a shared counter per instance appended (1805);
  when `Capture.shouldYield(counter, BASELINE_YIELD_EVERY)` → `task.wait()`.
- In `buildSnapshot`'s per-instance property loop (1837): same counter + `task.wait()` cadence (this
  loop is the heavier of the two — it reads all props per instance).
- **Race note (acceptable):** yielding lets the tree mutate mid-walk. Baseline is a snapshot; live
  deltas + drift recovery (Phase 5) reconcile. Existing `pcall` guards already tolerate vanished
  instances. Do NOT add locking.
- **Test (SelfTest):** truth-table for `shouldYield` — `(0,500)=false`, `(500,500)=true`,
  `(750,500)=false`, `(1000,500)=true`, `(n,0)=false`.

**B. Optimistic batch-`pcall` in `readProperties` (1685).**
- Replace the per-property `pcall` loop with: one `pcall` that reads + serializes ALL
  `getPropertyNames(inst)` into a local table; on success use it; on failure **reset** the table and
  fall back to the existing per-property `pcall` loop (preserving the `errors` array). Keep the
  Model bounding-box / Pivot block (1699-1713) unchanged.
- **Test (SelfTest):** pure `Capture.readPropsFrom(fakeInst, names)` wrapper test using a fake table —
  success path returns all names; a throwing key triggers the fallback and still returns the rest +
  records the error. (Factor the read loop so it can take a fake instance + name list.)

**C. Capture script `Source` (the seam).**
- Add `function Capture.readSource(inst)`: `if inst:IsA("LuaSourceContainer")` → `pcall` read
  `inst.Source` → return the string (or `nil` for non-scripts / read failure). `LuaSourceContainer`
  is the base of Script/LocalScript/ModuleScript — one check covers all + future script types.
- `buildSnapshot` per-instance loop (1837): `entry.source = Capture.readSource(inst)` (nil ⇒ key
  absent in JSON ⇒ non-scripts unaffected).
- `buildUpsertedEntry` (2448 return table): add `source = Capture.readSource(inst)`.
- **Do NOT** put Source into `entry.properties` (keeps it out of the fingerprint — discovery #3).

**D. Dirty scripts on Source change (discovery #2).**
- `Live.classifyChangedProp` (2200): add a branch **before** the curated check:
  `elseif prop == "Source" then return "dirty"`. Update the NOTE comment (2198) to document the
  PluginSecurity special-case.
- **Test (SelfTest):** add `classify Source -> dirty` alongside the existing classify assertions
  (3953-3955).
- **Known cost (note in code + plan, NOT fixed here):** a script dirtied for an unrelated property
  re-ships its full Source on the next delta. Acceptable for Phase 4; per-property source granularity
  is Phase 5 `/tick` territory.

### Daemon

**E. Wire Source ingest into `insert_instance` (`src/capture.rs:440`).**
- After the `instances` row insert (post-506), before returning:
  ```rust
  if let Some(src) = inst.get("source").and_then(Value::as_str) {
      let normalized = crate::write::safety::normalize_newlines(src);
      let hash = crate::write::safety::sha256_hex(normalized.as_bytes());
      crate::storage::upsert_script_source(tx, capture_id, &id, &normalized, &hash)?;
  }
  ```
  (Use the crate's existing import style; `&Transaction` → `&Connection` via Deref.) This one site
  covers baseline ingest AND live-delta upserts (both funnel here).
- Remove `#[allow(dead_code)]` from `upsert_script_source`.

**F. Clean `script_sources` on delete/re-upsert (`delete_instance_rows`, `src/capture.rs:406`).**
- Add `"script_sources"` to the table list (411-418). This handles true removals AND re-upserts
  (`upsert_instance` deletes then re-inserts → idempotent).

**G. Tests (CLI/HTTP integration, `tests/live_convergence.rs` or sibling).**
1. `script_source_round_trip`: ingest a baseline fixture containing a ModuleScript with a `source`
   field that uses **CRLF** newlines → assert `script_sources` has the **normalized** (`\n`) text and
   `source_hash == sha256_hex(normalize_newlines(raw))`. (Add a `script-source <place> <path>` debug
   subcommand OR query the DB directly in the test — prefer the debug subcommand for parity with
   `live-services`.)
2. `delta_updates_script_source`: apply_delta upsert of the same instance with new source → row
   updated; apply_delta removal → row gone (proves Task F).
3. `source_excluded_from_fingerprint` (regression, locks discovery #3): `fingerprint_instance` for an
   instance is **byte-identical** whether the upsert Value carries a `source` field or not. (Insert
   twice — once with `source`, once without — assert equal digests; assert the service/global
   fingerprint XOR invariant holds.)
4. `non_script_no_source_row`: ingest a Part (no `source`) → zero `script_sources` rows, no error.
- Add a fixture (e.g. `tests/fixtures/live/baseline_script.json` or extend `baseline.json`) with a
  ModuleScript carrying `source` with CRLF.

---

## ✅ PHASE 4 GATE
- `cargo test` green (incl. the 4 new tests; XOR invariant intact).
- Plugin SelfTest green (`shouldYield` table, `readPropsFrom` fallback, `classify Source -> dirty`).
- **Studio manual (user gate):** capture a large place → window stays responsive (no multi-second
  freeze). After capture, `script_sources` is populated and each hash equals the projection hash for
  identical bytes. Live-edit a script's Source → the edit ships (appears in a delta) and updates the
  stored source/hash.

## Version
Bump via `scripts\bump-version.ps1` to **0.4.17** as part of the push to `development` (policy: every
dev push bumps). Plugin + daemon move together.

## Out of scope (deferred)
- Per-property source granularity / only-ship-source-when-Source-changed (Phase 5 `/tick`).
- `last_synced_hash` reconciliation + projection writeback (Phase 5/6).
- Defaults skip (P5/6).
