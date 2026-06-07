# Studio Stud Plugin — Technical Review (secure / smart / efficient)

**Target:** `plugin/StudioStud.plugin.lua` (v0.4.19, working tree — file is uncommitted/modified)
**Scope:** read-only review for correctness, efficiency, and security. **No code was changed.**
**Reviewed:** full file, 4,607 lines.
**For:** hand-off to implementation planner. Each finding has `file:line` refs and a fix direction — not a patch.

> Reviewer's note for the planner picking this up cold: the plugin runs **inside Roblox Studio** as a
> plugin (the `plugin` global must exist). It walks the edit-session DataModel, tracks live changes via
> instance signals, and POSTs snapshots/ticks to a local daemon at `http://127.0.0.1:31878`. The
> "live capture engine" (`Live.*`) is the heart of it: signals mark instances dirty → a tick loop drains
> the dirty set → uploads inline or as chunked "bulk". Three of the findings below break that engine in
> the current working tree.

---

## Severity summary

| ID | Sev | Area | One-liner |
|----|-----|------|-----------|
| C1 | 🔴 Critical | Correctness | `Live.markDirtyUpsert` is infinite recursion — dirty-tracking is dead, stack-overflows on first change |
| C2 | 🟠 High | Correctness | `pausedBaseline`/`onReturnToEdit` used before declaration → play→edit auto-resume silently disabled |
| C3 | 🟠 High | Correctness | `syncFn` calls `startupConnectAndCapture` before it's in scope → nil call on pre-live `Sync()` |
| E1 | 🟠 High | Efficiency | O(K²) payload re-encode per tick when sizing inline-vs-bulk |
| E2 | 🟡 Med | Efficiency | O(N²) sibling rescans on mass rename/reparent/delete |
| E3 | 🟡 Med | Efficiency | Redundant full-tree walk + double property read on every connect |
| E4 | 🟡 Med | Efficiency | Full place re-baseline on every undo/redo (+ a dropped-rebaseline race) |
| E5 | ⚪ Low | Efficiency | Per-tick `GetSetting` boundary hop; token re-fetch on every ping |
| S1 | 🟠 Med | Security | No loopback enforcement on daemon URL + auto-upload of all source on load |
| S2 | 🟡 Med | Security | `_G.StudioStud.Sync/Capture` reachable by any code sharing the Studio VM |
| S3 | ⚪ Low | Security | Write token stored in plaintext plugin settings |
| S4 | ⚪ Low | Security | Unpublished places (`PlaceId == 0`) collide on the daemon |
| M1 | 🟡 Med | Maintainability | No `--!strict`/lint — would have caught C1–C3 |
| M2 | 🟡 Med | Maintainability | Service fingerprint keys include `[1]`; test fixtures don't match real paths |
| M3 | ⚪ Low | Maintainability | Hash is FNV-32 (not SHA-256 as docs say); `source` excluded from drift hash |
| M4 | ⚪ Low | Maintainability | `UserInputService` connections leak per `Shell.build` |
| M5 | ⚪ Low | Maintainability | Vestigial `pollGeneration`; `collectOpsFromEntries` test-only |
| M6 | 🟡 Med | Testing | Self-tests structurally cannot catch C1–C3; add regressions |

---

## 🔴 Critical / High — correctness (break live capture today)

### C1 — `Live.markDirtyUpsert` is infinite recursion
`plugin/StudioStud.plugin.lua:2347`
```lua
function Live.markDirtyUpsert(inst)
	Live.markDirtyUpsert(inst)        -- calls itself unconditionally (non-tail) → stack overflow
	Live.dirtyStamp += 1
	Live.upsertStamp[inst] = Live.dirtyStamp
end
```
Compare the sibling `Live.markDirtyRemoved` at `:2353`, which correctly does `Live.dirtyRemoved[id] = true`.
The intended first line is almost certainly `Live.dirtyUpsert[inst] = true`.

**Why it matters:** `markDirtyUpsert` is the **only writer** of `Live.dirtyUpsert` (every other `dirtyUpsert[...]`
in the file is a `nil`-clear or a self-test direct-assign). It is invoked from ~10 live signal handlers:
`Changed` (`:2626`), `AncestryChanged` (`:2568`), `AttributeChanged` (`:2588`), ValueBase `Value` (`:2609`),
`DescendantAdded` (`:2709`), `SelectionChanged` (`:3136`), plus the subtree/sibling cascades (`:2487`, `:2506`,
`:2516`). With auto-connect on load, the first property edit or selection change after connecting overflows the
stack, and the dirty set that `collectOpsFromDirty` (`:2813`) drains is never populated.

**Fix direction:** body's first line → `Live.dirtyUpsert[inst] = true` (keep the two stamp lines).

---

### C2 — `pausedBaseline` / `onReturnToEdit` referenced before declaration → play→edit resume disabled
`plugin/StudioStud.plugin.lua:2152` uses locals declared ~1,100 lines later at `:3273` / `:3274`.
```lua
-- line 2152, inside startupConnectAndCapture (defined at :2132)
Live.startTickLoop(pausedBaseline, onReturnToEdit)
...
-- :3273 / :3274 — declared AFTER the use site
local pausedBaseline = { revision = 0, instanceCount = 0 }
local function onReturnToEdit() ... end
```
In Lua, a local's scope begins **after** its declaration statement. At `:2152` both names bind to **globals
(nil)**. So the first connect calls `startTickLoop(nil, nil)`, and in `startTickLoop`:
- `:3181` `if pausedBaselineRef then ...` → skipped (revision/instanceCount not saved on entering play).
- `:3191` `if onReturnToEditFn then task.defer(onReturnToEditFn) end` → **skipped → live capture never
  resumes after a playtest.**

This defeats the "Reconnects automatically…" copy in the Settings UI (`:3612`) and the edit-session-gating
design. (The *correct* call at `:3282` inside `onReturnToEdit` is never reached, because the first
connect passed nil and never scheduled it.)

**Fix direction:** forward-declare near the other forward decls at `:1573–1576`:
`local startupConnectAndCapture, pausedBaseline, onReturnToEdit` — so every reference binds the same upvalue.

---

### C3 — `syncFn` calls `startupConnectAndCapture` before it's in scope → nil call
`plugin/StudioStud.plugin.lua:2068` (inside `syncFn`, assigned at `:2059`) references
`startupConnectAndCapture`, but `local function startupConnectAndCapture` isn't declared until `:2132`.
So the `not liveRunning` branch resolves to a nil global → `attempt to call a nil value`. This is the path
taken by `_G.StudioStud.Sync()` / `.Capture()` before live mode is running. Same root cause and same fix
as C2 (missing forward declaration).

> **Why CI is green anyway:** SelfTest drives the dirty sets by *direct assignment*
> (`live.dirtyUpsert[dummyInst] = true`, `:4449`) and never calls `markDirtyUpsert`, a real connect, or the
> pre-live `Sync()` path — so none of C1–C3 are reachable from tests. **All three are caught by
> `--!strict` / `luau-analyze`** ("Unknown global 'startupConnectAndCapture/pausedBaseline/onReturnToEdit'").
> See M1.

---

## 🟠 Efficiency

### E1 — O(K²) payload sizing on the tick hot path
`plugin/StudioStud.plugin.lua:2828–2852` (`collectOpsFromDirty`) and its twin `collectOpsFromEntries`
(`:2408`) choose inline-vs-bulk by **re-encoding the whole cumulative payload for every candidate op**:
each iteration builds a full `trialUpserted` copy (`:2836`) and calls
`shouldBreakOpsCap → tickPayloadByteLen → safeEncode` (`:2388`), which `JSONEncode`s all prior entries **plus
all service fingerprints** again. For K dirty instances that's K encodes of sizes 1..K → **O(K²)** bytes,
inside `runTick` which runs up to 10×/sec. Fine for dragging one part (K=1); expensive for bulk edits
(folder rename, multi-select transform of N parts).

**Fix direction:** encode each entry once, keep a running byte sum (+ a fixed fingerprint/overhead constant),
compare incrementally; drop the per-iteration `trialUpserted` copy.

### E2 — O(N²) sibling rescans on mass operations
`buildUpsertedEntry` (`:2747–2760`) recomputes `siblingIndex`/`duplicate` by scanning the parent's full child
list for **each** dirtied instance. A folder rename/reparent dirties the whole subtree via `markSubtreeUpsert`
(`:2480`); with N same-parent children that's N scans of N → **O(N²)**. `markSiblingsDirty` (`:2501`, fired on
every add/remove/rename) and per-child `onDescendantRemoving` (`:2714`) on mass delete compound it.

**Fix direction:** when many siblings of one parent are dirtied in a tick, compute that parent's
`siblingCounts`/index map once and reuse across its dirtied children.

### E3 — Redundant full-tree walk + double property read on connect
`connectLiveMode` (`:3104–3105`) runs `collectBaseInstances()` then `initFingerprintsFromWalk()`, which calls
`buildUpsertedEntry` (full property read + sibling scan) for **every** instance — and those fingerprints are
then **discarded** by `resetFingerprints()` inside `buildBaselineSnapshot` (`:2964`) when the first tick
triggers a baseline. On a cold daemon the tree is walked ~3× and properties read ~2× per connect.

**Fix direction:** keep the walk only for the *warm-reconnect* case it actually helps (proving "no drift" so
the first tick can skip re-upload); skip it when a fresh baseline is about to run anyway.

### E4 — Full re-baseline on every undo/redo (+ dropped-rebaseline race)
`runTick` (`:3017`): any `OnUndo`/`OnRedo` (`:3146`) sets `historyDirty`, forcing a whole-place
re-capture+upload on the next tick — even for undoing one property tweak. Also `historyDirty` is cleared
*before* `triggerFullBaseline`, which no-ops if `baselineInProgress`, so a rebaseline can be dropped during
rapid undo (recovered later only by drift detection).

**Fix direction:** reasonable tradeoff given ChangeHistory gives no delta — at minimum, document it and
don't clear `historyDirty` until a baseline actually starts.

### E5 — Minor per-tick boundary calls
`startTickLoop` (`:3172`) calls `Settings.getDebounceMs()` (a `pcall` + `plugin:GetSetting` C-boundary hop)
every loop; `statusFn` (`:2121`) re-fetches the write token on every successful ping. Cheap individually;
cache and refresh-on-change if tidying the hot loop.

---

## 🔒 Security

### S1 — No loopback enforcement on daemon URL + auto-upload of all source on load
The plugin reads **every script's `Source`** (`readSource`, `:1870`, PluginSecurity) and POSTs the whole
DataModel to `Transport.currentUrl()`. `parseDaemonUrl` (`:1010`) accepts any host; nothing constrains it to
localhost, and bootstrap auto-connects on load (`onWidgetEnabled`, `:4576`). A mistyped or tampered
`StudioStudDaemonUrl` setting silently exfiltrates full place source off-machine.

**Fix direction:** validate the host is loopback (`127.0.0.1` / `localhost` / `::1`) before any capture/source
upload, or warn + require explicit opt-in for non-loopback. The product is local-only, so this is cheap
hardening.

### S2 — `_G.StudioStud.Sync/Capture/Status` reachable by any code sharing the Studio VM
`GlobalApi.wireCapture` (`:3345`) exposes capture/sync on the shared `_G`, so any other plugin or the command
bar can trigger a full capture+upload. Intentional for the command bar/self-test, but worth gating
(namespaced token, or expose only `RunSelfTest`) now that `Sync` has upload side effects.

### S3 — Write token stored in plaintext plugin settings
`fetchWriteToken` (`:1152`) persists the token via `plugin:SetSetting` (`:1155`); readable by any plugin via
`GetSetting`. Low risk (localhost scope; addon enable/disable only). Document the trust boundary.

### S4 — Unpublished places (`PlaceId == 0`) collide
`buildSnapshot` (`:2042`) falls back to `game.Name` for the place key, but `tickQuerySuffix` (`:2367`) and the
tick body route on raw `placeId=0`. Every unpublished place shares key `0` on the daemon → cross-place state
mixing. Reconcile the keying, or refuse live mode at `PlaceId == 0`.

---

## 🟡 Maintainability / testing

- **M1 — Adopt `--!strict` + `luau-analyze` in CI.** The file has no luau-check directive and only sparse
  annotations. All of C1–C3 surface as analyzer warnings (unknown globals; the recursion as a self-write
  with no external write). Highest-leverage single change for "smart + secure."
- **M2 — Service fingerprint keys include the `[1]` suffix; test fixtures don't match production.** Real walk
  paths are `Workspace[1]/Part[1]` (`collectBaseInstances`, `:1951`), so `serviceOf` (`:2294`) yields
  `"Workspace[1]"` as the fingerprint key — but self-test fixtures use `"Workspace/A[1]"` (`:4239`), yielding
  `"Workspace"`. Tests can't catch a plugin/daemon key-derivation mismatch. Verify both sides agree; make
  fixtures use the real path shape.
- **M3 — Hash is FNV-32 lanes, not SHA-256.** `hashInstance` (`:2239`) is 8×FNV-32 (fine for non-adversarial
  drift detection), despite docs/memory calling it "SHA-256." Also `source` is intentionally excluded from the
  hash (`buildUpsertedEntry`, `:2797`), so a source-only divergence is covered by the dirty path but **not** by
  the per-service drift safety net — add an explicit comment so it isn't "fixed" later by accident.
- **M4 — `UserInputService` connections leak.** `makeMsSlider` (`:721` / `:730`) connects
  `InputChanged`/`InputEnded` on the never-destroyed `UserInputService` and never disconnects; each
  `Shell.build` → `buildSettingsOverlay` leaks two (self-test calls `Shell.build` twice more). Track and
  disconnect on teardown, or guard against a destroyed `track`.
- **M5 — Vestigial / dead code.** `pollGeneration`/`myGeneration` (`:3305`) is exposed but no poll loop
  consumes it (the tick loop uses `tickGeneration`); `collectOpsFromEntries` (`:2408`) appears reachable only
  from self-tests. Confirm and prune.
- **M6 — Regression-test the gaps.** Add tests that (a) call `markDirtyUpsert` and assert `dirtyUpsert[inst]`
  is set without recursion, (b) drive a real connect and assert `startTickLoop` receives a non-nil
  `onReturnToEditFn`, (c) assert `_G.StudioStud.Sync()` doesn't nil-call before live mode.

---

## ✅ What's solid (keep / don't regress)

- `Session.decide` pure + truth-tabled (`:39`) — edit/play gate is unit-testable and correct.
- `sanitizeJsonValue` / `safeEncode` (`:1050`) — a capture can never hard-fail JSON encode (NaN/inf, bad
  UTF-8, cyclic tables all handled, offenders logged).
- Single `Changed` connection collapsing N per-property signals, with the writable-prop `~= nil` membership
  fix (`classifyChangedProp`, `:2525`).
- Incremental XOR service fingerprints with correct add/remove inverse (`applyFpUpsert`, `:2314`).
- Stamp-based `clearSentDirty` (`:2872`) so edits arriving mid-tick aren't lost.
- Thorough `teardown` + connection hygiene (`:3229`); mutual protocol-version handshake (`:2078`);
  plugin-vs-game-script guard (`:12`).

---

## Suggested order of work

1. **C1–C3** — one-line edit (`dirtyUpsert[inst] = true`) + a forward-declaration block. Unbreaks the live
   path, pre-live `Sync()`, and play→edit auto-resume.
2. **E1** — incremental byte sizing (removes the O(K²) tick cost).
3. **E2 / E3** — sibling-scan and connect-walk dedupe.
4. **S1** — loopback guard before source upload.
5. **M1** — `--!strict` + `luau-analyze` in CI, so the whole C-class can't recur.
6. **M6** — regression tests for C1–C3.
