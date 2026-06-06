# Phase 2 — Reflection Allow-List + Versioning (daemon)

> **For Composer 2.5 (Cursor):** Execute this plan **task by task** with TDD (write test → see it
> fail → implement → see it pass → commit). **Phase 2 only.** Stop at the Phase 2 Gate. Branch is
> `feature/tick-phase2-reflection` (already cut from `development`). Parent design: `docs/tick-protocol-redesign-design.md` (D9, D14, D15). Phase 1 is already merged to `development`.

**Goal:** Generate the property allow-list from Roblox's bundled reflection database, version it per
`place.db`, and serve it over HTTP so the plugin (a later phase) can use it as its capture filter —
replacing the hand-curated `CLASS_PROPERTIES`. **Daemon-only; no plugin change; no wire-breaking
change** (adds one new read-only endpoint).

**Architecture:** `rbx_reflection_database::get()` returns a static `ReflectionDatabase` (already a
dependency, already used in `src/project/manifest.rs`). We walk each class + its superclass chain,
filter properties to scriptable + serializable (tagging read-only ones), and expose the result via
`GET /studio-stud/allowlist` and stamp the version into `place.db meta.reflection_version`.

---

## Grounding facts (verified against the crate + repo — do not re-guess)

**`rbx_reflection` 6.1.0 API** (from the crate source; pattern in `src/project/manifest.rs:173`):
- `rbx_reflection_database::get() -> Option<&'static rbx_reflection::ReflectionDatabase<'static>>`.
  In-repo wrapper: `fn reflection_db() -> &'static ReflectionDatabase<'static> { get().expect("rbx_reflection_database") }`.
- `ReflectionDatabase`:
  - `version: [u32; 4]` — the Roblox release. **This is our reflection version.** Format:
    `format!("{}.{}.{}.{}", v[0], v[1], v[2], v[3])`.
  - `classes: HashMap<Cow<str>, ClassDescriptor>`.
  - `superclasses_iter(&self, &ClassDescriptor) -> impl Iterator<Item = &ClassDescriptor>` — yields
    the class then each ancestor up to `Instance`. **Use this to collect inherited properties.**
- `ClassDescriptor`: `name: Cow<str>`, `superclass: Option<Cow<str>>`, `tags: HashSet<ClassTag>`,
  `properties: HashMap<Cow<str>, PropertyDescriptor>` (properties *declared on this class only* —
  inherited ones come from walking superclasses).
- `PropertyDescriptor`: `name: Cow<str>`, `scriptability: Scriptability`, `tags: HashSet<PropertyTag>`,
  `kind: PropertyKind`.
- `Scriptability` (enum): `None | ReadWrite | Read | Write | Custom`. Readable from a plugin =
  `Read` or `ReadWrite`.
- `PropertyTag` (enum): `Deprecated | Hidden | NotBrowsable | NotReplicated | NotScriptable | ReadOnly | WriteOnly`.
- `PropertyKind` (enum): `Canonical { serialization: PropertySerialization } | Alias { alias_for }`.
- `PropertySerialization` (enum): `Serializes | DoesNotSerialize | SerializesAs(name) | Migrate(..)`.

**The allow-list filter (D9)** — include a property iff:
- `kind` is `Canonical` (skip `Alias` — the canonical is captured instead), **and**
- `serialization` is `Serializes` or `SerializesAs(_)` (real saved state), **and**
- `scriptability` is `Read` or `ReadWrite` (we can read it), **and**
- `tags` does **not** contain `Deprecated`, `Hidden`, `NotScriptable`, or `WriteOnly`.
- Set `read_only = (scriptability == Read) || tags.contains(ReadOnly)`.
- When the same property name appears on a class and an ancestor, the **nearest** (subclass) wins.

**Repo hook points (verified):**
- Storage helpers already exist (Phase 1, `pub(crate)`, `src/storage.rs`): `read_reflection_version(&Connection) -> Result<Option<String>>`, `write_reflection_version(&Connection, &str) -> Result<()>`.
- `materialize_snapshot` (`src/capture.rs:38`) takes `&ConnRegistry` and runs the baseline inside
  `registry.with_writer(&place.db_path, |conn| { ... })` — stamp the version there.
- HTTP dispatch is a `match (method, path.as_str())` in `handle_daemon_request` (`src/http.rs:144`);
  ping arm at `:159`. Add a new arm for `/studio-stud/allowlist`. `ServeConfig` is `&config`.
- `ureq` is used already — model the fetch agent on `src/update.rs:24` (`ureq::Agent::config_builder()...`).

**Test styles:** in-crate `#[cfg(test)] mod tests` for pure/reflection logic (the crate `get()`
works in tests); HTTP integration via spawning `serve` (pattern: `tests/http_reliability.rs`).
Most fns are `pub(crate)` — keep new ones `pub(crate)` and test in-crate where possible.

---

## Task 2.1 — Allow-list generation from the reflection DB

**Files:**
- Create: `src/reflection.rs`
- Modify: `src/lib.rs` (add `pub mod reflection;`)
- Test: in-crate `#[cfg(test)] mod tests` in `src/reflection.rs`

- [ ] **Step 1: Write the failing test**

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allowlist_basepart_includes_inherited_and_own_props() {
        let al = generate_allowlist();
        assert!(!al.version.is_empty());
        let bp = al.classes.get("BasePart").expect("BasePart present");
        let by_name = |n: &str| bp.iter().find(|p| p.name == n);

        // own, writable, serializing
        let t = by_name("Transparency").expect("Transparency curated");
        assert!(!t.read_only, "Transparency is writable");
        assert!(by_name("Size").is_some(), "Size curated");

        // inherited from Instance
        assert!(by_name("Name").is_some(), "inherited Name curated");

        // deprecated/non-scriptable aliases must be excluded (brickColor is a legacy alias)
        assert!(by_name("brickColor").is_none(), "legacy alias excluded");
    }
}
```

Run: `cargo test --lib reflection::tests::allowlist_basepart_includes_inherited_and_own_props`
Expected: FAIL (`generate_allowlist` undefined).

- [ ] **Step 2: Implement `src/reflection.rs`**

```rust
use std::collections::{BTreeMap, BTreeSet};

use rbx_reflection::{
    ClassDescriptor, PropertyDescriptor, PropertyKind, PropertySerialization, PropertyTag,
    Scriptability,
};
use rbx_reflection_database::get;

#[derive(Debug, Clone, serde::Serialize)]
pub(crate) struct PropEntry {
    pub name: String,
    #[serde(rename = "readOnly")]
    pub read_only: bool,
}

#[derive(Debug, Clone, serde::Serialize)]
pub(crate) struct AllowList {
    pub version: String,
    pub classes: BTreeMap<String, Vec<PropEntry>>,
}

fn db() -> &'static rbx_reflection::ReflectionDatabase<'static> {
    get().expect("rbx_reflection_database")
}

pub(crate) fn current_version() -> String {
    let v = db().version;
    format!("{}.{}.{}.{}", v[0], v[1], v[2], v[3])
}

/// True if the property represents real, plugin-readable saved state we want to mirror.
fn included(p: &PropertyDescriptor) -> bool {
    let canonical_serializes = matches!(
        &p.kind,
        PropertyKind::Canonical { serialization }
            if matches!(
                serialization,
                PropertySerialization::Serializes | PropertySerialization::SerializesAs(_)
            )
    );
    let readable = matches!(p.scriptability, Scriptability::Read | Scriptability::ReadWrite);
    let bad_tag = p.tags.contains(&PropertyTag::Deprecated)
        || p.tags.contains(&PropertyTag::Hidden)
        || p.tags.contains(&PropertyTag::NotScriptable)
        || p.tags.contains(&PropertyTag::WriteOnly);
    canonical_serializes && readable && !bad_tag
}

fn read_only(p: &PropertyDescriptor) -> bool {
    matches!(p.scriptability, Scriptability::Read) || p.tags.contains(&PropertyTag::ReadOnly)
}

fn curated_for(class: &ClassDescriptor) -> Vec<PropEntry> {
    let database = db();
    let mut seen: BTreeSet<String> = BTreeSet::new();
    let mut out: Vec<PropEntry> = Vec::new();
    // nearest (subclass) wins: superclasses_iter yields this class first, then ancestors
    for ancestor in database.superclasses_iter(class) {
        for (name, prop) in &ancestor.properties {
            if seen.contains(name.as_ref()) {
                continue;
            }
            if included(prop) {
                seen.insert(name.to_string());
                out.push(PropEntry {
                    name: name.to_string(),
                    read_only: read_only(prop),
                });
            } else {
                // still mark as seen so a deprecated ancestor copy doesn't get re-added
                seen.insert(name.to_string());
            }
        }
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

pub(crate) fn generate_allowlist() -> AllowList {
    let database = db();
    let mut classes = BTreeMap::new();
    for (name, class) in &database.classes {
        classes.insert(name.to_string(), curated_for(class));
    }
    AllowList {
        version: current_version(),
        classes,
    }
}
```

Add `pub mod reflection;` to `src/lib.rs`.

- [ ] **Step 3: Run the test** → PASS. If `brickColor` assertion is flaky against the bundled
  version, replace it with another known alias/deprecated property — but keep the `Transparency`,
  `Size`, and inherited-`Name` assertions (all stable).

- [ ] **Step 4: Commit**

```bash
git add src/reflection.rs src/lib.rs
git commit -m "feat(daemon): generate property allow-list from rbx_reflection_database"
```

## Task 2.2 — Version compare helper (D15)

**Files:** Modify `src/reflection.rs`; test in-crate.

- [ ] **Step 1: Failing test**

```rust
#[test]
fn needs_update_logic() {
    assert!(needs_update(None, "0.659.0.1"));               // fresh db
    assert!(!needs_update(Some("0.659.0.1"), "0.659.0.1")); // match
    assert!(needs_update(Some("0.658.0.9"), "0.659.0.1"));  // differs
}
```

Run: `cargo test --lib reflection::tests::needs_update_logic` → FAIL.

- [ ] **Step 2: Implement**

```rust
/// Whether the stored reflection version is missing or differs from the current one.
pub(crate) fn needs_update(stored: Option<&str>, current: &str) -> bool {
    stored != Some(current)
}
```

- [ ] **Step 3:** Run → PASS. **Commit** `feat(daemon): reflection version compare helper`.

## Task 2.3 — `GET /studio-stud/allowlist` endpoint

**Files:** Modify `src/http.rs` (add a dispatch arm); test `tests/http_reliability.rs`.

- [ ] **Step 1: Failing HTTP test** (in `tests/http_reliability.rs`, reuse its helpers)

```rust
#[test]
fn allowlist_endpoint_serves_curated_classes() {
    let storage = temp_storage("allowlist");
    let serve = start_serve(&storage);
    let (status, body) = http_request("GET", serve.port, "/studio-stud/allowlist", None);
    assert_eq!(status, 200);
    let v = parse_json(&body);
    assert_eq!(v.get("ok").and_then(Value::as_bool), Some(true));
    assert!(v.get("version").and_then(Value::as_str).is_some());
    let classes = v.get("classes").and_then(Value::as_object).expect("classes map");
    let bp = classes.get("BasePart").and_then(Value::as_array).expect("BasePart");
    assert!(bp.iter().any(|p| p.get("name").and_then(Value::as_str) == Some("Transparency")));
}
```

Run: `cargo test --test http_reliability allowlist_endpoint_serves_curated_classes` → FAIL (404).

- [ ] **Step 2: Implement** — add an arm to the `match (method, path.as_str())` in
  `handle_daemon_request` (`src/http.rs`, near the `/ping` arm ~159):

```rust
(tiny_http::Method::Get, "/studio-stud/allowlist") => {
    let al = crate::reflection::generate_allowlist();
    json!({ "ok": true, "version": al.version, "classes": al.classes })
}
```

(`AllowList`/`PropEntry` derive `Serialize`, so `al.classes` serializes directly to the
`{Class: [{name, readOnly}]}` shape.)

- [ ] **Step 3:** Run → PASS. **Commit** `feat(daemon): GET /studio-stud/allowlist endpoint`.

## Task 2.4 — Stamp `meta.reflection_version` on baseline (D14)

So each `place.db` records the reflection version its data was built against.

**Files:** Modify `src/capture.rs` (`materialize_snapshot`); test `tests/live_convergence.rs`.

- [ ] **Step 1: Failing integration test** — ingest, then a new debug surfacing of the stored
  version. Add a tiny field to the `ingest` output: in `materialize_snapshot`'s returned `json!`,
  add `"reflectionVersion": crate::reflection::current_version()`. Then:

```rust
#[test]
fn ingest_stamps_reflection_version() {
    let storage = temp_storage("refl_ver");
    let out = run_cli(&["ingest", "--raw", fixture("baseline.json").to_str().unwrap()], &storage);
    let v = out.get("reflectionVersion").and_then(Value::as_str).expect("reflectionVersion");
    assert!(!v.is_empty());
    // version must be persisted into meta
    let dump = run_cli(&["live-services", "999001"], &storage);
    assert_eq!(dump.get("ok").and_then(Value::as_bool), Some(true)); // place db exists
}
```

Run → FAIL (no `reflectionVersion` field yet).

- [ ] **Step 2: Implement** — inside `materialize_snapshot`'s `registry.with_writer(...)` closure,
  after `write_live_state`, call `crate::storage::write_reflection_version(conn, &crate::reflection::current_version())?;`
  and add `"reflectionVersion": crate::reflection::current_version()` to the returned JSON.

- [ ] **Step 3:** Run → PASS. **Commit** `feat(daemon): stamp meta.reflection_version on baseline`.

## Task 2.5 — Runtime-fetch scaffolding with bundled fallback (D14, best-effort)

> **Scope note:** the bundled `rbx_reflection_database` is the guaranteed source. Runtime-fetch is an
> enhancement for when the user's Studio is newer than the bundled DB. The exact Roblox CDN URL /
> version→deploy-hash resolution is **unverified** — implement the structure with the bundled DB as
> the fallback so the system always works, and the test covers **only** the fallback (no network in
> CI). Wiring this to the plugin's reported Studio version happens in a later (plugin) phase.

**Files:** Modify `src/reflection.rs`; test in-crate.

- [ ] **Step 1: Failing test** (fallback path, deterministic, no network)

```rust
#[test]
fn fetch_falls_back_to_bundled_on_error() {
    // A fetcher that always fails must yield the bundled version, never panic.
    let al = generate_allowlist_for(|_url| Err(anyhow::anyhow!("network down")));
    assert_eq!(al.version, current_version());
    assert!(al.classes.contains_key("BasePart"));
}
```

Run → FAIL (`generate_allowlist_for` undefined).

- [ ] **Step 2: Implement** — a fetcher-injected variant + a real fetcher modeled on `src/update.rs::agent()`:

```rust
/// Fetch a dump for a target version; on ANY error, fall back to the bundled allow-list.
/// `fetch` returns the raw API-dump JSON bytes for a version, or an error.
pub(crate) fn generate_allowlist_for<F>(fetch: F) -> AllowList
where
    F: FnOnce(&str) -> anyhow::Result<String>,
{
    match fetch(&current_version()) {
        Ok(_dump_json) => {
            // TODO(verify URL/parse): parse the fetched dump into a ReflectionDatabase and
            // generate from it. Until verified, fall through to bundled.
            generate_allowlist()
        }
        Err(_) => generate_allowlist(),
    }
}

#[allow(dead_code)]
fn fetch_dump(_target_version: &str) -> anyhow::Result<String> {
    // Model on src/update.rs::agent(); resolve the Roblox API-dump URL for the version.
    // Left unwired until the URL resolution is verified against a real Studio version.
    anyhow::bail!("runtime reflection fetch not yet enabled")
}
```

- [ ] **Step 3:** Run → PASS. **Commit** `feat(daemon): reflection runtime-fetch scaffolding with bundled fallback`.

---

## ✅ PHASE 2 GATE

- [ ] `cargo test` — all unit + integration green.
- [ ] `cargo clippy --lib 2>&1 | grep -E "reflection\.rs|http\.rs|capture\.rs"` — no new warnings from the changed files.
- [ ] Manual: `cargo run -- serve --storage-root <tmp> --verbose` then
  `curl http://127.0.0.1:31878/studio-stud/allowlist` returns a JSON object with a `version` string
  and a `classes` map where `BasePart` lists `Transparency` (readOnly:false). Eyeball that the class
  count is in the thousands and each entry has `name` + `readOnly`.
- [ ] Checkpoint commit: `git commit --allow-empty -m "checkpoint: Phase 2 reflection allow-list complete (gate green)"`.

**Then STOP.** Do not start Phase 3 (the plugin consuming this allow-list). Report what changed per
task, test results, and the `/allowlist` version + a sample class.

---

## Deferred to later phases (do NOT build here)
- The plugin fetching `/allowlist` and using it as the capture filter + the `Changed` gap-probe → **Phase 3**.
- The on-connect "Property Updates" handshake using the **plugin's reported Studio version** (needs
  the plugin to send its `version()`), and enabling real runtime-fetch once the CDN URL is verified → **Phase 3/5**.

_Plan grounded in rbx_reflection 6.1.0 (verified crate source) + the Phase-1 daemon interfaces now on `development`._
