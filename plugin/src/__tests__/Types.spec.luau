--!strict
-- Headless test for Types: proves the module loads and that values shaped to the
-- protocol-v2 wire contract type-check against the exported aliases. Types is
-- logic-free, so the guarantee is structural — if a wire field were dropped or
-- mistyped, constructing these annotated literals would fail luau-lsp analyze
-- (and a stray runtime field would surface here). Run:
--   lune run plugin/src/__tests__/Types.spec.luau

local Types = require("../Types")

type InstanceEntry = Types.InstanceEntry
type Ops = Types.Ops
type TickPacket = Types.TickPacket
type TickResponse = Types.TickResponse
type AllowList = Types.AllowList
type LiveState = Types.LiveState
type Bytes = Types.Bytes
type Hex64 = Types.Hex64

local failures = 0
local function check(label: string, cond: boolean)
	if not cond then
		failures += 1
		print("FAIL: " .. label)
	else
		print("ok: " .. label)
	end
end

-- A 64-hex fingerprint and its 32-byte unpacked form.
local fp: Hex64 = string.rep("ab", 32)
check("Hex64 is 64 chars", #fp == 64)

local bytes: Bytes = table.create(32, 0)
bytes[1] = 171
check("Bytes has 32 slots", #bytes == 32)

-- A full instance entry with the optional source fields present (script case).
local scriptEntry: InstanceEntry = {
	id = "ref-1",
	parentId = "ref-0",
	path = "Workspace[1]/Part[1]",
	name = "Part",
	className = "Part",
	depth = 1,
	siblingIndex = 1,
	childCount = 0,
	duplicateSiblingName = false,
	properties = { Anchored = true, Size = { type = "Vector3", x = 1, y = 2, z = 3 } },
	attributes = { Custom = 5 },
	tags = { "Spawn" },
	fp = fp,
	source = "print('hi')",
	sourceEncoding = "utf8",
}
check("entry has wire fp", scriptEntry.fp == fp)
check("entry source present", scriptEntry.source == "print('hi')")
check("entry sourceEncoding utf8", scriptEntry.sourceEncoding == "utf8")

-- A root entry: parentId nil, no source fields.
local rootEntry: InstanceEntry = {
	id = "ref-0",
	parentId = nil,
	path = "Workspace[1]",
	name = "Workspace",
	className = "Workspace",
	depth = 0,
	siblingIndex = 1,
	childCount = 1,
	duplicateSiblingName = false,
	properties = {},
	attributes = {},
	tags = {},
	fp = fp,
}
check("root parentId nil", rootEntry.parentId == nil)
check("root source absent", rootEntry.source == nil)

local ops: Ops = {
	upserted = { rootEntry, scriptEntry },
	removed = { "ref-9" },
}
check("ops upserted count", #ops.upserted == 2)
check("ops removed count", #ops.removed == 1)

-- Tick packet: inline ops form.
local inlinePacket: TickPacket = {
	placeId = "12345",
	sessionMode = "edit",
	baseRevision = 7,
	serviceFingerprints = { Workspace = fp },
	ops = ops,
	bulkRef = nil,
}
check("packet placeId is string", typeof(inlinePacket.placeId) == "string")
check("packet sessionMode edit", inlinePacket.sessionMode == "edit")
check("packet svc fp", inlinePacket.serviceFingerprints.Workspace == fp)

-- Tick packet: bulk spill form (empty ops + bulkRef).
local bulkPacket: TickPacket = {
	placeId = "12345",
	sessionMode = "play",
	baseRevision = 7,
	serviceFingerprints = {},
	ops = { upserted = {}, removed = {} },
	bulkRef = "sync-abc",
}
check("packet sessionMode play", bulkPacket.sessionMode == "play")
check("packet bulkRef set", bulkPacket.bulkRef == "sync-abc")

-- Tick response: ok form with drift + reserved applyScripts.
local okResponse: TickResponse = {
	ok = true,
	revision = 8,
	instanceCount = 42,
	driftServices = { "Workspace" },
	request = { reason = "rebaseline" },
	applyScripts = {
		{ studioPath = "Workspace/Script", newSource = "return 1", expectedPriorHash = "deadbeef" },
	},
}
check("response ok", okResponse.ok == true)
check("response revision", okResponse.revision == 8)
check("response drift", okResponse.driftServices ~= nil and #(okResponse.driftServices :: { string }) == 1)
check("response applyScript path", okResponse.applyScripts ~= nil)

-- Tick response: error form (no_baseline) — optional fields omitted.
local errResponse: TickResponse = {
	ok = false,
	error = "no_baseline",
}
check("response error ok=false", errResponse.ok == false)
check("response error code", errResponse.error == "no_baseline")

-- Allow-list: parsed shape.
local allow: AllowList = {
	version = "2026.1",
	sets = { Part = { Anchored = false, Position = true } },
	lists = { Part = { "Anchored", "Position" } },
}
check("allowlist set readOnly", allow.sets.Part.Position == true)
check("allowlist list order", allow.lists.Part[1] == "Anchored")

-- Live state: full field set.
local state: LiveState = {
	liveRunning = false,
	currentRevision = 0,
	liveInstanceCount = 0,
	networkErrorCount = 0,
	dirtyStamp = 0,
	dirtyUpsert = {},
	dirtyRemoved = {},
	upsertStamp = {},
	removedStamp = {},
	instFp = {},
	serviceFpBytes = {},
}
state.dirtyRemoved["ref-9"] = true
state.instFp["ref-1"] = fp
state.serviceFpBytes["Workspace"] = bytes
check("state dirtyRemoved by id", state.dirtyRemoved["ref-9"] == true)
check("state instFp by id", state.instFp["ref-1"] == fp)
check("state serviceFpBytes len", #state.serviceFpBytes["Workspace"] == 32)

if failures == 0 then
	print("ALL TYPES TESTS PASSED")
else
	print(("%d FAILURE(S)"):format(failures))
	error("Types.spec failed", 0)
end
