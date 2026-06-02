# Studio Stud

An AI-first, read-only live Roblox Studio inspector. A local Rust daemon + a single Studio plugin
keep one live SQLite picture of a place's DataModel and expose compact, bounded JSON for agents
(`analyze`, `query`) plus a policy-gated file-write primitive and a read-only Rojo-style project diff.

Windows-only. Localhost only (`127.0.0.1:31878`). Never publishes, cloud-saves, or mutates the place.

## Install

| Channel | One-liner |
|---------|-----------|
| **Release** (stable) | `irm https://tyleradams2002.github.io/studio-stud/install.ps1 \| iex` |
| **Beta** (testers) | `irm https://tyleradams2002.github.io/studio-stud/install-beta.ps1 \| iex` |
| **Dev** (internal) | `irm https://tyleradams2002.github.io/studio-stud/install-dev.ps1 \| iex` |

Downloads `studio-stud-setup.exe` and launches the GUI installer. The tool installs once under
`%LOCALAPPDATA%\studio-stud`, copies the core plugin into your Roblox Plugins folder, registers
one or more repo paths, and adds `studio-stud` / `studio-stud-setup` to your user PATH (new terminal
required). Beta and dev channels are password-protected and prompt at install time.

Then in Studio: enable HTTP requests; the core plugin loads from your Plugins folder automatically.
Run (from any registered repo, in a **new** terminal):

```powershell
studio-stud serve       # leave running
studio-stud doctor
studio-stud capture
```

Setup CLI: `studio-stud-setup health`, `repair`, `update --check`, `repo-health <path>`, `repo-repair <path>`.

See [`docs/usage.md`](docs/usage.md) for the full command surface and [`docs/platform-design.md`](docs/platform-design.md)
for the architecture.

## Version checking

The daemon and plugin confirm to each other (and against the published release) whether an update is
required:

- **Mutual handshake** — each side carries its own version and the minimum it requires of the other.
  On connect the plugin compares against the daemon manifest and surfaces "Daemon outdated" or
  "Plugin outdated"; the daemon flags too-old plugins in its responses.
- **Remote check** — `studio-stud-setup update --check` (single update owner); the daemon only applies
  a previously staged exe swap on `serve` startup.

Version source of truth: daemon = `Cargo.toml`, plugin = `PLUGIN_VERSION`, shared `PROTOCOL_VERSION`.
CI derives `latest.json` from these at release time.

## Development

```powershell
.\scripts\build-local.ps1     # cargo build --release → bin/studio-stud.exe
cargo test                    # full suite
```

Repo layout:

```
src/                 Rust daemon/CLI (cli, http, storage, capture, live, write, project, diff, ...)
tests/               unit + golden + integration fixtures
plugin/              StudioStud.plugin.lua + assets (core plugin)
addon-plugins/       extension plugins built on the core (sdk/, _template/, one folder per addon)
scripts/             build-local.ps1, package-release.ps1, launcher templates
site/                GitHub Pages: install.ps1, latest.json (+ /beta, /dev subpaths)
setup/               studio-stud-setup.exe (GUI install/uninstall + CLI health/update/repair)
consumer-template/   files the installer drops into a consumer repo
docs/                usage.md, platform-design.md, plans/ (dev history)
```

## Releasing

Branch flow: **`development`** → PR → **`beta`** → PR → **`main`**

Every push to any branch triggers `deploy.yml`:
- `development` → builds, encrypts with dev password, publishes dev channel to Pages
- `beta` → builds, encrypts with beta password, publishes beta channel to Pages
- `main` → builds, publishes release channel to Pages

To cut a versioned GitHub Release, push a `v*` tag after merging to `main`:

```powershell
git tag v0.5.0 && git push origin v0.5.0
```

Use **Actions → Promote** to open promotion PRs (`development → beta`, `beta → main`).
