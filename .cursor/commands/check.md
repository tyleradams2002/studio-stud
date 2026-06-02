# Fast validation loop

Run the quick "did I break anything" pass and report only failures.

1. Rust: `cargo check` then `cargo clippy --all-targets -- -D warnings`.
2. Luau plugin: typecheck (`luau-analyze` / LSP, or `selene` + `stylua --check` if this repo uses them).
3. If anything failed, list each failure with the file and the minimal fix. If everything passed, say so in one line — don't summarize what you ran.

Read-only: don't edit files unless I ask.
