---
name: build-and-package
description: Build the full Studio Stud distributable — compile the Rust engine and assemble dist/ with the engine exe and the plugin .lua. Use when asked to build, package, produce a plugin file, or verify the whole thing compiles end to end.
---

# Build & package Studio Stud

Compiles the engine and assembles the runtime bundle. The plugin is a hand-written `plugin/StudioStud.plugin.lua` — it is **copied**, not built (no Rojo, no `.rbxm`). Run from the repo root (Windows / PowerShell 7).

## Steps
1. **Toolchain check.** `cargo` must be on PATH (or `$env:CARGO` / `~/.cargo/bin/cargo.exe`). If it's missing, stop and report — don't silently skip.
2. **Build the engine.** Run `scripts/build-local.ps1`. It runs `cargo build --release` (with `CARGO_TARGET_DIR=target`) and copies the exe to `bin/studio-stud.exe`. If `studio-stud serve` is running it can't overwrite `bin/` — stop it and rerun. Then run `cargo clippy --all-targets -- -D warnings` and treat warnings as failures.
3. **Package.** Run `scripts/package-release.ps1` (pass `-SkipBuild` if step 2 already built). It builds `studio-stud-setup` and assembles:
   - `dist/studio-stud.exe`, `dist/StudioStud.plugin.lua`, `dist/studio-stud-setup.exe`
   - `dist/.studio-stud-tool/` (legacy bundle layout + `addons/` payloads from `addon-plugins/`)
   - `site/latest.json` (release channel manifest with `setupUrl`, `channelSequence`)
4. **Verify.** Confirm `dist/` contains all three exes and the plugin `.lua`; run `cargo test --workspace`.

## Notes
- This is the deterministic "does it all still build" path — prefer running this over reasoning about whether a change compiles.
- Versions come from `Cargo.toml` (daemon), `PLUGIN_VERSION` in the plugin, and `PROTOCOL_VERSION` / `MIN_PLUGIN_PROTOCOL_VERSION` in `src/util.rs`. See the `release` skill before bumping them.
