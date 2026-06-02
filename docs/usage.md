# Studio Stud

Studio Stud is the AI-first live Roblox Studio inspection path for Fisher's Life. It captures as much read-only Studio metadata as practical, stores the heavy data locally, indexes it into SQLite, and exposes compact JSON query surfaces for agents.

The core rule is simple: capture and storage are verbose; command output is compact unless `--markdown`, `--all`, `--props`, `--full-paths`, or another explicit detail flag asks for more.

Studio Stud does not publish, cloud-save, or mutate the place.

## Files

After installing into a consumer repo (via `install.ps1`):

```text
.studio-stud-tool/bin/studio-stud.exe      CLI/daemon (downloaded release binary)
.studio-stud-tool/plugin/StudioStud.plugin.lua
.studio-stud-tool/version.json             installed versions + protocol
studio-stud.ps1 / studio-stud.cmd          root launcher (.\studio-stud)
.studio-stud/policy.json                   per-project write policy
```

In this source repo (development):

```text
src/                                       Rust daemon/CLI source
plugin/StudioStud.plugin.lua               Studio plugin source
plugin/assets/studio-stud-logo*.png        logos (512 / 128 / 64)
scripts/build-local.ps1                    dev build → bin/studio-stud.exe
```

### Plugin logo (optional raster)

The widget uses a built-in vector gauge logo by default. For the toolbar icon and a sharper widget logo:

1. The committed PNGs live in `plugin/assets/` (`studio-stud-logo.png` 512, plus 128/64). A regeneration script is not currently included.
2. Upload `plugin/assets/studio-stud-logo.png` to Roblox as an **Image** (not a Decal — Decals can preview as a white square for UI icons).
3. Set `PLUGIN_LOGO_ASSET_ID` at the top of `StudioStud.plugin.lua` to `rbxassetid://YOUR_ID`.

Upload `studio-stud-logo.png` (512×512). Smaller exports: `studio-stud-logo-128.png`, `studio-stud-logo-64.png`.

## Requirements

- Windows, using `.studio-stud-tool/bin/studio-stud.exe` (installed) or `bin/studio-stud.exe` (dev build).
- Project-root launcher: `.\studio-stud <subcommand>`.
- Roblox Studio with the Studio Stud plugin installed from `.studio-stud-tool/plugin/StudioStud.plugin.lua`.
- Studio HTTP requests enabled for the experience.
- Localhost access to `127.0.0.1:31878`.
- Writable local app data storage for `%LOCALAPPDATA%/StudioStud/`.

## Storage

Captures are stored outside the repo under `%LOCALAPPDATA%/StudioStud/`. Each place has **one live SQLite DB** (`live.db`) that the plugin keeps current via incremental deltas. There is no capture history — the DB always reflects the live Studio state.

The compressed baseline (`baseline.json.gz`) is written atomically on each full capture and is used by `verify_drift` as a known-good reference. Do not load raw snapshots into chat for routine AI work.

## Live Capture

After the first successful `studio-stud capture`, the plugin activates live mode:

1. **Stable instance IDs** — each instance is identified by `GetDebugId(0)`, a Studio-session-stable opaque string. IDs do not shift when siblings are added or removed.
2. **Signal listeners** — `GetPropertyChangedSignal`, `AncestryChanged`, `AttributeChanged`, `DescendantAdded`, `DescendantRemoving` fire and mark instances dirty.
3. **Debounce flush** — dirty instances are coalesced and sent as `POST /studio-stud/live/delta` every 300 ms (configurable). The delta carries full structural entries (`upserted`) and removed IDs (`removed`).
4. **Neighbor-dirtying** — renames cascade path updates to the entire subtree; reparents dirty both old and new sibling groups for correct `siblingIndex`/`duplicateSiblingName` maintenance.
5. **Drift backstop** — `undo`/`redo` set `verifyNeeded=true`; every 3 minutes a full snapshot is sent to `POST /studio-stud/live/verify/*` regardless. The daemon computes fingerprints and promotes the staging partition if drift is detected.

The plugin does **not** use `sha256` locally — drift detection is revision-based (quick) plus periodic full-verify (hard backstop). The daemon's `apply_delta` result includes the new `revision` and `instanceCount` which the plugin tracks.

Delta convergence is guaranteed without a verify step: structural metadata (`path`, `parentId`, `siblingIndex`, `childCount`, `duplicateSiblingName`) is recomputed from the live tree at flush, and upserted entries are sent in parent-before-child topological order.

## Connection Resilience

The plugin tracks consecutive network failures. After **4 consecutive failures**, it tears down live mode, marks itself as disconnected, and begins polling for the daemon to come back. When the daemon becomes reachable again, the plugin automatically re-baselines (full capture) and re-enters live mode — no manual action required.

On `Live.teardown()` the error counter always resets to zero, so each new connection cycle starts clean.

The debounce flush timer (configurable in Settings, default 300 ms) controls how quickly dirty instances are sent. Undo/redo events bypass the debounce and set `verifyNeeded = true`, triggering the next verify cycle immediately.

Daemon connection count reference (measured June 2026, MikesResort):

| Scenario | Behaviour |
|----------|-----------|
| First plugin load | Auto-connect → full capture → live mode |
| Daemon restart | Detected within 3 s poll → auto re-baseline → live mode |
| 4 consecutive delta failures | Teardown → polling → auto re-baseline on reconnect |
| `undo`/`redo` | Sets `verifyNeeded=true`; next verify clears drift |

## Output Contract

- Default command output is compact JSON for AI.
- `--markdown` is the only human-readable output mode.
- `--detail` requires `--props` or `--all`.
- `--bulk` detail requests also require `props` or `all`.
- Paths are relative to the most useful base when possible.
- Use `--full-paths` only when full Explorer paths are needed.
- Bounded outputs include `returned`, `total`, `limit`, and `truncated` where relevant.

## Setup

Confirm the checked-in executable runs:

```powershell
.\studio-stud --help
```

Run the setup doctor during install or troubleshooting:

```powershell
.\studio-stud doctor
```

Use `--markdown` only when a human-readable report is needed:

```powershell
.\studio-stud doctor --markdown
```

Start the local server in its own terminal and leave it open:

```powershell
.\studio-stud serve
```

## Version checking & updates

The daemon and plugin confirm to each other (and against the published release) whether an update is
required.

**Mutual handshake (localhost).** On connect the plugin reads the daemon manifest (`/studio-stud/ping`)
and compares both directions:

- daemon `protocolVersion` < plugin `MIN_DAEMON_PROTOCOL_VERSION` → widget shows "Daemon outdated — update it"
- plugin `PROTOCOL_VERSION` < daemon `minPluginProtocolVersion` → widget shows "Plugin outdated — reinstall plugin"

So whichever side is behind is named explicitly, by both the daemon (its responses) and the plugin (its UI).

**Remote check (release manifest).**

- The daemon checks `latest.json` at launch and self-updates: `studio-stud serve` applies any
  previously staged update, then downloads a newer release as `studio-stud.exe.new` (Windows cannot
  overwrite a running exe) and refreshes the plugin file; the staged exe swaps in on the next launch.
  Disable with `--no-update`.
- `studio-stud update --check` reports availability as JSON; `studio-stud update` downloads/stages.
- The plugin fetches `latest.json` (throttled ~daily) and appends "Update available: …" to its status.

Version source of truth: daemon = `Cargo.toml`, plugin = `PLUGIN_VERSION`, shared `PROTOCOL_VERSION`;
the release pipeline derives `latest.json` from these (`scripts/package-release.ps1`).

In Roblox Studio, enable HTTP requests and install the plugin. Copy or symlink `.studio-stud-tool/plugin/StudioStud.plugin.lua` into your Studio plugins folder (not Downloads), then restart Studio or reload plugins.

Capture polling starts automatically when Studio loads the plugin. You do not click anything to enable polling.

## Plugin UI

The widget uses a chart-console look (deep navy, copper accent, teal status) — not a Rojo clone:

- **Logo + title** — survey-gauge mark (teal ring, copper pin, depth ticks) or uploaded raster from `plugin/assets/studio-stud-logo.png`; Merriweather title, “Live place inspector” subtitle, plugin version tag (currently `v0.3.7`; see `PLUGIN_VERSION` in `StudioStud.plugin.lua`).
- **Status card** — two-line card: top line is colored status text (idle / connected / syncing / error); bottom line shows live stats (`rev N · M instances · X pending`) updated every heartbeat.
- **Daemon endpoint** — labeled `HOST` / `PORT` fields (defaults `127.0.0.1` / `31878`).
- **Settings + Connect** — equal-width action row; Connect pings the daemon (health check only).
- **Settings panel** — full daemon URL, place info, last capture summary, setup steps, and a debounce slider (100 ms–2 000 ms, default 300 ms) controlling how long the plugin waits before flushing a dirty batch.

Captures are always requested from the CLI (`studio-stud capture`), not from the plugin panel. There is no manual capture button, copy-trigger helper, or start-polling toggle.

While Studio is open with the plugin loaded, the plugin polls the daemon every 3 seconds for pending capture requests and to detect daemon availability changes.

## AI Workflow

Check current local state:

```powershell
.\studio-stud status
```

Request a fresh capture. `serve` must already be running and the plugin must be loaded in Studio:

```powershell
.\studio-stud capture
```

Start with compact navigation context:

```powershell
.\studio-stud analyze
.\studio-stud analyze 139581542512435 --report context
```

Use count or narrow filters before asking for details:

```powershell
.\studio-stud query 139581542512435 --find Trader --count-only
.\studio-stud query 139581542512435 --find Trader --limit 10
.\studio-stud query 139581542512435 --name BoatSpawnPoints
.\studio-stud query 139581542512435 --path Workspace/BoatSpawnPoints
```

Use scoped relative results for hierarchy work:

```powershell
.\studio-stud query 139581542512435 --under Workspace/BoatSpawnPoints --class Part --limit 10
.\studio-stud query 139581542512435 --tree Workspace/BoatSpawnPoints --depth 1 --limit-siblings 25
```

Use explicit property selection for details:

```powershell
.\studio-stud query 139581542512435 --detail Workspace/BoatSpawnPoints --props Position,Size
.\studio-stud query 139581542512435 --detail MeshPart:000123 --props MeshId,TextureID,RenderFidelity,CollisionFidelity
.\studio-stud query 139581542512435 --detail MeshPart:000123 --all
```

Use `--bulk` when the AI already knows several bounded facts it needs (one process, one DB connection — preferred over parallel `query` calls):

```powershell
.\studio-stud query 139581542512435 --bulk '{"queries":[{"key":"boatSpawns","path":"Workspace/BoatSpawnPoints"},{"key":"spawnTree","tree":"Workspace/BoatSpawnPoints","depth":1,"limitSiblings":10},{"key":"dockProps","detail":"Workspace/Dock","props":["Position","Size"]}]}'
.\studio-stud query 139581542512435 --bulk @bulk.json
```

Default command output is **compact JSON on stdout** (warnings go to stderr). Parse stdout directly as JSON, or pipe to `ConvertFrom-Json` in PowerShell. Do **not** wrap stdout in `ConvertTo-Json` (that double-encodes). For deep `--tree` payloads, prefer reading raw stdout — PowerShell 5.1 `ConvertFrom-Json` can truncate nested depth.

Bare detail is intentionally invalid:

```powershell
.\studio-stud query 139581542512435 --detail MeshPart:000123
```

Use markdown only for human review:

```powershell
.\studio-stud analyze --markdown
.\studio-stud query 139581542512435 --find Trader --limit 10 --markdown
```

## Report Views

Keep reports narrow. `context` is the default AI navigation view. `findings` and `critical` are available when specifically useful. (`comparison` was removed in Stage 2 — there is only one live DB per place now.) Avoid broad report dumps; query SQLite through bounded `query` calls instead.

## Safety

- Daemon binds to `127.0.0.1` by default.
- Plugin only reads DataModel metadata and posts it to localhost.
- Raw snapshots stay local and should not be loaded into chat by default.
- Use compact `analyze` and bounded `query` output for AI access.

## Benchmarks (daemon-side ingest, Stage 2 measurements)

The hidden `bench` subcommand times only the Rust ingest pipeline on a fixture snapshot. Plugin capture walk and HTTP transfer are Studio/Luau-side and are not measured.

```powershell
# from the repo root (dev build)
# Full baseline ingest:
.\bin\studio-stud.exe bench --raw tests\fixtures\baseline_capture.json --iterations 100 --json
# Delta vs baseline comparison (3 ops: 2 upserts + 1 remove):
.\bin\studio-stud.exe bench --raw tests\fixtures\baseline_capture.json --delta tests\fixtures\delta_simple.json --iterations 100 --json
```

Recorded on a Windows dev machine (2026-06-02, release build, 100 iterations, 5-instance fixture):

| Stage | Median (ms) | Notes |
| --- | --- | --- |
| decode (gzip/utf-8) | ~0.029 | |
| parse (JSON) | ~0.010 | |
| captureMeta | ~0.005 | |
| ingestSqlite (full, in-memory DB) | ~0.638 | Full baseline path |
| **applyDelta (3 ops)** | **~0.118** | **~5.4× faster than full ingest** |

`applyDelta` includes the O(n) `recompute_findings` and `recompute_critical_presence` passes. For a 5-instance fixture the delta is ~5× cheaper than a full re-ingest. The ratio grows as place size increases (ingest is O(n) while delta is O(changed_instances)).

## Write Protocol (Stage 3)

Stage 3 adds a **generic, policy-gated Studio→filesystem write primitive**. There is **no write consumer yet** — Stage 5 (synced Luau) and Stage 8 (boat config) will call these endpoints later. The daemon validates and writes finished client text only; it never generates file bodies.

### Policy file (committed, team-shared)

Path: `.studio-stud/policy.json` at the repo root. **Committed** — not gitignored. Both developers must share the same policy in Stage 6.

```powershell
.\studio-stud policy init              # create default policy (minimal allowlist)
.\studio-stud policy check             # validate schema + globs (CI gate)
.\studio-stud policy explain --path synced/foo.luau
```

`policy explain` is content-independent: it reports allowlist match, place gate, size cap, and whether a generated header would be required. Luau parse, CAS, and header presence are enforced at write time.

Default `policy init` keeps `allowedWritePaths` **empty** (least privilege). Stage 5 broadens synced Luau globs; Stage 8 adds boat config paths.

### HTTP endpoints (token-gated)

Requires `studio-stud serve` running. The write token is issued locally and stored under `%LOCALAPPDATA%/StudioStud/write.token` — **never committed**.

| Route | Purpose |
| --- | --- |
| `GET /studio-stud/write/token` | Issue `{ ok, token }` for the plugin handshake |
| `POST /studio-stud/write/validate` | Run all gates without writing |
| `POST /studio-stud/write/preview` | Unified diff only; no write |
| `POST /studio-stud/write/apply` | Validate + atomic write |

Token transport: header `X-StudioStud-Token` first; body field `token` is fallback. Missing/invalid token ⇒ **401** `tokenInvalid`. Malformed JSON ⇒ **400** `badRequest`. Policy/validation blocks ⇒ **200** with `{ ok:false, blocked:true, blockedReason }`.

**Honesty note:** the localhost token mainly prevents accidental cross-talk from other local tools. Real protection is the allowlist, policy caps, place-id gate, and (later) hash CAS — not the token alone.

### Plugin handshake

On successful daemon ping, the plugin calls `Transport.fetchWriteToken()` and caches the token in plugin settings. `Transport.requestJsonAuthed()` attaches `X-StudioStud-Token` and retries once on 401 after re-fetching the token. No write UI or write calls in Stage 3.

### Determinism contract

- Line endings normalized to LF on write (`\r\n` and lone `\r` collapse to `\n`).
- **`changed`** = raw on-disk bytes differ from normalized proposed bytes (CRLF→LF rewrite counts as changed).
- **`hashBefore` / `hashAfter`** = sha256 over **normalized** bytes (CAS basis). `hashBefore == hashAfter` with `changed:true` is legal (EOL-only rewrite).
- Writes are atomic: temp file in target directory → `rename`. Failed validation creates no temp; failed rename removes the temp and leaves the original intact.

### Block reasons

| `blockedReason` | Meaning |
| --- | --- |
| `noPolicy` | Missing/invalid `.studio-stud/policy.json` |
| `pathNotAllowed` | Path escapes repo root or not in allowlist |
| `placeMismatch` | Place ID not in `allowedPlaceIds` |
| `invalidUtf8` | Content is not valid UTF-8 |
| `oversize` | Content exceeds `maxPatchBytes` |
| `headerMissing` | Generated header required but absent |
| `parseError` | Luau parse failed (`full-moon`) |
| `hashMismatch` | `--expected-hash` / `expectedHash` CAS mismatch |
| `internalError` | Policy IO, glob compile, canonicalize, or write failure |
| `tokenInvalid` | HTTP only — missing/wrong write token |
| `badRequest` | HTTP only — malformed JSON or missing fields |

Hidden CLI (no token; trusted local user): `write-validate`, `write-preview`, `write-apply` with `--repo-root`, `--path`, `--content-file`.

Permanent regression tests: `tests/write_safety.rs`, `tests/write_http.rs`, `tests/fixtures/write/*`, `tests/golden/write_*`.

## Project Diff (Stage 4)

Stage 4 adds a **read-only** repo index, Rojo v7 desired projection, and ownership-aware structural diff. It never writes files, mutates Studio, changes the SQLite schema, or adds HTTP routes. Script **source bodies are not compared** — capture stores no `Source`; source sync is Stage 5.

### Commands

```powershell
.\studio-stud project check                          # manifest + projection valid (no DB)
.\studio-stud project index                          # role counts; --full for entries
.\studio-stud project projection --full              # flattened desired instances + source hashes
.\studio-stud project diff <PLACE>                   # desired vs live DB (read-only)
.\studio-stud project diff <PLACE> --under ServerScriptService/Systems --limit 50
```

`--repo-root` resolves like `policy` (explicit path, else `.studio-stud/policy.json` or `default.project.json` ancestor). `project diff` uses `--storage-root` / `<PLACE>` like `analyze` / `query`.

### Diff categories

| Category | Meaning |
| --- | --- |
| `matched` | Present in repo projection and Studio; same class |
| `classMismatch` | Same path key; class differs |
| `missingInStudio` | Repo expects instance; absent in Studio |
| `extraInStudio` | Studio-only under a repo-owned subtree (`ignoreUnknownInstances: false` ancestor) — delete *candidate*, reported only |
| `studioOwned` | Studio-only under an ignore-true ancestor or unprojected service (Workspace, Lighting, …) |
| `unsupported` | Repo file type not projected this stage (`.rbxmx`, `.json`, …) |

**Ownership rule (Rojo v7):** `$path` nodes default `ignoreUnknownInstances: false` unless explicit; pure tree nodes (no `$path`) default `true`. FishersLife service roots set `ignore:true`, but directory-projected folders (e.g. `ServerScriptService/Core`) default `false` — Studio-only children there surface as `extraInStudio`, not under the service root.

Default output: actionable categories (`classMismatch`, `missingInStudio`, `extraInStudio`) carry bounded `items` (default `--limit 25`); bulk categories are count-only unless `--verbose`. `policyReadiness` reports which projected source paths would be writable under the current policy (read-only pre-flight).

Permanent regression tests: `tests/project_diff.rs`, `tests/fixtures/project/*`, `tests/golden/project_projection_fixture.txt`.
