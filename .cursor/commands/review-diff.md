# Review against Studio Stud conventions

Review the current working diff (staged + unstaged) against this repo's rules:

- **Rust:** no `unwrap` / `expect` / `panic!` in library paths, typed errors via `thiserror`, `tracing` not `println!`, stable `--json` output for any new command.
- **Plugin:** thin client (no logic that belongs in the engine), DataModel edits wrapped in `ChangeHistoryService`, clean teardown, `--!strict`.
- **Bridge:** if any message shape changed, confirm Rust + Luau + schema doc + protocol version all moved together.

Output a short list of concrete violations (file:line + fix). If clean, say so. Don't restate the diff.
