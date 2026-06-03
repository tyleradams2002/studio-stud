<div align="center">

<img src="plugin/assets/studio-stud-logo.png" width="120" alt="Studio Stud logo">

# Studio Stud

*An AI-first, read-only live inspector for Roblox Studio.*

[![platform](https://img.shields.io/badge/platform-Windows-0c1a2b)](#requirements)
[![Roblox](https://img.shields.io/badge/Roblox-Studio-39b3a6)](#requirements)
[![release](https://img.shields.io/github/v/release/tyleradams2002/studio-stud?color=c8794a)](https://github.com/tyleradams2002/studio-stud/releases)

[Website](https://tyleradams2002.github.io/studio-stud) ·
[Docs](docs/usage.md) ·
[Releases](https://github.com/tyleradams2002/studio-stud/releases)

</div>

A local Rust daemon plus a single Studio plugin keep one live SQLite picture of your place's
DataModel and expose compact, bounded JSON for AI agents — alongside a policy-gated file-write
primitive and a Rojo-style project diff.

> **Windows only. Localhost only (`127.0.0.1:31878`). Never publishes, cloud-saves, or mutates your place.**

## Why Studio Stud

- 🔎 **Always-fresh live picture** — the plugin streams incremental deltas, so the local database
  tracks Studio continuously. No manual re-capture loop.
- 🤖 **Built for AI agents** — output is compact, bounded JSON by default (`analyze`, `query`); add
  `--markdown` when a human needs to read it.
- 🔒 **Read-only by default** — file writes are opt-in, allowlist-gated, atomic, and undoable. The
  tool never touches the place itself.
- 🧩 **Rojo-style project diff** — compare your repo's desired tree against live Studio state,
  ownership-aware, without writing anything.

<!--
  Screenshot of the plugin widget goes here once captured, e.g.:
  ![Studio Stud widget in Roblox Studio](docs/assets/widget.png)
  A single screenshot is the highest-impact thing you can add to this README.
-->

## Requirements

- **Windows** with **Roblox Studio**
- **Allow HTTP Requests** enabled for the experience (Game Settings → Security)
- A Git repo for your place (the tool installs into it)

## Install

```powershell
irm https://tyleradams2002.github.io/studio-stud/install.ps1 | iex
```

This downloads the setup bundle and runs the installer. It installs the tool once under
`%LOCALAPPDATA%`, copies the core plugin into your Roblox Plugins folder, registers your repo, and
adds `studio-stud` / `studio-stud-setup` to your user PATH. **Open a new terminal** afterward so the
PATH change takes effect.

Working with an AI agent? Install the bundled workflow rule and command too:

```powershell
& ([scriptblock]::Create((irm https://tyleradams2002.github.io/studio-stud/install.ps1))) -WithCursorRule
```

## Quickstart

1. In Studio, enable **Game Settings → Security → Allow HTTP Requests**.
2. From your repo, in a **new** terminal:

```powershell
studio-stud serve        # start the local daemon — leave this running
studio-stud doctor       # confirm Studio, plugin, and daemon are wired up
studio-stud capture      # take the first live snapshot (Studio must be open)
studio-stud analyze      # compact navigation context for an agent
```

Once `capture` succeeds, the plugin switches into live mode and keeps the local picture current on
its own — you don't need to capture again by hand.

## Everyday use

`analyze` gives you a bounded overview; `query` drills in. Count or narrow before asking for details:

```powershell
studio-stud query <PLACE> --find Trader --count-only
studio-stud query <PLACE> --find Trader --limit 10
studio-stud query <PLACE> --tree Workspace/BoatSpawnPoints --depth 1
studio-stud query <PLACE> --detail Workspace/Dock --props Position,Size
```

Output is compact JSON on stdout (parse it directly, or pipe to `ConvertFrom-Json`). Add
`--markdown` for a human-readable report:

```powershell
studio-stud analyze --markdown
```

The full command surface — `query` filters, the `--bulk` batch form, `policy`, `project diff`, and
the write protocol — lives in **[docs/usage.md](docs/usage.md)**.

## Safety

- The daemon binds to `127.0.0.1` only.
- The plugin reads DataModel **metadata** and posts it to localhost; it never publishes or edits the place.
- Raw snapshots stay on your machine. Use the compact `analyze` / bounded `query` output for AI, not raw dumps.
- File writes require a committed `.studio-stud/policy.json` allowlist and are blocked by default
  (least privilege). See [docs/usage.md](docs/usage.md) for the write protocol.

## Updates

The daemon and plugin negotiate compatibility on connect and name whichever side is behind. To check
for and apply a new release:

```powershell
studio-stud-setup update --check
studio-stud-setup update
```

Other setup helpers: `studio-stud-setup health`, `repair`, `repo-health <path>`, `repo-repair <path>`.

## Learn more

- **[docs/usage.md](docs/usage.md)** — full command reference and output contract
- **[docs/platform-design.md](docs/platform-design.md)** — architecture and design
- **[Releases](https://github.com/tyleradams2002/studio-stud/releases)** — changelog and downloads

## Build from source

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
site/                GitHub Pages: install.ps1, latest.json
setup/               studio-stud-setup.exe (GUI install/uninstall + CLI health/update/repair)
consumer-template/   files the installer drops into a consumer repo
docs/                usage.md, platform-design.md, plans/ (dev history)
```

To cut a release, push to `main`; for a versioned GitHub Release with downloadable artifacts, push a
tag (`git tag v0.5.0 && git push origin v0.5.0`).
