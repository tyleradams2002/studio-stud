# Repo Map

Compact, signature-only index of the Rust engine source tree (no bodies). Use
it to locate symbols and understand a file's surface area *without* reading
files.

```powershell
python tools/repomap.py                 # regenerate docs/repo-map.md
python tools/repomap.py --if-stale      # regenerate only if a source file is newer
python tools/repomap.py --format json   # regenerate docs/repo-map.jsonl
python tools/repomap.py --stdout        # print instead of writing
```

Auto-regeneration: `.cursor/hooks.json` runs `--if-stale --quiet` on every
prompt submit (`beforeSubmitPrompt`), so the map stays current automatically.
The fresh-case check is a quick timestamp scan; real work only happens when a
`.rs` file actually changed.

## How to use it (token-cheap navigation)

1. **Find where a symbol lives** — grep the map, then open the file directly:

```powershell
Select-String -Path docs/repo-map.md -Pattern "live_fingerprint"
```

2. **Understand a file's API** — read just its block in `docs/repo-map.md`
   instead of the whole source file.
3. **Broad architecture question** — read the whole map rather than dozens of
   files.

## When to regenerate

After adding/removing/renaming files, functions, or types. The script reads
`src/` in well under a second. Output is committed so a session can read it
without running anything; regenerate if it looks stale.
