---
name: release
description: Cut a Studio Stud release — bump versions across the Rust crate, the plugin, and the protocol, update the changelog, build release artifacts for both halves, and prepare the plugin for distribution. Use when asked to release, cut a version, or publish.
---

# Release Studio Stud

## Steps
1. **Decide the version** (semver). Confirm with the user if ambiguous.
2. **Bump in lockstep:** the engine `Cargo.toml` version, the plugin's version constant / project metadata, and the **protocol version** if the wire contract changed since the last release.
3. **Changelog.** Add a dated section summarizing changes (engine, plugin, protocol) since the last tag. Factual, grouped by area.
4. **Build release artifacts** via the `build-and-package` skill. Don't release if it fails.
5. **Tag.** `git tag vX.Y.Z` + commit the version/changelog bump. Push/tag only if the user confirms.
6. **Distribute the plugin.** Produce the install `.rbxm` and, if applicable, the Creator Store steps/asset. Print exactly what the user must upload and where.

## Notes
- Engine version, plugin version, and protocol version are three separate numbers — only the protocol version is tied to wire compatibility. Don't conflate them.
- Never release with a dirty protocol (Rust and Luau out of sync). Verify against the `bridge-protocol` rule first.
