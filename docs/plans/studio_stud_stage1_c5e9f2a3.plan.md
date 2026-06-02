---
name: Studio Stud Platform — Stage 1 (Plugin shell + tab host + settings)
overview: Refactor the single-file Studio plugin into a generic shell with a dynamic panel/tab registry, a centralized settings surface (daemon endpoint + inert live/debounce/per-tab settings), and the existing capture behavior relocated into a registered Capture/Query panel. Plugin-only; zero daemon/Rust changes; capture wire protocol byte-identical.
todos: []
isProject: false
---

# Studio Stud Platform — Stage 1 Execution Plan (Plugin shell + tab host + settings)

Status: READY TO EXECUTE. Source of truth: `docs/studio-stud-platform-design.md` §11 (Stage 1), §5.4
(Plugin Tab Host), §14 (D2), and Appendix references. This plan is the authoritative,
implementation-level breakdown for Composer; it executes the design, it does not re-litigate it.

Scope is exactly the Stage 1 deliverables and nothing more. Do NOT introduce any Stage 2+ surface (no
`/studio-stud/live/*` deltas, no signal listeners, no `/studio-stud/write/*`, no token handshake, no
policy file, no repo index/projection, no `rbx-dom`/`full-moon`, no Boat Configurator panel). Stage 1 is
**plugin-only**: there are **zero Rust/daemon changes**.

---

## 0. Locked decisions (do not revisit)

1. **Single composed plugin file (settles D2).** The plugin installs as ONE local `.lua` file
   (`tools/studio_stud/plugin/StudioStud.plugin.lua`), copied/symlinked into the Studio plugins folder
   (verified: `docs/studio-stud.md` line 81). Loose sibling `.luau` files in that folder each load as a
   SEPARATE plugin and cannot `require` one another, so multi-ModuleScript packaging is impossible
   without inventing an `.rbxmx`/Rojo build step — explicitly out of scope for Stage 1. Therefore the
   tab host, registry, settings, transport, theme, and the Capture/Query panel all live in the one file,
   organized as **internal module-like local tables**, not separate ModuleScripts.
2. **No daemon/Rust changes.** Do not touch `tools/studio_stud/src/**`, `Cargo.toml`, routes, protocol
   constants, or the SQLite schema. Stage 0 goldens (`cargo test`) must stay green untouched — they are
   the proof the capture/query backend is unchanged.
3. **Capture wire protocol + snapshot shape are byte-identical.** Relocate `serializeValue`,
   `serializeVector3/CFrame/Color3`, `getPropertyNames`, `readProperties/readAttributes/readTags`,
   `getRootEntries`, `collectBaseInstances`, `buildSnapshot`, `requestJson`, `requestBody`, the
   `sync()` upload flow, and the 2s poll loop **verbatim** (relocation only — no logic edits). The
   constants `ROOT_SERVICE_ORDER`, `ROOT_SERVICE_INDEX`, `DESCENDANT_ROOT_SERVICES`, `CLASS_PROPERTIES`,
   `PROTOCOL_VERSION = 1`, snapshot `formatVersion = 1` / `snapshotKind = "studio-stud-live-snapshot"`
   stay exactly as they are. A real capture must still ingest identically (same instance count).
4. **Stage 2 settings are persisted but INERT.** The "live capture" toggle (default ON) and the
   "debounce" value (default 300 ms) are stored via `plugin:SetSetting`/`GetSetting` and shown in the UI,
   but NOTHING reads them for behavior in Stage 1. Polling behavior is unchanged (2s, daemon-request
   driven, auto-start). They exist now only so Stage 2 can flip them on without a settings migration.
5. **Settings is a global overlay, not a registered panel.** A gear/Settings control in the shell header
   opens a settings overlay (like today's `settingsFrame`). It is always available, independent of which
   tab is selected, and is NOT subject to per-tab enable/disable.
6. **Polling lifecycle is owned by the Capture/Query panel, pinned to the BUILD INSTANCE, and NOT gated
   by tab selection.** Capture requests arrive from the CLI at any time, so the poll loop runs
   continuously while the Capture/Query panel is enabled+initialized — it does not stop when the user
   switches tabs. **Critically:** the loop's running flag is owned by the specific panel build (not a
   reused file-scope `pollStarted`/`polling`), so teardown→re-init starts ONE fresh loop and never
   orphans or doubles a loop. The loop body re-checks the running flag AFTER `task.wait` so the trailing
   tick after teardown does not call `sync()` against destroyed UI. It stops on panel teardown/disable or
   `plugin.Unloading`. (See §6 C2 for the exact contract.)
7. **`_G.StudioStud` is re-wired on every (re)build and degrades safely when the panel is disabled.**
   Preserve the API (`Status`, `Sync`, `Capture`) and add `RunSelfTest` (Workstream E). On each
   Capture/Query panel build, (re)point `_G.StudioStud.{Status,Sync,Capture}` at THAT build's closures.
   On teardown/disable, replace them with safe no-ops that `warn("[Studio Stud] Capture/Query panel is
   disabled")` and return `{ ok = false, error = "panel disabled" }`, so a stale command-bar caller never
   touches destroyed `resultLabel`/`errorLabel`. On `Unloading`, clear `_G.StudioStud` only if it still
   points at this plugin instance (as today).
8. **`Shell.build` is idempotent.** It always `widget:ClearAllChildren()` + `Registry.teardownAll()` at
   the top before re-rendering chrome (matching today's `buildUi` `ClearAllChildren`). Calling it twice
   never duplicates a tab or leaks frames. Panel DESCRIPTOR registration happens once at module load (not
   inside `Shell.build`), so rebuilds re-render from the existing registry.
9. This plan is saved under `.cursor/plans/` matching the existing `*_<hex>.plan.md` convention.

---

## 1. Hard guardrails / definition of done

- **Zero behavior change to capture, polling, connect/health-check, or the snapshot wire format.** The
  refactor is structural: the existing home-panel behavior is relocated into a registered panel and
  reached through a tab host. A live `serve` + `studio-stud capture` round-trip produces the same
  instance count and the same `analyze`/`query` output as before Stage 1.
- **One plugin, one update target.** After Stage 1 there is exactly one plugin file hosting the
  Capture/Query tab via the registry. The shell contains NO project-specific (no "boat", no game) words.
- **Portability is structural.** The panel contract + `ctx` must be sufficient for a future project panel
  (e.g., Boat Configurator, Stage 8) to register with no shell edits. Stage 1 ships exactly one real
  panel; multi-panel behavior is proven by the self-test's throwaway dummy panel, not by shipping a
  second real panel.
- **Clean teardown.** Selecting/deselecting/tearing down panels and reloading the plugin leaks no
  Instances and no live connections (every panel `destroy` disconnects its signals and `Destroy`s its
  frame; `Unloading` calls `teardownAll`).
- **No new register-pressure failures.** Keep per-panel/per-section logic in their own functions and
  module tables; do not create a single function with hundreds of locals (Luau 200-local-register limit,
  per `.cursor/rules/luau-files.mdc`).

---

## 2. Current state (verified facts, do not re-discover)

- The plugin is ONE file: `tools/studio_stud/plugin/StudioStud.plugin.lua` (~1,460 lines). Installed by
  copy/symlink into the Studio plugins folder (`docs/studio-stud.md` line 81). There is no plugin build
  step and no Rojo mapping for it.
- Stage 0 is complete: the daemon is split into `tools/studio_stud/src/{lib,cli,http,storage,capture,
  analyze,query,output,util,bench}.rs` with golden/bench tests under `tools/studio_stud/tests/`. **None
  of that is touched in Stage 1.**
- Current plugin structure (top → bottom), all in module/global scope of the one file:
  - Config constants: `PLUGIN_VERSION`, `PLUGIN_LOGO_ASSET_ID`, `PROTOCOL_VERSION`,
    `DEFAULT_TOOLBAR_ICON`, `normalizePluginAssetId`, `SERVICE_NAME`, `DEFAULT_DAEMON_URL`,
    `SETTINGS_DAEMON_URL = "StudioStudDaemonUrl"`, `SETTINGS_WELCOME = "StudioStudWelcomeVersion"`,
    `WELCOME_VERSION`.
  - Capture data tables: `ROOT_SERVICE_ORDER`/`ROOT_SERVICE_INDEX`, `DESCENDANT_ROOT_SERVICES`,
    `CLASS_PROPERTIES`.
  - Toolbar + button creation; `THEME`, fonts (`CODE_FONT`/`UI_FONT`/`UI_FONT_BOLD`/`TITLE_FONT`), `PAD`;
    dock widget creation.
  - Forward-declared UI state locals (`statusLabel`, `placeLabel`, `connectButton`, `homePanel`,
    `settingsFrame`, `mainFrame`, `syncing`, `polling`, `daemonConnected`, etc.).
  - URL/settings helpers: `getDaemonUrl`/`setDaemonUrl`, `parseDaemonUrl`/`buildDaemonUrl`,
    `readConnectionFields`/`persistConnectionFields`/`refreshConnectionFieldsFromSettings`.
  - UI primitives: `makeLabel`, `makeCorner`, `makeStroke`, `makeSectionLabel`, `makePrimaryButton`,
    `makeSecondaryButton`, `makeStatusCard`, `setStatusPresentation`, `makeVectorLogo`, `makeBrandBadge`,
    `makeConnectionField`.
  - Panels: `buildSettingsPanel`, `buildUi` (home panel: header/badge/title/status card/connection
    field/`Settings`+`Connect` buttons).
  - Snapshot: `serializeVector3/CFrame/Color3`, `serializeValue`, `getPropertyNames`,
    `readProperties`, `readAttributes`, `readTags`, `getRootEntries`, `collectBaseInstances`,
    `buildSnapshot`.
  - Transport: `requestJson`, `requestBody`.
  - Behavior: `sync(options)` (start → body/chunk → complete upload), `status()` (ping/health check).
  - Bootstrap: `buildUi()`, `_G.StudioStud = { Status, Sync, Capture }`, `pollSyncRequests()` (2s loop),
    `task.defer(status)`, toolbar click toggle, `plugin.Unloading`, `showWelcomeOnce`.
- Settings persistence uses `plugin:GetSetting`/`SetSetting` (only `StudioStudDaemonUrl` and
  `StudioStudWelcomeVersion` today). These persist across reloads.
- The widget is a single dock widget; the home panel and settings panel are sibling frames toggled by
  `Visible`. There is currently NO tab strip.

---

## 3. Target structure (single file, internal sections)

Reorganize the one file into clearly delimited internal sections. **Each shared section MUST be a single
`local` table** (`Theme`, `Ui`, `Settings`, `Transport`, `Registry`, `CapturePanel`, `Shell`), NOT a
loose pile of file-scope `local function`s. This is mandatory, not optional: collapsing today's ~25
module-scope helper locals into a handful of table locals is what keeps the main chunk well under the
Luau 200-local-register limit (`.cursor/rules/luau-files.mdc`). Order matters for Luau (define before
use). Recommended section order:

1. **Config** — constants (existing) + a `SETTINGS` keys table (new, see Workstream A2).
2. **Theme** — `Theme` table: colors, fonts, `PAD`. (Relocate `THEME` + fonts verbatim.)
3. **Ui** — UI primitive helpers (`makeLabel`, `makeCorner`, `makeStroke`, `makeSectionLabel`,
   `makePrimaryButton`, `makeSecondaryButton`, `makeStatusCard`, `setStatusPresentation`,
   `makeVectorLogo`, `makeBrandBadge`). Pure builders that take an explicit `parent`; remove reliance on
   file-scope `statusLabel` etc. by returning created instances (see A3).
4. **Settings** — typed get/set accessors over `plugin:GetSetting/SetSetting` with defaults (A2).
5. **Transport** — `Transport` table: `parseDaemonUrl`, `buildDaemonUrl`, `currentUrl()` (reads
   Settings), `requestJson`, `requestBody`. (Relocate verbatim; `readConnectionFields` becomes
   `Transport.currentUrl()` backed by Settings, NOT by UI text boxes — see A4.)
6. **Registry** — the panel/tab registry (Workstream B).
7. **CapturePanel** — the Capture/Query panel descriptor: snapshot building, `sync`, `status`, poll loop,
   and panel UI; registers itself with the Registry (Workstream C).
8. **Shell** — toolbar, widget, header chrome, tab strip, settings overlay, lifecycle wiring
   (Workstream D).
9. **SelfTest + bootstrap** — `RunSelfTest`, `_G.StudioStud`, `Unloading`, `showWelcomeOnce`
   (Workstream E).

---

## 4. Workstream A — Shared infrastructure (mechanical, no behavior change)

### A1. Theme + UI primitives
- Move `THEME`, the four `Font.new` constants, and `PAD` into a `Theme` table. Keep exact RGB/font
  values.
- Move the `make*` primitives into a `Ui` table (e.g. `Ui.makeLabel`, `Ui.makeStatusCard`, …). These
  already take a `parent`; keep their signatures. **Table form is mandatory** (per §3) — do not leave
  them as flat file-scope `local function`s.

### A2. Settings module (centralized keys + new inert settings)
Add a `SETTINGS` keys table and a `Settings` accessor table. Keys:
- `daemonUrl` → `"StudioStudDaemonUrl"` (existing; keep the literal so prior values survive).
- `welcomeVersion` → `"StudioStudWelcomeVersion"` (existing).
- `liveCaptureEnabled` → `"StudioStudLiveCaptureEnabled"` (NEW; default `true`; **inert** in Stage 1).
- `debounceMs` → `"StudioStudDebounceMs"` (NEW; default `300`; **inert** in Stage 1).
- `panelEnabled` → `"StudioStudPanelEnabled"` (NEW; a JSON-encoded map `{ [panelId] = boolean }` for
  per-tab enable/disable; missing/true ⇒ enabled).

`Settings` accessors (all pcall-wrapped, like the existing helpers):
- `Settings.getString(key, default)`, `Settings.setString(key, value)`
- `Settings.getBool(key, default)`, `Settings.setBool(key, value)`
- `Settings.getNumber(key, default)`, `Settings.setNumber(key, value)`
- `Settings.getPanelEnabled(panelId)` / `Settings.setPanelEnabled(panelId, bool)` (read/modify the
  JSON map; default enabled when absent).

Keep behavior identical for the daemon URL: `Settings.getString(SETTINGS.daemonUrl, DEFAULT_DAEMON_URL)`
replaces `getDaemonUrl`.

### A3. Decouple UI primitives from file-scope state
The current `makeStatusCard`/`setStatusPresentation` write to file-scope `statusLabel`. Refactor so the
status card is an object: `Ui.makeStatusCard(parent, y)` returns `{ frame, setState(state, message) }`.
The Shell owns one status card and passes `setState` into panels via `ctx.setStatus`. No behavior change;
just removes hidden global coupling so panels can update status through `ctx`.

**Coupling inventory (relocate-safe list).** Before moving capture logic, account for EVERY file-scope
local the relocated functions touch, not just the obvious ones: `statusLabel` (→ status-card object),
`daemonConnected` (→ `ctx.isConnected`/`ctx.setConnected`), `hostBox`/`portBox`/`settingsUrlBox`
(→ Settings overlay), `resultLabel`/`errorLabel` (→ panel body), and **`placeLabel`** (→ Settings
overlay, written on settings-open). In particular the relocated `status()` currently also writes
`placeLabel.Text` (today's lines ~1367-1369): **DROP that write from the relocated `status()`** — place
info is already populated when the Settings overlay opens (today's line ~904), and the panel no longer
owns `placeLabel`. Leaving it in is a dangling-reference/load error. `ctx` is NOT given a place-info
setter (place info is a Settings-overlay concern only).

### A4. Connection fields read from Settings, not from text boxes
Today `readConnectionFields()` reads live `hostBox`/`portBox` text. In the tab-host model the endpoint
lives in the Settings overlay. Make `Transport.currentUrl()` read `Settings.getString(daemonUrl, ...)`.
The Settings overlay's URL field writes through `Settings.setString` on `FocusLost`. This is a small,
intentional behavior tidy (single source of truth = Settings), NOT a wire change. Preserve
`parseDaemonUrl`/`buildDaemonUrl` for the host/port split if you keep host/port fields in the overlay.

**Verify after A:** `pwsh tools/studio_stud/build-local.ps1` is N/A (no Rust). Instead, load the plugin
in Studio and confirm the widget still opens, connects, and a CLI capture still ingests — but do this
incrementally; A alone need only compile/load without error.

---

## 5. Workstream B — Panel registry + panel contract

### B1. Panel descriptor (the portability contract)
A panel registers a descriptor table:
```lua
-- descriptor
{
  id = "capture",            -- stable string id (settings key, selection key)
  title = "Capture / Query", -- tab label
  defaultEnabled = true,     -- per-tab enable default
  build = function(parent, ctx) ... return handle end,
}
```
`ctx` (built by the Shell, passed to every `build`) exposes ONLY generic services — no game words:
- `ctx.theme` (the `Theme` table), `ctx.ui` (the `Ui` primitives)
- `ctx.transport` (`requestJson`, `requestBody`, `currentUrl`)
- `ctx.settings` (the `Settings` accessors)
- `ctx.setStatus(state, message)` (drive the shared status card)
- `ctx.plugin`, `ctx.widget` (for `SetSetting`, dock widget queries)
- `ctx.isConnected()` / `ctx.setConnected(bool)` (shared daemon-connected flag)

`build` returns an optional `handle`:
```lua
-- handle (all optional except frame)
{
  frame = Frame,                  -- the panel root, parented under the panel host
  onShow = function() end,
  onHide = function() end,
  destroy = function() end,       -- disconnect signals, stop loops, Destroy(frame)
  onConnectRequested = function() end, -- OPTIONAL; Shell calls on widget-enable if present (health check)
}
```
The Shell must null-check every optional member before calling it — dummy/self-test panels and future
project panels won't all implement `onConnectRequested` (Finding: Connect/health-check is currently a
Capture/Query concern, not yet a shared Shell capability).

### B2. Registry API
A `Registry` table with:
- `Registry.register(descriptor)` — validates `id`/`title`/`build`; rejects duplicate ids; appends in
  registration order.
- `Registry.unregister(id)` — removes the descriptor from the registry (after tearing down its built
  handle if present) and re-renders the tab strip. **Required** so transient panels (e.g. the
  self-test's dummies, §8 E1) fully clean up; `teardownAll` alone only destroys built handles and leaves
  descriptors registered, which would otherwise leak ghost tabs. May also purge the panel's key from the
  persisted `panelEnabled` map (used by the self-test cleanup).
- `Registry.list()` — returns descriptors in registration order, each annotated with `enabled` (from
  `Settings.getPanelEnabled(id)` honoring `defaultEnabled`).
- `Registry.setEnabled(id, bool)` — persists via `Settings.setPanelEnabled`; if disabling the currently
  selected panel, tears it down and selects the next enabled one (or shows an empty-state).
- `Registry.select(id)` — hides the current panel (`onHide` + `frame.Visible=false`), then builds the
  target on first selection (calls `build`, caches the handle, parents `frame` under the panel host) or
  re-shows it (`onShow` + `frame.Visible=true`). Ignores selection of disabled/unknown ids.
- `Registry.teardownAll()` — calls each built handle's `destroy` (or `frame:Destroy()`), disconnects the
  panel, clears the BUILT-HANDLE cache. **It does NOT remove descriptors** — registered panels survive a
  rebuild and are re-rendered from the registry. Called on `Unloading` and at the top of `Shell.build`.
- `Registry.selected()` — current selected id (or nil).

Keep the registry self-contained (no UI rendering inside it). The Shell renders the tab strip from
`Registry.list()` and calls `Registry.select(id)` on tab click.

---

## 6. Workstream C — Capture/Query panel (relocate existing behavior)

Move the existing capture functionality into a `CapturePanel` descriptor and register it. The panel keeps
ALL current capture logic verbatim (locked decision 3).

### C1. Panel UI (`build`)
Recreate today's home panel as the panel `frame` (parented under the Shell's panel host, NOT directly to
the widget): brand badge/title block is now in the Shell header (Workstream D), so the panel body holds:
- the shared status card is owned by the Shell (panel calls `ctx.setStatus`); the panel body shows the
  capture summary (`resultLabel` equivalent), error text (`errorLabel`), and the `Connect` (health-check)
  button. Decide placement: keep a `Connect` button in the panel that calls the panel's `status()`.
- The daemon endpoint field MOVES to the Settings overlay (Workstream D). The panel no longer renders
  host/port boxes; it reads the endpoint via `ctx.transport.currentUrl()`.

### C2. Panel behavior (verbatim relocation)
- `serialize*`, `getPropertyNames`, `readProperties/Attributes/Tags`, `getRootEntries`,
  `collectBaseInstances`, `buildSnapshot` — move into the panel's closure (or a panel-local `Capture`
  sub-table). No edits.
- `sync(options)` and `status()` — move into the panel; route status updates through `ctx.setStatus` and
  the connected flag through `ctx.setConnected`. The upload flow (start → body/chunk → complete) and all
  error formatting are unchanged. **Drop the `placeLabel.Text` write from `status()`** (§4 A3).
- **Poll loop (build-instance-pinned, per locked decision 6):** the loop's running flag lives on THIS
  panel build, not a reused file-scope `pollStarted`/`polling`. Concretely:
  - In `build`, create `local running = true` (a per-build upvalue) and `task.spawn` the loop ONCE.
  - Loop shape: `while running do task.wait(2); if not running then break end; <existing request+sync
    body> end`. The `if not running then break end` AFTER the `wait` ensures the trailing tick after a
    teardown does not fire `sync()` against destroyed UI (the current `while polling do task.wait(2);
    body end` lacks this guard and would fire once more).
  - `destroy` sets `running = false` (no global flag), guaranteeing exactly one loop per build; a later
    re-init spawns a fresh, single loop. Tab switches do NOT touch `running`.
- **`_G` wiring (per locked decision 7):** on `build`, set `_G.StudioStud.{Status,Sync,Capture}` to this
  build's `status`/`sync`. On `destroy`, replace them with the safe no-ops (warn + `{ ok=false, error=
  "panel disabled" }`). Re-init re-wires them to the new closures. This keeps `_G` callers from touching
  a destroyed panel and makes `_G.StudioStud.Sync` identity equal the live panel's `sync` after re-init.

### C3. Register
At the end of the `CapturePanel` section: `Registry.register(CapturePanel.descriptor)`.

---

## 7. Workstream D — Tab-host shell chrome + settings surface

### D1. Shell header + tab strip
`Shell.build()` is **idempotent** (locked decision 8): its FIRST two statements are
`widget:ClearAllChildren()` and `Registry.teardownAll()`, so a second call never duplicates a tab or
leaks frames. Panel descriptors are registered ONCE at module load (§6 C3), not inside `Shell.build`, so
a rebuild re-renders from the surviving registry. It builds the widget chrome:
- Top rule + header with brand badge, "Studio Stud" title, subtitle, version tag (relocate from today's
  `buildUi`), plus a **gear/Settings** button and the shared status card (D3 owns the card).
- A **tab strip** below the header that renders one button per ENABLED panel from `Registry.list()`,
  highlighting the selected tab (use `Theme.copper` for active, `Theme.surface` for inactive). Clicking a
  tab calls `Registry.select(id)`. With one enabled panel, the strip shows a single tab. Re-render the
  strip whenever enable/disable changes (so it stays dynamic per design §5.4).
- A **panel host** Frame fills the remaining area; selected panel frames are parented here.

### D2. Settings overlay
Recreate `buildSettingsPanel` as a Shell-owned overlay (`Visible=false` by default, `ZIndex` above the
panel host), opened by the gear button, closed by a `Back` button. Contents:
- **Daemon endpoint** — host/port (or full URL) field(s) writing through `Settings.setString(daemonUrl)`
  on `FocusLost`; show the resolved URL. (Relocate the connection-field UI here.)
- **Live capture** — a toggle bound to `Settings.getBool/setBool(liveCaptureEnabled, true)`. Label it
  clearly as taking effect in a later update (inert now). Default ON.
- **Debounce (ms)** — a numeric field bound to `Settings.getNumber/setNumber(debounceMs, 300)`. Inert
  now.
- **Tabs** — a list of all registered panels with an enable/disable toggle each, bound to
  `Registry.setEnabled(id, bool)`; re-renders the tab strip on change.
- **Place info + setup steps** — relocate the existing `placeLabel` and the setup instructions text.

### D3. Shared status card + connected flag
The Shell owns one `Ui.makeStatusCard` instance and a `connected` boolean; it exposes
`ctx.setStatus`/`ctx.isConnected`/`ctx.setConnected` to panels. The Connect button (in the Capture panel)
and the poll/sync flow drive it exactly as `setStatusPresentation`/`daemonConnected` do today.

### D4. Lifecycle wiring
- Toolbar click toggles `widget.Enabled` (as today); on enable, refresh settings-derived fields and, IF
  the selected panel's handle exposes an optional `onConnectRequested`/`status` hook, call it (health
  check). The hook is **optional** — dummy/self-test panels and future project panels that don't do
  daemon health checks simply omit it, so the Shell must null-check before calling (do not assume every
  panel has `status()`). Connect/health-check remains a Capture/Query concern in Stage 1; a later stage
  may hoist it to a shared transport/Connect control in the Shell (noted, not done here).
- Module load order: register the Capture/Query descriptor (§6 C3), then `Shell.build()`, which selects
  the first enabled panel via `Registry.select(firstEnabledId)`.
- `plugin.Unloading` → `Registry.teardownAll()`, stop polling (each panel's `destroy` clears its own
  running flag), clear `_G.StudioStud` if it still points at this instance.

---

## 8. Workstream E — Self-test, `_G` API, welcome

### E1. `_G.StudioStud.RunSelfTest()`
A deterministic, in-Studio test routine (run from the command bar) that exercises the registry and
settings WITHOUT touching the daemon or live capture. It must print a clear `PASS`/`FAIL` summary and
return a boolean, and it must FULLY restore state (unregister dummies, restore settings, leave the real
Capture/Query panel built and usable). **Snapshot the pre-test registry id set and the affected settings
at the start; assert they are byte-equal at the end** (this is the regression that proves cleanup
worked). Cover:
- **register/list/order:** register two throwaway dummy panels (`__selftest_a`, `__selftest_b`); assert
  `Registry.list()` returns them in registration order with `enabled` honoring `defaultEnabled`; assert
  duplicate-id registration is rejected.
- **select lifecycle:** select A then B; assert A's `onShow` then `onHide` fired and B's `onShow` fired
  (use counters set by the dummy panels); assert exactly one panel frame is `Visible`.
- **enable/disable persistence:** `Registry.setEnabled("__selftest_a", false)` then re-read
  `Settings.getPanelEnabled("__selftest_a")` ⇒ false; re-enable ⇒ true. Assert the disabled panel drops
  out of `Registry.list()`'s enabled set.
- **settings round-trip:** set/get `liveCaptureEnabled` (bool), `debounceMs` (number), `daemonUrl`
  (string) through `Settings`; assert values come back equal. Restore originals at the end.
- **teardown + unregister (no ghost tabs):** `Registry.unregister("__selftest_a")` /
  `unregister("__selftest_b")` ⇒ each dummy's `destroy` fired, its frame is no longer parented under the
  panel host (no leak), AND `Registry.list()` no longer contains the dummy ids; purge their
  `panelEnabled` keys. **Assert `Registry.list()` id set == the pre-test snapshot** and the tab strip
  shows no `__selftest_*` tabs.
- **single poll loop after re-init:** tear down and re-init the Capture/Query panel; assert exactly one
  poll loop is live. Implement via a build-generation counter the loop captures: each loop increments a
  shared "live loops" count on entry and decrements in a `defer`/on-exit, OR simpler — the loop checks
  its captured `running` flag and the test asserts the previous build's `running` is false after
  teardown and only the new build's is true.
- **`_G` re-wire identity:** after re-init, assert `_G.StudioStud.Sync == <live panel's sync closure>`
  and that, while torn down, `_G.StudioStud.Sync()` returns `{ ok = false, error = "panel disabled" }`
  (no error thrown).
- **idempotent re-init:** call `Shell.build()` twice; assert the Capture/Query tab appears exactly once
  and no orphaned frames remain under the widget.

### E2. `_G.StudioStud`
Preserve `{ Status, Sync, Capture }` and add `RunSelfTest`. Per locked decision 7: re-wire
`Status`/`Sync`/`Capture` on every Capture/Query panel build; on teardown/disable replace them with safe
no-ops that `warn` and return `{ ok = false, error = "panel disabled" }`. `RunSelfTest` is wired once at
module load (it does not depend on the Capture panel being built). Clear `_G.StudioStud` on `Unloading`
only if it still points at this instance (as today).

### E3. Welcome
Keep `showWelcomeOnce` and `WELCOME_VERSION` (bump the version string if the message text changes;
optional).

---

## 9. Execution order (for Composer)

1. **Snapshot the baseline** (no edits) — this is the load-bearing regression oracle for the "verbatim"
   relocation, so make it byte-level, not a count:
   - With `serve` running and the CURRENT plugin loaded, run `studio-stud capture` against a fixed,
     unchanged place (do not edit the place between baseline and post-refactor captures, so the
     ordinal-based instance `id`s stay stable).
   - Save the daemon-persisted RAW snapshot JSON for that place (the same raw form the bench fixture
     `tools/studio_stud/tests/fixtures/baseline_capture.json` and `decode_raw_snapshot` accept, taken
     from the storage root) to a baseline file, e.g. `baseline_pre.json`.
   - Also save `studio-stud analyze <PLACE> --report context` (compact, deterministic) and one bounded
     `studio-stud query <PLACE> --class Part --limit 5` to text as a complementary cheap oracle.
   - Run `cargo test` in `tools/studio_stud` to confirm Stage 0 goldens are green (proves the daemon is
     the constant; it does NOT validate plugin output — that's what the raw-snapshot diff is for).
2. **Workstream A** (Theme/Ui/Settings/Transport extraction) — load-check in Studio after.
3. **Workstream B** (Registry) — pure logic; covered by E1 later.
4. **Workstream C** (Capture/Query panel; relocate verbatim) — load-check.
5. **Workstream D** (Shell chrome + tab strip + settings overlay + lifecycle).
6. **Workstream E** (self-test + `_G` API + welcome).
7. **Final verification** (§10) — self-test PASS, settings persist across reload, capture round-trip
   matches the §9.1 baseline, manual UI pass.

Commit per workstream so any regression is bisectable. Because there is no Luau build/lint in CI, "build"
verification = the plugin loads in Studio with no error in the Output window and the self-test passes.

---

## 10. Testing strategy & exit gate

### Automated-ish (in Studio, deterministic)
- `_G.StudioStud.RunSelfTest()` returns `true` and prints `PASS` for every check in §8.1.

### Settings persistence
- In the Settings overlay, change the daemon URL, toggle Live capture OFF, set Debounce to a non-default
  value, and disable a panel via the Tabs list. Reload the plugin (or restart Studio). Re-open Settings:
  all four values are retained. (The inert ones simply persist; nothing else changes.)

### Capture-path regression (the load-bearing check)
- With `serve` running and the refactored plugin loaded against the SAME unchanged place: `studio-stud
  capture` ingests successfully; save the new raw snapshot as `baseline_post.json`.
- **Diff `baseline_pre.json` vs `baseline_post.json` modulo volatile fields** — exclude
  `sync.startedAtUtc`, `sync.finishedAtUtc`, and `sync.requestId` (everything else, including every
  instance's `properties`/`attributes`/`tags`/`propertyErrors`/`Model` bounding-box+pivot block, must be
  identical). This catches the failure modes an instance COUNT cannot: a dropped serialize branch, a
  missed `instanceIdByRef = {}` reset, an omitted attribute/tag/bounding-box block. A clean diff is the
  real proof that "verbatim relocation" held.
- Complementary cheap check: `studio-stud analyze <PLACE> --report context` and the bounded `query`
  output match the §9.1 text baselines.
- `cargo test` (Stage 0 goldens) still green — proves the daemon was untouched.

### Manual Studio verification
- Toolbar button opens/closes the widget; widget shows the header, one "Capture / Query" tab, and the
  panel body.
- Status card transitions idle → syncing → connected on `Connect` with `serve` up; shows an error state
  with `serve` down.
- Gear opens the Settings overlay; `Back` returns to the panel; tab strip re-renders when a panel is
  toggled in the Tabs list.
- Switching tabs (with the self-test dummy temporarily registered, or just the single tab) does not stop
  capture polling: trigger a CLI capture while on the panel and confirm it still ingests.
- **After running `RunSelfTest` (which tears down + re-inits the Capture/Query panel), fire one CLI
  `studio-stud capture` and confirm it still ingests.** This is the exact regression Findings 1-2 would
  silently introduce (dead or doubled poll loop after re-init); the self-test asserts loop singularity,
  this confirms it end-to-end against the daemon.

### Exit gate checklist (all must be true)
- [ ] One plugin file hosts the Capture/Query tab via the `Registry`; shell has no project-specific code.
- [ ] `Registry` register/select/teardown/**unregister** + settings round-trip pass via `RunSelfTest`
      (PASS printed); `Registry.list()` returns to its pre-test id set (no ghost `__selftest_*` tabs).
- [ ] Poll loop is single-instance after teardown→re-init (self-test assertion) AND a post-self-test CLI
      capture still ingests; `_G.StudioStud.Sync` identity equals the live panel's `sync` after re-init.
- [ ] Live-capture toggle (default ON), debounce (default 300), and per-tab enable/disable persist across
      reload and are INERT (no Stage 2 behavior).
- [ ] Capture wire protocol/snapshot unchanged: **raw-snapshot JSON diff (pre vs post, modulo
      `startedAtUtc`/`finishedAtUtc`/`requestId`) is clean**; `analyze`/`query` output matches the §9.1
      baseline; Stage 0 `cargo test` green.
- [ ] No leaked Instances/connections after teardown/reload; `Shell.build` is idempotent (no duplicate
      tab on a second call).
- [ ] No daemon/Rust changes in the diff.

---

## 11. Risks & mitigations

- **Accidentally altering the snapshot/transport** (would break ingest; a verbatim-copy slip an instance
  count can't see). Mitigated by relocating C2 functions verbatim and the **raw-snapshot JSON diff
  modulo volatile fields** (§9.1/§10) — not just a count; `cargo test` confirms the daemon side is the
  constant.
- **Hidden file-scope coupling** breaking when code moves into panels — full inventory in §4 A3:
  `statusLabel` (→ status-card object), `daemonConnected` (→ `ctx`), `hostBox`/`portBox`/`settingsUrlBox`
  + `placeLabel` (→ Settings overlay), `resultLabel`/`errorLabel` (→ panel body). The easily-missed one
  is **`placeLabel`**, written by the relocated `status()` — that write must be dropped. Extract/inventory
  these BEFORE moving capture logic.
- **Teardown leaks + ghost tabs** (orphaned connections/frames on reload/disable; descriptors lingering
  after a transient panel). Mitigated by a strict `destroy` contract (disconnect signals, `Destroy`
  frame), `Registry.unregister` for transient panels (descriptors, not just handles), and `teardownAll`
  at `Shell.build` top + `Unloading`; the self-test asserts no leftover frame AND that `Registry.list()`
  returns to its pre-test id set.
- **Orphaned/doubled poll loop or stale `_G`** across teardown→re-init. Mitigated by the build-instance
  running flag + post-`wait` guard (§6 C2) and `_G` re-wire-on-build / no-op-on-teardown (decision 7);
  the self-test asserts loop singularity and `_G.Sync` identity, and a post-self-test CLI capture
  confirms ingest end-to-end (§10).
- **Luau 200-local-register pressure** on the growing single file. Mitigated by keeping per-section/
  per-panel logic in their own functions and module tables; no mega-function. Re-check after Workstream D.
- **Scope creep into Stage 2+** (someone "wiring up" the live toggle or adding signal listeners).
  Explicitly forbidden in §0.4; the toggle/debounce are persisted-but-inert only.
- **No Luau test framework** means register/select/teardown can't be `cargo test`ed. Mitigated by the
  in-Studio `RunSelfTest` as the deterministic gate, plus the daemon-side goldens for the capture path.

---

## 12. Out of scope (defer to later stages)
Live deltas, signal listeners, single-live-DB/WAL migration, drift backstop (Stage 2);
`/studio-stud/write/*`, policy file, write token + handshake, `full-moon` (Stage 3); repo index, Rojo v7
projection, `rbx-dom` (Stage 4); FS→Studio apply endpoints (Stage 5); multi-developer concurrency,
`flctl sync` (Stage 6); format parity/build/sourcemap (Stage 7); the Boat Configurator panel (Stage 8).
Any `.rbxmx`/Rojo plugin build step (multi-ModuleScript packaging) is explicitly deferred — Stage 1 stays
a single composed file.
