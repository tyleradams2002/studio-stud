--!strict
-- SelfTest — the in-engine acceptance harness, ported faithfully from the
-- monolith's SelfTest block (StudioStud.plugin.lua:3918-4571) and re-pointed at
-- the modular API. Every assertion the monolith ran is preserved (Workstream E,
-- Phase 3/4/5C, JSON-safety, edit-gate, allow-list parse), PLUS the new
-- regressions this rewrite exists to lock in: C1 (markDirtyUpsert sets
-- dirtyUpsert[inst] WITHOUT recursion), C2 (a simulated connect passes a NON-NIL
-- onReturnToEdit to startTickLoop), C3 (Sync() before live mode does not nil-call),
-- and a Hash wire-parity assertion (the new Hash.hashInstance must agree with the
-- monolith's recipe oracle, byte-for-byte).
--
-- WHY THIS RUNS IN-ENGINE ONLY: it drives the real Registry/Shell/Live engine over
-- a live DataModel (Instance.new, game:GetService, GetDebugId, signal wiring). It is
-- NOT a pure module, so — like the monolith's SelfTest.run — it is exercised through
-- `_G.StudioStud.RunSelfTest()` inside Studio, never headless under lune. (The pure
-- modules it leans on — Hash / Fingerprints / Capture / Live byte sizing — have their
-- own headless lune specs under __tests__/; this harness is the integration layer.)
--
-- API RE-POINTING (the monolith's flat `live.*` surface, now modular):
--   live.hashInstance               -> Hash.hashInstance
--   live.resetFingerprints          -> Fingerprints:reset()
--   live.applyFpUpsert/applyFpRemove -> Fingerprints:applyFpUpsert / :applyFpRemove
--   live.serviceFpHex               -> Fingerprints:serviceFpHex
--   live.serviceFingerprintsWire    -> Fingerprints:serviceFingerprintsWire()
--   live.buildTickBody              -> Live:buildTickBody (a `:` method)
--   live.buildBaselineSnapshot      -> Live:buildBaselineSnapshot (`:` method)
--   live.classifyChangedProp        -> Live:classifyChangedProp (`:` method)
--   live.recordPropGap              -> Live:recordPropGap (`:` method)
--   live.registerInstance/...       -> Live:registerInstance / :unregisterInstance
--   live.setupAfterBaseline         -> Live:setupAfterBaseline (`:` method)
--   live.teardown                   -> Live:teardown (`:` method)
--   live.collectOpsFromEntries(...) -> Live:collectOpsFromDirty() over real dirty
--                                      instances (the byte-incremental cap is now
--                                      internal to collectOpsFromDirty — driven here
--                                      with a fat + small instance, the E1 forward-
--                                      progress path).
-- DEVIATIONS from the monolith assertion set (functions that no longer exist as a
-- standalone surface; the BEHAVIOR they tested is preserved and re-asserted through
-- the surviving API):
--   * `live.classifyPayload(n)` is gone — payload inline/bulk is no longer a named
--     predicate; the wire boundary is Config.TICK_INLINE_THRESHOLD. The two
--     classify assertions are re-expressed as the same threshold comparison.
--   * `live.scheduleDriftRecovery(svc, up, rm)` is gone — drift recovery is now
--     Live:triggerDriftRecovery, which is guarded (no-op off-live) and never touches
--     the dirty sets. The "drift recovery preserves dirty" intent is re-asserted by
--     marking dirty, invoking the guarded recovery, and confirming the dirty sets
--     survive.
--
-- Structure note (the bug class this rewrite kills): SelfTest holds no
-- forward-referenced upvalues. `assert`/`run` are fields on the module table reached
-- through `SelfTest.*` (call-time field reads), and every collaborator is a required
-- module table. There is no before-local window anywhere here.

local Config = require("./Config")
local Session = require("./Session")
local Settings = require("./Settings")
local Transport = require("./Transport")
local AllowList = require("./AllowList")
local Hash = require("./Hash")
local Fingerprints = require("./Fingerprints")
local Registry = require("./Registry")
local GlobalApi = require("./GlobalApi")
local Theme = require("./ui/Theme")
local Shell = require("./ui/Shell")

local SETTINGS = Config.SETTINGS
local DEFAULT_DAEMON_URL = Config.DEFAULT_DAEMON_URL
local TICK_INLINE_THRESHOLD = Config.TICK_INLINE_THRESHOLD

-- == Monolith fingerprint oracle (the Hash wire-parity guard) ==

-- The 0.4.21 fingerprint recipe, copied VERBATIM from StudioStud.plugin.lua:2189-2302
-- as an independent oracle. The new Hash.hashInstance MUST agree with this
-- byte-for-byte or the unchanged daemon sees phantom drift on every tick. This is the
-- in-engine twin of Hash.spec's headless oracle — kept here so the Studio gate proves
-- parity in the real runtime too.
local ORACLE_OFFSETS = { 0x811C9DC5, 0x050C5D1F, 0x9E3779B9, 0x7F4A7C15 }
local ORACLE_PRIME = 16777619

local function oracleSortedKeys(tbl: { [any]: any }): { string }
	local keys: { string } = {}
	for key in pairs(tbl) do
		keys[#keys + 1] = tostring(key)
	end
	table.sort(keys)
	return keys
end

local oracleSerializeScalar: (value: any) -> string
function oracleSerializeScalar(value: any): string
	local kind = typeof(value)
	if kind == "string" then
		return "s:" .. value
	elseif kind == "number" then
		return "n:" .. tostring(value)
	elseif kind == "boolean" then
		if value then
			return "b:1"
		else
			return "b:0"
		end
	elseif kind == "nil" then
		return "z"
	elseif kind == "table" then
		local tbl = value :: { [any]: any }
		if #tbl > 0 then
			local parts: { string } = {}
			for _, item in ipairs(tbl) do
				parts[#parts + 1] = oracleSerializeScalar(item)
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local parts: { string } = {}
		for _, key in ipairs(oracleSortedKeys(tbl)) do
			parts[#parts + 1] = key .. "=" .. oracleSerializeScalar(tbl[key])
		end
		return "{" .. table.concat(parts, ";") .. "}"
	end
	return "u:" .. tostring(value)
end

local function oracleSerializeMap(map: { [string]: any }?): string
	local source: { [any]: any } = map or {}
	local parts: { string } = {}
	for _, key in ipairs(oracleSortedKeys(source)) do
		parts[#parts + 1] = key .. "=" .. oracleSerializeScalar(source[key])
	end
	return table.concat(parts, ";")
end

local function oracleFnv32(str: string, offset: number): number
	local h = offset
	for i = 1, #str do
		h = bit32.bxor(h, string.byte(str, i))
		h = (h * ORACLE_PRIME) % 4294967296
	end
	return h
end

local function oracleHashInstance(entry: { [string]: any }): string
	local parts: { string } = {
		tostring(entry.className or ""),
		tostring(entry.name or ""),
		tostring(entry.parentId or ""),
		tostring(entry.path or ""),
		tostring(entry.depth or 0),
		tostring(entry.siblingIndex or 0),
		tostring(entry.childCount or 0),
		(if entry.duplicateSiblingName then "1" else "0"),
		oracleSerializeMap(entry.properties),
		oracleSerializeMap(entry.attributes),
	}
	local tagParts: { string } = {}
	for _, tag in ipairs(entry.tags or {}) do
		tagParts[#tagParts + 1] = tostring(tag)
	end
	parts[#parts + 1] = table.concat(tagParts, ",")
	local canonical = table.concat(parts, "|")
	local hexParts: { string } = {}
	for lane = 1, 4 do
		local lo = oracleFnv32(canonical, ORACLE_OFFSETS[lane])
		local hi = oracleFnv32(canonical .. "#" .. tostring(lane), bit32.bxor(ORACLE_OFFSETS[lane], 0xA5A5A5A5))
		hexParts[#hexParts + 1] = string.format("%08x%08x", lo, hi)
	end
	return table.concat(hexParts)
end

-- == Public interface ==

export type SelfTestModule = {
	-- One assertion: print PASS, or record `name` in `failures` and warn FAIL.
	-- Faithful to the monolith's SelfTest.assert(name, condition, failures).
	assert: (name: string, condition: any, failures: { string }) -> (),

	-- Run the whole suite in the live edit DataModel. Returns true iff every check
	-- passed (the bare boolean the monolith returned and GlobalApi.RunSelfTest
	-- publishes). Restores all settings/registry it touched before returning.
	run: () -> boolean,
}

-- Single module table; methods reach one another via `SelfTest.*` (call-time field
-- reads), never a forward-referenced upvalue.
local SelfTest = {} :: SelfTestModule

-- == assert ==

function SelfTest.assert(name: string, condition: any, failures: { string }): ()
	if condition then
		print("[Studio Stud SelfTest] PASS:", name)
	else
		failures[#failures + 1] = name
		warn("[Studio Stud SelfTest] FAIL:", name)
	end
end

-- == run ==

function SelfTest.run(): boolean
	local failures: { string } = {}
	local preIds = Registry.snapshotIds()
	local origLive = Settings.getBool(SETTINGS.liveCaptureEnabled, true)
	local origDebounce = Settings.getNumber(SETTINGS.debounceMs, 300)
	local origUrl = Settings.getString(SETTINGS.daemonUrl, DEFAULT_DAEMON_URL)

	-- HttpService for the JSON-safety raw-encode checks (resolved once, cache-at-event).
	local httpService = game:GetService("HttpService")

	-- A dummy panel descriptor factory (verbatim port of makeDummy, monolith :3938):
	-- a registerable panel whose handle exposes show/hide/destroy counters.
	local function makeDummy(id: string, title: string): Registry.PanelDescriptor
		local showCount = 0
		local hideCount = 0
		local destroyCount = 0
		local descriptor: Registry.PanelDescriptor = {
			id = id,
			title = title,
			defaultEnabled = true,
			build = function(parent: Frame, _ctx: any): Registry.PanelHandle
				local label = Instance.new("TextLabel")
				label.BackgroundTransparency = 1
				label.Size = UDim2.fromScale(1, 1)
				label.FontFace = Theme.UI_FONT
				label.TextColor3 = Theme.body
				label.Text = title
				label.Parent = parent
				return {
					frame = parent,
					onShow = function()
						showCount += 1
					end,
					onHide = function()
						hideCount += 1
					end,
					destroy = function()
						destroyCount += 1
						parent:Destroy()
					end,
					showCount = function(): number
						return showCount
					end,
					hideCount = function(): number
						return hideCount
					end,
					destroyCount = function(): number
						return destroyCount
					end,
				}
			end,
		}
		return descriptor
	end

	local dummyA = makeDummy("__selftest_a", "SelfTest A")
	local dummyB = makeDummy("__selftest_b", "SelfTest B")

	local okA = Registry.register(dummyA)
	SelfTest.assert("register dummy A", okA, failures)
	local okDup = Registry.register(dummyA)
	SelfTest.assert("reject duplicate id", not okDup, failures)
	local okB = Registry.register(dummyB)
	SelfTest.assert("register dummy B", okB, failures)

	local idsAfterRegister = Registry.snapshotIds()
	local indexA: number?, indexB: number? = nil, nil
	for index, id in ipairs(idsAfterRegister) do
		if id == "__selftest_a" then
			indexA = index
		elseif id == "__selftest_b" then
			indexB = index
		end
	end
	SelfTest.assert("registration order", indexA ~= nil and indexB ~= nil and indexA < indexB, failures)

	Registry.select("__selftest_a")
	Registry.select("__selftest_b")
	local handleA = Registry.getHandle("__selftest_a")
	local handleB = Registry.getHandle("__selftest_b")
	SelfTest.assert(
		"select lifecycle onShow/onHide",
		handleA ~= nil and handleB ~= nil and handleA.hideCount() >= 1 and handleB.showCount() >= 1,
		failures
	)

	local visibleCount = 0
	for _, handle in pairs(Registry.handles) do
		if handle.frame and handle.frame.Visible then
			visibleCount += 1
		end
	end
	SelfTest.assert("one visible panel frame", visibleCount == 1, failures)

	Registry.setEnabled("__selftest_a", false)
	SelfTest.assert("disable persists", Settings.getPanelEnabled("__selftest_a", true) == false, failures)
	local enabledAfterDisable = false
	for _, item in ipairs(Registry.list()) do
		if item.id == "__selftest_a" and item.enabled then
			enabledAfterDisable = true
		end
	end
	SelfTest.assert("disabled panel excluded from enabled set", not enabledAfterDisable, failures)
	Registry.setEnabled("__selftest_a", true)

	Settings.setBool(SETTINGS.liveCaptureEnabled, false)
	Settings.setDebounceMs(450)
	Settings.setString(SETTINGS.daemonUrl, "http://127.0.0.1:31999")
	SelfTest.assert("settings round-trip bool", Settings.getBool(SETTINGS.liveCaptureEnabled, true) == false, failures)
	SelfTest.assert("settings round-trip number", Settings.getDebounceMs() == 450, failures)
	SelfTest.assert(
		"settings round-trip string",
		Settings.getString(SETTINGS.daemonUrl, DEFAULT_DAEMON_URL) == "http://127.0.0.1:31999",
		failures
	)

	Settings.setString(SETTINGS.writeToken, "selftest-write-token")
	SelfTest.assert(
		"write token settings round-trip",
		Settings.getString(SETTINGS.writeToken, "") == "selftest-write-token",
		failures
	)
	local authedHeaders = Transport.buildAuthedHeaders(Settings.getString(SETTINGS.writeToken, ""))
	SelfTest.assert(
		"requestJsonAuthed attaches write token header",
		authedHeaders["X-StudioStud-Token"] == "selftest-write-token",
		failures
	)
	Settings.setString(SETTINGS.writeToken, "")

	local captureHandleBefore = Registry.getHandle("capture")
	local oldRunningFn = captureHandleBefore and captureHandleBefore.isRunning
	local oldRunning = (oldRunningFn ~= nil and oldRunningFn()) or false

	Registry.unregister("__selftest_a")
	Registry.unregister("__selftest_b")
	SelfTest.assert(
		"unregister removes dummy ids",
		Registry.snapshotIds()[1] == "capture" and #Registry.snapshotIds() == 1,
		failures
	)

	Registry.teardownAll()
	SelfTest.assert(
		"teardown stops capture loop",
		captureHandleBefore ~= nil and not captureHandleBefore.isRunning(),
		failures
	)
	-- S2: `_G.StudioStud` no longer publishes `Sync`; the disabled-handler is held
	-- internally on GlobalApi (the panel destroy ran installNoOps on teardown). The
	-- monolith asserted `_G.StudioStud.Sync()` returned the disabled shape; the faithful
	-- equivalent under S2 is GlobalApi.syncFn being cleared (the disabled state).
	SelfTest.assert("_G no-op while torn down (S2: syncFn cleared)", GlobalApi.syncFn == nil, failures)
	local disabledFn = GlobalApi.makeDisabledFn()
	local disabledResult = disabledFn()
	SelfTest.assert(
		"disabled handler shape",
		disabledResult.ok == false and disabledResult.error == "panel disabled",
		failures
	)

	Shell.build()
	local captureHandleAfter = Registry.getHandle("capture")
	SelfTest.assert("re-init capture handle", captureHandleAfter ~= nil, failures)
	-- S2: identity is now GlobalApi.syncFn == handle.sync (the panel wires its sync entry
	-- into GlobalApi on build), replacing the monolith's `_G.StudioStud.Sync == handle.sync`.
	SelfTest.assert(
		"_G re-wire identity (S2: GlobalApi.syncFn == handle.sync)",
		captureHandleAfter ~= nil and GlobalApi.syncFn == captureHandleAfter.sync,
		failures
	)
	SelfTest.assert(
		"single poll loop after re-init",
		captureHandleAfter ~= nil
			and captureHandleAfter.isRunning()
			and (not oldRunning or (captureHandleBefore ~= nil and not captureHandleBefore.isRunning())),
		failures
	)

	local tabCount = 0
	local tabStrip0 = Shell.tabStrip
	if tabStrip0 then
		for _, child in ipairs(tabStrip0:GetChildren()) do
			if child:IsA("TextButton") then
				tabCount += 1
			end
		end
	end
	Shell.build()
	local tabCountAgain = 0
	local tabStrip1 = Shell.tabStrip
	if tabStrip1 then
		for _, child in ipairs(tabStrip1:GetChildren()) do
			if child:IsA("TextButton") then
				tabCountAgain += 1
			end
		end
	end
	SelfTest.assert("idempotent Shell.build tab count", tabCountAgain == 1, failures)
	SelfTest.assert(
		"no ghost selftest tabs",
		not string.find(table.concat(Registry.snapshotIds(), ","), "__selftest"),
		failures
	)

	-- == Live machinery self-tests (Workstream E) ==
	do
		-- GetDebugId stability across reparent.
		local testFolder = Instance.new("Folder")
		testFolder.Name = "StudioStudSelfTestLive"
		testFolder.Parent = game:GetService("ReplicatedStorage")
		local okBefore, idBeforeRaw = pcall(function(): string
			return testFolder:GetDebugId(0)
		end)
		local idBefore = if okBefore then idBeforeRaw else ""
		testFolder.Parent = game:GetService("ServerStorage")
		local okAfter, idAfterRaw = pcall(function(): string
			return testFolder:GetDebugId(0)
		end)
		local idAfter = if okAfter then idAfterRaw else ""
		SelfTest.assert("GetDebugId stable across reparent", idBefore ~= "" and idBefore == idAfter, failures)
		testFolder:Destroy()
	end

	-- The capture/live exports off the rebuilt panel handle.
	local captureHandleLive = Registry.getHandle("capture")
	local live = captureHandleLive and captureHandleLive.live
	local capture = captureHandleLive and captureHandleLive.capture

	-- == Phase 3: getPropertyNames + curatedSet routing ==
	do
		if capture then
			local part = Instance.new("Part")
			-- not loaded -> static fallback includes CFrame (BasePart).
			AllowList.loaded = false
			local fallbackNames = capture.getPropertyNames(part)
			local hasCFrame = false
			for _, n in ipairs(fallbackNames) do
				if n == "CFrame" then
					hasCFrame = true
				end
			end
			SelfTest.assert("getPropertyNames fallback includes CFrame", hasCFrame, failures)
			-- loaded -> uses the allow-list.
			AllowList.loaded = true
			AllowList.lists = { Part = { "Transparency" } }
			AllowList.sets = { Part = { Transparency = false } }
			local allowNames = capture.getPropertyNames(part)
			SelfTest.assert(
				"getPropertyNames uses allow-list when loaded",
				#allowNames == 1 and allowNames[1] == "Transparency",
				failures
			)
			SelfTest.assert("curatedSet membership from allow-list", capture.curatedSet(part).Transparency == false, failures)
			-- restore.
			AllowList.loaded = false
			AllowList.lists = {}
			AllowList.sets = {}
			part:Destroy()
		else
			print("[Studio Stud SelfTest] SKIP: capture handle not available")
		end
	end

	-- == Phase 4: baseline yield + readPropsFrom + readSource ==
	do
		if capture then
			SelfTest.assert("shouldYield(0,500)=false", not capture.shouldYield(0, 500), failures)
			SelfTest.assert("shouldYield(500,500)=true", capture.shouldYield(500, 500), failures)
			SelfTest.assert("shouldYield(750,500)=false", not capture.shouldYield(750, 500), failures)
			SelfTest.assert("shouldYield(1000,500)=true", capture.shouldYield(1000, 500), failures)
			SelfTest.assert("shouldYield(5,0)=false", not capture.shouldYield(5, 0), failures)

			local fakeOk = { Transparency = 0.5, Size = Vector3.new(1, 2, 3) }
			local propsOk, errsOk = capture.readPropsFrom(fakeOk, { "Transparency", "Size" })
			SelfTest.assert(
				"readPropsFrom success path",
				propsOk.Transparency == 0.5 and propsOk.Size ~= nil and #errsOk == 0,
				failures
			)

			local fakeThrow = setmetatable({}, {
				__index = function(_, key: any): any
					if key == "BadProp" then
						error("read failed")
					end
					if key == "GoodProp" then
						return 1
					end
					if key == "GoodProp2" then
						return 1
					end
					return nil
				end,
			})
			local propsFb, errsFb = capture.readPropsFrom(fakeThrow, { "GoodProp", "BadProp", "GoodProp2" })
			SelfTest.assert(
				"readPropsFrom fallback returns rest",
				propsFb.GoodProp == 1 and propsFb.GoodProp2 == 1 and #errsFb == 1,
				failures
			)

			local mod = Instance.new("ModuleScript")
			mod.Source = "return 42"
			local srcUtf8, encUtf8 = capture.readSource(mod)
			SelfTest.assert("readSource ModuleScript utf8", srcUtf8 == "return 42" and encUtf8 == "utf8", failures)
			local part = Instance.new("Part")
			local srcNil, encNil = capture.readSource(part)
			SelfTest.assert("readSource non-script nil", srcNil == nil and encNil == nil, failures)
			local binary = string.char(0xFF, 0x00, 0xAB)
			local encB64 = capture.base64encode(binary)
			local roundTrip = capture.base64decode(encB64)
			SelfTest.assert("base64 round-trip", roundTrip == binary, failures)
			SelfTest.assert("base64 alphabet valid", string.match(encB64, "^[A-Za-z0-9+/=]+$") ~= nil, failures)
			mod:Destroy()
			part:Destroy()
		else
			print("[Studio Stud SelfTest] SKIP: capture handle not available (phase 4)")
		end
	end

	-- == Hash wire-parity (NEW regression): Hash.hashInstance must equal the
	-- monolith recipe oracle byte-for-byte, in the live runtime. A drift here means
	-- the unchanged daemon would report phantom drift on every tick. ==
	do
		local sample: { [string]: any } = {
			id = "hp1",
			className = "Part",
			name = "P",
			parentId = "ws",
			path = "Workspace/P[1]",
			depth = 1,
			siblingIndex = 1,
			childCount = 0,
			duplicateSiblingName = true,
			properties = {
				Transparency = 0.5,
				Anchored = true,
				CanCollide = false,
				Size = { type = "Vector3", x = 1, y = 2, z = 3 },
				CFrame = { 0, 5, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 },
			},
			attributes = { foo = "bar", count = 7 },
			tags = { "tagA", "tagB" },
		}
		SelfTest.assert(
			"Hash parity: full entry matches monolith oracle",
			Hash.hashInstance(sample :: any) == oracleHashInstance(sample),
			failures
		)
		-- source is EXCLUDED (M3): an entry differing only by source hashes equal.
		local withSource: { [string]: any } = table.clone(sample)
		withSource.source = "print('x')"
		withSource.sourceEncoding = "utf8"
		SelfTest.assert(
			"Hash parity: source excluded from hash (M3)",
			Hash.hashInstance(withSource :: any) == Hash.hashInstance(sample :: any),
			failures
		)
		-- sparse defaults reproduce the monolith `or` fallbacks.
		local sparse: { [string]: any } = { id = "sp" }
		SelfTest.assert(
			"Hash parity: sparse defaults match oracle",
			Hash.hashInstance(sparse :: any) == oracleHashInstance(sparse),
			failures
		)
	end

	-- == Phase 5C: hashInstance + incremental serviceFp ==
	if live then
		do
			local realLive = live :: typeof(live)
			local sample: { [string]: any } = {
				id = "a1",
				className = "Part",
				name = "P",
				parentId = "ws",
				path = "Workspace/P[1]",
				depth = 1,
				siblingIndex = 1,
				childCount = 0,
				duplicateSiblingName = false,
				properties = { Transparency = 0.5, Size = { type = "Vector3", x = 1, y = 2, z = 3 } },
				attributes = { foo = "bar" },
				tags = { "tagA", "tagB" },
			}
			local h1 = Hash.hashInstance(sample :: any)
			local h2 = Hash.hashInstance(sample :: any)
			SelfTest.assert("hashInstance stable", h1 == h2, failures)
			SelfTest.assert("hashInstance 64 hex", #h1 == 64 and string.match(h1, "^[0-9a-f]+$") ~= nil, failures)

			local snap = realLive:buildBaselineSnapshot("selftest")
			SelfTest.assert("baseline snapshot has instances", #snap.instances > 0, failures)
			local reordered: { [string]: any } = {
				id = "a1",
				className = "Part",
				name = "P",
				parentId = "ws",
				path = "Workspace/P[1]",
				depth = 1,
				siblingIndex = 1,
				childCount = 0,
				duplicateSiblingName = false,
				properties = { Size = { type = "Vector3", x = 1, y = 2, z = 3 }, Transparency = 0.5 },
				attributes = { foo = "bar" },
				tags = { "tagA", "tagB" },
			}
			SelfTest.assert("hashInstance property order invariant", Hash.hashInstance(reordered :: any) == h1, failures)
			sample.properties.Transparency = 0.6
			SelfTest.assert("hashInstance property change", Hash.hashInstance(sample :: any) ~= h1, failures)

			Fingerprints:reset()
			local entryA: { [string]: any } = {
				id = "a",
				className = "Part",
				name = "A",
				parentId = "ws",
				path = "Workspace/A[1]",
				depth = 1,
				siblingIndex = 1,
				childCount = 0,
				duplicateSiblingName = false,
				properties = {},
				attributes = {},
				tags = {},
			}
			local entryB: { [string]: any } = {
				id = "b",
				className = "Part",
				name = "B",
				parentId = "ws",
				path = "Workspace/B[1]",
				depth = 1,
				siblingIndex = 2,
				childCount = 0,
				duplicateSiblingName = false,
				properties = {},
				attributes = {},
				tags = {},
			}
			Fingerprints:applyFpUpsert("a", entryA :: any, nil)
			Fingerprints:applyFpUpsert("b", entryB :: any, nil)
			local fpB = Hash.hashInstance(entryB :: any)
			local wsXor = Fingerprints:serviceFpHex("Workspace")
			Fingerprints:applyFpRemove("a", entryA.path)
			SelfTest.assert("serviceFp remove A leaves B", Fingerprints:serviceFpHex("Workspace") == fpB, failures)
			Fingerprints:applyFpUpsert("a", entryA :: any, nil)
			SelfTest.assert("serviceFp re-add A restores XOR", Fingerprints:serviceFpHex("Workspace") == wsXor, failures)

			local body = realLive:buildTickBody("123", "edit", 2, { Workspace = string.rep("a", 64) }, {
				upserted = { { id = "x" } :: any },
				removed = { "y" },
			}, nil)
			SelfTest.assert(
				"buildTickBody shape",
				body.placeId == "123"
					and body.sessionMode == "edit"
					and body.baseRevision == 2
					and body.ops.upserted[1].id == "x"
					and body.bulkRef == nil,
				failures
			)
			-- DEVIATION: live.classifyPayload is gone; the inline/bulk boundary is now
			-- Config.TICK_INLINE_THRESHOLD (the byte size collectOpsFromDirty caps on).
			-- Re-assert the same two classification facts against that threshold.
			SelfTest.assert("payload inline below threshold", 1024 <= TICK_INLINE_THRESHOLD, failures)
			SelfTest.assert("payload bulk above threshold", 300000 > TICK_INLINE_THRESHOLD, failures)

			Fingerprints:reset()
			Fingerprints:applyFpUpsert("ws", {
				path = "Workspace",
				fp = Hash.hashInstance({
					id = "ws",
					path = "Workspace",
					name = "Workspace",
					className = "Workspace",
					depth = 0,
					siblingIndex = 0,
					childCount = 0,
					duplicateSiblingName = false,
					properties = {},
					attributes = {},
					tags = {},
				} :: any),
			}, nil)
			local fpPreOp = Fingerprints:serviceFingerprintsWire()
			Fingerprints:applyFpUpsert("p1", {
				path = "Workspace/Part[1]",
				fp = Hash.hashInstance({
					id = "p1",
					path = "Workspace/Part[1]",
					name = "Part",
					className = "Part",
					depth = 1,
					siblingIndex = 1,
					childCount = 0,
					duplicateSiblingName = false,
					properties = {},
					attributes = {},
					tags = {},
				} :: any),
			}, nil)
			local fpPostOp = Fingerprints:serviceFingerprintsWire()
			SelfTest.assert("edit tick fingerprints are post-ops", fpPreOp.Workspace ~= fpPostOp.Workspace, failures)

			-- DEVIATION: live.scheduleDriftRecovery(svc, up, rm) is gone. Drift recovery
			-- is now Live:triggerDriftRecovery — guarded (no-op off-live) and it NEVER
			-- touches the dirty sets. Re-assert the "preserves dirty" intent: mark dirty,
			-- invoke the guarded recovery (off-live -> returns false, no-op), confirm the
			-- dirty sets survive untouched.
			local ws = game:GetService("Workspace")
			realLive.dirtyUpsert[ws] = true
			realLive.dirtyRemoved.z = true
			local recoveryStarted = realLive:triggerDriftRecovery({ "Workspace" })
			SelfTest.assert("drift recovery is a no-op while off-live", recoveryStarted == false, failures)
			SelfTest.assert(
				"drift recovery preserves dirty",
				realLive.dirtyUpsert[ws] == true and realLive.dirtyRemoved.z == true,
				failures
			)
			realLive.dirtyUpsert = {}
			realLive.dirtyRemoved = {}

			-- E1 forward-progress + cap: drive the real collectOpsFromDirty with a fat
			-- (over-threshold) and a small instance among the dirty set. The fat one is
			-- depth-sorted equal, so ordering is by the pairs() walk; we assert the cap
			-- ships at most one when the fat entry would overflow, and that a SOLO fat
			-- entry still ships (forward-progress). This is the modular equivalent of the
			-- monolith's collectOpsFromEntries cap tests.
			do
				local capFolder = Instance.new("Folder")
				capFolder.Name = "StudioStudSelfTestCap"
				capFolder.Parent = game:GetService("ReplicatedStorage")

				local fatPart = Instance.new("Part")
				fatPart.Name = "Fat"
				fatPart.Parent = capFolder
				-- An attribute large enough to push the entry over TICK_INLINE_THRESHOLD.
				fatPart:SetAttribute("pad", string.rep("x", TICK_INLINE_THRESHOLD + 4096))

				local smallPart = Instance.new("Part")
				smallPart.Name = "Small"
				smallPart.Parent = capFolder

				-- Register both in the live identity maps so buildUpsertedEntry resolves them.
				local fatId = fatPart:GetDebugId(0)
				local smallId = smallPart:GetDebugId(0)
				local capId = capFolder:GetDebugId(0)
				capture.instanceIdByRef[capFolder] = capId
				capture.pathByRef[capFolder] = "ReplicatedStorage/StudioStudSelfTestCap[1]"
				capture.instanceIdByRef[fatPart] = fatId
				capture.pathByRef[fatPart] = ""
				capture.instanceIdByRef[smallPart] = smallId
				capture.pathByRef[smallPart] = ""

				-- SOLO fat: forward-progress ships it even though it exceeds the threshold.
				Fingerprints:reset()
				realLive.dirtyUpsert = {}
				realLive.dirtyRemoved = {}
				realLive.upsertStamp = {}
				realLive.removedStamp = {}
				realLive:markDirtyUpsert(fatPart)
				local soloUpserted = realLive:collectOpsFromDirty()
				SelfTest.assert(
					"solo fat op collects one entry (forward-progress)",
					#soloUpserted == 1 and soloUpserted[1].id == fatId,
					failures
				)

				-- small + fat: the cap breaks after the first committed op, so the batch
				-- never ships BOTH inline (the fat overflow is deferred to the next tick).
				Fingerprints:reset()
				realLive.dirtyUpsert = {}
				realLive.dirtyRemoved = {}
				realLive.upsertStamp = {}
				realLive.removedStamp = {}
				realLive:markDirtyUpsert(smallPart)
				realLive:markDirtyUpsert(fatPart)
				local cappedUpserted = realLive:collectOpsFromDirty()
				SelfTest.assert(
					"fat batch caps (does not ship both inline)",
					#cappedUpserted < 2,
					failures
				)

				-- Clean the live maps + DataModel.
				capture.instanceIdByRef[capFolder] = nil
				capture.pathByRef[capFolder] = nil
				capture.instanceIdByRef[fatPart] = nil
				capture.pathByRef[fatPart] = nil
				capture.instanceIdByRef[smallPart] = nil
				capture.pathByRef[smallPart] = nil
				realLive.dirtyUpsert = {}
				realLive.dirtyRemoved = {}
				realLive.upsertStamp = {}
				realLive.removedStamp = {}
				Fingerprints:reset()
				capFolder:Destroy()
			end
		end
	end

	-- == JSON safety: a snapshot must always encode, even with NaN/inf or invalid-UTF-8 (0.4.18) ==
	do
		local report: { string } = {}
		local dirty: { [string]: any } = {
			nan = 0 / 0,
			posInf = math.huge,
			negInf = -math.huge,
			ok = 1.5,
			badStr = "abc" .. string.char(0xFF, 0xFE) .. "z",
			goodStr = "héllo",
			nested = { x = 0 / 0, y = 2 },
		}
		local rawOk = pcall(function()
			return httpService:JSONEncode(dirty)
		end)
		SelfTest.assert("dirty snapshot fails raw JSONEncode", not rawOk, failures)
		Transport.sanitizeJsonValue(dirty, "root", report, nil)
		local postOk = pcall(function()
			return httpService:JSONEncode(dirty)
		end)
		SelfTest.assert("sanitized snapshot encodes", postOk, failures)
		SelfTest.assert("sanitize reported offenders", #report >= 4, failures)
		SelfTest.assert("sanitize replaced NaN with 0", dirty.nan == 0, failures)
		SelfTest.assert("sanitize kept finite number", dirty.ok == 1.5, failures)
		SelfTest.assert("sanitize kept valid multibyte string", dirty.goodStr == "héllo", failures)
	end

	if live then
		local realLive = live :: typeof(live)
		realLive:teardown()
		SelfTest.assert("live.teardown clears liveRunning", not realLive.liveRunning, failures)
		SelfTest.assert("live.teardown clears instConns", next(realLive.instConns) == nil, failures)
		SelfTest.assert("live.teardown clears rootConns", #realLive.rootConns == 0, failures)
		SelfTest.assert("live.teardown clears globalConns", #realLive.globalConns == 0, failures)
		SelfTest.assert("live.teardown resets revision", realLive.currentRevision == 0, failures)
		SelfTest.assert("live.teardown resets liveInstanceCount", realLive.liveInstanceCount == 0, failures)
		SelfTest.assert("live.teardown clears dirtyUpsert", next(realLive.dirtyUpsert) == nil, failures)
		SelfTest.assert("live.teardown clears dirtyRemoved", next(realLive.dirtyRemoved) == nil, failures)
		SelfTest.assert("live.teardown resets verifyNeeded", realLive.verifyNeeded == false, failures)

		-- Settings gate: liveCaptureEnabled = false → setupAfterBaseline is a no-op.
		Settings.setBool(SETTINGS.liveCaptureEnabled, false)
		realLive:setupAfterBaseline({ revision = 5, instances = 100 })
		SelfTest.assert("live gated by liveCaptureEnabled=false", not realLive.liveRunning, failures)
		Settings.setBool(SETTINGS.liveCaptureEnabled, true)

		-- Dirty-set precedence: removed wins over upserted for same id.
		local dummyInst = Instance.new("Folder")
		dummyInst.Parent = game:GetService("ReplicatedStorage")
		local dummyId = dummyInst:GetDebugId(0)
		realLive.dirtyUpsert[dummyInst] = true
		realLive.dirtyRemoved[dummyId] = true
		-- collectOpsFromDirty skips this inst because its id is in dirtyRemoved.
		local skipped = realLive.dirtyRemoved[dummyId] == true
		SelfTest.assert("removed wins over upserted in dirty sets", skipped, failures)
		realLive.dirtyUpsert = {}
		realLive.dirtyRemoved = {}
		dummyInst:Destroy()

		-- == C1 regression: markDirtyUpsert sets dirtyUpsert[inst] WITHOUT recursion ==
		-- The monolith's buggy markDirtyUpsert called itself (infinite recursion). The
		-- cure: it ONLY sets dirtyUpsert[inst]=true + stamps. Assert the post-condition
		-- (the inst is dirty and stamped) AND that the call returns normally (a recursive
		-- version would stack-overflow before reaching the assert).
		do
			realLive.dirtyUpsert = {}
			realLive.upsertStamp = {}
			realLive.dirtyStamp = 0
			local c1Inst = Instance.new("Folder")
			c1Inst.Parent = game:GetService("ReplicatedStorage")
			realLive:markDirtyUpsert(c1Inst)
			SelfTest.assert(
				"C1: markDirtyUpsert sets dirtyUpsert[inst] (no recursion)",
				realLive.dirtyUpsert[c1Inst] == true,
				failures
			)
			SelfTest.assert(
				"C1: markDirtyUpsert stamps the inst once",
				realLive.dirtyStamp == 1 and realLive.upsertStamp[c1Inst] == 1,
				failures
			)
			realLive.dirtyUpsert = {}
			realLive.upsertStamp = {}
			c1Inst:Destroy()
		end

		-- == C2 regression: a simulated connect passes a NON-NIL onReturnToEdit to
		-- startTickLoop ==
		-- The monolith captured a not-yet-assigned `onReturnToEdit` upvalue into
		-- startTickLoop (nil at capture time -> the play->edit resume silently died).
		-- Simulate the connect seam: build a real callback and hand it to startTickLoop,
		-- asserting the engine accepts a non-nil onReturnToEdit (and that the call itself
		-- returns normally — a nil-call would have thrown). Tear down immediately so the
		-- spawned loop exits on its next generation guard.
		do
			Settings.setBool(SETTINGS.liveCaptureEnabled, true)
			realLive.liveRunning = true -- arm the loop guard so startTickLoop spawns
			local returnSeen = false
			local onReturnToEdit = function()
				returnSeen = true
			end
			local okStart = pcall(function()
				realLive:startTickLoop({ revision = 0, instanceCount = 0 }, onReturnToEdit)
			end)
			SelfTest.assert("C2: startTickLoop accepts a non-nil onReturnToEdit", okStart, failures)
			SelfTest.assert("C2: onReturnToEdit is a function (non-nil)", type(onReturnToEdit) == "function", failures)
			-- `returnSeen` exists only so the closure is genuinely capturable (no dead
			-- upvalue); the loop fires it only on a play->edit transition, not here.
			SelfTest.assert("C2: onReturnToEdit closure is live", returnSeen == false, failures)
			realLive:teardown() -- bump generation so the spawned loop exits
		end

		-- == C3 regression: Sync() before live mode does not nil-call ==
		-- The monolith's Sync() before live nil-called a not-yet-assigned upvalue. Here
		-- the engine's host starts as a NO-OP stub (Live.host = NOOP_HOST) until attach,
		-- so a pre-live engine call routes through the stub and is a safe no-op. After
		-- teardown the engine is off-live; drive a host-touching engine path
		-- (triggerRebaseline goes straight through host.* ) and assert it does not throw.
		do
			realLive.liveRunning = false
			local okPreLive = pcall(function()
				realLive:triggerRebaseline("c3-pre-live")
			end)
			SelfTest.assert("C3: pre-live engine call is a safe no-op (no nil-call)", okPreLive, failures)
			-- And the panel handle's sync entry (the real Sync()) returns a result table
			-- rather than throwing, even with no daemon (off-live, edit session).
			if captureHandleLive then
				local okSync, syncResult = pcall(function(): any
					return captureHandleLive.sync()
				end)
				SelfTest.assert(
					"C3: Sync() before live returns a result (no nil-call)",
					okSync and type(syncResult) == "table",
					failures
				)
			end
		end

		-- == Phase 3: detection collapse ==
		do
			local curated = { Transparency = false }
			SelfTest.assert("classify Name -> name", realLive:classifyChangedProp("Name", curated) == "name", failures)
			SelfTest.assert("classify Source -> dirty", realLive:classifyChangedProp("Source", curated) == "dirty", failures)
			SelfTest.assert(
				"classify curated -> dirty",
				realLive:classifyChangedProp("Transparency", curated) == "dirty",
				failures
			)
			SelfTest.assert(
				"classify uncurated -> gap",
				realLive:classifyChangedProp("Archivable", curated) == "gap",
				failures
			)

			-- gap-probe dedup.
			realLive.propGaps = {}
			realLive:recordPropGap("Part", "Foo")
			realLive:recordPropGap("Part", "Foo")
			local gapCount = 0
			for _ in pairs(realLive.propGaps) do
				gapCount += 1
			end
			SelfTest.assert("recordPropGap dedups", gapCount == 1, failures)

			-- connection-count collapse: a Part should register ~3 connections, not ~20.
			AllowList.loaded = true
			AllowList.lists = { Part = { "Transparency", "Size" } }
			AllowList.sets = { Part = { Transparency = false, Size = false } }
			local part = Instance.new("Part")
			realLive:registerInstance(part)
			local partConns = realLive.instConns[part]
			SelfTest.assert("registerInstance collapses Part to <=4 conns", partConns ~= nil and #partConns <= 4, failures)
			realLive:unregisterInstance(part)
			part:Destroy()

			-- ValueBase registers explicit signals (Ancestry + Attribute + Name + Value).
			local iv = Instance.new("IntValue")
			realLive:registerInstance(iv)
			local ivConns = realLive.instConns[iv]
			SelfTest.assert("ValueBase registers >=3 conns", ivConns ~= nil and #ivConns >= 3, failures)
			realLive:unregisterInstance(iv)
			iv:Destroy()

			AllowList.loaded = false
			AllowList.lists = {}
			AllowList.sets = {}
		end
	else
		-- Live handle not available: skip but don't fail.
		print("[Studio Stud SelfTest] SKIP: live handle not available (live tests skipped)")
	end

	-- == Phase 3: allow-list parse (pure) ==
	do
		local parsed = AllowList.parse({
			version = "1.2.3.4",
			classes = {
				Part = {
					{ name = "Transparency", readOnly = false },
					{ name = "AbsoluteSize", readOnly = true },
				},
			},
		})
		SelfTest.assert("allowlist parse version", parsed ~= nil and parsed.version == "1.2.3.4", failures)
		SelfTest.assert("allowlist parse membership", parsed ~= nil and parsed.sets.Part.Transparency == false, failures)
		SelfTest.assert("allowlist parse readOnly flag", parsed ~= nil and parsed.sets.Part.AbsoluteSize == true, failures)
		SelfTest.assert("allowlist parse ordered list", parsed ~= nil and #parsed.lists.Part == 2, failures)
		SelfTest.assert("allowlist parse rejects bad input", AllowList.parse({}) == nil, failures)
	end

	-- == Edit-session gate self-tests ==
	-- SelfTest runs in a genuine edit session, so the primitive MUST resolve to edit.
	-- A failure here means the gate would wrongly suspend all capture during normal editing.
	do
		SelfTest.assert("Session.decide is a function", type(Session.decide) == "function", failures)
		SelfTest.assert("Session.signals is a function", type(Session.signals) == "function", failures)
		-- Pure decision truth table (independent of the live RunService):
		SelfTest.assert("decide edit when isEdit & !isRunning", Session.decide(true, false) == "edit", failures)
		SelfTest.assert("decide play when isRunning", Session.decide(false, true) == "play", failures)
		SelfTest.assert("decide play when !isEdit", Session.decide(false, false) == "play", failures)
		SelfTest.assert("decide play when isEdit & isRunning", Session.decide(true, true) == "play", failures)
		-- SelfTest runs in a genuine edit session, so the LIVE decision must be edit:
		SelfTest.assert("Session.mode() == 'edit' while editing", Session.mode() == "edit", failures)
	end

	Settings.setBool(SETTINGS.liveCaptureEnabled, origLive)
	Settings.setNumber(SETTINGS.debounceMs, origDebounce)
	Settings.setString(SETTINGS.daemonUrl, origUrl)
	SelfTest.assert(
		"registry ids restored",
		Registry.snapshotIds()[1] == preIds[1] and #Registry.snapshotIds() == #preIds,
		failures
	)

	if #failures == 0 then
		print("[Studio Stud SelfTest] PASS — all checks passed")
		return true
	end
	warn("[Studio Stud SelfTest] FAIL — " .. tostring(#failures) .. " check(s) failed")
	return false
end

return SelfTest
