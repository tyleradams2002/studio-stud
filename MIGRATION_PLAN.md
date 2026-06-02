# Studio Stud — Migration & Standalone Repo Plan

Status: PLAN (pre-execution). This document governs moving the entire Studio Stud project out of
the FishersLife repo into this standalone repo (`tyleradams2002/studio-stud`), cleaning FishersLife
completely, and setting the project up to be hosted on GitHub + GitHub Pages for one-command install
into FishersLife and any other project.

## 1. Goals (locked with Tyler)

1. Move **absolutely everything** Studio Stud from FishersLife into this repo. This becomes the
   project's permanent home.
2. **Strip FishersLife entirely** of Studio Stud. It re-acquires the tool only via the installer.
3. **Vendored runtime install**: a single PowerShell command installs the runtime-only files into a
   clean folder inside any consumer repo (exe + plugin + launcher + version metadata + starter
   policy). No Rust source, tests, fixtures, or design docs go to consumers.
4. **Host on GitHub + GitHub Pages** so install/reinstall is a one-liner.
5. **Version checking in BOTH the daemon and the plugin** so they confirm to each other (and against
   the published release) whether an update is required.
6. **Clean copy** (git history is NOT preserved; history remains in FishersLife).

## 2. Source-of-truth inventory (verified on disk in FishersLife)

Everything below was confirmed to exist on disk. The migration copies from the **working tree**, not
git history, so files that are committed, staged-as-added, or untracked all transfer as their current
(post-revert) on-disk content.

### 2.1 Post-revert note (Clayton's bad push)
A `git revert` restored 26 Studio Stud files after a bad push. `git status` shows 25 staged `A` +
1 untracked (`.cursor/plans/studio_stud_edit_session_gating_a7f2c9e1.plan.md`). Because we copy from
disk, the reverted/good content is what transfers. These 26 are a subset of the full set below.

### 2.2 Rust crate `tools/studio_stud/` (→ new repo root)

Crate root: `Cargo.toml`, `Cargo.lock`, `build-local.ps1`

`src/` (23 files):
`main.rs`, `lib.rs`, `cli.rs`, `http.rs`, `util.rs`, `storage.rs`, `capture.rs`, `live.rs`,
`analyze.rs`, `query.rs`, `output.rs`, `policy.rs`, `diff.rs`, `bench.rs`, `write.rs`,
`write/file.rs`, `write/safety.rs`, `project.rs`, `project/index.rs`, `project/manifest.rs`,
`project/projection.rs`, `stage3_cli.rs`, `stage4_cli.rs`

`tests/`:
- Integration: `golden_outputs.rs`, `live_convergence.rs`, `write_safety.rs`, `write_http.rs`,
  `http_reliability.rs`, `project_diff.rs`
- `tests/golden/` (11): `analyze_markdown.txt`, `doctor_json.txt`, `status_json.txt`,
  `analyze_context_findings_critical.txt`, `query_class_part.txt`, `query_detail_boat_spawn.txt`,
  `query_name_boat_spawn.txt`, `query_tree_boat_spawn.txt`, `write_apply_outcome.txt`,
  `write_preview_diff.txt`, `project_projection_fixture.txt`
- `tests/fixtures/`: `README.md`, `baseline_capture.json`, `delta_simple.json`, `bulk_smoke.json`,
  `clayton_prompt.json`
- `tests/fixtures/live/`: `README.md`, `baseline.json`, `full_after.json`, `delta_struct.json`,
  `partial_delta.json`
- `tests/fixtures/write/`: `policy.json`, `target_clean.luau`, `target_malformed.luau`,
  `target_generated_no_header.luau`, `target_generated_with_header.luau`
- `tests/fixtures/project/`: `actual.json`, `repo/default.project.json`,
  `repo/.studio-stud/policy.json`, `repo/server/main.server.luau`, `repo/server/X.spec.luau`,
  `repo/server/Core/init.luau`, `repo/server/Core/DataManager.luau`,
  `repo/server/Systems/Combat.luau`
  (NOTE: this nested fixture repo's `.studio-stud/policy.json` and `default.project.json` are test
  data — distinct from the real consumer files — and must travel verbatim.)

`plugin/`: `StudioStud.plugin.lua`, `assets/studio-stud-logo.png`, `assets/studio-stud-logo-64.png`,
`assets/studio-stud-logo-128.png`

### 2.3 Outside the crate (→ new repo)
- Launchers: `studio-stud.ps1`, `studio-stud.cmd`
- Docs: `docs/studio-stud.md`, `docs/studio-stud-platform-design.md`
- Plans (7): `studio_stud_stage0_b7d4e0a1`, `studio_stud_stage1_c5e9f2a3`,
  `studio_stud_stage2_a1f4d6e2`, `studio_stud_stage3_e2c7a9f4`, `studio_stud_stage4_d3b9f1c7`,
  `studio_stud_edit_session_gating_a7f2c9e1`, `studio_stud_reliability_fixes`
- Cursor rule/command: `.cursor/rules/studio-stud.mdc`, `.cursor/commands/studio-stud.md`
- Consumer policy: `.studio-stud/policy.json` (kept as a reference template, not as FishersLife config)

### 2.4 Explicitly NOT migrated
- `tools/studio_stud/target/**` — build output (regenerated)
- `tools/studio_stud/bin/studio-stud.exe` — rebuilt; shipped as a release/runtime-bundle artifact

### 2.5 Known stale references to fix during the move
- `docs/studio-stud.md` references `tools/studio_stud/plugin/assets/generate_logo.py`, which does
  **not** exist. Either regenerate the script or fix the doc.
- `docs/studio-stud-platform-design.md` references two nonexistent plans
  (`studio_stud_rojo_97675197.plan.md`, `boat_plugin_plan_929c3fdf.plan.md`). Remove the dead links.

## 3. New repo structure (development home)

```
studio-stud/
  Cargo.toml  Cargo.lock
  src/                          # crate promoted to repo root (full module tree)
  tests/                        # fixtures, golden, integration
  plugin/StudioStud.plugin.lua
  plugin/assets/                # logos (+ generate_logo.py if regenerated)
  scripts/
    build-local.ps1            # dev build → target/release
    package-release.ps1        # assembles the runtime bundle (section 4)
    launcher.ps1 / launcher.cmd # templates the installer drops into consumers
  docs/usage.md                 # from docs/studio-stud.md (paths updated)
  docs/platform-design.md       # from docs/studio-stud-platform-design.md (dead links removed)
  docs/plans/*                  # the 7 dev-history plans (archived)
  site/                         # GitHub Pages: index.html, install.ps1, latest.json
  .github/workflows/release.yml # build exe → Release → deploy Pages
  README.md
  .gitignore                    # ignores target/, bin/ (exe is NOT committed)
  MIGRATION_PLAN.md             # this file
```

## 4. Runtime bundle (vendored into a consumer repo)

Built by CI on a version tag (manual `package-release.ps1` fallback) and attached to a GitHub
Release. Runtime-only — no source/tests/fixtures/design docs.

```
<consumer-repo>/.studio-stud-tool/
  bin/studio-stud.exe
  plugin/StudioStud.plugin.lua
  version.json                  # installed daemon+plugin version, protocol, source URL
<consumer-repo>/studio-stud.ps1 # launcher shim → keeps `.\studio-stud` working
<consumer-repo>/studio-stud.cmd
<consumer-repo>/.studio-stud/policy.json   # starter policy (placeIds blank/prompted)
```

Optional installer flag `--with-cursor-rule` also drops a thinned `.cursor/rules/studio-stud.mdc`
and `.cursor/commands/studio-stud.md` so an AI agent in the consumer repo knows how to use the tool.

Default folder name: `.studio-stud-tool/` (keeps `.studio-stud/policy.json` separate; leaves
`.\studio-stud` free as the command).

## 5. GitHub Pages + one-line install

- Pages base: `https://tyleradams2002.github.io/studio-stud/`
- Install: `irm https://tyleradams2002.github.io/studio-stud/install.ps1 | iex`
- `install.ps1` reads `latest.json`, downloads the release bundle into `.studio-stud-tool/`, writes
  the launcher shims + starter policy, records `version.json`, and prints next steps.
- `latest.json` is the published version source of truth:

```json
{
  "daemonVersion": "0.4.0",
  "pluginVersion": "0.3.7",
  "protocolVersion": 1,
  "minPluginProtocolVersion": 1,
  "minDaemonProtocolVersion": 1,
  "binaryUrl": "https://github.com/tyleradams2002/studio-stud/releases/download/v0.4.0/studio-stud.exe",
  "pluginUrl": "https://github.com/tyleradams2002/studio-stud/releases/download/v0.4.0/StudioStud.plugin.lua",
  "releasedAt": "<iso8601>"
}
```

## 6. Version checking (the headline feature)

### 6.1 Local mutual handshake (daemon ↔ plugin)
Each side ships its own version AND the minimum it requires of the other.
- Daemon manifest (`/ping`, `/manifest`) already returns `version`, `protocolVersion`,
  `minPluginProtocolVersion`. Add explicit `daemonVersion` naming and a structured
  `updateRequired: "plugin"` response when a too-old plugin connects.
- Plugin gains `MIN_DAEMON_PROTOCOL_VERSION`. On connect it compares its `PROTOCOL_VERSION` /
  `PLUGIN_VERSION` against the manifest and surfaces, in the widget status card:
  - daemon too old → "Daemon outdated — re-run install"
  - plugin too old → "Plugin outdated — reinstall plugin"
- Net effect: whichever side is behind is named by BOTH the CLI/daemon and the plugin UI.

### 6.2 Remote update check (against Pages `latest.json`)
- New CLI `studio-stud update --check` and the `serve` banner fetch `latest.json`, compare to local
  `version.json`, and print the upgrade command. Optional `update --apply` self-downloads.
- Plugin fetches `latest.json` (throttled ~daily via `HttpService`) and shows an "Update available"
  chip.

### 6.3 Single source of truth
Daemon version = `Cargo.toml`; plugin version = `PLUGIN_VERSION`; shared `PROTOCOL_VERSION`. CI
derives `latest.json` from these so versions never drift.

## 7. FishersLife cleanup

### 7.1 Delete (Group A — the tool's own files)
- `tools/studio_stud/` (entire tree)
- `studio-stud.ps1`, `studio-stud.cmd`
- `docs/studio-stud.md`, `docs/studio-stud-platform-design.md`
- `.cursor/rules/studio-stud.mdc`, `.cursor/commands/studio-stud.md`
- 7 `.cursor/plans/studio_stud_*.plan.md`
- `.studio-stud/policy.json`
- `.gitignore` lines 16–21 (Rust build-output + bin exceptions for the tool)

### 7.2 Neutralize cross-references (Group B — host files stay, Stud lines removed)
Default policy: remove the studio-stud-specific lines, keep surrounding general guidance. The
dedicated rule/command returns later via the installer's `--with-cursor-rule`.

- `.cursor/rules/repo-navigation.mdc` — remove `tools/studio_stud/...` layout rows + Stud file table
- `.cursor/rules/roblox-fishers-life.mdc` — remove "Studio Stud verify before depending" lines
- `.cursor/rules/world-snapshot.mdc` — drop the Stud tier; keep rbxlx fallback
- `.cursor/rules/rod-model-building.mdc` — remove mention
- `.cursor/skills/roblox-model-development/SKILL.md` + `MODEL_WORKFLOWS.md` — remove mentions
- `.cursor/skills/import-generated-model/SKILL.md` — remove mention
- `.cursor/skills/add-fish-model/SKILL.md` — remove mention
- `.cursor/commands/model-import-check.md` — remove mention
- `docs/local-automation-tooling.md` — remove the Studio Stud section
- `docs/meshy-companion-workflow.md` — remove mention
- `CLAUDE.md` (gitignored, local) — remove the "Studio World-State Verification" section + the
  reference-table row pointing at `.cursor/rules/studio-stud.mdc`
- `tools/check_automation.ps1` — remove any Studio Stud check entry

## 8. Execution checklist (ordered)

- [x] **Step 1 — Build out the new repo** from the section 2 manifest (clean copy):
      crate → root, plugin/docs/plans relocated, internal paths updated, stale refs fixed
      (section 2.5), add `scripts/`, `site/`, `.github/workflows/release.yml`, `README.md`,
      `.gitignore`. **`cargo build` + 54 tests pass at the new root.**
- [x] **Step 2 — Implement version checking** (section 6): daemon mutual handshake + `update`/
      `update --check` + launch-time self-update in `serve` (`src/update.rs`, `ureq`); plugin
      `MIN_DAEMON_PROTOCOL_VERSION` directional handshake + throttled remote check; `version.json` /
      `latest.json` formats. Build + tests green; `update --check` degrades gracefully when offline.
- [x] **Step 3 — Authoring**: `install.ps1`, `package-release.ps1`, Pages `site/` (index + latest.json),
      `.github/workflows/release.yml`.
- [x] **Step 4 — First push + tag** to `origin/main` → CI built the v0.4.0 Release (exe + plugin
      attached) and deployed Pages. Pages is split to deploy from `main` (the `github-pages`
      environment rejects tag deploys); build/release runs on `v*` tags. Published installer
      smoke-tested end-to-end in a temp repo: downloads daemon 0.4.0 + plugin 0.3.7, writes launchers/
      policy, and `update --check` reports up-to-date against live `latest.json`. Fixed an installer
      TLS type bug (`SecurityProtocolType`) found during the smoke test.
- [x] **Step 5 — Strip FishersLife** per section 7. Group A deleted (`tools/studio_stud/`, root
      launchers, `docs/studio-stud*.md`, the rule/command, 7 plan files). `.gitignore` Rust/tool lines
      replaced with a single `.studio-stud-tool/` ignore. Group B fully stripped (full-strip option):
      Studio Stud references removed from `repo-navigation.mdc`, `roblox-fishers-life.mdc`,
      `world-snapshot.mdc`, `rod-model-building.mdc`, the model/fish skills + `MODEL_WORKFLOWS.md`,
      `model-import-check.md`, `local-automation-tooling.md`, `meshy-companion-workflow.md`,
      `check_automation.ps1`, a stale `BoatAuthoringConfig.luau` comment, and `CLAUDE.md`. Verification
      guidance now points at the read-only Studio MCP / rbxlx fallback.
      **Deviation:** FishersLife's real `.studio-stud/policy.json` (place IDs + owned services) was
      KEPT, not deleted — the installer preserves an existing policy, so wiping it would have lost
      working config.
- [x] **Step 6 — Reinstall into FishersLife** via the published one-liner with `-WithCursorRule`:
      vendored daemon 0.4.0 + plugin 0.3.7 into `.studio-stud-tool/`, launcher shims, and the
      self-contained `.cursor/rules/studio-stud.mdc` + command re-added. Existing policy preserved.
      `.\studio-stud doctor` → `ready: true` (plugin source found, storage writable, SQLite OK; the
      two warnings are expected — server not yet running, Studio HTTP toggled at runtime).

> Distribution note: the `github-pages` environment rejects tag deploys, so CI splits — `build` +
> Release run on `v*` tags; `deploy-pages` (serving the committed `site/`) runs on `main` /
> `workflow_dispatch`. Future releases must commit an updated `site/latest.json` to `main` so Pages
> serves the new version. Installer TLS type bug fixed during smoke testing.

> Note: `Cargo.toml` gained `ureq` (HTTPS client for the daemon self-update). The daemon self-update
> stages `studio-stud.exe.new` and swaps it on next launch (Windows can't overwrite a running exe);
> the plugin file refreshes in place. Auto-update is on by default for `serve`; opt out with
> `--no-update`.

## 9. Open items / risks

- **Binary distribution**: recommended path is CI-built GitHub Release artifact (exe not committed).
  Manual `package-release.ps1` + manual release upload is the fallback if Actions setup is deferred.
- **Git history not preserved** (Tyler's choice). History stays recoverable in FishersLife.
- **Stale refs** (section 2.5) must be fixed during the move, not carried over.
- **Consumer footprint** is intentionally zero until reinstall; the `--with-cursor-rule` flag is how
  AI guidance returns.
- **The new repo is currently empty** (only `.git`, no commits) — migration starts from scratch.
