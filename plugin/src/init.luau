--!strict
-- init — the plugin bootstrap and darklua bundle root. Ported faithfully from the
-- monolith's top guard (StudioStud.plugin.lua:1-24) and its Bootstrap block
-- (:4572-4613). This is the ONE file darklua resolves `require`s from to produce
-- the single distributable `dist/StudioStud.plugin.lua`; every other module is
-- reached through it (directly or transitively).
--
-- WHAT THIS OWNS (the contract item "Session/misc: plugin-vs-game-script guard;
-- toolbar/widget bootstrap with auto-connect"):
--   1. The plugin-only guard (:12): refuse to do anything unless the `plugin`
--      global exists, so an embedded copy pasted into a place never runs inside a
--      live game DataModel and captures the running game.
--   2. Install the minimal `_G.StudioStud` surface (S2: only RunSelfTest + token)
--      via GlobalApi. The per-panel capture handlers are wired INSIDE the panel
--      lifecycle (CapturePanel.build wires, destroy unwires) — faithful to the
--      monolith — not here, so they always track the currently-live panel across
--      rebuilds/teardown rather than going stale at a destroyed panel.
--   3. Register the CapturePanel descriptor, build the widget chrome (Shell), and
--      auto-connect on widget-enable.
--   4. The toolbar-button toggle, the Unloading reclaim, and the once-per-version
--      welcome print.
--
-- Structure note (the bug class this rewrite kills): this is a flat, linear
-- bootstrap. There are no forward-referenced locals — every collaborator is a
-- required module table (Shell/Registry/GlobalApi/...) whose methods are field
-- reads resolved at call time, and the only closures (the toolbar click handler,
-- the deferred enable, the welcome) capture already-required module tables, never a
-- not-yet-assigned local. The C1-C3 forward-reference window does not exist here.
--
-- Trust boundary: the `plugin` global is the single Studio handle this file reads;
-- it is typed via globalTypes.d.luau under the analyzer and captured once. `_G`
-- hardening lives in GlobalApi (ownership token); panel/Studio errors are swallowed
-- where the monolith swallowed them (the welcome pcall).

-- == Plugin-only guard (verbatim port of :12) ==

-- This file MUST run as a Studio plugin (loaded from the Plugins folder), where the
-- `plugin` global exists. If a copy of this source is ever embedded in a place
-- (e.g. pasted into Workspace as a Script and saved), it would otherwise run inside
-- the running game's Server/Client DataModels during a playtest and capture the
-- live game. When `plugin` is nil we are NOT a plugin — bail out before requiring
-- (and thus loading/bootstrapping) any subsystem.
--
-- `plugin` is the plugin-context global typed by globalTypes.d.luau. The analyzer
-- types it non-optional, but at the bundle root it genuinely may be nil (the
-- embedded-script case the guard exists for), so it is read through an `any` shim
-- here — the single place this file treats a Studio global as untrusted — rather
-- than disabling checks for the whole module.
local pluginGlobal: Plugin? = (plugin :: any) :: Plugin?
if not pluginGlobal then
	warn(
		"[StudioStud] This is a Studio plugin, not a game script. Install it via the Roblox "
			.. "Plugins folder and remove any embedded copy (e.g. Workspace.Script) from the place."
	)
	-- Bail out without bootstrapping. Returning an empty typed module keeps the
	-- bundle root a valid `--!strict` ModuleScript in the embedded-script case while
	-- doing nothing (the monolith bare-`return`ed here).
	return {}
end

-- Past the guard `pluginGlobal` is non-nil; narrow it into a non-optional handle so
-- the field accesses below (CreateToolbar via Shell, Unloading, GetSetting) type
-- cleanly without per-call narrowing.
local pluginHandle: Plugin = pluginGlobal

local Config = require("@src/Config")
local Settings = require("@src/Settings")
local Registry = require("@src/Registry")
local GlobalApi = require("@src/GlobalApi")
local SelfTest = require("@src/SelfTest")
local Shell = require("@src/ui/Shell")
local CapturePanel = require("@src/ui/CapturePanel")

local PLUGIN_VERSION = Config.PLUGIN_VERSION
local WELCOME_VERSION = Config.WELCOME_VERSION
local SETTINGS = Config.SETTINGS

-- == RunSelfTest binding ==

-- The monolith published `_G.StudioStud.RunSelfTest = SelfTest.run`; `SelfTest.run`
-- returns a bare boolean (`true` on pass, `false` on fail).
local runSelfTest = SelfTest.run

-- == Public interface ==

-- The bootstrap exports the small surface that drives load: `start` performs the
-- full bootstrap (install the global, register panel, build chrome — the panel wires
-- its own capture handlers as it builds — arm the toolbar/unload hooks, schedule
-- auto-connect, show the welcome). Exported
-- (rather than run at module load) so the darklua bundle root can call it once and
-- so the in-engine SelfTest can assert the wiring is idempotent. `runSelfTest` and
-- the captured `plugin` handle are exposed for the same test surface.
export type InitModule = {
	start: () -> (),
	runSelfTest: () -> boolean,
	plugin: Plugin,
}

-- == Bootstrap helpers ==

-- Once-per-version welcome (verbatim port of showWelcomeOnce, :4600). Best-effort:
-- the GetSetting read and the SetSetting write are each pcall-guarded exactly as the
-- monolith did, so a corrupt/unwritable setting never blocks load. Reads/writes go
-- through the captured `pluginHandle` (not Settings) to mirror the monolith's raw
-- GetSetting/SetSetting calls and their exact welcome semantics.
local function showWelcomeOnce(): ()
	local ok, value = pcall(function()
		return pluginHandle:GetSetting(SETTINGS.welcomeVersion)
	end)
	if ok and value == WELCOME_VERSION then
		return
	end
	print(
		"[Studio Stud] Loaded v"
			.. PLUGIN_VERSION
			.. ". Run `studio-stud serve`, then open this panel — it connects and captures automatically."
	)
	pcall(function()
		pluginHandle:SetSetting(SETTINGS.welcomeVersion, WELCOME_VERSION)
	end)
end

-- == start ==

local started = false

local function start(): ()
	-- Idempotent: a second call (e.g. a SelfTest re-bootstrap probe) is a no-op so we
	-- never double-register the descriptor or stack duplicate toolbar/unload hooks.
	if started then
		return
	end
	started = true

	-- One-time: bring a pre-revision install onto the current default debounce (500ms) and
	-- debug-off BEFORE the settings overlay reads them, so the UI shows the expected state.
	-- Idempotent (guarded by settingsRev), so this is a no-op on every subsequent load.
	Settings.applyDefaultsMigration()

	-- Install the minimal global surface BEFORE building the panel, mirroring the
	-- monolith's `_G.StudioStud = _G.StudioStud or {}` + `RunSelfTest` running ahead of
	-- the panel. (S2: only RunSelfTest + the ownership token are published; the panel's
	-- capture handlers are wired internally on GlobalApi during its own build, not here.)
	GlobalApi.install(runSelfTest)

	-- Register the one panel descriptor, then build the widget chrome. Shell.build
	-- wires the Registry host and selects the first enabled tab, which lazily builds
	-- the CapturePanel — and CapturePanel.build itself wires its capture handlers into
	-- GlobalApi (S2, internal-only) as part of that build, so no bootstrap-level wire
	-- is needed and the handlers always track the live panel across rebuilds/teardown.
	Registry.register(CapturePanel.descriptor)
	Shell.build()

	-- Auto-connect on enable (verbatim port of the deferred Shell.onWidgetEnabled at
	-- :4581): defer so the widget finishes laying out before the connect handshake.
	task.defer(function()
		Shell.onWidgetEnabled()
	end)

	-- Toolbar toggle (verbatim port of :4585): flip the widget, sync the button's
	-- active state, and kick the connect handshake when it becomes visible.
	Shell.toolbarButton.Click:Connect(function()
		Shell.widget.Enabled = not Shell.widget.Enabled
		Shell.toolbarButton:SetActive(Shell.widget.Enabled)
		if Shell.widget.Enabled then
			Shell.onWidgetEnabled()
		end
	end)

	-- Unload reclaim (verbatim port of :4593): tear down every built panel and, only
	-- if we still own `_G.StudioStud` (GlobalApi's ownership token — the monolith's
	-- `RunSelfTest == SelfTest.run` identity guard, generalized), nil the slot so a
	-- later-loaded plugin that replaced it is never clobbered.
	pluginHandle.Unloading:Connect(function()
		Registry.teardownAll()
		GlobalApi.reclaim()
	end)

	showWelcomeOnce()
end

-- == Module table ==

local Init: InitModule = {
	start = start,
	runSelfTest = runSelfTest,
	plugin = pluginHandle,
}

-- Run the bootstrap now: as the darklua bundle root this module is required exactly
-- once at plugin load, and `start` is idempotent, so calling it here reproduces the
-- monolith's run-at-load behavior while keeping the logic exported for tests.
start()

return Init
