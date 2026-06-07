--!strict
-- Headless test for the Live engine's PURE / DataModel-free behaviors — the C1-C3
-- regression guards plus the dirty-stamp no-data-loss invariant, the classifyChangedProp
-- truth table (the ~= nil membership fix), and the tick-body wire shape. The signal
-- wiring, the walk, and the network paths need a real DataModel and run only in the
-- Studio SelfTest gate; here we pin the logic that can be exercised without `game`.
--
-- Run:
--   lune run plugin/src/__tests__/Live.spec.luau

local Live = require("../Live")
local Transport = require("../Transport")

local failures = 0
local function check(label: string, cond: boolean)
	if not cond then
		failures += 1
		print("FAIL: " .. label)
	else
		print("ok: " .. label)
	end
end

-- The dirty maps are keyed by Instance in Studio; headless we use plain string handles
-- as stand-in keys (runtime table keys, type-checking off at runtime). Cast through any
-- so the typed methods accept them.
local function inst(name: string): any
	return name
end

-- ============================================================================
-- Public interface presence
-- ============================================================================
check("dirtyUpsert starts a table", type(Live.dirtyUpsert) == "table")
check("dirtyRemoved starts a table", type(Live.dirtyRemoved) == "table")
check("upsertStamp starts a table", type(Live.upsertStamp) == "table")
check("removedStamp starts a table", type(Live.removedStamp) == "table")
check("markDirtyUpsert is a function", type(Live.markDirtyUpsert) == "function")
check("classifyChangedProp is a function", type(Live.classifyChangedProp) == "function")
check("clearSentDirty is a function", type(Live.clearSentDirty) == "function")
check("buildTickBody is a function", type(Live.buildTickBody) == "function")
check("attach is a function", type(Live.attach) == "function")
check("host stub present before attach", type(Live.host) == "table")

-- ============================================================================
-- C1 REGRESSION: markDirtyUpsert sets dirtyUpsert[inst]=true and stamps it WITHOUT
-- recursion (the buggy monolith version called itself). A recursive self-call would
-- stack-overflow; reaching the assertions at all proves no recursion, and we verify
-- the exact state writes + monotonic stamp.
-- ============================================================================
do
	Live.dirtyUpsert = {}
	Live.upsertStamp = {}
	Live.dirtyStamp = 0
	local a = inst("A")
	local b = inst("B")
	Live:markDirtyUpsert(a)
	check("C1: dirtyUpsert[a] == true", Live.dirtyUpsert[a] == true)
	check("C1: stamp bumped to 1", Live.dirtyStamp == 1)
	check("C1: upsertStamp[a] == 1", Live.upsertStamp[a] == 1)
	Live:markDirtyUpsert(b)
	check("C1: stamp bumped to 2", Live.dirtyStamp == 2)
	check("C1: upsertStamp[b] == 2", Live.upsertStamp[b] == 2)
	-- Re-marking a bumps the stamp (the mid-tick edit signal).
	Live:markDirtyUpsert(a)
	check("C1: re-mark a bumps stamp to 3", Live.dirtyStamp == 3)
	check("C1: upsertStamp[a] updated to 3", Live.upsertStamp[a] == 3)
end

-- ============================================================================
-- markDirtyRemoved stamps the removed id the same way.
-- ============================================================================
do
	Live.dirtyRemoved = {}
	Live.removedStamp = {}
	Live.dirtyStamp = 0
	Live:markDirtyRemoved("id1")
	check("markDirtyRemoved sets dirtyRemoved[id1]", Live.dirtyRemoved.id1 == true)
	check("markDirtyRemoved stamps id1", Live.removedStamp.id1 == 1)
end

-- ============================================================================
-- classifyChangedProp truth table (the ~= nil membership fix). curatedSet maps
-- propName -> readOnly; a WRITABLE curated prop is `false`, which is still membership,
-- so it must classify as "dirty" (truthiness would have dropped it). Name -> name,
-- Source -> dirty (PluginSecurity special-case), uncurated -> gap.
-- ============================================================================
do
	local curated = {
		Anchored = false, -- writable curated prop: the bug-prone case
		ClassName = true, -- read-only curated prop
	}
	check("classify Name -> name", Live:classifyChangedProp("Name", curated) == "name")
	check("classify Source -> dirty", Live:classifyChangedProp("Source", curated) == "dirty")
	check("classify writable curated (false) -> dirty", Live:classifyChangedProp("Anchored", curated) == "dirty")
	check("classify read-only curated (true) -> dirty", Live:classifyChangedProp("ClassName", curated) == "dirty")
	check("classify uncurated -> gap", Live:classifyChangedProp("Transparency", curated) == "gap")
end

-- ============================================================================
-- clearSentDirty: stamp-based no-data-loss. An entry whose stamp is unchanged since
-- send is cleared; an entry re-marked mid-tick (stamp bumped) stays dirty.
-- ============================================================================
do
	Live.dirtyUpsert = {}
	Live.upsertStamp = {}
	Live.dirtyRemoved = {}
	Live.removedStamp = {}
	Live.dirtyStamp = 0
	local a = inst("A")
	local b = inst("B")
	Live:markDirtyUpsert(a) -- stamp 1
	Live:markDirtyUpsert(b) -- stamp 2
	-- Capture the stamps we "sent".
	local sentUpsert = { [a] = Live.upsertStamp[a], [b] = Live.upsertStamp[b] }
	-- Mid-tick: a is edited again (stamp bumped); b is untouched.
	Live:markDirtyUpsert(a) -- stamp 3, upsertStamp[a] = 3 (differs from sent 1)
	Live:markDirtyRemoved("r1")
	local sentRemoved = { r1 = Live.removedStamp.r1 }
	Live:clearSentDirty(sentUpsert, sentRemoved)
	check("no-data-loss: re-marked a stays dirty", Live.dirtyUpsert[a] == true)
	check("no-data-loss: unchanged b is cleared", Live.dirtyUpsert[b] == nil)
	check("no-data-loss: b stamp cleared", Live.upsertStamp[b] == nil)
	check("no-data-loss: a stamp retained", Live.upsertStamp[a] == 3)
	check("no-data-loss: removed r1 cleared (stamp matched)", Live.dirtyRemoved.r1 == nil)
end

-- ============================================================================
-- buildTickBody: the protocol-v2 wire shape. placeId stringified; fields pass through.
-- ============================================================================
do
	local fps = { Workspace = string.rep("0", 64) }
	local ops = { upserted = {}, removed = { "x" } }
	local body = Live:buildTickBody(12345, "edit", 7, fps, ops, nil)
	check("buildTickBody: placeId stringified", body.placeId == "12345")
	check("buildTickBody: sessionMode", body.sessionMode == "edit")
	check("buildTickBody: baseRevision", body.baseRevision == 7)
	check("buildTickBody: serviceFingerprints passthrough", body.serviceFingerprints == fps)
	check("buildTickBody: ops passthrough", body.ops == ops)
	check("buildTickBody: bulkRef nil", body.bulkRef == nil)
	local body2 = Live:buildTickBody(0, "play", 0, fps, ops, "sync-99")
	check("buildTickBody: bulkRef set", body2.bulkRef == "sync-99")
	check("buildTickBody: play mode", body2.sessionMode == "play")
end

-- ============================================================================
-- C3 REGRESSION: a host call BEFORE attach() routes through the no-op stub and does
-- NOT nil-call (the monolith's Sync()-before-live path nil-called a forward upvalue).
-- The stub's isConnected/isRunning return safe defaults; transport returns a failure
-- shape rather than throwing.
-- ============================================================================
do
	-- Fresh module state is the no-op host; calling through it must not throw.
	local okStatus = pcall(function()
		Live.host.setStatus("idle", "pre-attach")
		Live.host.setStats("")
		Live.host.setConnected(false)
		Live.host.setBaseline(false)
	end)
	check("C3: pre-attach host calls do not throw", okStatus)
	check("C3: stub isConnected() == false", Live.host.isConnected() == false)
	check("C3: stub isRunning() == true", Live.host.isRunning() == true)
	local okT, resT = Live.host.transport.requestJson("GET", "/x", nil)
	check("C3: stub transport returns (false, failure)", okT == false and type(resT) == "table")

	-- attach() swaps the host; a subsequent call hits the injected one (the C2 path —
	-- the orchestrator's real collaborator is now wired, not a nil upvalue).
	local seen = { status = false }
	local fakeHost: any = {
		transport = {
			requestJson = function(): (boolean, any)
				return true, { ok = true }
			end,
			requestBody = function(): (boolean, any)
				return true, {}
			end,
		},
		setStatus = function(_k: string, _m: string)
			seen.status = true
		end,
		setStats = function(_t: string) end,
		setConnected = function(_c: boolean) end,
		isConnected = function(): boolean
			return true
		end,
		setBaseline = function(_b: boolean) end,
		reconnect = function() end,
		isRunning = function(): boolean
			return true
		end,
	}
	Live:attach(fakeHost)
	check("C2: attach swaps host (isConnected now true)", Live.host.isConnected() == true)
	Live.host.setStatus("connected", "live")
	check("C2: injected setStatus is invoked", seen.status == true)
end

-- ============================================================================
-- Tick resilience: no HTTP during baseline upload; no teardown during recovery.
-- ============================================================================
do
	require("./testRoblox")()

	local requestCount = 0
	local fakeHost: any = {
		transport = {
			requestJson = function(): (boolean, any)
				requestCount += 1
				return true, { ok = true, revision = 0, instanceCount = 0 }
			end,
			requestBody = function(): (boolean, any)
				return true, {}
			end,
		},
		setStatus = function(_k: string, _m: string) end,
		setStats = function(_t: string) end,
		setConnected = function(_c: boolean) end,
		isConnected = function(): boolean
			return true
		end,
		setBaseline = function(_b: boolean) end,
		reconnect = function() end,
		isRunning = function(): boolean
			return true
		end,
	}
	Live:attach(fakeHost)

	-- baselineInProgress=true -> runTick is a no-op (no requestJson, dirty untouched).
	Live.liveRunning = true
	Live.syncInFlight = false
	Live.baselineInProgress = true
	Live.historyDirty = false
	Live.dirtyUpsert = {}
	Live.dirtyRemoved = {}
	local a = inst("tick-guard-A")
	Live:markDirtyUpsert(a)
	local countBefore = requestCount
	Live:runTick("edit")
	check("baselineInProgress: requestJson not called", requestCount == countBefore)
	check("baselineInProgress: dirty set untouched", Live.dirtyUpsert[a] == true)

	-- pendingBulkRef + ConnectFail -> no teardown; networkErrorCount still increments.
	-- lune's HttpService lacks JSONEncode/UrlEncode; stub the wire helpers so runTick
	-- reaches requestJson.
	local savedEncode = Transport.safeEncode
	local savedSuffix = Live.tickQuerySuffix
	Transport.safeEncode = function(): (boolean, string)
		return true, "{}"
	end
	Live.tickQuerySuffix = function(): string
		return "placeId=0"
	end
	Live.baselineInProgress = false
	Live.pendingBulkRef = "sync-test"
	Live.networkErrorCount = 3
	Live.syncInFlight = false
	requestCount = 0
	fakeHost.transport.requestJson = function(): (boolean, any)
		requestCount += 1
		return false, nil
	end
	Live:runTick("edit")
	Transport.safeEncode = savedEncode
	Live.tickQuerySuffix = savedSuffix
	check("recovery: requestJson called once", requestCount == 1)
	check("recovery: liveRunning stays true", Live.liveRunning == true)
	check("recovery: networkErrorCount incremented to 4", Live.networkErrorCount == 4)

	-- Reset module state so later specs (if any) see a clean slate.
	Live.liveRunning = false
	Live.pendingBulkRef = nil
	Live.networkErrorCount = 0
	Live.baselineInProgress = false
	Live.syncInFlight = false
end

if failures == 0 then
	print("ALL LIVE TESTS PASSED")
else
	print(("%d FAILURE(S)"):format(failures))
	error("Live.spec failed", 0)
end
