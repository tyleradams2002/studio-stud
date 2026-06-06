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

/// Whether the stored reflection version is missing or differs from the current one.
pub(crate) fn needs_update(stored: Option<&str>, current: &str) -> bool {
    stored != Some(current)
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

    #[test]
    fn needs_update_logic() {
        assert!(needs_update(None, "0.659.0.1")); // fresh db
        assert!(!needs_update(Some("0.659.0.1"), "0.659.0.1")); // match
        assert!(needs_update(Some("0.658.0.9"), "0.659.0.1")); // differs
    }

    #[test]
    fn fetch_falls_back_to_bundled_on_error() {
        // A fetcher that always fails must yield the bundled version, never panic.
        let al = generate_allowlist_for(|_url| Err(anyhow::anyhow!("network down")));
        assert_eq!(al.version, current_version());
        assert!(al.classes.contains_key("BasePart"));
    }
}
