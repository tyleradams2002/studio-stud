use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, RwLock};
use std::time::Duration;

use anyhow::Result;
use rbx_reflection::{
    ClassDescriptor, DataType, PropertyDescriptor, PropertyKind, PropertySerialization,
    PropertyTag, Scriptability,
};
use rbx_reflection_database::get;

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub(crate) struct PropEntry {
    pub name: String,
    #[serde(rename = "readOnly")]
    pub read_only: bool,
    /// Roblox type, e.g. "float", "CFrame", "Color3", "Enum.Material", "Instance".
    /// Empty when unknown (e.g. an older cache entry before this field existed).
    /// Reserved for the write path (value validation/coercion) + AI reasoning.
    #[serde(rename = "valueType", default)]
    pub value_type: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub(crate) struct AllowList {
    pub version: String,
    pub classes: BTreeMap<String, Vec<PropEntry>>,
}

pub(crate) type SharedAllowList = Arc<RwLock<AllowList>>;

#[derive(serde::Deserialize)]
struct RawDump {
    #[serde(rename = "Classes")]
    classes: Vec<RawClass>,
}

#[derive(serde::Deserialize)]
struct RawClass {
    #[serde(rename = "Name")]
    name: String,
    #[serde(rename = "Superclass")]
    superclass: Option<String>,
    #[serde(rename = "Members")]
    members: Vec<RawMember>,
}

#[derive(serde::Deserialize)]
struct RawMember {
    #[serde(rename = "MemberType")]
    member_type: String,
    #[serde(rename = "Name")]
    name: String,
    #[serde(rename = "Security")]
    security: Option<RawSecurityField>,
    #[serde(rename = "Serialization")]
    serialization: Option<RawSerialization>,
    #[serde(rename = "Tags", default)]
    tags: Vec<serde_json::Value>,
    #[serde(rename = "ValueType")]
    value_type: Option<RawValueType>,
}

#[derive(serde::Deserialize)]
struct RawValueType {
    #[serde(rename = "Category")]
    category: String,
    #[serde(rename = "Name")]
    name: String,
}

#[derive(serde::Deserialize)]
struct RawSecurity {
    #[serde(rename = "Read")]
    read: String,
    #[serde(rename = "Write")]
    write: String,
}

#[derive(serde::Deserialize)]
#[serde(untagged)]
enum RawSecurityField {
    Shorthand(String),
    Detail(RawSecurity),
}

#[derive(serde::Deserialize)]
struct RawSerialization {
    #[serde(rename = "CanSave")]
    can_save: bool,
}

fn security_reads_none(sec: &Option<RawSecurityField>) -> bool {
    match sec {
        None => false,
        Some(RawSecurityField::Shorthand(s)) => s == "None",
        Some(RawSecurityField::Detail(d)) => d.read == "None",
    }
}

fn security_writes_none(sec: &Option<RawSecurityField>) -> bool {
    match sec {
        None => true,
        Some(RawSecurityField::Shorthand(s)) => s == "None",
        Some(RawSecurityField::Detail(d)) => d.write == "None",
    }
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

/// Type string for the bundled (rbx_reflection) source. Naming follows rbx_types' Debug
/// (e.g. "Float32", "CFrame"); slightly different from the raw dump's lowercase ("float"),
/// but the bundled path is only the offline fallback.
fn bundled_value_type(p: &PropertyDescriptor) -> String {
    match &p.data_type {
        DataType::Value(vt) => format!("{vt:?}"),
        DataType::Enum(name) => format!("Enum.{name}"),
        _ => String::new(),
    }
}

fn member_tag(m: &RawMember, name: &str) -> bool {
    m.tags
        .iter()
        .filter_map(|t| t.as_str())
        .any(|t| t == name)
}

fn raw_included(m: &RawMember) -> bool {
    m.member_type == "Property"
        && security_reads_none(&m.security)
        && m.serialization.as_ref().is_some_and(|s| s.can_save)
        && !member_tag(m, "Deprecated")
        && !member_tag(m, "Hidden")
        && !member_tag(m, "NotScriptable")
        && !member_tag(m, "WriteOnly")
}

fn raw_read_only(m: &RawMember) -> bool {
    member_tag(m, "ReadOnly") || !security_writes_none(&m.security)
}

/// Type string from the raw dump's ValueType {Category, Name}, e.g. "float", "CFrame",
/// "Enum.Material", "Instance". Empty when the member has no ValueType.
fn raw_value_type(m: &RawMember) -> String {
    match &m.value_type {
        Some(vt) if vt.category == "Enum" => format!("Enum.{}", vt.name),
        Some(vt) => vt.name.clone(),
        None => String::new(),
    }
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
                    value_type: bundled_value_type(prop),
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
/// Wired into the on-connect version-check in a later (plugin) phase.
#[allow(dead_code)]
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

pub(crate) fn generate_allowlist_from_dump(json: &str, version: &str) -> Result<AllowList> {
    let dump: RawDump = serde_json::from_str(json)?;
    let by_name: HashMap<&str, &RawClass> = dump.classes.iter().map(|c| (c.name.as_str(), c)).collect();
    let mut classes = BTreeMap::new();
    for class in &dump.classes {
        let mut seen = BTreeSet::new();
        let mut out: Vec<PropEntry> = Vec::new();
        let mut cur = Some(class);
        while let Some(c) = cur {
            for m in &c.members {
                if m.member_type != "Property" || seen.contains(&m.name) {
                    continue;
                }
                seen.insert(m.name.clone());
                if raw_included(m) {
                    out.push(PropEntry {
                        name: m.name.clone(),
                        read_only: raw_read_only(m),
                        value_type: raw_value_type(m),
                    });
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
    Ok(AllowList {
        version: version.to_string(),
        classes,
    })
}

fn agent() -> ureq::Agent {
    ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(6)))
        .build()
        .into()
}

pub(crate) fn fetch_current_version() -> Result<String> {
    let mut resp = agent()
        .get("https://setup.rbxcdn.com/versionQTStudio")
        .call()
        .map_err(|e| anyhow::anyhow!("version fetch failed: {e}"))?;
    let body = resp
        .body_mut()
        .read_to_string()
        .map_err(|e| anyhow::anyhow!("version body read failed: {e}"))?;
    Ok(body.trim().to_string())
}

fn fetch_dump(hash: &str) -> Result<String> {
    let url = format!("https://setup.rbxcdn.com/{hash}-Full-API-Dump.json");
    let mut resp = agent()
        .get(&url)
        .call()
        .map_err(|e| anyhow::anyhow!("dump fetch failed {url}: {e}"))?;
    resp.body_mut()
        .with_config()
        .limit(256 * 1024 * 1024)
        .read_to_string()
        .map_err(|e| anyhow::anyhow!("dump body read failed {url}: {e}"))
}

/// Fetcher returns the raw dump JSON for a version hash; on ANY error → bundled allow-list.
pub(crate) fn generate_allowlist_for<F>(fetch: F) -> AllowList
where
    F: FnOnce(&str) -> Result<String>,
{
    let result = (|| -> Result<AllowList> {
        let hash = fetch_current_version()?;
        let json = fetch(&hash)?;
        generate_allowlist_from_dump(&json, &hash)
    })();
    result.unwrap_or_else(|_| generate_allowlist())
}

/// Live fetch: returns the fetched allow-list, or the bundled one on failure.
pub(crate) fn fetch_allowlist() -> AllowList {
    generate_allowlist_for(fetch_dump)
}

fn cache_path(root: &Path, hash: &str) -> PathBuf {
    let safe = hash.replace(['/', '\\'], "_");
    root.join("reflection").join(format!("{safe}.json"))
}

pub(crate) fn write_cache(root: &Path, al: &AllowList) {
    let path = cache_path(root, &al.version);
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Ok(json) = serde_json::to_string_pretty(al) {
        let tmp = path.with_extension("json.tmp");
        if fs::write(&tmp, json).is_ok() {
            let _ = fs::rename(tmp, path);
        }
    }
}

pub(crate) fn read_cache(root: &Path, hash: &str) -> Option<AllowList> {
    let path = cache_path(root, hash);
    let text = fs::read_to_string(path).ok()?;
    serde_json::from_str(&text).ok()
}

/// Background refresh: fetch Roblox version hash, load or build allow-list, swap shared state.
pub(crate) fn refresh(shared: &SharedAllowList, storage_root: Option<&Path>) {
    let Ok(hash) = fetch_current_version() else {
        return;
    };
    if shared
        .read()
        .map(|al| al.version == hash)
        .unwrap_or(false)
    {
        return;
    }
    let al = storage_root
        .and_then(|root| read_cache(root, &hash))
        .unwrap_or_else(|| {
            let al = fetch_allowlist();
            if let Some(root) = storage_root {
                write_cache(root, &al);
            }
            al
        });
    if let Ok(mut guard) = shared.write() {
        *guard = al;
    }
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
        assert!(!t.value_type.is_empty(), "bundled value_type populated");
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
    fn allowlist_from_dump_filters_correctly() {
        let raw = r#"{
          "Classes": [
            {"Name":"Instance","Superclass":"<<<ROOT>>>","Members":[
              {"MemberType":"Property","Name":"Name",
               "Security":{"Read":"None","Write":"None"},"Serialization":{"CanLoad":true,"CanSave":true}}
            ]},
            {"Name":"BasePart","Superclass":"Instance","Members":[
              {"MemberType":"Property","Name":"Transparency",
               "Security":{"Read":"None","Write":"None"},"Serialization":{"CanLoad":true,"CanSave":true},
               "ValueType":{"Category":"Primitive","Name":"float"}},
              {"MemberType":"Property","Name":"Material",
               "Security":{"Read":"None","Write":"None"},"Serialization":{"CanLoad":true,"CanSave":true},
               "ValueType":{"Category":"Enum","Name":"Material"}},
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
        assert!(
            by("Transparency").is_some_and(|p| !p.read_only),
            "writable serializing prop"
        );
        assert!(by("Name").is_some(), "inherited from Instance");
        assert!(
            by("AssemblyMass").is_none(),
            "ReadOnly + non-serializing excluded (CanSave=false)"
        );
        assert!(by("LegacyThing").is_none(), "Deprecated excluded");
        assert!(by("SecretProp").is_none(), "non-None Read security excluded");
        assert!(by("Resize").is_none(), "functions excluded");
        assert_eq!(by("Transparency").unwrap().value_type, "float", "primitive value_type from dump");
        assert_eq!(by("Material").unwrap().value_type, "Enum.Material", "enum value_type prefixed");
    }

    #[test]
    fn fetch_allowlist_falls_back_to_bundled() {
        let al = generate_allowlist_for(|_ver| Err(anyhow::anyhow!("offline")));
        assert_eq!(al.version, current_version());
        assert!(al.classes.contains_key("BasePart"));
    }

    #[test]
    fn allowlist_cache_round_trip() {
        let dir = std::env::temp_dir().join(format!(
            "studio_stud_refl_cache_{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("temp dir");
        let al = generate_allowlist();
        write_cache(&dir, &al);
        let loaded = read_cache(&dir, &al.version).expect("read back");
        assert_eq!(loaded.version, al.version);
        assert_eq!(loaded.classes.get("BasePart"), al.classes.get("BasePart"));
        let _ = fs::remove_dir_all(&dir);
    }
}
