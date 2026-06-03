//! Signature-only repo map of the Rust engine.
//!
//! Emits one block per source file: the relative path followed by its public
//! surface and top-level items -- function signatures, structs/enums/traits,
//! type aliases, consts/statics, `impl` headers, and `mod` declarations -- with
//! no bodies. Parsed with `syn` (a real AST), so signatures are accurate
//! regardless of formatting. `mod tests` (and any `#[cfg(test)]` module) is
//! skipped. The goal is a high-signal navigation index an agent can grep
//! instead of reading the whole tree.

use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use anyhow::{Context, Result, anyhow};
use serde::Serialize;
use syn::spanned::Spanned;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileMap {
    pub path: String,
    pub signatures: Vec<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RepoMap {
    pub files: Vec<FileMap>,
    pub file_count: usize,
    pub signature_count: usize,
}

/// Collapse whitespace runs and tidy spacing around punctuation so a
/// (possibly multi-line) span reads as a compact one-liner.
fn normalize(text: &str) -> String {
    let collapsed = text.split_whitespace().collect::<Vec<_>>().join(" ");
    collapsed
        .replace("( ", "(")
        .replace(" )", ")")
        .replace(" ,", ",")
        .replace(" ;", ";")
        .replace(",)", ")")
        .trim()
        .to_string()
}

/// Slice the original source for a parsed node's span. Relies on proc-macro2
/// fallback spans (enabled via the `span-locations` feature) which carry byte
/// offsets into the parsed string.
fn span_text(src: &str, span: proc_macro2::Span) -> Option<String> {
    let range = span.byte_range();
    if range.is_empty() {
        return None;
    }
    src.get(range).map(normalize)
}

fn signature_text(src: &str, sig: &syn::Signature) -> String {
    span_text(src, sig.span()).unwrap_or_else(|| format!("fn {}(...)", sig.ident))
}

fn impl_header(src: &str, item: &syn::ItemImpl) -> String {
    let start = item.impl_token.span().byte_range().start;
    let end = item.brace_token.span.open().byte_range().start;
    let header = src
        .get(start..end)
        .map(normalize)
        .unwrap_or_else(|| "impl".to_string());
    let header = header.trim_end_matches('{').trim();
    // Drop a trailing where-clause to keep the header compact.
    let header = header.split(" where ").next().unwrap_or(header).trim();
    header.to_string()
}

fn is_test_module(module: &syn::ItemMod, src: &str) -> bool {
    if module.ident == "tests" {
        return true;
    }
    module.attrs.iter().any(|attr| {
        attr.path().is_ident("cfg")
            && span_text(src, attr.span())
                .map(|t| t.contains("test"))
                .unwrap_or(false)
    })
}

fn push(out: &mut Vec<String>, seen: &mut HashSet<String>, sig: String) {
    if !sig.is_empty() && seen.insert(sig.clone()) {
        out.push(sig);
    }
}

fn collect_items(
    items: &[syn::Item],
    src: &str,
    out: &mut Vec<String>,
    seen: &mut HashSet<String>,
) {
    for item in items {
        match item {
            syn::Item::Fn(f) => push(out, seen, signature_text(src, &f.sig)),
            syn::Item::Struct(s) => push(out, seen, format!("struct {}", s.ident)),
            syn::Item::Enum(e) => push(out, seen, format!("enum {}", e.ident)),
            syn::Item::Type(t) => push(out, seen, format!("type {}", t.ident)),
            syn::Item::Const(c) => {
                let ty = span_text(src, c.ty.span()).unwrap_or_default();
                push(out, seen, format!("const {}: {}", c.ident, ty));
            }
            syn::Item::Static(s) => {
                let ty = span_text(src, s.ty.span()).unwrap_or_default();
                push(out, seen, format!("static {}: {}", s.ident, ty));
            }
            syn::Item::Trait(t) => {
                push(out, seen, format!("trait {}", t.ident));
                for ti in &t.items {
                    if let syn::TraitItem::Fn(m) = ti {
                        push(out, seen, signature_text(src, &m.sig));
                    }
                }
            }
            syn::Item::Impl(im) => {
                push(out, seen, impl_header(src, im));
                for ii in &im.items {
                    if let syn::ImplItem::Fn(m) = ii {
                        push(out, seen, signature_text(src, &m.sig));
                    }
                }
            }
            syn::Item::Mod(m) => {
                if is_test_module(m, src) {
                    continue;
                }
                match &m.content {
                    Some((_, inner)) => collect_items(inner, src, out, seen),
                    None => push(out, seen, format!("mod {}", m.ident)),
                }
            }
            _ => {}
        }
    }
}

/// Extract the ordered, de-duplicated signature list from one Rust source file.
/// Unparseable input yields an empty list (the file is still recorded).
pub fn extract_signatures(src: &str) -> Vec<String> {
    let Ok(file) = syn::parse_file(src) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    collect_items(&file.items, src, &mut out, &mut seen);
    out
}

fn collect_rs_files(dir: &Path, files: &mut Vec<PathBuf>) -> Result<()> {
    for entry in fs::read_dir(dir).with_context(|| format!("read dir {}", dir.display()))? {
        let path = entry?.path();
        if path.is_dir() {
            collect_rs_files(&path, files)?;
        } else if path.extension().is_some_and(|ext| ext == "rs") {
            files.push(path);
        }
    }
    Ok(())
}

pub fn build_repo_map(root: &Path, repo_root: &Path) -> Result<RepoMap> {
    let mut paths = Vec::new();
    collect_rs_files(root, &mut paths)?;
    paths.sort();

    let mut files = Vec::with_capacity(paths.len());
    let mut signature_count = 0;
    for path in paths {
        let text = fs::read_to_string(&path).with_context(|| format!("read {}", path.display()))?;
        let signatures = extract_signatures(&text);
        signature_count += signatures.len();
        let rel = path
            .strip_prefix(repo_root)
            .unwrap_or(&path)
            .to_string_lossy()
            .replace('\\', "/");
        files.push(FileMap {
            path: rel,
            signatures,
        });
    }
    let file_count = files.len();
    Ok(RepoMap {
        files,
        file_count,
        signature_count,
    })
}

pub fn render_text(map: &RepoMap) -> String {
    let mut lines = vec![
        "# Studio Stud — Repo Map".to_string(),
        "# Generated by `studio-stud repo-map` · signatures only, no bodies.".to_string(),
        "# Regenerate after structural changes: studio-stud repo-map".to_string(),
        format!(
            "# {} files · {} signatures",
            map.file_count, map.signature_count
        ),
        String::new(),
    ];
    for file in &map.files {
        lines.push(file.path.clone());
        if file.signatures.is_empty() {
            lines.push("  (no top-level items)".to_string());
        } else {
            lines.extend(file.signatures.iter().map(|s| format!("  {s}")));
        }
        lines.push(String::new());
    }
    lines.join("\n")
}

pub fn render_jsonl(map: &RepoMap) -> String {
    map.files
        .iter()
        .map(|f| serde_json::to_string(f).unwrap_or_default())
        .collect::<Vec<_>>()
        .join("\n")
}

fn newest_source_mtime(root: &Path) -> Option<SystemTime> {
    let mut paths = Vec::new();
    collect_rs_files(root, &mut paths).ok()?;
    paths
        .iter()
        .filter_map(|p| fs::metadata(p).and_then(|m| m.modified()).ok())
        .max()
}

/// True if the map is missing, older than the newest source file, or older than
/// the running binary (a rebuild may change the map's own logic). Stats only --
/// cheap enough to run on every prompt submit.
fn is_stale(root: &Path, out_path: &Path) -> bool {
    let Ok(out_mtime) = fs::metadata(out_path).and_then(|m| m.modified()) else {
        return true;
    };
    if let Some(src_mtime) = newest_source_mtime(root)
        && src_mtime > out_mtime
    {
        return true;
    }
    if let Ok(exe) = std::env::current_exe()
        && let Ok(exe_mtime) = fs::metadata(&exe).and_then(|m| m.modified())
        && exe_mtime > out_mtime
    {
        return true;
    }
    false
}

fn write_atomic(path: &Path, content: &str) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension("tmp");
    fs::write(&tmp, content)?;
    fs::rename(&tmp, path)?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub fn cmd_repo_map(
    root: Option<&Path>,
    out: Option<&Path>,
    as_json: bool,
    to_stdout: bool,
    if_stale: bool,
    quiet: bool,
) -> Result<()> {
    let repo_root = std::env::current_dir()?;
    let root_dir = repo_root.join(root.unwrap_or(Path::new("src")));
    if !root_dir.exists() {
        return Err(anyhow!("source dir not found: {}", root_dir.display()));
    }

    let default_out = if as_json {
        "docs/repo-map.jsonl"
    } else {
        "docs/repo-map.md"
    };
    let out_rel = out
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from(default_out));
    let out_path = repo_root.join(&out_rel);

    if if_stale && !to_stdout && !is_stale(&root_dir, &out_path) {
        if !quiet {
            println!("{} is up to date", out_rel.display());
        }
        return Ok(());
    }

    let map = build_repo_map(&root_dir, &repo_root)?;
    let content = if as_json {
        render_jsonl(&map)
    } else {
        render_text(&map)
    };

    if to_stdout {
        println!("{content}");
        return Ok(());
    }

    write_atomic(&out_path, &format!("{content}\n"))?;
    if !quiet {
        println!(
            "Wrote {} — {} files, {} signatures",
            out_rel.display(),
            map.file_count,
            map.signature_count
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_public_surface() {
        let src = r#"
pub struct Foo;
pub enum Bar { A, B }
pub const N: i64 = 3;
pub type Alias = Vec<u8>;

pub fn free(x: &str) -> Result<()> {
    Ok(())
}

impl Foo {
    pub fn method(
        &self,
        n: usize,
    ) -> [u8; 32] {
        [0; 32]
    }
}

#[cfg(test)]
mod tests {
    fn hidden_helper() {}
}
"#;
        let sigs = extract_signatures(src);
        assert!(sigs.contains(&"struct Foo".to_string()));
        assert!(sigs.contains(&"enum Bar".to_string()));
        assert!(sigs.contains(&"type Alias".to_string()));
        assert!(sigs.iter().any(|s| s.starts_with("const N: i64")));
        assert!(sigs.contains(&"fn free(x: &str) -> Result<()>".to_string()));
        assert!(sigs.contains(&"impl Foo".to_string()));
        // Multi-line method signature is reassembled, array return type intact.
        assert!(sigs.contains(&"fn method(&self, n: usize) -> [u8; 32]".to_string()));
        // Test module contents are skipped.
        assert!(!sigs.iter().any(|s| s.contains("hidden_helper")));
    }

    #[test]
    fn unparseable_file_yields_empty() {
        assert!(extract_signatures("this is not valid rust }{").is_empty());
    }
}
