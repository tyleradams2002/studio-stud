# Repo Map

Compact, signature-only index of the Rust engine source tree (no bodies),
produced by the `repo-map` engine subcommand (parses with `syn`). Use it to
locate symbols and understand a file's surface area *without* reading files.

```powershell
.\bin\studio-stud.exe repo-map                 # regenerate docs/repo-map.md
.\bin\studio-stud.exe repo-map --if-stale      # regenerate only if a source file is newer
.\bin\studio-stud.exe repo-map --json          # regenerate docs/repo-map.jsonl
.\bin\studio-stud.exe repo-map --stdout        # print instead of writing
cargo run --release -- repo-map                # if the binary isn't built yet
```

Auto-regeneration: `.cursor/hooks.json` runs `repo-map --if-stale --quiet` on
every prompt submit (`beforeSubmitPrompt`, via `.cursor/hooks/repo-map.ps1`), so
the map stays current automatically. The fresh-case check is a quick timestamp
scan; real work only happens when a `.rs` file actually changed. The hook is a
silent no-op until `bin/studio-stud.exe` exists (run `scripts/build-local.ps1`).

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

After adding/removing/renaming files, functions, or types. The scan runs in well
under a second. Output is committed so a session can read it without running
anything; regenerate if it looks stale.
