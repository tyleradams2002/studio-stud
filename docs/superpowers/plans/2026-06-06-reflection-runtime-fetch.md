# Phase R — Runtime Reflection Fetch (D14/D15 pulled forward)

> **For Composer 2.5 (Cursor):** Execute task-by-task with TDD. **Daemon-only (Rust)** — no plugin
> change. Mostly CI-testable (parser/filter/cache/fallback); only the live network fetch is manual,
> and its endpoints+schema are **already verified live** (see below). Branch `feature/tick-reflection-fetch`
> (off `development`, plan committed on it). Parent design: `docs/tick-protocol-redesign-design.md`
> (D14, D15). Repurposes the Phase 2 scaffolding in `src/reflection.rs`.

**Goal:** The daemon fetches the **latest Roblox API dump at runtime**, generates the property
allow-list from it, caches it, and serves it via `/studio-stud/allowlist` — so the allow-list
reflects Roblox's current properties **without a daemon rebuild**. Falls back to the bundled
`rbx_reflection_database` when offline. The plugin is unchanged (it already fetches `/allowlist`).

---

## Verified facts (hit the live endpoints — do NOT re-guess)

- **Version:** `GET https://setup.rbxcdn.com/versionQTStudio` → plain-text hash, e.g.
  `version-d0e8cfcd943d4ae2`.
- **Dump:** `GET https://setup.rbxcdn.com/{hash}-Full-API-Dump.json` → 200, JSON. (Use **Full**-API-Dump;
  the plain `API-Dump.json` omits ~160 classes — 682 vs the bundled ~846.)
- **Schema (confirmed):** top-level `{ Classes:[...], Enums:[...], Version:[...] }`. Each class:
  `{ Name, Superclass, Tags?:[...], Members:[...] }` (root `Instance` has `Superclass:"<<<ROOT>>>"`).
  Each property member:
  ```json
  { "MemberType":"Property", "Name":"Transparency",
    "Security":{"Read":"None","Write":"None"},
    "Serialization":{"CanLoad":true,"CanSave":true},
    "Tags":["ReadOnly","NotReplicated"],          // optional
    "ValueType":{"Category":"Primitive","Name":"float"} }
  ```
- **Filter (mirrors Phase 2's bundled filter, using raw-dump fields):** include a property iff
  `MemberType=="Property"` ∧ `Security.Read=="None"` ∧ `Serialization.CanSave==true` ∧ Tags has
  none of `Deprecated|Hidden|NotScriptable|WriteOnly`. `read_only = Tags has "ReadOnly" || Security.Write != "None"`.
- **`ureq` is already a dependency** — model the HTTP agent on `src/update.rs::agent()`.
- **Existing scaffolding to repurpose** (`src/reflection.rs`): `current_version()`, `needs_update()`,
  `generate_allowlist_for<F>(fetch)`, stub `fetch_dump()`, and the `AllowList`/`PropEntry` structs.

## Design (daemon owns freshness; plugin unchanged)

- A shared `Arc<RwLock<AllowList>>` holds the **current best** allow-list. Initialized to the
  **bundled** `generate_allowlist()` (instant, offline-safe).
- **On serve startup:** spawn a background thread → `refresh()` (so serve never blocks on the network).
- **Background timer:** every ~60 min, `refresh()` again.
- **`refresh()`:** fetch `versionQTStudio`; if it equals the current cached hash → no-op. Else: load
  the allow-list from the on-disk cache for that hash, or fetch `{hash}-Full-API-Dump.json` →
  `generate_allowlist_from_dump` → write to disk cache; then swap into the shared `RwLock`.
- **`GET /allowlist`** just reads the shared state — **never blocks on the network**. So a connect at
  most reflects the last refresh (Roblox deploys infrequently; 60 min staleness is fine).
- **Fallback chain:** fetched(live) → cached(last good on disk) → bundled crate. Any failure leaves
  the current state intact.
- **Versioning:** the fetched `AllowList.version` is set to the **`versionQTStudio` hash** (e.g.
  `version-d0e8cfcd…`), so `/allowlist` showing a `version-…` hash is the at-a-glance proof it fetched
  live (vs the bundled dotted `0.700.0.7000935`). Disk cache is keyed by that hash.

**Test reality:** parser, filter, cache, fallback, and TTL logic are **CI-testable** (unit +
integration with the bundled source in CI — no network). The live fetch is verified manually (the
endpoints are already proven to work).

---

## Task R.1 — Raw-dump parser + filter (`generate_allowlist_from_dump`)

**Files:** Modify `src/reflection.rs`; test in-crate.

- [ ] **Step 1: Failing test** (small inline fixture exercising every filter branch)

```rust
#[test]
fn allowlist_from_dump_filters_correctly() {
    let raw = r#"{
      "Classes": [
        {"Name":"Instance","Superclass":"<<<ROOT>>>","Members":[
          {"MemberType":"Property","Name":"Name",
           "Security":{"Read":"None","Write":"None"},"Serialization":{"CanLoad":true,"CanSave":true}}
        ]},
        {"Name":"BasePart","Superclass":"Instance","Members":[
          {"MemberType":"Property","Name":"Transparency",
           "Security":{"Read":"None","Write":"None"},"Serialization":{"CanLoad":true,"CanSave":true}},
          {"MemberType":"Property","Name":"AssemblyMass",
           "Security":{"Read":"None","Write":"None"},"Serialization":{"CanLoad":false,"CanSave":false},
           "Tags":["ReadOnly"]},
          {"MemberType":"Property","Name":"LegacyThing",
           "Security":{"Read":"None","Write":"None"},"Serialization":{"CanLoad":true,"CanSave":true},
           "Tags":["Deprecated"]},
          {"MemberType":"Property","Name":"SecretProp",
           "Security":{"Read":"RobloxScriptSecurity","Write":"RobloxScriptSecurity"},
           "Serialization":{"CanLoad":true,"CanSave":true}},
          {"MemberType":"Function","Name":"Resize",
           "Security":{"Read":"None","Write":"None"},"Serialization":{"CanLoad":false,"CanSave":false}}
        ]}
      ], "Enums": [], "Version": [0,1,2,3]
    }"#;
    let al = generate_allowlist_from_dump(raw, "version-test").expect("parse");
    assert_eq!(al.version, "version-test");
    let bp = al.classes.get("BasePart").expect("BasePart");
    let by = |n: &str| bp.iter().find(|p| p.name == n);
    assert!(by("Transparency").is_some_and(|p| !p.read_only), "writable serializing prop");
    assert!(by("Name").is_some(), "inherited from Instance");
    assert!(by("AssemblyMass").is_none(), "ReadOnly + non-serializing excluded (CanSave=false)");
    assert!(by("LegacyThing").is_none(), "Deprecated excluded");
    assert!(by("SecretProp").is_none(), "non-None Read security excluded");
    assert!(by("Resize").is_none(), "functions excluded");
}
```

Run: `cargo test --lib reflection::tests::allowlist_from_dump_filters_correctly` → FAIL (undefined).

- [ ] **Step 2: Implement** — add the raw structs + the generator in `src/reflection.rs`:

```rust
#[derive(serde::Deserialize)]
struct RawDump { #[serde(rename = "Classes")] classes: Vec<RawClass> }
#[derive(serde::Deserialize)]
struct RawClass {
    #[serde(rename = "Name")] name: String,
    #[serde(rename = "Superclass")] superclass: Option<String>,
    #[serde(rename = "Members")] members: Vec<RawMember>,
}
#[derive(serde::Deserialize)]
struct RawMember {
    #[serde(rename = "MemberType")] member_type: String,
    #[serde(rename = "Name")] name: String,
    #[serde(rename = "Security")] security: Option<RawSecurity>,
    #[serde(rename = "Serialization")] serialization: Option<RawSerialization>,
    #[serde(rename = "Tags", default)] tags: Vec<String>,
}
#[derive(serde::Deserialize)]
struct RawSecurity { #[serde(rename = "Read")] read: String, #[serde(rename = "Write")] write: String }
#[derive(serde::Deserialize)]
struct RawSerialization { #[serde(rename = "CanSave")] can_save: bool }

fn raw_included(m: &RawMember) -> bool {
    m.member_type == "Property"
        && m.security.as_ref().map(|s| s.read == "None").unwrap_or(false)
        && m.serialization.as_ref().map(|s| s.can_save).unwrap_or(false)
        && !m.tags.iter().any(|t| matches!(t.as_str(),
            "Deprecated" | "Hidden" | "NotScriptable" | "WriteOnly"))
}
fn raw_read_only(m: &RawMember) -> bool {
    m.tags.iter().any(|t| t == "ReadOnly")
        || m.security.as_ref().map(|s| s.write != "None").unwrap_or(true)
}

pub(crate) fn generate_allowlist_from_dump(json: &str, version: &str) -> anyhow::Result<AllowList> {
    let dump: RawDump = serde_json::from_str(json)?;
    let by_name: std::collections::HashMap<&str, &RawClass> =
        dump.classes.iter().map(|c| (c.name.as_str(), c)).collect();
    let mut classes = std::collections::BTreeMap::new();
    for class in &dump.classes {
        let mut seen = std::collections::BTreeSet::new();
        let mut out: Vec<PropEntry> = Vec::new();
        // walk class + superclass chain (nearest wins); stop at <<<ROOT>>> / missing
        let mut cur = Some(class);
        while let Some(c) = cur {
            for m in &c.members {
                if m.member_type != "Property" || seen.contains(&m.name) { continue; }
                seen.insert(m.name.clone());
                if raw_included(m) {
                    out.push(PropEntry { name: m.name.clone(), read_only: raw_read_only(m) });
                }
            }
            cur = match &c.superclass {
                Some(s) if s != "<<<ROOT>>>" => by_name.get(s.as_str()).copied(),
                _ => None,
            };
        }
        out.sort_by(|a, b| a.name.cmp(&b.name));
        classes.insert(class.name.clone(), out);
    }
    Ok(AllowList { version: version.to_string(), classes })
}
```

Run → PASS. **Commit** `feat(daemon): parse Roblox Full-API-Dump.json into the allow-list (raw filter)`.

## Task R.2 — Real fetch (version + dump) + fallback

**Files:** `src/reflection.rs` (replace the stub `fetch_dump`, add `fetch_current_version` + `fetch_allowlist`); reuse the `update.rs` agent pattern. Test the fallback in-crate.

- [ ] **Step 1: Failing test** — the fallback must yield the bundled list, never panic, when the
  fetcher errors (no network in CI):

```rust
#[test]
fn fetch_allowlist_falls_back_to_bundled() {
    // generate_allowlist_for takes a fetcher returning the dump JSON; on error → bundled.
    let al = generate_allowlist_for(|_ver| Err(anyhow::anyhow!("offline")));
    assert_eq!(al.version, current_version()); // bundled dotted version
    assert!(al.classes.contains_key("BasePart"));
}
```

- [ ] **Step 2: Implement** — wire the real fetchers and make `generate_allowlist_for` parse the dump:

```rust
fn agent() -> ureq::Agent { /* model on src/update.rs::agent() — sensible timeouts */ }

pub(crate) fn fetch_current_version() -> anyhow::Result<String> {
    let body = agent().get("https://setup.rbxcdn.com/versionQTStudio").call()?
        .body_mut().read_to_string()?;          // adjust to the ureq 3.x body API in update.rs
    Ok(body.trim().to_string())
}

fn fetch_dump(hash: &str) -> anyhow::Result<String> {
    let url = format!("https://setup.rbxcdn.com/{hash}-Full-API-Dump.json");
    Ok(agent().get(&url).call()?.body_mut().read_to_string()?)
}

/// fetcher returns the raw dump JSON for a version hash; on ANY error → bundled allow-list.
pub(crate) fn generate_allowlist_for<F>(fetch: F) -> AllowList
where F: FnOnce(&str) -> anyhow::Result<String> {
    let result = (|| -> anyhow::Result<AllowList> {
        let hash = fetch_current_version()?;
        let json = fetch(&hash)?;
        generate_allowlist_from_dump(&json, &hash)
    })();
    result.unwrap_or_else(|_| generate_allowlist())
}

/// Live fetch: returns the fetched allow-list, or the bundled one on failure.
pub(crate) fn fetch_allowlist() -> AllowList { generate_allowlist_for(|hash| fetch_dump(hash)) }
```

> Match the exact `ureq` 3.x request/response API used in `src/update.rs` (the `.body_mut().read_to_string()`
> calls above are indicative — copy the real pattern from `update.rs`).

- [ ] **Step 3:** Run the fallback test → PASS. **Commit** `feat(daemon): live-fetch the Roblox API dump (bundled fallback)`.

## Task R.3 — Disk cache (by version hash)

**Files:** `src/reflection.rs` (cache read/write); test in-crate (round-trip).

- [ ] **Step 1: Failing test** — write an AllowList to a temp cache dir, read it back identically.
- [ ] **Step 2: Implement** `cache_path(root, hash)` → `{root}/reflection/{safe(hash)}.json`,
  `write_cache(root, &AllowList)`, `read_cache(root, hash) -> Option<AllowList>` (serde_json; ignore
  errors → None). `AllowList`/`PropEntry` need `Deserialize` added (currently only `Serialize`).
- [ ] **Step 3:** Run → PASS. **Commit** `feat(daemon): cache generated allow-list to disk by version hash`.

## Task R.4 — Shared state + refresh + wire into serve

**Files:** `src/reflection.rs` (refresh), `src/http.rs` (`ServeConfig` + `/allowlist` reads shared
state), `src/cli.rs` (`cmd_serve` spawns startup + timer refresh). Test via HTTP integration.

- [ ] **Step 1:** Add a shared type `pub type SharedAllowList = Arc<RwLock<AllowList>>` and
  `refresh(shared, storage_root)`:
  ```text
  hash = fetch_current_version()?            // on error: return (keep current)
  if hash == shared.read().version: return    // already current
  let al = read_cache(root, &hash)
            .unwrap_or_else(|| { let a = fetch_allowlist(); write_cache(root, &a); a });
  *shared.write() = al;
  ```
- [ ] **Step 2:** `ServeConfig` gains `pub allowlist: reflection::SharedAllowList`. In `cmd_serve`,
  init it to `Arc::new(RwLock::new(reflection::generate_allowlist()))` (bundled, instant), then spawn:
  (a) a one-shot background `refresh()` at startup, and (b) a loop thread that `sleep(60 min)` →
  `refresh()` (respecting the `shutdown` flag, like the Phase-1 eviction thread).
- [ ] **Step 3:** Change the `/studio-stud/allowlist` handler to read the shared state instead of
  calling `generate_allowlist()` directly:
  ```rust
  let al = config.allowlist.read().map_err(|_| anyhow!("allowlist lock poisoned"))?.clone();
  json!({ "ok": true, "version": al.version, "classes": al.classes })
  ```
- [ ] **Step 4: HTTP integration test** (CI, no network) — spawn `serve`, GET `/allowlist`, assert it
  still returns a `version` + `classes` map with `BasePart→Transparency` (the bundled list, since the
  background fetch may not have completed / no network in CI). This proves the shared-state path works
  and never blocks.
- [ ] **Step 5:** `cargo test` + `cargo clippy --lib` (changed files clean). **Commit**
  `feat(daemon): self-refreshing allow-list (startup + hourly), served from shared state`.

---

## ✅ GATE

- [ ] `cargo test` — all green (parser/filter, fallback, cache round-trip, `/allowlist` integration).
- [ ] `cargo clippy --lib 2>&1 | grep reflection` — no new warnings.
- [ ] **Manual (live, with network):** run `studio-stud serve --verbose`; within ~a few seconds the
  background refresh completes; then `(irm http://127.0.0.1:31878/studio-stud/allowlist).version`
  returns a **`version-…` hash** (proves it fetched live from Roblox), not the bundled
  `0.700.0.7000935`. A `reflection/version-….json` cache file appears under the storage root.
- [ ] **Manual (offline):** with no network at startup, `/allowlist` still serves the bundled list
  (version `0.700.x`) and the daemon doesn't hang. Restoring network → next refresh swaps to live.

When the gate is green, STOP and report: the `/allowlist` version before (bundled dotted) vs after
(live hash), the class count, and the cache file path.

---

## Notes / deferred
- **No plugin change** — it already fetches `/allowlist` on connect and gets whatever the daemon
  currently holds. The D15 plugin-reports-its-Studio-version handshake is **not needed** (the daemon
  owns freshness) and stays unbuilt.
- **Gap-probe reporting** (plugin → daemon → validate-and-add discovered props) remains deferred to
  Phase 5; this phase only changes where the *baseline* allow-list comes from.
- Per the version policy, the merge to `development` carries a version bump.

_Plan grounded in the live-verified Roblox endpoints (`setup.rbxcdn.com/versionQTStudio` +
`{hash}-Full-API-Dump.json`) and schema, and the Phase 2 `reflection.rs` scaffolding._
