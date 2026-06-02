#!/usr/bin/env python3
"""Generate a compact, signature-only map of the Rust engine source tree.

The goal is to give an AI agent (or a human) a high-signal mental model of the
codebase without paying the token cost of the full source. We emit one block
per file: the relative path followed by its public surface and top-level items
-- module declarations, structs/enums/traits, type aliases, consts/statics,
`impl` headers, and function signatures (name + params + return type, no
bodies). Test modules (`mod tests`) are skipped. Files with nothing to show
are listed with a short tag so the agent still knows the file exists.

Usage (run from the repo root):
    python tools/repomap.py                 # write docs/repo-map.md
    python tools/repomap.py --stdout        # print to stdout instead
    python tools/repomap.py --format json   # write docs/repo-map.jsonl
    python tools/repomap.py --if-stale      # regenerate only if a source file is newer
    python tools/repomap.py --root src --out docs/repo-map.md
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

# --- Patterns -------------------------------------------------------------
# Visibility prefix (pub / pub(crate) / pub(super) / ...), optional.
_VIS = r"(?:pub(?:\s*\([^)]*\))?\s+)?"

FN = re.compile(rf"^\s*{_VIS}(?:async\s+|unsafe\s+|const\s+|extern\s+\"[^\"]*\"\s+)*fn\s+([A-Za-z_]\w*)")
STRUCT = re.compile(rf"^\s*{_VIS}struct\s+([A-Za-z_]\w*)")
ENUM = re.compile(rf"^\s*{_VIS}enum\s+([A-Za-z_]\w*)")
TRAIT = re.compile(rf"^\s*{_VIS}(?:unsafe\s+)?trait\s+([A-Za-z_]\w*)")
TYPE = re.compile(rf"^\s*{_VIS}type\s+([A-Za-z_]\w*)")
CONST = re.compile(rf"^\s*{_VIS}(?:const|static)\s+(?:mut\s+)?([A-Za-z_]\w*)\s*:\s*([^=;]+?)\s*(?:=|;)")
MOD_DECL = re.compile(rf"^\s*{_VIS}mod\s+([A-Za-z_]\w*)\s*;")
IMPL = re.compile(r"^\s*impl\b(.*)$")
MOD_TESTS = re.compile(r"^\s*(?:#\[cfg\(test\)\]\s*)?mod\s+tests\b")

_LINE_COMMENT = re.compile(r"//.*$")
_STR_DQ = re.compile(r'"(?:\\.|[^"\\])*"')
_STR_SQ = re.compile(r"'(?:\\.|[^'\\])*'")


@dataclass
class FileMap:
    path: str
    signatures: list[str] = field(default_factory=list)


def _norm(text: str) -> str:
    """Collapse all runs of whitespace to single spaces."""
    return re.sub(r"\s+", " ", text).strip()


def _strip_strings(line: str) -> str:
    """Blank out string/char literal contents so brace counting is reliable."""
    return _STR_SQ.sub("''", _STR_DQ.sub('""', line))


def _collect_fn_signature(lines: list[str], i: int) -> str:
    """Join a (possibly multi-line) `fn` definition up to its body/`;`/`where`.

    Returns the normalized signature text starting at the `fn` keyword, e.g.
    `fn run(args: Args) -> Result<()>`. Only paren depth is tracked for the
    stop condition, so generic angle brackets and `->` are left alone.
    """
    buf: list[str] = []
    paren = 0
    bracket = 0
    opened = False
    for j in range(i, len(lines)):
        raw = _LINE_COMMENT.sub("", lines[j])
        seg: list[str] = []
        stop = False
        for ch in raw:
            if ch == "(":
                paren += 1
                opened = True
                seg.append(ch)
            elif ch == ")":
                paren -= 1
                seg.append(ch)
            elif ch == "[":
                bracket += 1
                seg.append(ch)
            elif ch == "]":
                bracket -= 1
                seg.append(ch)
            elif ch == "{" and paren == 0 and bracket == 0 and opened:
                stop = True
                break
            elif ch == ";" and paren == 0 and bracket == 0:
                stop = True
                break
            else:
                seg.append(ch)
        buf.append("".join(seg))
        if stop:
            break
    text = re.split(r"\bwhere\b", " ".join(buf), maxsplit=1)[0]
    return _norm(text)


def extract_signatures(text: str) -> list[str]:
    lines = text.splitlines()
    sigs: list[str] = []
    seen: set[str] = set()

    depth = 0
    skip_until: int | None = None  # brace depth to return to before re-enabling

    for idx, raw in enumerate(lines):
        clean = _strip_strings(_LINE_COMMENT.sub("", raw))

        if skip_until is None and MOD_TESTS.match(raw):
            skip_until = depth  # skip this test module's contents

        if skip_until is None:
            sig: str | None = None

            m = FN.match(raw)
            if m:
                full = _collect_fn_signature(lines, idx)
                after = re.search(rf"\bfn\s+{re.escape(m.group(1))}", full)
                sig = "fn " + m.group(1) + (full[after.end():] if after else "")
                sig = _norm(sig)
            elif (m := STRUCT.match(raw)):
                sig = f"struct {m.group(1)}"
            elif (m := ENUM.match(raw)):
                sig = f"enum {m.group(1)}"
            elif (m := TRAIT.match(raw)):
                sig = f"trait {m.group(1)}"
            elif (m := MOD_DECL.match(raw)):
                sig = f"mod {m.group(1)}"
            elif (m := TYPE.match(raw)):
                sig = f"type {m.group(1)}"
            elif (m := CONST.match(raw)):
                sig = f"const {m.group(1)}: {_norm(m.group(2))}"
            elif (m := IMPL.match(raw)):
                target = _norm(re.split(r"\bwhere\b", m.group(1))[0]).rstrip("{").strip()
                if target:
                    sig = f"impl {target}"

            if sig and sig not in seen:
                seen.add(sig)
                sigs.append(sig)

        depth += clean.count("{") - clean.count("}")
        if skip_until is not None and depth <= skip_until:
            skip_until = None

    return sigs


def build_maps(root: Path, repo_root: Path) -> list[FileMap]:
    maps: list[FileMap] = []
    for path in sorted(root.rglob("*.rs")):
        text = path.read_text(encoding="utf-8", errors="replace")
        rel = path.relative_to(repo_root).as_posix()
        maps.append(FileMap(path=rel, signatures=extract_signatures(text)))
    return maps


def is_stale(root: Path, out_path: Path, generator: Path) -> bool:
    """True if the map is missing or any source file is newer than it.

    Only stats files (no content reads), so the fresh-case check is cheap --
    ideal for running on every prompt submit via a hook.
    """
    if not out_path.exists():
        return True
    out_mtime = out_path.stat().st_mtime
    if generator.exists() and generator.stat().st_mtime > out_mtime:
        return True
    for path in root.rglob("*.rs"):
        if path.stat().st_mtime > out_mtime:
            return True
    return False


def render_text(maps: list[FileMap]) -> str:
    total_sigs = sum(len(m.signatures) for m in maps)
    lines = [
        "# Studio Stud — Repo Map",
        "# Generated by tools/repomap.py · signatures only, no bodies.",
        "# Regenerate after structural changes: python tools/repomap.py",
        f"# {len(maps)} files · {total_sigs} signatures",
        "",
    ]
    for m in maps:
        lines.append(m.path)
        if m.signatures:
            lines.extend(f"  {s}" for s in m.signatures)
        else:
            lines.append("  (no top-level items)")
        lines.append("")
    return "\n".join(lines)


def render_jsonl(maps: list[FileMap]) -> str:
    return "\n".join(
        json.dumps({"path": m.path, "signatures": m.signatures}, separators=(",", ":"))
        for m in maps
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default="src", help="Source dir to scan (default: src)")
    parser.add_argument("--out", default=None, help="Output file (defaults depend on --format)")
    parser.add_argument("--format", choices=("text", "json"), default="text", help="Output format")
    parser.add_argument("--stdout", action="store_true", help="Print to stdout instead of writing a file")
    parser.add_argument("--if-stale", action="store_true", help="Skip regeneration when no source file is newer than the map")
    parser.add_argument("--quiet", action="store_true", help="Suppress the summary line (for hook/automation use)")
    args = parser.parse_args(argv)

    def log(msg: str) -> None:
        if not args.quiet:
            print(msg)

    repo_root = Path.cwd()
    root = (repo_root / args.root).resolve()
    if not root.exists():
        print(f"error: source dir not found: {root}", file=sys.stderr)
        return 1

    out = args.out or ("docs/repo-map.jsonl" if args.format == "json" else "docs/repo-map.md")
    out_path = repo_root / out

    if args.if_stale and not args.stdout and not is_stale(root, out_path, Path(__file__).resolve()):
        log(f"{out} is up to date")
        return 0

    maps = build_maps(root, repo_root)
    content = render_jsonl(maps) if args.format == "json" else render_text(maps)

    if args.stdout:
        print(content)
        return 0

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(content + "\n", encoding="utf-8")
    total_sigs = sum(len(m.signatures) for m in maps)
    log(f"Wrote {out} — {len(maps)} files, {total_sigs} signatures")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
