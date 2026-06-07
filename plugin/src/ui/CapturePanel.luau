--!strict
-- CapturePanel — the Capture/Query panel VIEW, ported faithfully from the
-- monolith's CapturePanel block (StudioStud.plugin.lua:1564-3346) MINUS the live
-- engine and the capture serializer, which now live in their own modules (Live /
-- Capture / Fingerprints / Hash). What remains here is exactly what the rewrite
-- assigns to this module: the panel chrome (result/error labels + the Connect
-- button), the Connect-button state machine, the daemon ping/handshake (statusFn),
-- the connect+baseline orchestration (syncFn / startupConnectAndCapture), the
-- play->edit resume (onReturnToEdit — the C2 path), and the LiveHost the engine
-- calls back through.
--
-- VIEW-ONLY, ENGINE LIVES IN Live: this module owns no dirty sets, no tick loop,
-- no fingerprints — it BUILDS the ctx the engine needs (setStatus/setStats/
-- transport/isRunning/...) via Live's typed `LiveHost` seam and attaches it with
-- `Live:attach(host)`, then drives the engine through its public methods
-- (connectLiveMode / startTickLoop / triggerFullBaseline / teardown). The monolith
-- reached the engine through closure upvalues; here the seam is the injected,
-- typed host (Live.LiveHost) — the structural cure for the C1-C3 forward-reference
-- bug class.
--
-- Structure note (the bug class this rewrite kills): the monolith held statusFn /
-- syncFn / startupConnectAndCapture / onReturnToEdit / responseNeedsRebaseline /
-- setConnectButtonState as forward-declared build-closure LOCALS referenced before
-- assignment — the exact before-local window that produced C2 (a nil onReturnToEdit
-- captured into startTickLoop) and C3 (Sync() before live nil-calls). Here they are
-- fields on a per-build `panel` state table; every cross-call goes through
-- `panel.*` (a field read resolved at call time), so nothing is read before its
-- field is assigned. `panel` is fully assembled before any handler can fire.
--
-- GlobalApi (the monolith's GlobalApi.wireCapture / installNoOps) is NOT wired
-- here: that is the bootstrap's job (P6). The panel handle exports `sync` and
-- `status` so the bootstrap can register them on `_G`; the panel itself never
-- touches `_G`. See DEVIATIONS in the structured report.

local Theme = require("./Theme")
local Ui = require("./Ui")
local Shell = require("./Shell")
local Config = require("../Config")
local Session = require("../Session")
local AllowList = require("../AllowList")
local Live = require("../Live")
local Capture = require("../Capture")

type ShellContext = Shell.ShellContext
type LiveHost = Live.LiveHost
type LiveModule = Live.LiveModule
type CaptureModule = Capture.CaptureModule

local PLUGIN_VERSION = Config.PLUGIN_VERSION
local PROTOCOL_VERSION = Config.PROTOCOL_VERSION
local MIN_DAEMON_PROTOCOL_VERSION = Config.MIN_DAEMON_PROTOCOL_VERSION

-- `game` is a Studio/plugin global the analyzer types via globalTypes.d.luau; read
-- directly where the monolith read it (PlaceId / Name in the connect result).

-- == Update-nudge helpers (ported verbatim from the monolith Config block) ==

-- These are NOT compile-time constants — `updateInstallHint` is channel-aware and
-- `checkRemoteUpdate` carries per-ping mutable state — so Config (constants-only)
-- intentionally omits them; they belong with their UI consumer (this panel). Ported
-- verbatim from StudioStud.plugin.lua:61-140.

-- Channel-aware install one-liner for the "update available" nudge. The daemon ping
-- reports the machine's channel; dev points at its own bootstrap so following the
-- hint never silently switches the user onto release.
local function updateInstallHint(channel: any): string
	local script = "install.ps1"
	if channel == "dev" then
		script = "install-dev.ps1"
	end
	return ("irm https://tyleradams2002.github.io/studio-stud/%s | iex"):format(script)
end

-- Update nudge from /studio-stud/ping (channel-aware). Best-effort; never throws.
-- State bundled in one table (matches the monolith's module-scope-low rationale).
local updateCheck = { at = 0, note = "", done = false }
local function checkRemoteUpdate(pingResult: any): string
	local now = os.time()
	if updateCheck.done and (now - updateCheck.at) < 86400 then
		return updateCheck.note
	end
	updateCheck.done = true
	updateCheck.at = now
	updateCheck.note = ""

	if type(pingResult) ~= "table" then
		return updateCheck.note
	end
	if pingResult.onFallback == true then
		return updateCheck.note
	end
	if pingResult.updateAvailable ~= true then
		return updateCheck.note
	end
	local notes: { string } = {}
	if
		type(pingResult.latestPluginVersion) == "string"
		and pingResult.latestPluginVersion ~= ""
		and pingResult.latestPluginVersion ~= PLUGIN_VERSION
	then
		notes[#notes + 1] = ("plugin %s"):format(pingResult.latestPluginVersion)
	end
	if type(pingResult.latestDaemonVersion) == "string" and pingResult.latestDaemonVersion ~= "" then
		notes[#notes + 1] = ("daemon %s"):format(pingResult.latestDaemonVersion)
	end
	if #notes > 0 then
		updateCheck.note = "Update available: " .. table.concat(notes, ", ")
	end
	return updateCheck.note
end

-- == Public interface ==

-- The orchestration result a connect/sync attempt returns. Open by design: the
-- monolith returned ad-hoc `{ ok, error?, status?, daemon?, placeId?, placeName? }`
-- shapes and callers (the SelfTest, _G.StudioStud.Sync) read whichever fields are
-- present. Kept loose so the wire/behaviour is unchanged.
export type SyncResult = {
	ok: boolean,
	error: string?,
	status: string?,
	daemon: any?,
	placeId: any?,
	placeName: string?,
	[string]: any,
}

-- The panel handle returned by `build`, mirroring the monolith's CapturePanel
-- handle one-for-one. `frame` is the panel root (Registry uses it for show/hide and
-- as the destroy fallback); `sync`/`status` are the orchestration entry points the
-- bootstrap registers on `_G`; `onConnectRequested` is what Shell.onWidgetEnabled
-- calls; `live`/`capture` are exposed for the SelfTest and `_G.StudioStud.Live`.
export type PanelHandle = {
	frame: Frame,
	sync: (options: any?) -> SyncResult,
	status: () -> SyncResult,
	isRunning: () -> boolean,
	pollGeneration: number,
	onConnectRequested: () -> SyncResult,
	destroy: () -> (),
	live: LiveModule,
	capture: CaptureModule,
	[string]: any,
}

-- The exported panel module: the `build` the descriptor points at, plus the static
-- descriptor the bootstrap registers with Registry.
export type CapturePanelModule = {
	build: (parent: Frame, ctx: ShellContext) -> PanelHandle,
	descriptor: {
		id: string,
		title: string,
		defaultEnabled: boolean,
		build: (parent: Frame, ctx: ShellContext) -> PanelHandle,
	},
}

-- == Per-build state record (the C1-C3-safe shape) ==

-- Everything the monolith held as forward-declared build-closure locals lives here
-- as fields; methods reach siblings through `panel.*` (call-time field reads), never
-- a read-before-local. One record per build() so each panel instance is isolated.
type PanelState = {
	ctx: ShellContext,
	parent: Frame,
	resultLabel: TextLabel,
	errorLabel: TextLabel,
	connectButton: TextButton,
	connectConnection: RBXScriptConnection?,
	syncing: boolean,
	running: boolean,
	pollGeneration: number,
	sessionHasBaseline: boolean,
	pausedBaseline: { revision: number, instanceCount: number },

	formatError: (self: PanelState, prefix: string, result: any) -> string,
	setConnectButtonState: (self: PanelState) -> (),
	statusFn: (self: PanelState) -> SyncResult,
	syncFn: (self: PanelState, options: any?) -> SyncResult,
	startupConnectAndCapture: (self: PanelState) -> SyncResult,
	onReturnToEdit: (self: PanelState) -> (),
}

local CapturePanel = {} :: CapturePanelModule

-- == build ==

function CapturePanel.build(parent: Frame, ctx: ShellContext): PanelHandle
	local debugLog = ctx.settings.debugLog

	local resultLabel = Ui.makeLabel(parent, "Latest capture: none", Theme.PAD, 72, Theme.muted)
	resultLabel.TextSize = 12

	local errorLabel = Ui.makeLabel(parent, "", Theme.PAD + 80, 80, Theme.warn)
	errorLabel.TextSize = 12

	local connectButton = Ui.makePrimaryButton(parent, "Connect")
	connectButton.Position = UDim2.fromOffset(Theme.PAD, Theme.PAD + 168)
	connectButton.Size = UDim2.new(1, -Theme.PAD * 2, 0, 36)

	-- The state record; fields assigned below before any handler can fire.
	local panel: PanelState = {
		ctx = ctx,
		parent = parent,
		resultLabel = resultLabel,
		errorLabel = errorLabel,
		connectButton = connectButton,
		connectConnection = nil,
		syncing = false,
		running = true,
		pollGeneration = 0,
		sessionHasBaseline = false,
		pausedBaseline = { revision = 0, instanceCount = 0 },
	} :: PanelState

	-- VERBATIM port of CapturePanel.build's formatError (monolith :1594).
	function panel.formatError(_self: PanelState, prefix: string, result: any): string
		local message = prefix .. ": " .. tostring(result and result.error or "unknown error")
		if result and result.statusCode then
			message = message .. " (HTTP " .. tostring(result.statusCode) .. ")"
		end
		if result and result.body and result.body ~= "" then
			message = message .. "\n" .. tostring(result.body)
		end
		return message
	end

	-- VERBATIM port of setConnectButtonState (monolith :1605). Three states, driven
	-- by `syncing` and ctx.isConnected().
	function panel.setConnectButtonState(self: PanelState): ()
		if self.syncing then
			self.connectButton.Text = "Capturing..."
			self.connectButton.BackgroundColor3 = Theme.teal
			self.connectButton.AutoButtonColor = false
		elseif self.ctx.isConnected() then
			self.connectButton.Text = "Capture / Query"
			self.connectButton.BackgroundColor3 = Theme.copper
			self.connectButton.AutoButtonColor = true
		else
			self.connectButton.Text = "Connect"
			self.connectButton.BackgroundColor3 = Theme.copper
			self.connectButton.AutoButtonColor = true
		end
	end

	-- VERBATIM port of statusFn (monolith :2077): ping the daemon, run the mutual
	-- protocol handshake, set the connection LED/status, and (on success) prime the
	-- write token. Returns the loose result shape the monolith returned.
	function panel.statusFn(self: PanelState): SyncResult
		self.ctx.setStatus("syncing", "Checking daemon...")
		local ok, result = self.ctx.transport.requestJson("GET", "/studio-stud/ping", nil)
		if ok and result.ok then
			local daemonProtocol = tonumber(result.protocolVersion) or 0
			local daemonMinPlugin = tonumber(result.minPluginProtocolVersion) or daemonProtocol
			-- Mutual handshake: name whichever side is behind.
			if daemonProtocol < MIN_DAEMON_PROTOCOL_VERSION then
				self.ctx.setConnected(false)
				self:setConnectButtonState()
				self.ctx.setStatus("error", "Daemon outdated — update it")
				self.errorLabel.Text = ("Daemon protocol %d < plugin requires %d. Update: %s"):format(
					daemonProtocol,
					MIN_DAEMON_PROTOCOL_VERSION,
					updateInstallHint(result.channel)
				)
				return {
					ok = false,
					error = "daemon outdated",
					daemon = result,
					placeId = game.PlaceId,
					placeName = game.Name,
				}
			end
			if PROTOCOL_VERSION < daemonMinPlugin then
				self.ctx.setConnected(false)
				self:setConnectButtonState()
				self.ctx.setStatus("error", "Plugin outdated — reinstall plugin")
				self.errorLabel.Text = ("Plugin protocol %d < daemon requires %d. Reinstall from .studio-stud-tool/plugin/StudioStud.plugin.lua"):format(
					PROTOCOL_VERSION,
					daemonMinPlugin
				)
				return {
					ok = false,
					error = "plugin outdated",
					daemon = result,
					placeId = game.PlaceId,
					placeName = game.Name,
				}
			end
			self.ctx.setConnected(true)
			self:setConnectButtonState()
			local updateNote = checkRemoteUpdate(result)
			if updateNote ~= "" then
				self.ctx.setStatus(
					"connected",
					("Daemon %s — %s"):format(tostring(result.version or "unknown"), updateNote)
				)
				self.errorLabel.Text = updateNote .. "  (run: " .. updateInstallHint(result.channel) .. ")"
			else
				self.ctx.setStatus(
					"connected",
					("Daemon %s — listening for captures"):format(tostring(result.version or "unknown"))
				)
				self.errorLabel.Text = ""
			end
			self.ctx.transport.fetchWriteToken()
			return { ok = true, daemon = result, placeId = game.PlaceId, placeName = game.Name }
		end
		self.ctx.setConnected(false)
		self:setConnectButtonState()
		self.ctx.setStatus("idle", "Run studio-stud serve, then Connect")
		self.errorLabel.Text = self:formatError("Connect failed", result)
		return { ok = false, error = result.error, placeId = game.PlaceId, placeName = game.Name }
	end

	-- VERBATIM port of syncFn (monolith :2065): gate to edit sessions; if live is
	-- already running, schedule a tick baseline; else run the full connect+capture.
	function panel.syncFn(self: PanelState, options: any?): SyncResult
		if not Session.isEdit() then
			return { ok = false, error = "studio_in_play_session" }
		end
		if Live.liveRunning then
			Live:triggerFullBaseline(options and options.reason or "manual")
			self.ctx.setStatus("syncing", "Scheduling tick baseline...")
			return { ok = true, status = "baseline_scheduled" }
		end
		return self:startupConnectAndCapture()
	end

	-- VERBATIM port of startupConnectAndCapture (monolith :2138). Ping daemon; on the
	-- first success this session, load the allow-list once, bring up live mode, and
	-- start the single tick loop — handing it this panel's pausedBaseline ref and a
	-- NON-NIL onReturnToEdit (the C2 cure: the monolith captured a not-yet-assigned
	-- upvalue here). The onReturnToEdit closure routes back through `panel:onReturnToEdit()`.
	function panel.startupConnectAndCapture(self: PanelState): SyncResult
		-- Edit-session gate: do not connect/capture while Studio is in a play session.
		if not Session.isEdit() then
			return { ok = false, error = "studio_in_play_session" }
		end
		if self.syncing then
			return { ok = false, error = "Sync already running." }
		end
		local ping = self:statusFn()
		-- statusFn always returns a (non-nil) SyncResult, so the monolith's
		-- `not (ping and ping.ok)` reduces to `not ping.ok` here (same behaviour,
		-- and keeps the return typed SyncResult rather than SyncResult?).
		if not ping.ok then
			return ping
		end
		if not AllowList.loaded then -- load once per connect (best-effort; static fallback on failure)
			AllowList.fetch()
		end
		if self.sessionHasBaseline and Live.liveRunning then
			return ping
		end
		debugLog("startup: daemon reachable — starting tick live mode")
		if Live:connectLiveMode() then
			Live:startTickLoop(self.pausedBaseline, function()
				self:onReturnToEdit()
			end)
			self.ctx.setConnected(true)
			self.sessionHasBaseline = true
			self:setConnectButtonState()
			self.resultLabel.Text = "Connected — first tick will baseline via /tick"
			return { ok = true, daemon = ping.daemon }
		end
		return { ok = false, error = "live_connect_failed" }
	end

	-- VERBATIM port of onReturnToEdit (monolith :3280): the play->edit catch-up. After
	-- a short settle, if still in edit, re-arm live mode from the stashed pausedBaseline
	-- and restart the tick loop (re-passing self:onReturnToEdit so the loop stays armed
	-- across further transitions); else trigger a full rebaseline via the host.
	function panel.onReturnToEdit(self: PanelState): ()
		task.wait(1.5)
		if not Session.isEdit() then
			return
		end
		if Live:connectLiveMode() then
			Live.currentRevision = self.pausedBaseline.revision or 0
			Live.liveInstanceCount = self.pausedBaseline.instanceCount or 0
			Live:startTickLoop(self.pausedBaseline, function()
				self:onReturnToEdit()
			end)
			self.ctx.setConnected(true)
			self.sessionHasBaseline = true
			self:setConnectButtonState()
			self.ctx.setStatus("connected", "Live resumed — tick sync active")
			debugLog("session: resumed live after play (rev ", Live.currentRevision, ")")
		else
			Live:triggerRebaseline("return-to-edit")
		end
	end

	-- == Attach the engine host (the injected seam) ==

	-- Build the LiveHost the engine calls back through. transport/setStatus/setStats/
	-- isConnected/setConnected come straight from ctx (the monolith's closure upvalues,
	-- now typed). setBaseline persists this panel's sessionHasBaseline; reconnect is the
	-- full connect handshake (the monolith's startupConnectAndCapture, used by
	-- triggerRebaseline); isRunning is the panel-alive flag the tick loop checks.
	local host: LiveHost = {
		transport = {
			requestJson = ctx.transport.requestJson,
			requestBody = ctx.transport.requestBody,
		},
		setStatus = ctx.setStatus,
		setStats = function(text: string)
			ctx.setStats(text)
		end,
		setConnected = ctx.setConnected,
		isConnected = ctx.isConnected,
		setBaseline = function(hasBaseline: boolean)
			panel.sessionHasBaseline = hasBaseline
		end,
		setConnectButtonState = function()
			panel:setConnectButtonState()
		end,
		reconnect = function()
			panel:startupConnectAndCapture()
		end,
		isRunning = function(): boolean
			return panel.running
		end,
	}
	Live:attach(host)

	-- == Connect button wiring (verbatim port, monolith :3299) ==

	panel.connectConnection = connectButton.MouseButton1Click:Connect(function()
		if ctx.isConnected() then
			if Live.liveRunning then
				Live:triggerFullBaseline("manual")
			else
				panel:startupConnectAndCapture()
			end
		else
			panel:startupConnectAndCapture()
		end
	end)

	panel.pollGeneration += 1
	local myGeneration = panel.pollGeneration

	-- VERBATIM port of the panel's destroy (monolith :3316): stop the loop, tear down
	-- the engine, and disconnect the button. (GlobalApi.installNoOps is the bootstrap's
	-- responsibility — see header.)
	local function destroy(): ()
		panel.running = false
		Live:teardown()
		local conn = panel.connectConnection
		if conn then
			conn:Disconnect()
			panel.connectConnection = nil
		end
	end

	-- VERBATIM port of the panel handle (monolith :3325). `sync`/`status`/
	-- `onConnectRequested` close over `panel` and route through its methods.
	return {
		frame = parent,
		sync = function(options: any?): SyncResult
			return panel:syncFn(options)
		end,
		status = function(): SyncResult
			return panel:statusFn()
		end,
		isRunning = function(): boolean
			return panel.running
		end,
		pollGeneration = myGeneration,
		onConnectRequested = function(): SyncResult
			return panel:startupConnectAndCapture()
		end,
		destroy = destroy,
		live = Live, -- exposed for self-tests and _G.StudioStud.Live
		capture = Capture, -- Phase 3: exposed for self-tests (SelfTest reaches Capture only via this field)
	}
end

-- == Descriptor ==

-- VERBATIM port of CapturePanel.descriptor (monolith :3340): the tab the bootstrap
-- registers with Registry.
CapturePanel.descriptor = {
	id = "capture",
	title = "Capture / Query",
	defaultEnabled = true,
	build = CapturePanel.build,
}

return CapturePanel
