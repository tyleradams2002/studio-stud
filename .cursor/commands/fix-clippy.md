# Fix clippy

Run `cargo clippy --all-targets --fix --allow-dirty` for the mechanical fixes, then run `cargo clippy --all-targets -- -D warnings` again and fix the remaining warnings idiomatically (no `#[allow]` unless justified with a one-line comment). Show me the diff summary, not full files. Re-run until clippy is clean.
