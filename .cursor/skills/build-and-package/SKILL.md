---
name: build-and-package
description: Build the full Studio Stud distributable — compile the Rust engine and build the Luau plugin into an installable .rbxm, then assemble dist/. Use when asked to build, package, produce a plugin file, or verify the whole thing compiles end to end.
---

# Build & package Studio Stud

Produces both halves and assembles the distributable. Run from the repo root.

## Steps
1. **Toolchain check.** Ensure pinned tools are present: `rokit install` (installs Rojo/Lune/etc. per `rokit.toml`), and `rustup show` matches `rust-toolchain.toml`. If `rokit` / `cargo` are missing, stop and report — don't silently skip.
2. **Build the engine (Rust).** `cargo build --release`, and `cargo clippy --release -- -D warnings`. Treat warnings as failures. If it fails, fix or report; don't proceed to packaging.
3. **Build the plugin (Luau).** `rojo build plugin.project.json -o build/StudioStud.rbxm` (adjust the project file / output path to this repo). If the project builds via a Lune script instead, run that.
4. **Assemble.** Copy the release binary and the `.rbxm` into `dist/`, plus run `scripts/package.ps1` if present.
5. **Verify.** Confirm `dist/` contains both artifacts; print their paths and sizes. Confirm the `.rbxm` is non-empty and Rojo emitted no errors.

## Notes
- This is the deterministic "does it all still build" path — prefer running this over reasoning about whether a change compiles.
- Exact invocations (project file name, output paths, packaging script) are repo-specific — match them to this repo's real layout.
