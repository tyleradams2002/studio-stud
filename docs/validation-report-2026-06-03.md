# Studio Stud — In-Studio Validation Report (dev v0.4.9)

> **Purpose:** Hand this to a fresh Claude Code session to review and build a remediation plan.
> It is self-contained: every finding has repro, expected vs. actual, evidence, and a suspected cause.

**Date:** 2026-06-03 · **Environment:** Windows + PowerShell 5.1
**Tool:** Studio Stud, **dev** channel, **v0.4.9** · **Project phase (per maintainer):** completed phase 4 of 6 — the write/sync *workflow* is a later stage (Stage 7 reconcile / Stage 8 boat).
**Repo under test:** `C:\Users\tyler\OneDrive\Documents\GitHub\ExampleProjectTESTING` (Rojo project name `ExampleProject`)
**Place:** `100000000000002`, ~**38,737** instances · **Daemon:** `http://127.0.0.1:31878`, protocol 1

> All CLI verification was read-only against the live daemon/SQLite; **the place was never mutated**. The only file write was a temporary `policy.json` edit for the gate test, **reverted** at the end (`policy check` → `valid:true`). The in-Studio edits (add/rename/move/delete/paste) were made by the maintainer to exercise live deltas.

---

## TL;DR — headline issues, in priority order

1. **Install integrity is broken (P1).** The `studio-stud` launcher that wins on PATH is a **shim in `C:\WINDOWS\system32`** that points at a **second, different daemon binary** under `system32\.studio-stud-tool\`. There are **5 launchers on PATH**, **two divergent `studio-stud.exe` builds** (different SHA-256), and a **mostly-empty/stale `config.json`** registering the **wrong repo**. This is the root of the version confusion, the "access denied" on update, and the `release`-vs-`dev` update bug.
2. **First-connection did NOT auto-populate the data/policy/registry (P1).** *(maintainer call-out #2)* `config.json` stayed blank (`installRoot`/`pluginsDir`/`channel`/`versions` empty) with the wrong repo; the place worked only via a separate registry. Expected: the first plugin connection dynamically binds `PlaceId → repo` and fills config.
3. **Full capture false-fails with `HttpError: Timedout` (P2).** The widget reports failure (~10 s) while the daemon actually completes the capture (287 MB `syncs.db`). Plugin complete-timeout < daemon finalize time.
4. **Deletes are not live — every delete waited on the drift backstop (P2).** *(maintainer call-out #1)* 100% of delete operations (3/3) only reconciled on the periodic `verify`; adds/renames/paste were live. The backstop (a safety net) is doing the live path's job for an entire op class.
5. **Initial sync is slow (~10–11 s) and not instrumented (P2).** *(maintainer call-out #3)* The baseline capture / re-baseline takes ~10–11 s wall-clock; the daemon emits no timing logs to break it down.

---

## ⭐ Maintainer call-outs (explicitly requested)

### Call-out 1 — How many changes had to wait for the drift backstop (this should not happen)
The live delta path handled **adds, renames, moves, and bulk paste live (~1–2 s)** but **did not handle deletes live**. Tally from the session:

| Operation | Count in test | Reflected live? | Needed drift `verify` to reconcile? |
|---|--:|---|---|
| Add (insert Part) | 1 | ✅ yes | no |
| Rename | 2 | ✅ yes | no |
| Move | 1 | ✅ yes | no |
| Bulk paste (add) | 5 | ✅ yes | no |
| **Delete** | **3** | **❌ no** | **✅ all 3** |

- **3 of 3 deletes (100%)** required the periodic drift backstop to fix the count and/or purge a ghost row; **0 deletes** were reflected live.
- The backstop is designed as a **last-resort safety net** for rare missed signals — here it is the **primary mechanism for an entire operation class**. That is the wrong division of labor and means deletes are stale for up to one `verify` interval (observed tens of seconds).
- See **F-I** for evidence (count drift `38738` vs. expected `38737`; `query --find`/`--name` returning a deleted instance).

### Call-out 2 — Policy/registry data should have been dynamically filled on first connection; it wasn't
Per `platform-design.md` §2 ("Distribution and lifecycle"): *"the long-running daemon resolves `PlaceId → registered repo` per HTTP request … Unmapped places return `unbound` until bound via installer or `POST /studio-stud/context/bind`."* Expected behavior is that the **first plugin connection binds the place to its repo and populates the install/config record**. Observed:
- `%LOCALAPPDATA%\StudioStud\config.json` after a full session: `installRoot`,`pluginsDir`,`channel`,`versions.*` all **empty strings**; `pathShimInstalled:false` (a shim exists); `lastChannelSequence:{}`; `repos` lists **only** `…\GitHub\studio-stud` (the tool's own repo), **not** `ExampleProjectTESTING`.
- Yet capture/live/query all resolved `ExampleProject` correctly and the serve banner said **"Registry: 2 repo(s)"** — so the working binding came from a **different** registry than `config.json`, which was never populated/repaired on connect.
- `studio-stud-setup health --json` → `{"ok":false,"config":{"repoCount":1,"channel":"","installRoot":""},...}`.
- See **F-3**.

### Call-out 3 — Initial sync time
- **Initial full baseline capture / re-baseline: ~10–11 s wall-clock** (observed on `serve` restart auto re-baseline; the place returned to "Live" after ~10–11 s).
- The **first widget-triggered full capture exceeded the plugin's ~10 s HTTP timeout** and reported `HttpError: Timedout` even though the daemon completed it.
- The resulting `syncs.db` is **~287 MB** for 38,737 instances and is rebuilt on each cold baseline (drives the latency).
- **No daemon-side timing instrumentation exists** (the `serve` console prints only the startup banner), so the sync cannot be broken down into capture-walk / encode / transfer / ingest. `platform-design.md` §10 calls for a `--profile`/timing surface and §Stage 0 for a latency benchmark — neither is observable here. See **F-H**, **F-J**, **F-OBS**.

---

## Runbook results (Steps 0–9)

| # | Step | Result |
|---|------|--------|
| 0 | `serve` banner | ✅ PASS once 0.4.9 actually runs — rocky path to get there (F-2) |
| 1 | Widget connect / handshake | ✅ PASS (protocol 1, plugin auto-connected, v0.4.9) |
| 2 | Full capture from widget | ❌ **FAIL first attempt** (false `HttpError: Timedout`), succeeds on retry (F-H) |
| 3 | Agent verify (`status`/`analyze`/`query`) | ✅ PASS (bounded findings, placeId matches) |
| 4 | Live deltas (move/rename/add/delete) | ⚠️ **PARTIAL** — add/rename/move/paste live; **delete not live** (F-I) |
| 5 | Undo/redo/bulk paste reconverge | ✅ PASS (drift backstop converges; bulk-add live) |
| 6 | Stop/restart `serve` re-baseline | ✅ PASS correctness, ⚠️ **~10–11 s vs ~3 s** (F-J) |
| 7 | Allowlisted write | ✅ engine/401/diff PASS · ⏳ atomic-write workflow **not built (Stage 7/8)** (F-K) |
| 8 | Place-mismatch write block | ✅ `placeMismatch` engine PASS · ⏳ write-block workflow **not built** |
| 9 | Auto-update check | ⚠️ `false` ✓ + baseline ✓, but **wrong channel** (F-G) |

---

## Findings

### P1 — Distribution / install integrity

#### F-1 · PATH-winning launcher lives in `system32` and points at a *second* daemon binary
- **Evidence:**
  - `Get-Command studio-stud -All` returns **5** entries: `C:\WINDOWS\system32\studio-stud.ps1` (+`.cmd`) ← **wins precedence**; `…\GitHub\ExampleProject\studio-stud.ps1` (+`.cmd`) ← a **sibling** repo (not `ExampleProjectTESTING`); `…\AppData\Local\StudioStud\bin\studio-stud.exe`.
  - The winning shim computes its exe as `$PSScriptRoot\.studio-stud-tool\bin\studio-stud.exe` = **`C:\WINDOWS\system32\.studio-stud-tool\bin\studio-stud.exe`** — *distinct* from the `%LOCALAPPDATA%\StudioStud\bin\studio-stud.exe` that `studio-stud-setup` manages.
  - Two daemon binaries, **same size 12,708,864, different SHA-256**: `system32 = A22C520D…2F04` (mtime 01:56), `LocalAppData = 05A1D4B1…FBDB` (mtime 04:53). A `studio-stud.old` (10,178,560 = prior 0.4.0) sits beside the system32 one.
- **Impact:** Writing under `system32` needs admin → the **"access denied" on update**. Ambiguity over which binary actually runs.
- **Direction:** Install the launcher shim into a **user-writable** PATH dir, never `system32`; converge on **one** canonical daemon path; remove stale/duplicate shims (incl. sibling-repo ones); make the installer **idempotent** (detect + clean prior installs, including the legacy `.studio-stud-tool/` bundle the design doc says should be replaced).

#### F-2 · Fresh dev install shipped a 0.4.0 daemon under a 0.4.9 setup; "apply staged update" didn't take on first restart
- **Repro:** Fresh dev install → `studio-stud serve`.
- **Actual:** `update v0.4.9 downloaded (installed v0.4.0)` then `Studio Stud v0.4.0 serving…`. Restart → `applied staged update (0.4.9). Now running it.` **but still** `Studio Stud v0.4.0 serving…`. A **second** relaunch was required to actually serve 0.4.9. The old 0.4.0 daemon also used **CWD as repo root** (`Repo root: C:\WINDOWS\system32`), retired in the 0.4.9 banner ("Registry: 2 repo(s); PlaceId resolves per request").
- **Expected:** A fresh dev install runs 0.4.9 for both binaries; "Now running it" is actually running it.
- **Suspected cause:** Tied to F-1 — the staged update replaced one copy while the shim launched the other; the apply does not hot-swap the running process and the message is misleading.

#### F-3 · `config.json` mostly empty / wrong repo / split-brain with `version.json` (see Call-out 2)
- **Evidence:** `config.json` fields blank as listed in Call-out 2; `setup health --json` → `ok:false`, `repoCount:1`, `installRoot`/`pluginsDir` unconfigured. `version.json` (LocalAppData) is **correct**: `{channel:"dev",daemonVersion:"0.4.9",lastChannelSequence:{dev:1},pluginVersion:""}`. The **system32** install has a *different* `version.json`: `{daemonVersion:"0.4.9",pluginVersion:"0.4.9"}` (note LocalAppData `pluginVersion` is empty).
- **Impact:** Empty `channel` here is the likely root of **F-G**. Two version records disagree; the registry the daemon uses is not this file.
- **Direction:** Populate `config.json` on install/first-connect (installRoot, pluginsDir, channel, versions, real repo); make one record the source of truth and reconcile `version.json` ↔ `config.json`; bind the place→repo mapping on connect.

### P2 — Runtime / capture

#### F-H · Widget full capture reports `HttpError: Timedout` though the capture succeeds server-side
- **Repro:** Widget → **Capture / Query** on this 38,737-instance place.
- **Actual:** "Capturing place data…" → ~10 s → **"Capture failed / Complete failed: HttpError: Timedout"**; widget keeps stale `Latest capture: OK / rev 0`.
- **But the daemon completed it:** `status` `captureId` advanced (`capture_…200848791`), `updatedAtUtc` fresh, `analyze` returned the new capture; during the failure the DB was being written (`baseline.json.gz` + **`syncs.db` ≈ 287 MB**). Retry succeeds (DB already sized).
- **Suspected cause:** Plugin's HTTP **complete-timeout (~10 s)** < daemon finalize time for a large place. (CLI `capture` default timeout is **300 s** — so the limit is plugin-side.)
- **Direction:** Raise/parameterize the plugin complete-timeout, or have `/capture/complete` **ack immediately and finalize async**, or chunk; **investigate the ~287 MB `syncs.db`** (fixed size, doesn't grow per capture — possible over-allocation / no compaction) — it drives both this and F-J.

#### F-I · Deletes are not applied live — count drift + ghost rows until the periodic `verify` (see Call-out 1)
- **Repro:** With live streaming active: add `StudTest_Alpha`, rename a part to `StudTest_Bravo`, move one, delete one disposable; then delete `StudTest_Alpha`; later redo-delete via undo/redo.
- **Actual:**
  - Add & rename propagate **live**: `query --find StudTest_Alpha`/`StudTest_Bravo` found immediately; bulk paste of 5 → `query --find StudTest_Bravo --count-only` = `total:6` (1+5). ✅
  - **Deletes lag:** after deleting `StudTest_Alpha`, `instanceCount` decremented but **`query --find`/`--name StudTest_Alpha` still returned the deleted part** (ghost `id 449642`). A separate disposable-delete didn't decrement live (count read `38738` vs expected `38737`). Undo/redo showed `3 pending` and a wrong count until reconcile.
  - All corrected **only on the next periodic `verify`** (e.g., rev 23→24, `verify_…205437381`): count settled to the correct `38736`, ghost cleared (`total:0`).
- **Expected (runbook):** "status reflects the change within ~1–2 s."
- **Suspected cause:** `DescendantRemoving` is not producing a live removal delta the way `DescendantAdded`/property-change signals do; deletes are deferred to the drift backstop. `platform-design.md` §6 claims **"Complete"** coverage for removes — current behavior diverges.
- **Direction:** Emit removal deltas on `DescendantRemoving` so deletes are first-class live ops; keep the backstop as a net, not the primary delete path.

#### F-J · Auto re-baseline after `serve` restart takes ~10–11 s (runbook says ~3 s) (see Call-out 3)
- **Repro:** Ctrl+C the daemon, restart `studio-stud serve`; watch the widget return to "Live."
- **Actual:** Re-baselines **automatically** (no manual action ✅), but **~10–11 s**. After: fresh full baseline `capture_…210230126`, `revision:0`, state preserved (6 Bravos / 0 Alpha).
- **Suspected cause:** Re-baseline = full capture → rebuilds the ~287 MB `syncs.db` (same root as F-H).

### P2 — Update

#### F-G · `studio-stud-setup update --check` resolves to the `release` channel on a `dev` install
- **Evidence:** `studio-stud-setup update --check --json` → `{"channel":"release","requestedChannel":"release","installed":"0.4.9","latest":"0.4.9","updateAvailable":false}` while `version.json.channel="dev"`; the daemon **`/ping`** correctly reports `{"channel":"dev","updateAvailable":false}`. The `update` subcommand has **no `--channel` flag**.
- **Impact:** The runbook's Step 9 command would **not detect dev pushes**; only the daemon's own update path (which fired earlier to pull 0.4.0→0.4.9) uses `dev`.
- **Positive:** the channelSequence baseline fix **landed** — `version.json.lastChannelSequence.dev = 1` (a dev push with a higher sequence should trigger via the daemon even if the version string is unchanged). But `config.json.lastChannelSequence` is `{}`.
- **Suspected cause:** `update --check` reads `config.json.channel` (empty per F-3) and defaults to `release`. Fix F-3 and/or have `update` honor `version.json.channel`; add a `--channel`/`--dev` override.

### P3 — Papercuts / docs / CLI surface

#### F-B · `project check` / `policy check` fail with relative or default `--repo-root`; only absolute works
- **Repro (CWD = repo root, files valid, no BOM):**
  - `studio-stud project check --repo-root .` → `{"error":"missing or unreadable default.project.json","detail":"… (os error 2)"}`
  - `studio-stud policy check --repo-root .` → `Error: expected value at line 1 column 1`
  - Same with `--repo-root ./` and with **no flag** (default). With an **absolute** `--repo-root` → both `ok:true`.
- **Impact:** The runbook documents both commands with `--repo-root .`; as written they always fail. Confirmed on genuine 0.4.9.
- **Suspected cause:** Relative/default repo-root not canonicalized against the process CWD before opening `default.project.json` / `policy.json`.

#### F-K · `policy.json → allowedPlaceIds` requires integers; placeIds are strings everywhere else
- **Repro:** `"allowedPlaceIds": ["100000000000002"]` (string, as emitted by `status`/`query`/widget and implied by the runbook).
- **Actual:** `Error: invalid type: string "100000000000002", expected i64 at line 2 column 39` — never names `allowedPlaceIds`. Integer form `[100000000000002]` works, after which the engine is correct (see "Validated solid").
- **Direction:** Accept string **or** int (serde `deserialize_with`/untagged); emit a field-named error.

#### F-A · No `studio-stud --version`
- `studio-stud --version` → `error: unexpected argument '--version'`. Version is only on `studio-stud-setup --version`; `doctor`/`status` JSON carry no version field. The runbook prereq says `studio-stud --version → 0.4.9`. Add a `version` subcommand/flag to the main binary, or fix the runbook.

#### F-OBS · `serve` emits no per-request logs (observability gap)
- After every capture attempt the `serve` console showed **only the startup banner** — no capture/complete/error/duration lines; no log file in the storage root. This is why F-H/F-J are invisible daemon-side and why initial-sync timing can't be broken down. Add request/timing/error logging (stdout and/or a rotating file); aligns with the §10 `--profile` goal.

#### Minor
- `query … --count-only` still echoes `limit:25, truncated:true` though it only counts.
- **Security default to confirm:** empty `allowedPlaceIds` = **allow-all** (`placeAllowed:true`); it only enforces once populated. Confirm fail-open is intended for a write-safety gate.

---

## Validated solid (do not regress)
- Clean handshake (protocol 1), plugin **auto-connect**, plugin **v0.4.9**; `/studio-stud/ping` healthy (`channel:dev`, `protocolVersion:1`).
- `analyze --report context/findings/critical` bounded output; `--limit` truncation correct (`returned/total/truncated`).
- `query` surface (`--find`/`--name`/`--class --count-only`); live **add/rename** and **bulk paste** propagate ~1–2 s and index correctly (6 Bravos = 1+5).
- Drift backstop (`verify`) reconverges undo/redo churn **and** deletes to the correct state — no stuck/garbage counts (it works; it's just being over-relied-on per F-I).
- `project diff` bounded structured diff (260 matched / 4 extra / 4 missing / 38,477 studio-owned / 0 classMismatch) with policy gate applied (231 paths blocked).
- **Policy engine correct** (`policy explain`): allowlisted+allowed → `allowed:true`; non-allowlisted → `pathNotAllowed`; wrong place → `placeMismatch`. `policy check` validates.
- **Write endpoints exist and are token-gated:** `POST /studio-stud/write/validate` and `/write/preview` **without a token → HTTP 401** (Stage 3 built).

## Open (needs real conditions — not bugs)
- Step 7 atomic write + applied unified diff, and Step 8 actual write-block: need the **write workflow** (Stage 7 reconcile / Stage 8 boat) — not built yet. The substrate (policy engine, `/write/*` endpoints, token gate, diff) is in place.
- Step 9 "`updateAvailable:true` after a dev push": needs an actual CI **dev** publish to verify end-to-end.

---

## Appendix A — Top classes by instance count (sync-volume hot spots)

Ranked from `studio-stud query <place> --class <C> --count-only` over common classes (47 classes had >0; summed 36,708 of 38,737 ≈ 95% coverage). **Volume**, not measured change-frequency — see caveat below.

| Rank | Class | Count | Rank | Class | Count |
|--:|---|--:|--:|---|--:|
| 1 | **Part** | **16,449** (42%) | 14 | PointLight | 260 |
| 2 | SpecialMesh | 3,516 | 15 | ModuleScript | 230 |
| 3 | MeshPart | 2,829 | 16 | Animation | 197 |
| 4 | Model | 2,261 | 17 | StringValue | 192 |
| 5 | Texture | 1,904 | 18 | Motor6D | 158 |
| 6 | UnionOperation | 1,622 | 19 | WedgePart | 144 |
| 7 | WeldConstraint | 1,445 | 20 | NumberValue | 132 |
| 8 | Attachment | 1,420 | 21 | Frame | 125 |
| 9 | Weld | 1,399 | 22 | Decal | 115 |
| 10 | Vector3Value | 516 | 23 | ParticleEmitter | 103 |
| 11 | Beam | 375 | 24 | TextLabel | 103 |
| 12 | SurfaceAppearance | 364 | 25 | Sound | 84 |
| 13 | Folder | 304 | | | |

- **Top 9 classes ≈ 85%** of all instances (32,845 / 38,737); **Part = 42%**.
- Structural drivers from `analyze --report findings`: **18,328 instances with duplicate sibling names** (~47% — forces duplicate-safe path machinery; this rose to 18,328 after the test paste), **1,622 UnionOperation**, **1,360 MeshPart/UnionOperation under ReplicatedStorage**, 154 invisible-collidable parts, 19/66 ProximityPrompts missing text.
- **Caveat / feature gap:** the DB exposes no per-instance change/event-count history, so there is no true "noisiest during live editing" ranking. As a live-churn proxy, editing **Parts/Models** cascades the most deltas (a Model move → every descendant Part's CFrame; Welds/Attachments/Motor6D ride along). A per-instance/-subtree delta counter would make this measurable and make `liveCaptureScope` tuning data-driven.

## Appendix B — Environment & key evidence commands

```text
# versions / health
studio-stud-setup --version            # -> 0.4.9   (NOTE: studio-stud --version errors; F-A)
studio-stud doctor                     # ready:true, 2 expected warnings
studio-stud-setup health --json        # ok:false, repoCount:1, installRoot/pluginsDir empty (F-3)

# daemon / capture state
studio-stud status                     # daemon 0.4.9, protocol 1, place liveState
studio-stud analyze 100000000000002 --report context --limit 10
studio-stud query  100000000000002 --find <Name> [--count-only]

# repo-root bug (F-B): relative fails, absolute works
studio-stud project check --repo-root .                  # FAILS (os error 2)
studio-stud project check --repo-root C:\...\ExampleProjectTESTING   # ok:true

# policy engine (correct once placeId is an INTEGER — F-K)
studio-stud policy explain --path src/Shared/X.luau --place 100000000000002 --repo-root <ABS>

# write endpoints exist + token-gated (Step 7 partial)
Invoke-WebRequest http://127.0.0.1:31878/studio-stud/write/validate -Method POST -Body '{}'  # -> 401

# update channel bug (F-G)
studio-stud-setup update --check --json   # channel:"release" on a dev install
# vs daemon GET /studio-stud/ping          -> channel:"dev"
```

**Key file locations**
- `%LOCALAPPDATA%\StudioStud\config.json` — stale/empty, wrong repo (F-3)
- `%LOCALAPPDATA%\StudioStud\version.json` — correct (`dev`, `0.4.9`, `lastChannelSequence.dev:1`)
- `%LOCALAPPDATA%\StudioStud\ExampleProject\places\100000000000002\syncs.db` — **~287 MB** (F-H)
- `C:\WINDOWS\system32\studio-stud.ps1` + `C:\WINDOWS\system32\.studio-stud-tool\` — system32 install (F-1)
