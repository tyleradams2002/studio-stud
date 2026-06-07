--!strict
-- Live — the live capture engine, ported faithfully from the monolith's Live.*
-- block (StudioStud.plugin.lua:2168-3346), MINUS the Hash / Capture / Fingerprints
-- code already extracted into their own modules. This is the heart of protocol v2:
-- a single fixed-interval tick loop that ships dirty deltas (ops.upserted/removed)
-- to /studio-stud/tick, spills oversized payloads to /tick/bulk, recovers from
-- drift with a full rebaseline, and gates all traffic to genuine edit sessions.
--
-- ARCHITECTURE (the C1-C3 cure): the monolith held Live as a giant table inside an
-- 1,800-line build closure, alongside the UI, the orchestrator, and forward-declared
-- locals (`syncFn`, `startupConnectAndCapture`, `pausedBaseline`, `onReturnToEdit`,
-- `responseNeedsRebaseline`) that were referenced before assignment — the exact
-- before-local window that produced C1 (markDirtyUpsert self-call), C2 (a nil
-- onReturnToEdit captured into startTickLoop), and C3 (Sync() before live nil-calls).
-- Here Live is an explicit module table with typed fields and methods; every method
-- reaches state and siblings through `self`/module references, never a forward upvalue.
-- The orchestrator/UI seam the monolith reached through closure upvalues (`ctx`,
-- `running`, `sessionHasBaseline`, `startupConnectAndCapture`)
-- is now an INJECTED, typed `LiveHost` the bootstrap hands in via `Live.attach(host)`;
-- the engine calls back through it instead of capturing a closure. Until attached,
-- the host is a no-op stub, so a pre-live call (the C3 path) is a safe no-op, not a
-- nil-call.
--
-- SHARED IDENTITY MAPS: the monolith's `instanceIdByRef`/`pathByRef` (Instance -> id
-- / path) were build-closure locals shared by Capture and Live. In the modular split
-- Capture OWNS them (Capture.instanceIdByRef / Capture.pathByRef, rebuilt each walk);
-- Live reads/writes the SAME tables through Capture.* so id/path resolution stays
-- consistent across both — single source of truth, no parallel map.
--
-- FINGERPRINTS: the per-service XOR accumulator (instFp / serviceFpBytes /
-- applyFpUpsert / applyFpRemove / reset / serviceFingerprintsWire) lives in the
-- Fingerprints module; Live drives it. The hash recipe itself is Hash (the single
-- source of truth). serviceFingerprints are computed AFTER collectOpsFromDirty (the
-- Phase-5 post-ops fix): the accumulator is mutated as each op is built, so the wire
-- map must be snapshotted after the op loop, never before.
--
-- NON-NEGOTIABLE behaviors preserved verbatim (regression if changed):
--   * dirty sets + monotonic stamps; clearSentDirty stamp-based no-data-loss.
--   * registerInstance: ONE inst.Changed connection + classifyChangedProp (~= nil
--     membership; Name->name, Source->dirty); ValueBase explicit Name+Value;
--     AncestryChanged / AttributeChanged; root DescendantAdded / DescendantRemoving.
--   * markDirtyUpsert sets dirtyUpsert[inst]=true (NO recursion — the C1 cure).
--   * collectOpsFromDirty: depth-sorted, capped at TICK_INLINE_THRESHOLD with
--     forward-progress (a solo over-threshold op still ships); E1 incremental byte
--     sizing (encode each entry once, running sum, no per-op trial copy).
--   * runTick: serviceFingerprints AFTER collectOpsFromDirty; bulkRef commit;
--     drift -> triggerFullBaseline; no_baseline -> baseline; 4-error teardown.
--   * startTickLoop: ONE fixed-interval loop; play=keepalive + teardown; play->edit
--     resume via onReturnToEdit; generation-guarded.
--   * triggerFullBaseline: yielding fp loop in buildBaselineSnapshot (the Q1 fix).
--   * historyDirty -> rebaseline; teardown resets all; connect/baseline full bulk.

local Types = require("./Types")
local Config = require("./Config")
local Session = require("./Session")
local Settings = require("./Settings")
local Transport = require("./Transport")
local Capture = require("./Capture")
local Fingerprints = require("./Fingerprints")
local Hash = require("./Hash")

type InstanceEntry = Types.InstanceEntry
type Ops = Types.Ops
type SessionMode = Types.SessionMode
type Hex64 = Types.Hex64

local PLUGIN_VERSION = Config.PLUGIN_VERSION
local PROTOCOL_VERSION = Config.PROTOCOL_VERSION
local TICK_INLINE_THRESHOLD = Config.TICK_INLINE_THRESHOLD
local BASELINE_YIELD_EVERY = Config.BASELINE_YIELD_EVERY
local DEFAULT_BULK_CHUNK_BYTES = Config.DEFAULT_BULK_CHUNK_BYTES
local SETTINGS = Config.SETTINGS

-- == Engine handles ==

-- HttpService (for UrlEncode) and `game` are Studio globals typed via
-- globalTypes.d.luau. Resolve-and-cache HttpService on first use (cache-at-event);
-- `game` is a global the analyzer already types.
local httpService: HttpService? = nil
local function getHttpService(): HttpService
	local cached = httpService
	if cached then
		return cached
	end
	local resolved = game:GetService("HttpService") :: HttpService
	httpService = resolved
	return resolved
end

-- == Host seam (the injected orchestrator/UI collaborator) ==

-- The monolith reached the UI/orchestrator through closure upvalues. Here those are
-- an explicit, typed contract the bootstrap injects. Every field is something the
-- engine genuinely calls; nothing here re-implements engine logic.
--
--   transport.*        — the HTTP primitives the engine sends through (the monolith's
--                        ctx.transport). Pinned to the exact shapes Transport exports.
--   setStatus/setStats — UI status/stat text (ctx.setStatus / ctx.setStats).
--   setConnected/isConnected — connection LED state (ctx.setConnected / ctx.isConnected).
--   setBaseline        — persist sessionHasBaseline (the build-closure local).
--   reconnect          — startupConnectAndCapture: the full connect+baseline+loop
--                        bootstrap. Used by triggerRebaseline; injected so Live does
--                        not own the connect handshake (that's the orchestrator's job).
--   isRunning          — the `running` panel-alive flag the tick loop checks.
export type LiveHost = {
	transport: {
		requestJson: (method: string, path: string, body: any?, timeoutSeconds: number?) -> (boolean, any),
		requestBody: (path: string, body: string) -> (boolean, any),
	},
	setStatus: (kind: string, message: string) -> (),
	setStats: (text: string) -> (),
	setConnected: (connected: boolean) -> (),
	isConnected: () -> boolean,
	setBaseline: (hasBaseline: boolean) -> (),
	reconnect: () -> (),
	isRunning: () -> boolean,
}

-- == Public interface ==

export type LiveModule = {
	-- Live engine state (Types.LiveState fields are mirrored here; the accumulator
	-- halves instFp/serviceFpBytes live on Fingerprints, reached via the FP methods).
	liveRunning: boolean,
	currentRevision: number,
	liveInstanceCount: number,
	networkErrorCount: number,
	syncInFlight: boolean,
	verifyNeeded: boolean,
	dirtyStamp: number,
	dirtyUpsert: { [Instance]: boolean },
	dirtyRemoved: { [string]: boolean },
	upsertStamp: { [Instance]: number },
	removedStamp: { [string]: number },
	parentByInst: { [Instance]: Instance? },
	instConns: { [Instance]: { RBXScriptConnection } },
	rootConns: { RBXScriptConnection },
	globalConns: { RBXScriptConnection },
	propGaps: { [string]: boolean },
	pendingBulkRef: string?,
	baselineInProgress: boolean,
	recoveryServices: { string }?,
	tickGeneration: number,
	historyDirty: boolean,

	-- The host seam; a no-op stub until attach() injects the real orchestrator.
	host: LiveHost,
	attach: (self: LiveModule, host: LiveHost) -> (),

	-- Dirty marking (lazy; handlers set dirty only, values read at tick time).
	markDirtyUpsert: (self: LiveModule, inst: Instance) -> (),
	markDirtyRemoved: (self: LiveModule, id: string) -> (),
	markSubtreeUpsert: (self: LiveModule, root: Instance) -> (),
	markSiblingsDirty: (self: LiveModule, parent: Instance?, name: string) -> (),

	-- Property classification (pure; O(1) lookup).
	classifyChangedProp: (self: LiveModule, prop: string, curatedSet: { [string]: boolean }) -> string,
	recordPropGap: (self: LiveModule, className: string?, prop: any) -> (),
	onNameChanged: (self: LiveModule, inst: Instance) -> (),

	-- Per-instance signal wiring.
	registerInstance: (self: LiveModule, inst: Instance) -> (),
	unregisterInstance: (self: LiveModule, inst: Instance) -> (),
	unregisterSubtree: (self: LiveModule, root: Instance) -> (),
	onDescendantAdded: (self: LiveModule, child: Instance) -> (),
	onDescendantRemoving: (self: LiveModule, child: Instance) -> (),

	-- Op collection + stamp clearing (the no-data-loss path).
	collectOpsFromDirty: (self: LiveModule) -> (
		{ InstanceEntry },
		{ string },
		{ [Instance]: number },
		{ [string]: number }
	),
	clearSentDirty: (
		self: LiveModule,
		sentUpsertStamps: { [Instance]: number },
		sentRemovedStamps: { [string]: number }
	) -> (),

	-- Tick body + payload sizing.
	tickQuerySuffix: (self: LiveModule) -> string,
	buildTickBody: (
		self: LiveModule,
		placeId: any,
		sessionMode: SessionMode,
		baseRevision: number,
		serviceFingerprints: { [string]: Hex64 },
		ops: Ops,
		bulkRef: string?
	) -> any,

	-- Baseline + bulk upload.
	initFingerprintsFromWalk: (self: LiveModule) -> (),
	buildBaselineSnapshot: (self: LiveModule, reason: string?) -> any,
	uploadTickBulk: (self: LiveModule, jsonText: string, reason: string?) -> (boolean, any),
	triggerFullBaseline: (self: LiveModule, reason: string?) -> boolean,
	triggerDriftRecovery: (self: LiveModule, driftServices: { string }?) -> boolean,
	triggerRebaseline: (self: LiveModule, reason: string?) -> (),

	-- The tick + loop.
	runTick: (self: LiveModule, sessionMode: SessionMode?) -> (),
	startTickLoop: (
		self: LiveModule,
		pausedBaselineRef: { revision: number, instanceCount: number }?,
		onReturnToEditFn: (() -> ())?
	) -> (),

	-- Connect / teardown / session transitions.
	connectLiveMode: (self: LiveModule) -> boolean,
	setupAfterBaseline: (self: LiveModule, materialized: any?) -> (),
	teardown: (self: LiveModule) -> (),
}

-- Forward declaration of the module table so methods reach state and one another
-- through it (Live.markDirtyUpsert, Live.host, ...) WITHOUT a forward-referenced
-- upvalue. Live.* is a real table field by the time any method runs.
local Live: LiveModule

-- == No-op host stub (the C3 cure) ==

-- Before attach(), every host call is a safe no-op. The monolith's Sync()-before-live
-- nil-called a not-yet-assigned upvalue; here a pre-live call routes through this stub
-- and does nothing. requestJson/requestBody return a failure shape so any stray pre-
-- attach network call fails gracefully instead of throwing.
local NOOP_HOST: LiveHost = {
	transport = {
		requestJson = function(_method: string, _path: string, _body: any?, _timeout: number?): (boolean, any)
			return false, { error = "live host not attached" }
		end,
		requestBody = function(_path: string, _body: string): (boolean, any)
			return false, { error = "live host not attached" }
		end,
	},
	setStatus = function(_kind: string, _message: string) end,
	setStats = function(_text: string) end,
	setConnected = function(_connected: boolean) end,
	isConnected = function(): boolean
		return false
	end,
	setBaseline = function(_hasBaseline: boolean) end,
	reconnect = function() end,
	isRunning = function(): boolean
		return true
	end,
}

local function attach(self: LiveModule, host: LiveHost): ()
	self.host = host
end

-- == debugLog passthrough ==

-- The monolith logged through a closure `debugLog`; Settings.debugLog is the same
-- gate (warns iff the debugLogging setting is true). Single source of truth.
local debugLog = Settings.debugLog

-- == Dirty marking (lazy; handlers set dirty only) ==

-- VERBATIM port of Live.markDirtyUpsert (monolith :2353). Sets dirtyUpsert[inst]=true
-- and stamps it — NO recursion, NO read (the C1 cure: the buggy version called itself).
local function markDirtyUpsert(self: LiveModule, inst: Instance): ()
	self.dirtyUpsert[inst] = true
	self.dirtyStamp += 1
	self.upsertStamp[inst] = self.dirtyStamp
end

-- VERBATIM port of Live.markDirtyRemoved (monolith :2359).
local function markDirtyRemoved(self: LiveModule, id: string): ()
	self.dirtyRemoved[id] = true
	self.dirtyStamp += 1
	self.removedStamp[id] = self.dirtyStamp
end

-- BFS dirty-mark: root + all captured descendants (path cascade on rename/reparent).
-- VERBATIM port of Live.markSubtreeUpsert (monolith :2486). Only instances present in
-- the walk map are marked; GetChildren is pcall-guarded so a destroying node is skipped.
local function markSubtreeUpsert(self: LiveModule, root: Instance): ()
	local idByRef = Capture.instanceIdByRef
	local queue: { Instance } = { root }
	local qi = 1
	while qi <= #queue do
		local inst = queue[qi]
		qi += 1
		if idByRef[inst] then
			self:markDirtyUpsert(inst)
		end
		local ok, children = pcall(function()
			return inst:GetChildren()
		end)
		if ok then
			for _, child in ipairs(children) do
				queue[#queue + 1] = child
			end
		end
	end
end

-- Dirty parent + all same-name siblings under parent (siblingIndex/duplicate changed).
-- VERBATIM port of Live.markSiblingsDirty (monolith :2507).
local function markSiblingsDirty(self: LiveModule, parent: Instance?, name: string): ()
	if not parent then
		return
	end
	local realParent = parent :: Instance
	local idByRef = Capture.instanceIdByRef
	if idByRef[realParent] then
		self:markDirtyUpsert(realParent)
	end
	local ok, children = pcall(function()
		return realParent:GetChildren()
	end)
	if not ok then
		return
	end
	for _, sib in ipairs(children) do
		if sib.Name == name and idByRef[sib] then
			self:markDirtyUpsert(sib)
		end
	end
end

-- == Property classification (pure; O(1)) ==

-- VERBATIM port of Live.classifyChangedProp (monolith :2531). curatedSet maps
-- propName -> readOnly(boolean); a WRITABLE curated prop is `false`, so membership
-- MUST be tested with `~= nil`, not truthiness (the Phase-3 fix — else writable props
-- are missed). Source is PluginSecurity-only (excluded from the allow-list) — special-
-- cased to "dirty" so live source edits ship. Returns "name" | "dirty" | "gap".
local function classifyChangedProp(_self: LiveModule, prop: string, curatedSet: { [string]: boolean }): string
	if prop == "Name" then
		return "name"
	elseif prop == "Source" then
		return "dirty"
	elseif curatedSet[prop] ~= nil then
		return "dirty"
	else
		return "gap"
	end
end

-- Uncurated properties that fired, deduped, for later reporting (Phase 5). VERBATIM
-- port of Live.recordPropGap (monolith :2545).
local function recordPropGap(self: LiveModule, className: string?, prop: any): ()
	local key = (className or "?") .. "/" .. tostring(prop)
	if not self.propGaps[key] then
		self.propGaps[key] = true
		debugLog("allowlist gap:", key)
	end
end

-- Shared name-change cascade (was the body of the old Name signal). VERBATIM port of
-- Live.onNameChanged (monolith :2554): dirty the subtree (path cascade), then dirty
-- same-name siblings under both the old and new parent for siblingIndex/duplicate.
local function onNameChanged(self: LiveModule, inst: Instance): ()
	local pathByRef = Capture.pathByRef
	local oldPath = pathByRef[inst] or ""
	local oldName = oldPath:match("([^%[/]+)%[%d+%]$") or inst.Name
	self:markSubtreeUpsert(inst)
	local parent = self.parentByInst[inst] or inst.Parent
	self:markSiblingsDirty(parent, oldName)
	self:markSiblingsDirty(parent, inst.Name)
end

-- == Per-instance signal wiring ==

-- Connect per-instance signals for one instance. VERBATIM port of Live.registerInstance
-- (monolith :2564): AncestryChanged (intra-root reparent), AttributeChanged, then
-- EITHER ValueBase explicit Name+Value signals (ValueBase fires .Changed with the
-- VALUE, not a prop name) OR ONE inst.Changed connection routed through
-- classifyChangedProp. Every Connect is pcall-guarded (some signals throw on exotic
-- instances) and only kept on success.
local function registerInstance(self: LiveModule, inst: Instance): ()
	if self.instConns[inst] then
		return
	end
	local idByRef = Capture.instanceIdByRef
	local conns: { RBXScriptConnection } = {}

	-- AncestryChanged: intra-root reparent (fires on the moved node AND each dragged
	-- descendant). Mark the inst dirty; if it is the changed child whose parent moved,
	-- dirty same-name siblings under old and new parent and update parentByInst.
	local okA, cA = pcall(function()
		return inst.AncestryChanged:Connect(function(changedChild: Instance, newParent: Instance?)
			if idByRef[inst] then
				self:markDirtyUpsert(inst)
			end
			if changedChild == inst then
				local oldParent = self.parentByInst[inst]
				if oldParent ~= newParent then
					self:markSiblingsDirty(oldParent, inst.Name)
					self:markSiblingsDirty(newParent, inst.Name)
				end
				self.parentByInst[inst] = newParent
			end
		end)
	end)
	if okA then
		conns[#conns + 1] = cA
	end

	-- AttributeChanged.
	local okAt, cAt = pcall(function()
		return inst.AttributeChanged:Connect(function()
			if idByRef[inst] then
				self:markDirtyUpsert(inst)
			end
		end)
	end)
	if okAt then
		conns[#conns + 1] = cAt
	end

	if inst:IsA("ValueBase") then
		-- ValueBase fires .Changed with the VALUE, not the property name → explicit
		-- per-property signals for Name and Value. The defs only declare `Value` on the
		-- concrete ValueBase subclasses (IntValue/StringValue/…), not the abstract
		-- ValueBase the IsA narrowed to, so GetPropertyChangedSignal("Value") would
		-- otherwise flag an unknown key. The IsA gate guarantees the property exists and
		-- the pcall already hardens the call; index the signal off an `any` handle
		-- (mirrors Capture's dynamic `.Source` read on LuaSourceContainer).
		local valueInst = inst :: any
		local okN, cN = pcall(function()
			return inst:GetPropertyChangedSignal("Name"):Connect(function()
				self:onNameChanged(inst)
			end)
		end)
		if okN then
			conns[#conns + 1] = cN
		end
		local okV, cV = pcall(function()
			return valueInst:GetPropertyChangedSignal("Value"):Connect(function()
				if idByRef[inst] then
					self:markDirtyUpsert(inst)
				end
			end)
		end)
		if okV then
			conns[#conns + 1] = cV
		end
	else
		-- ONE Changed connection replaces ~N per-property signals + the Name signal.
		-- curatedSet is cached at registration time (cache-at-event) so the hot signal
		-- handler does only an O(1) table lookup via classifyChangedProp.
		local curated = Capture.curatedSet(inst)
		local okC, cC = pcall(function()
			return inst.Changed:Connect(function(prop: string)
				local kind = self:classifyChangedProp(prop, curated)
				if kind == "name" then
					self:onNameChanged(inst)
				elseif kind == "dirty" then
					if idByRef[inst] then
						self:markDirtyUpsert(inst)
					end
				else
					self:recordPropGap(inst.ClassName, prop)
				end
			end)
		end)
		if okC then
			conns[#conns + 1] = cC
		end
	end

	self.instConns[inst] = conns
end

-- Disconnect all per-instance signals for one instance (table not mutated during
-- iteration). VERBATIM port of Live.unregisterInstance (monolith :2648).
local function unregisterInstance(self: LiveModule, inst: Instance): ()
	local conns = self.instConns[inst]
	if conns then
		for _, conn in ipairs(conns) do
			pcall(function()
				conn:Disconnect()
			end)
		end
		self.instConns[inst] = nil
	end
	self.parentByInst[inst] = nil
end

-- Unregister an inst + its entire subtree: queue ids in dirtyRemoved, XOR their
-- fingerprints out, disconnect, clear maps. VERBATIM port of Live.unregisterSubtree
-- (monolith :2662). Disconnects inline (NOT via unregisterInstance) to avoid mutating
-- instConns during the outer BFS.
local function unregisterSubtree(self: LiveModule, root: Instance): ()
	local idByRef = Capture.instanceIdByRef
	local pathByRef = Capture.pathByRef
	local queue: { Instance } = { root }
	local qi = 1
	while qi <= #queue do
		local inst = queue[qi]
		qi += 1
		local id = idByRef[inst]
		if id then
			self:markDirtyRemoved(id)
			Fingerprints:applyFpRemove(id, pathByRef[inst])
		end
		local conns = self.instConns[inst]
		if conns then
			for _, conn in ipairs(conns) do
				pcall(function()
					conn:Disconnect()
				end)
			end
			self.instConns[inst] = nil
		end
		self.parentByInst[inst] = nil
		idByRef[inst] = nil
		pathByRef[inst] = nil
		local ok, children = pcall(function()
			return inst:GetChildren()
		end)
		if ok then
			for _, child in ipairs(children) do
				queue[#queue + 1] = child
			end
		end
	end
end

-- Root DescendantAdded handler. VERBATIM port of Live.onDescendantAdded (monolith
-- :2697): off-live, warn and bail; else assign a debug id (best-effort), record the
-- parent, register signals, mark dirty, and dirty same-name siblings.
local function onDescendantAdded(self: LiveModule, child: Instance): ()
	if not self.liveRunning then
		warn("[StudioStud] +added (live off — click Capture/Query first):", child:GetFullName())
		return
	end
	local idByRef = Capture.instanceIdByRef
	local pathByRef = Capture.pathByRef
	if not idByRef[child] then
		local ok, id = pcall(function()
			return child:GetDebugId(0)
		end)
		local resolved: string? = nil
		if ok and id ~= "" then
			resolved = id
		end
		if resolved then
			idByRef[child] = resolved
			pathByRef[child] = ""
			debugLog("+added:", child:GetFullName(), resolved)
		else
			debugLog("+added (no debugId):", child:GetFullName())
		end
	end
	self.parentByInst[child] = child.Parent
	self:registerInstance(child)
	if idByRef[child] then
		self:markDirtyUpsert(child)
	end
	self:markSiblingsDirty(child.Parent, child.Name)
end

-- Root DescendantRemoving handler. VERBATIM port of Live.onDescendantRemoving
-- (monolith :2720): off-live, warn and bail; else unregister the subtree, ensure the
-- removed node loses any pending upsert (removed wins), and dirty siblings.
local function onDescendantRemoving(self: LiveModule, child: Instance): ()
	if not self.liveRunning then
		warn("[StudioStud] -removing (live off, skipped):", child:GetFullName())
		return
	end
	local id = Capture.instanceIdByRef[child]
	debugLog("-removing:", child:GetFullName(), "id=", tostring(id))
	local parent = self.parentByInst[child] or child.Parent
	self:unregisterSubtree(child)
	-- removed wins: clear from upsert.
	self.dirtyUpsert[child] = nil
	self:markSiblingsDirty(parent, child.Name)
	debugLog("-removing queued in dirtyRemoved:", next(self.dirtyRemoved) ~= nil)
end

-- == Op collection (E1 incremental sizing + cap + forward-progress) ==

-- E1: encode each entry ONCE and keep a running byte sum, instead of the monolith's
-- per-op O(K^2) trial-copy + full re-encode. The monolith's cap logic was: build a
-- trialUpserted = current ++ entry, re-encode the WHOLE body, and break if it exceeded
-- the threshold AND at least one op was already committed (forward-progress: a solo
-- over-threshold op still ships). We reproduce the SAME decision with the same wire
-- semantics — the deciding quantity is the byte length of the encoded tick body — but
-- compute it incrementally.
--
-- Byte accounting: the wire body is buildTickBody(...) JSON-encoded. Its size is the
-- fixed envelope (placeId/sessionMode/baseRevision/serviceFingerprints/bulkRef + the
-- ops wrapper) plus the JSON of each entry plus inter-entry commas. The monolith's
-- threshold test compared the FULL encoded body to TICK_INLINE_THRESHOLD; we keep that
-- exact comparison by measuring the full body once with zero ops (the envelope) and
-- adding each entry's own encoded length + the comma that joins it. This yields a byte
-- count that tracks the real encoded size, and the break condition (over threshold AND
-- committedCount > 0) is identical to the monolith's shouldBreakOpsCap.

-- Encoded byte length of one entry, via safeEncode (the same encoder the wire uses).
-- A non-encodable entry returns math.huge so it is treated as oversized (forward-
-- progress still ships it solo, exactly as a huge tickPayloadByteLen would have).
local function entryByteLen(entry: InstanceEntry): number
	local ok, encoded = Transport.safeEncode(entry, "tick-entry")
	if ok then
		return #encoded
	end
	return math.huge
end

-- The fixed tick-body envelope size (zero ops): everything except the upserted/removed
-- arrays' contents. Measured once per flush, matching the monolith's full-body probe
-- but without re-encoding per op.
local function envelopeByteLen(self: LiveModule, removed: { string }): number
	local body = self:buildTickBody(
		game.PlaceId,
		"edit",
		self.currentRevision,
		Fingerprints:serviceFingerprintsWire(),
		{ upserted = {}, removed = removed },
		nil
	)
	local ok, encoded = Transport.safeEncode(body, "tick-probe")
	if ok then
		return #encoded
	end
	return math.huge
end

-- VERBATIM behavior port of Live.collectOpsFromDirty (monolith :2810). Builds the
-- removed list from dirtyRemoved, then the upsert list from dirtyUpsert (skipping ids
-- already removed), depth-sorts ascending (parents before children — path/parent
-- ordering), and builds each entry, XOR-ing its fingerprint into the accumulator. The
-- E1 incremental cap (committedBytes + this entry's bytes > threshold AND at least one
-- committed) breaks with forward-progress, rolling the just-applied fingerprint back
-- (and restoring the previous fp) exactly as the monolith did. Returns the ops plus
-- the per-op stamps so clearSentDirty can do its no-data-loss clear.
local function collectOpsFromDirty(self: LiveModule): (
	{ InstanceEntry },
	{ string },
	{ [Instance]: number },
	{ [string]: number }
)
	local idByRef = Capture.instanceIdByRef
	local sentUpsertStamps: { [Instance]: number } = {}
	local sentRemovedStamps: { [string]: number } = {}
	local removed: { string } = {}
	for id in pairs(self.dirtyRemoved) do
		removed[#removed + 1] = id
		sentRemovedStamps[id] = self.removedStamp[id]
	end

	-- Build the depth-sorted upsert work list (parents first).
	type WorkItem = { inst: Instance, depth: number }
	local upsertList: { WorkItem } = {}
	for inst in pairs(self.dirtyUpsert) do
		local id = idByRef[inst]
		if id and not self.dirtyRemoved[id] then
			local depth = 0
			local p = inst.Parent
			while p and p ~= game do
				depth += 1
				p = p.Parent
			end
			upsertList[#upsertList + 1] = { inst = inst, depth = depth }
		end
	end
	table.sort(upsertList, function(a: WorkItem, b: WorkItem): boolean
		return a.depth < b.depth
	end)

	-- E1: measure the envelope once, then add each entry's encoded length + comma.
	local committedBytes = envelopeByteLen(self, removed)
	local upserted: { InstanceEntry } = {}

	for _, item in ipairs(upsertList) do
		local inst = item.inst
		if inst.Parent ~= nil then
			local entry, oldPath = Capture.buildUpsertedEntry(inst)
			if entry then
				local realEntry = entry :: InstanceEntry
				local prevFp = Fingerprints.instFp[realEntry.id]
				Fingerprints:applyFpUpsert(realEntry.id, realEntry, oldPath)

				-- Incremental size: this entry's own JSON + the comma that joins it to
				-- the array (1 byte; absorbs the array-bracket fixed cost into the
				-- envelope's empty `[]`, which the comma replacement covers). The break
				-- test mirrors shouldBreakOpsCap: over threshold AND already committed.
				local addedBytes = entryByteLen(realEntry) + 1
				local trialBytes = committedBytes + addedBytes
				if trialBytes > TICK_INLINE_THRESHOLD and #upserted > 0 then
					-- Roll back the fingerprint op for the entry we are NOT shipping,
					-- restoring the previous fp if there was one (verbatim monolith).
					Fingerprints:applyFpRemove(realEntry.id, realEntry.path)
					if prevFp then
						Fingerprints:applyFpUpsert(
							realEntry.id,
							{ fp = prevFp, path = oldPath or realEntry.path },
							oldPath
						)
					end
					break
				end
				committedBytes = trialBytes
				upserted[#upserted + 1] = realEntry
				sentUpsertStamps[inst] = self.upsertStamp[inst]
			else
				-- buildUpsertedEntry early-out (no parent / not found / mid-destroy):
				-- treat as removed if we still have an id.
				local id = idByRef[inst]
				if id then
					removed[#removed + 1] = id
					sentRemovedStamps[id] = self.removedStamp[id]
				end
			end
		else
			local id = idByRef[inst]
			if id then
				removed[#removed + 1] = id
				sentRemovedStamps[id] = self.removedStamp[id]
			end
		end
	end

	return upserted, removed, sentUpsertStamps, sentRemovedStamps
end

-- Stamp-based clear (the no-data-loss invariant). VERBATIM port of Live.clearSentDirty
-- (monolith :2878): only clear a dirty entry if its CURRENT stamp equals the stamp at
-- send time — an edit that re-marked it mid-tick bumped the stamp, so it stays dirty
-- and is re-sent next tick.
local function clearSentDirty(
	self: LiveModule,
	sentUpsertStamps: { [Instance]: number },
	sentRemovedStamps: { [string]: number }
): ()
	for inst, stamp in pairs(sentUpsertStamps) do
		if self.upsertStamp[inst] == stamp then
			self.dirtyUpsert[inst] = nil
			self.upsertStamp[inst] = nil
		end
	end
	for id, stamp in pairs(sentRemovedStamps) do
		if self.removedStamp[id] == stamp then
			self.dirtyRemoved[id] = nil
			self.removedStamp[id] = nil
		end
	end
end

-- == Tick body + query ==

-- VERBATIM port of Live.tickQuerySuffix (monolith :2372): placeId, URL-encoded.
local function tickQuerySuffix(_self: LiveModule): string
	return "placeId=" .. getHttpService():UrlEncode(tostring(game.PlaceId))
end

-- VERBATIM port of Live.buildTickBody (monolith :2376). The protocol-v2 tick body.
-- placeId is stringified (the daemon expects a string placeId on the wire).
local function buildTickBody(
	_self: LiveModule,
	placeId: any,
	sessionMode: SessionMode,
	baseRevision: number,
	serviceFingerprints: { [string]: Hex64 },
	ops: Ops,
	bulkRef: string?
): any
	return {
		placeId = tostring(placeId),
		sessionMode = sessionMode,
		baseRevision = baseRevision,
		serviceFingerprints = serviceFingerprints,
		ops = ops,
		bulkRef = bulkRef,
	}
end

-- == Baseline + bulk upload ==

-- Rebuild the per-service accumulators from the current walk maps WITHOUT producing a
-- snapshot. VERBATIM port of Live.initFingerprintsFromWalk (monolith :2955): reset,
-- then buildUpsertedEntry each live instance (which sets pathByRef + fp), XOR-ing into
-- the accumulator via the FP module, yielding every BASELINE_YIELD_EVERY.
local function initFingerprintsFromWalk(_self: LiveModule): ()
	Fingerprints:reset()
	local processed = 0
	for inst in pairs(Capture.instanceIdByRef) do
		if inst.Parent ~= nil then
			local entry, oldPath = Capture.buildUpsertedEntry(inst)
			if entry then
				local realEntry = entry :: InstanceEntry
				Fingerprints:applyFpUpsert(realEntry.id, realEntry, oldPath)
			end
			processed += 1
			if Capture.shouldYield(processed, BASELINE_YIELD_EVERY) then
				task.wait()
			end
		end
	end
end

-- Build a full baseline snapshot AND rebuild the accumulators from it. VERBATIM port
-- of Live.buildBaselineSnapshot (monolith :2969): reset, build the snapshot, then a
-- YIELDING loop (the Q1 fix — never stall the frame) that hashes each entry and XORs
-- it into the accumulator.
local function buildBaselineSnapshot(_self: LiveModule, reason: string?): any
	Fingerprints:reset()
	local snapshot = Capture.buildSnapshot({ reason = reason or "tick-baseline" })
	local processed = 0
	for _, entry in ipairs(snapshot.instances) do
		entry.fp = Hash.hashInstance(entry)
		Fingerprints:applyFpUpsert(entry.id, entry, nil)
		processed += 1
		if Capture.shouldYield(processed, BASELINE_YIELD_EVERY) then
			task.wait()
		end
	end
	return snapshot
end

-- Upload a pre-encoded baseline JSON via the chunked /tick/bulk channel. VERBATIM
-- port of Live.uploadTickBulk (monolith :2893): start -> chunk(s) -> complete, sending
-- the whole body in one chunk when it fits, else splitting by maxChunkBytes. Returns
-- (true, {syncId=...}) on success so the caller stages pendingBulkRef.
local function uploadTickBulk(self: LiveModule, jsonText: string, reason: string?): (boolean, any)
	local query = self:tickQuerySuffix()
	local http = getHttpService()
	local placeKey: string
	if game.PlaceId ~= 0 then
		placeKey = "Place" .. tostring(game.PlaceId)
	else
		placeKey = game.Name
	end
	local okStart, startResult = self.host.transport.requestJson(
		"POST",
		"/studio-stud/tick/bulk/start?" .. query,
		{
			pluginVersion = PLUGIN_VERSION,
			protocolVersion = PROTOCOL_VERSION,
			place = {
				placeId = game.PlaceId,
				placeKey = placeKey,
				name = game.Name,
			},
		}
	)
	if not okStart or not startResult or not startResult.syncId then
		return false, startResult
	end
	local syncId = startResult.syncId
	local maxChunk = tonumber(startResult.maxChunkBytes) or DEFAULT_BULK_CHUNK_BYTES
	if #jsonText <= maxChunk then
		local okBody = self.host.transport.requestBody(
			"/studio-stud/tick/bulk/chunk?" .. query .. "&syncId=" .. http:UrlEncode(syncId) .. "&index=0",
			jsonText
		)
		if not okBody then
			return false, { error = "bulk chunk failed" }
		end
	else
		local chunkCount = math.ceil(#jsonText / maxChunk)
		for index = 1, chunkCount do
			local startByte = ((index - 1) * maxChunk) + 1
			local chunk = string.sub(jsonText, startByte, startByte + maxChunk - 1)
			local okChunk = self.host.transport.requestBody(
				("/studio-stud/tick/bulk/chunk?%s&syncId=%s&index=%d"):format(
					query,
					http:UrlEncode(syncId),
					index - 1
				),
				chunk
			)
			if not okChunk then
				return false, { error = "bulk chunk failed", index = index }
			end
		end
	end
	local expectedChunks: number? = nil
	if #jsonText > maxChunk then
		expectedChunks = math.ceil(#jsonText / maxChunk)
	end
	local okComplete, completeResult = self.host.transport.requestJson(
		"POST",
		"/studio-stud/tick/bulk/complete?" .. query,
		{ syncId = syncId, expectedChunks = expectedChunks }
	)
	if not okComplete or not completeResult or completeResult.ok ~= true then
		return false, completeResult
	end
	debugLog("tick bulk staged:", reason or "bulk", syncId)
	return true, { syncId = syncId }
end

-- Trigger a full rebaseline spilled to /tick/bulk, committed on the next tick via
-- pendingBulkRef. VERBATIM port of Live.triggerFullBaseline (monolith :2991): guard
-- against re-entry (baselineInProgress / pendingBulkRef / not live / not edit), then
-- spawn the build+encode+upload off the caller's frame. Returns whether it started.
local function triggerFullBaseline(self: LiveModule, reason: string?): boolean
	if self.baselineInProgress or self.pendingBulkRef or not self.liveRunning then
		return false
	end
	if not Session.isEdit() then
		return false
	end
	self.baselineInProgress = true
	task.spawn(function()
		local snapshot = self:buildBaselineSnapshot(reason or "tick-baseline")
		local okEnc, jsonText = Transport.safeEncode(snapshot, "tick-baseline")
		if not okEnc then
			warn("[StudioStud] baseline encode failed:", tostring(jsonText))
			self.baselineInProgress = false
			return
		end
		local okBulk, bulkResult = self:uploadTickBulk(jsonText, reason or "tick-baseline")
		if okBulk and bulkResult and bulkResult.syncId then
			self.pendingBulkRef = bulkResult.syncId
			debugLog("baseline bulk staged, awaiting tick commit")
		else
			warn("[StudioStud] baseline bulk upload failed")
		end
		self.baselineInProgress = false
	end)
	return true
end

-- VERBATIM port of Live.triggerDriftRecovery (monolith :2984): same guards, then a
-- full rebaseline (delta-only recovery — no partial materialize).
local function triggerDriftRecovery(self: LiveModule, _driftServices: { string }?): boolean
	if self.baselineInProgress or self.pendingBulkRef or not self.liveRunning then
		return false
	end
	return self:triggerFullBaseline("drift-recovery")
end

-- VERBATIM port of Live.triggerRebaseline (monolith :2464): deferred teardown +
-- disconnect + full reconnect through the host (the orchestrator owns the handshake).
local function triggerRebaseline(self: LiveModule, reason: string?): ()
	task.defer(function()
		if self.liveRunning then
			self:teardown()
		end
		self.host.setConnected(false)
		self.host.setBaseline(false)
		self.host.setStatus("syncing", "Re-baselining...")
		warn("[StudioStud] re-baseline:", reason or "live-rebaseline")
		self.host.reconnect()
	end)
end

-- == The tick ==

-- VERBATIM port of Live.runTick (monolith :3019). Single tick: gate on live/in-flight;
-- on an edit tick with a pending history change, schedule a rebaseline; collect ops
-- (edit-only, and only when not committing a bulkRef); snapshot serviceFingerprints
-- AFTER op collection (the post-ops fix); POST; on ok, advance revision/count, commit
-- bulkRef, clear sent dirty (stamp-based), and handle drift/no_baseline; on repeated
-- failure (>=4) tear down and surface the offline status.
local function runTick(self: LiveModule, sessionMode: SessionMode?): ()
	if not self.liveRunning or self.syncInFlight or self.baselineInProgress then
		return
	end
	if sessionMode == "edit" and self.historyDirty then
		self.historyDirty = false
		self:triggerFullBaseline("history-change")
	end
	self.syncInFlight = true

	local mode: SessionMode
	if sessionMode then
		mode = sessionMode
	elseif Session.isEdit() then
		mode = "edit"
	else
		mode = "play"
	end

	local bulkRef = self.pendingBulkRef
	local upserted: { InstanceEntry } = {}
	local removed: { string } = {}
	local sentUpsertStamps: { [Instance]: number } = {}
	local sentRemovedStamps: { [string]: number } = {}
	if mode == "edit" and not bulkRef then
		upserted, removed, sentUpsertStamps, sentRemovedStamps = self:collectOpsFromDirty()
	end

	-- Post-ops: snapshot fingerprints AFTER collectOpsFromDirty has XOR'd this tick's
	-- entries into the accumulators (the Phase-5 ordering fix).
	local serviceFingerprints = Fingerprints:serviceFingerprintsWire()
	local ops: Ops = { upserted = upserted, removed = removed }
	local body = self:buildTickBody(game.PlaceId, mode, self.currentRevision, serviceFingerprints, ops, bulkRef)

	local okEnc, encoded = Transport.safeEncode(body, "tick")
	if not okEnc then
		warn("[StudioStud] tick encode failed:", tostring(encoded))
		self.syncInFlight = false
		return
	end

	local tickPath = "/studio-stud/tick?" .. self:tickQuerySuffix()
	local ok, result = self.host.transport.requestJson("POST", tickPath, body)
	if ok and result and result.ok then
		self.currentRevision = result.revision or self.currentRevision
		self.liveInstanceCount = result.instanceCount or self.liveInstanceCount
		self.networkErrorCount = 0
		if bulkRef then
			self.pendingBulkRef = nil
		end
		if mode == "edit" then
			self:clearSentDirty(sentUpsertStamps, sentRemovedStamps)
		end
		local drift = result.driftServices
		if type(drift) == "table" and #drift > 0 then
			debugLog("tick drift services:", table.concat(drift, ", "))
			self.recoveryServices = drift
			self:triggerDriftRecovery(drift)
		end
		if result.request then
			debugLog("tick request from daemon:", result.request)
		end
		self.host.setStatus("connected", "Live — tick sync active")
	elseif ok and result and result.error == "revision_mismatch" then
		warn("[StudioStud] tick revision_mismatch: server=", result.revision, "local=", self.currentRevision)
		if result.revision then
			self.currentRevision = result.revision
		end
	elseif ok and result and result.error == "no_baseline" then
		debugLog("tick no_baseline — scheduling full baseline")
		self:triggerFullBaseline("tick-no-baseline")
	elseif not ok or (result and result.ok == false) then
		self.networkErrorCount += 1
		local errText: any
		if result then
			errText = result.error or "no response"
		else
			errText = "no response"
		end
		warn("[StudioStud] tick error:", errText)
		if self.networkErrorCount >= 4 and not self.pendingBulkRef and not self.baselineInProgress then
			self:teardown()
			self.host.setConnected(false)
			self.host.setBaseline(false)
			self.host.setStatus("error", "Daemon offline — reconnecting automatically")
			self.host.setStats("")
		end
	end
	self.syncInFlight = false
end

-- == The fixed-interval tick loop ==

-- VERBATIM port of Live.startTickLoop (monolith :3172). ONE generation-guarded loop
-- (replacing the old 3): wait the debounce interval, re-check liveness/generation/
-- running, detect edit<->play transitions (entering play: stash revision/count, tear
-- down, idle status; returning to edit: defer onReturnToEditFn — the C2 path, now a
-- real injected function), keepalive-tick during play, and run an edit tick otherwise
-- with a pending-count stat line.
local function startTickLoop(
	self: LiveModule,
	pausedBaselineRef: { revision: number, instanceCount: number }?,
	onReturnToEditFn: (() -> ())?
): ()
	self.tickGeneration += 1
	local myTickGen = self.tickGeneration
	local lastSessionMode = Session.mode()
	task.spawn(function()
		while self.liveRunning and self.tickGeneration == myTickGen and self.host.isRunning() do
			local intervalSeconds = Settings.getDebounceMs() / 1000
			task.wait(intervalSeconds)
			if not self.liveRunning or self.tickGeneration ~= myTickGen or not self.host.isRunning() then
				break
			end
			local mode = Session.mode()
			if mode ~= lastSessionMode then
				lastSessionMode = mode
				if mode == "play" then
					if pausedBaselineRef then
						pausedBaselineRef.revision = self.currentRevision
						pausedBaselineRef.instanceCount = self.liveInstanceCount
					end
					self:teardown()
					self.host.setStatus("idle", "Paused — Studio in play session")
					self.host.setStats("")
					debugLog("session: entered play — live paused")
				else
					debugLog("session: returned to edit — scheduling catch-up")
					if onReturnToEditFn then
						task.defer(onReturnToEditFn)
					end
				end
			end
			if mode ~= "edit" or not self.liveRunning then
				if mode == "play" then
					local okTick, errTick = pcall(function()
						self:runTick("play")
					end)
					if not okTick then
						warn("[StudioStud] play keepalive error:", errTick)
					end
				end
				continue
			end
			local pending = 0
			for _ in pairs(self.dirtyUpsert) do
				pending += 1
			end
			for _ in pairs(self.dirtyRemoved) do
				pending += 1
			end
			local statsText = ("rev %d · %d instances"):format(self.currentRevision, self.liveInstanceCount)
			if pending > 0 then
				statsText = statsText .. (" · %d pending"):format(pending)
			end
			self.host.setStats(statsText)
			local okTick, errTick = pcall(function()
				self:runTick("edit")
			end)
			if not okTick then
				warn("[StudioStud] runTick error:", errTick)
			end
		end
	end)
end

-- == Connect / teardown / session transitions ==

-- Bring up live mode: reset, rebuild the walk maps + accumulators, wire per-instance
-- and root signals, and connect Selection/ChangeHistory globals. VERBATIM port of
-- Live.connectLiveMode (monolith :3099). Returns false (without arming) when live
-- capture is disabled in settings.
local function connectLiveMode(self: LiveModule): boolean
	if not Settings.getBool(SETTINGS.liveCaptureEnabled, true) then
		return false
	end
	self:teardown()
	self.liveRunning = true
	self.currentRevision = 0
	self.liveInstanceCount = 0
	self.pendingBulkRef = nil
	-- Capture owns the identity maps; collectBaseInstances rebuilds them fresh.
	Capture.collectBaseInstances()
	self:initFingerprintsFromWalk()
	for inst in pairs(Capture.instanceIdByRef) do
		self.parentByInst[inst] = inst.Parent
		self:registerInstance(inst)
	end
	for _, root in ipairs(Capture.getRootEntries()) do
		if root.includeDescendants then
			local rootInst = root.instance
			self.rootConns[#self.rootConns + 1] = rootInst.DescendantAdded:Connect(function(child: Instance)
				self:onDescendantAdded(child)
			end)
			self.rootConns[#self.rootConns + 1] = rootInst.DescendantRemoving:Connect(function(child: Instance)
				self:onDescendantRemoving(child)
			end)
		end
	end
	local selOk, selConn = pcall(function()
		local Selection = game:GetService("Selection")
		return Selection.SelectionChanged:Connect(function()
			local okSel, selected = pcall(function()
				return Selection:Get()
			end)
			if okSel then
				for _, inst in ipairs(selected) do
					if Capture.instanceIdByRef[inst] then
						self:markDirtyUpsert(inst)
					end
				end
			end
		end)
	end)
	if selOk then
		self.globalConns[#self.globalConns + 1] = selConn
	end
	local changeHistory = game:GetService("ChangeHistoryService")
	local undoOk, undoConn = pcall(function()
		return changeHistory.OnUndo:Connect(function()
			self.historyDirty = true
		end)
	end)
	if undoOk then
		self.globalConns[#self.globalConns + 1] = undoConn
	end
	local redoOk, redoConn = pcall(function()
		return changeHistory.OnRedo:Connect(function()
			self.historyDirty = true
		end)
	end)
	if redoOk then
		self.globalConns[#self.globalConns + 1] = redoConn
	end
	self.host.setStatus("connected", "Live — tick sync active")
	self.host.setStats(("rev %d · %d instances"):format(self.currentRevision, self.liveInstanceCount))
	return true
end

-- VERBATIM port of Live.setupAfterBaseline (monolith :3272): arm live mode and seed
-- revision/count from the materialized baseline result.
local function setupAfterBaseline(self: LiveModule, materialized: any?): ()
	if self:connectLiveMode() then
		self.currentRevision = (materialized and materialized.revision) or 0
		self.liveInstanceCount = (materialized and (materialized.instances or materialized.totalItems)) or 0
	end
end

-- Tear down all live state and disconnect everything. VERBATIM port of Live.teardown
-- (monolith :3235): disconnect root/global/per-instance connections, clear every
-- dirty/stamp/parent map, reset fingerprints, bump the tick generation so any running
-- loop exits on its next guard check.
local function teardown(self: LiveModule): ()
	self.liveRunning = false
	for _, conn in ipairs(self.rootConns) do
		pcall(function()
			conn:Disconnect()
		end)
	end
	self.rootConns = {}
	for _, conn in ipairs(self.globalConns) do
		pcall(function()
			conn:Disconnect()
		end)
	end
	self.globalConns = {}
	for _, conns in pairs(self.instConns) do
		for _, conn in ipairs(conns) do
			pcall(function()
				conn:Disconnect()
			end)
		end
	end
	self.instConns = {}
	self.dirtyUpsert = {}
	self.networkErrorCount = 0
	self.dirtyRemoved = {}
	self.parentByInst = {}
	self.currentRevision = 0
	self.liveInstanceCount = 0
	self.verifyNeeded = false
	Fingerprints:reset()
	self.pendingBulkRef = nil
	self.upsertStamp = {}
	self.removedStamp = {}
	self.tickGeneration += 1
end

-- == Module table ==

-- Assembled as a real value before return; the state tables start empty and every
-- method reaches state/siblings through `self`/module refs, so there is no
-- forward-reference-before-local read anywhere. The host starts as the no-op stub so a
-- pre-attach call is a safe no-op (the C3 cure).
Live = {
	liveRunning = false,
	currentRevision = 0,
	liveInstanceCount = 0,
	networkErrorCount = 0,
	syncInFlight = false,
	verifyNeeded = false,
	dirtyStamp = 0,
	dirtyUpsert = {},
	dirtyRemoved = {},
	upsertStamp = {},
	removedStamp = {},
	parentByInst = {},
	instConns = {},
	rootConns = {},
	globalConns = {},
	propGaps = {},
	pendingBulkRef = nil,
	baselineInProgress = false,
	recoveryServices = nil,
	tickGeneration = 0,
	historyDirty = false,

	host = NOOP_HOST,
	attach = attach,

	markDirtyUpsert = markDirtyUpsert,
	markDirtyRemoved = markDirtyRemoved,
	markSubtreeUpsert = markSubtreeUpsert,
	markSiblingsDirty = markSiblingsDirty,

	classifyChangedProp = classifyChangedProp,
	recordPropGap = recordPropGap,
	onNameChanged = onNameChanged,

	registerInstance = registerInstance,
	unregisterInstance = unregisterInstance,
	unregisterSubtree = unregisterSubtree,
	onDescendantAdded = onDescendantAdded,
	onDescendantRemoving = onDescendantRemoving,

	collectOpsFromDirty = collectOpsFromDirty,
	clearSentDirty = clearSentDirty,

	tickQuerySuffix = tickQuerySuffix,
	buildTickBody = buildTickBody,

	initFingerprintsFromWalk = initFingerprintsFromWalk,
	buildBaselineSnapshot = buildBaselineSnapshot,
	uploadTickBulk = uploadTickBulk,
	triggerFullBaseline = triggerFullBaseline,
	triggerDriftRecovery = triggerDriftRecovery,
	triggerRebaseline = triggerRebaseline,

	runTick = runTick,
	startTickLoop = startTickLoop,

	connectLiveMode = connectLiveMode,
	setupAfterBaseline = setupAfterBaseline,
	teardown = teardown,
}

return Live
