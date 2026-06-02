# Review against Studio Stud conventions

Review the current working diff (staged + unstaged) against this repo's rules:

- **Rust:** no `unwrap` / `expect` / `panic!` in library paths, `anyhow` with `.context(…)` (no `thiserror`), no stray `println!` / `eprintln!` outside the CLI output path, stable `--json` output for any new command, clippy clean.
- **Plugin:** thin client (no logic that belongs in the engine), DataModel edits wrapped in `ChangeHistoryService`, clean teardown, `--!strict`.
- **Bridge:** if any message shape changed, confirm Rust DTO + Luau handler + doc + protocol version constants all moved together, and the wire stays `camelCase`.

Output a short list of concrete violations (file:line + fix). If clean, say so. Don't restate the diff.
