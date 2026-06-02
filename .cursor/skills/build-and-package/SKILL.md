---
name: build-and-package
description: Build the full Studio Stud distributable — compile the Rust engine and assemble dist/ with the engine exe and the plugin .lua. Use when asked to build, package, produce a plugin file, or verify the whole thing compiles end to end.
---

# Build & package Studio Stud

Compiles the engine and assembles the runtime bundle. The plugin is a hand-written `plugin/StudioStud.plugin.lua` — it is **copied**, not built (no Rojo, no `.rbxm`). Run from the repo root (Windows / PowerShell 7).

## Steps
1. **Toolchain check.** `cargo` must be on PATH (or `$env:CARGO` / `~/.cargo/bin/cargo.exe`). If it's missing, stop and report — don't silently skip.
2. **Build the engine.** Run `scripts/build-local.ps1`. It runs `cargo build --release` (with `CARGO_TARGET_DIR=target`) and copies the exe to `bin/studio-stud.exe`. If `studio-stud serve` is running it can't overwrite `bin/` — stop it and rerun. Then run `cargo clippy --all-targets -- -D warnings` and treat warnings as failures.
3. **Package.** Run `scripts/package-release.ps1` (pass `-SkipBuild` if step 2 already built). It assembles:
   - `dist/.studio-stud-tool/bin/studio-stud.exe`
   - `dist/.studio-stud-tool/plugin/StudioStud.plugin.lua`
   - `dist/.studio-stud-tool/version.json`
   - `dist/studio-stud.exe` and `dist/StudioStud.plugin.lua` (release assets)
   - `site/latest.json` (Pages version manifest)
4. **Verify.** Confirm `dist/` contains the exe and the plugin `.lua`; print their paths and sizes. The script reads the version numbers (daemon / plugin / protocol) and prints them — confirm they look right.

## Notes
- This is the deterministic "does it all still build" path — prefer running this over reasoning about whether a change compiles.
- Versions come from `Cargo.toml` (daemon), `PLUGIN_VERSION` in the plugin, and `PROTOCOL_VERSION` / `MIN_PLUGIN_PROTOCOL_VERSION` in `src/util.rs`. See the `release` skill before bumping them.
