# Studio Stud

An AI-first, read-only live Roblox Studio inspector. A local Rust daemon + a single Studio plugin
keep one live SQLite picture of a place's DataModel and expose compact, bounded JSON for agents
(`analyze`, `query`) plus a policy-gated file-write primitive and a read-only Rojo-style project diff.

Windows-only. Localhost only (`127.0.0.1:31878`). Never publishes, cloud-saves, or mutates the place.

## Install into any project (one line)

```powershell
irm https://tyleradams2002.github.io/studio-stud/install.ps1 | iex
```

This downloads the latest release into a clean `.studio-stud-tool/` folder inside your repo, drops a
`studio-stud.ps1` / `studio-stud.cmd` launcher at the repo root (so `.\studio-stud <cmd>` works), and
writes a starter `.studio-stud/policy.json`. Add `-WithCursorRule` to also install the AI workflow
rule + command:

```powershell
& ([scriptblock]::Create((irm https://tyleradams2002.github.io/studio-stud/install.ps1))) -WithCursorRule
```

Then in Studio: enable HTTP requests, load `.studio-stud-tool/plugin/StudioStud.plugin.lua`, and run:

```powershell
.\studio-stud doctor
.\studio-stud serve      # leave running in its own terminal
.\studio-stud capture
.\studio-stud analyze
```

See [`docs/usage.md`](docs/usage.md) for the full command surface and [`docs/platform-design.md`](docs/platform-design.md)
for the architecture.

## Version checking

The daemon and plugin confirm to each other (and against the published release) whether an update is
required:

- **Mutual handshake** — each side carries its own version and the minimum it requires of the other.
  On connect the plugin compares against the daemon manifest and surfaces "Daemon outdated" or
  "Plugin outdated"; the daemon flags too-old plugins in its responses.
- **Remote check** — `studio-stud update --check` and the plugin compare local versions against
  `https://tyleradams2002.github.io/studio-stud/latest.json` and print the upgrade command.

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
site/                GitHub Pages: install.ps1, latest.json, index.html
consumer-template/   files the installer drops into a consumer repo
docs/                usage.md, platform-design.md, plans/ (dev history)
```

## Releasing

Push a `v*` tag. CI (`.github/workflows/release.yml`) builds `studio-stud.exe`, attaches it plus
`StudioStud.plugin.lua` to a GitHub Release, regenerates `latest.json`, and deploys the Pages site.
