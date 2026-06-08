--!strict
-- Headless test for Fingerprints: the per-service XOR accumulator behavior the
-- daemon depends on. The recipe (the hash) is parity-tested in Hash.spec; here we
-- verify the ACCUMULATION math is correct and self-inverse — add/remove/reparent —
-- and that the wire map shape and reset are exactly the monolith's.
--
-- The release-blocking invariant (from the rewrite plan): the accumulator is XOR of
-- the live instances' fingerprints, so
--   add A, add B -> serviceFp == hash(A) XOR hash(B); remove A -> == hash(B);
--   re-add A -> back to hash(A) XOR hash(B).
-- We compute the expected XOR independently from Hash (the oracle for the recipe) so
-- a drift in EITHER the recipe or the accumulation is caught.
-- Run:
--   lune run plugin/src/__tests__/Fingerprints.spec.luau

local Fingerprints = require("../Fingerprints")
local Hash = require("../Hash")

local failures = 0
local function check(label: string, cond: boolean)
	if not cond then
		failures += 1
		print("FAIL: " .. label)
	else
		print("ok: " .. label)
	end
end

-- Independent XOR-of-two-hex64 oracle (uses Hash byte helpers, which are themselves
-- oracle-tested in Hash.spec): the expected accumulator when two fingerprints are
-- present in one service.
local function xorHex(a: string, b: string): string
	local bytes = Hash.fpHexToBytes(a)
	Hash.fpXor(bytes, Hash.fpHexToBytes(b))
	return Hash.fpBytesToHex(bytes)
end

local ZERO64 = string.rep("0", 64)

-- ============================================================================
-- Public interface presence
-- ============================================================================
check("instFp starts a table", type(Fingerprints.instFp) == "table")
check("serviceFpBytes starts a table", type(Fingerprints.serviceFpBytes) == "table")
check("serviceFpHex is a function", type(Fingerprints.serviceFpHex) == "function")
check("serviceFingerprintsWire is a function", type(Fingerprints.serviceFingerprintsWire) == "function")
check("applyFpUpsert is a function", type(Fingerprints.applyFpUpsert) == "function")
check("applyFpRemove is a function", type(Fingerprints.applyFpRemove) == "function")
check("reset is a function", type(Fingerprints.reset) == "function")

-- ============================================================================
-- Fixtures: two real entries in the Workspace service (distinct fingerprints).
-- ============================================================================
local function entryA(): any
	return {
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
end
local function entryB(): any
	return {
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
end

local fpA = Hash.hashInstance(entryA())
local fpB = Hash.hashInstance(entryB())
check("fixtures have distinct fingerprints", fpA ~= fpB)

-- ============================================================================
-- serviceFpHex on an empty service is 64 zeros.
-- ============================================================================
Fingerprints:reset()
check("empty service -> 64 zeros", Fingerprints:serviceFpHex("Workspace") == ZERO64)
check("serviceFingerprintsWire empty -> {}", next(Fingerprints:serviceFingerprintsWire()) == nil)

-- ============================================================================
-- THE CORE INVARIANT: add A, add B -> hash(A) XOR hash(B); remove A -> hash(B);
-- re-add A -> back. (The plan's named acceptance behavior.)
-- ============================================================================
do
	Fingerprints:reset()
	Fingerprints:applyFpUpsert("a", entryA(), nil)
	check("after add A :: service == hash(A)", Fingerprints:serviceFpHex("Workspace") == fpA)
	check("after add A :: instFp[a] == hash(A)", Fingerprints.instFp.a == fpA)

	Fingerprints:applyFpUpsert("b", entryB(), nil)
	local wsXor = Fingerprints:serviceFpHex("Workspace")
	check("after add A,B :: service == hash(A) XOR hash(B)", wsXor == xorHex(fpA, fpB))

	Fingerprints:applyFpRemove("a", "Workspace/A[1]")
	check("after remove A :: service == hash(B)", Fingerprints:serviceFpHex("Workspace") == fpB)
	check("after remove A :: instFp[a] cleared", Fingerprints.instFp.a == nil)
	check("after remove A :: instFp[b] intact", Fingerprints.instFp.b == fpB)

	Fingerprints:applyFpUpsert("a", entryA(), nil)
	check("after re-add A :: service restored to A XOR B", Fingerprints:serviceFpHex("Workspace") == wsXor)
end

-- ============================================================================
-- applyFpUpsert MUTATES entry.fp (callers ship it on the wire) and honors a
-- precomputed entry.fp (no re-hash).
-- ============================================================================
do
	Fingerprints:reset()
	local e = entryA()
	check("entry.fp nil before upsert", e.fp == nil)
	Fingerprints:applyFpUpsert("a", e, nil)
	check("applyFpUpsert sets entry.fp", e.fp == fpA)

	-- A precomputed fp is used verbatim (not re-hashed): give a bogus fp and confirm
	-- the accumulator uses it.
	Fingerprints:reset()
	local bogus = string.rep("ab", 32)
	Fingerprints:applyFpUpsert("x", { fp = bogus, path = "Workspace/X" }, nil)
	check("precomputed fp used verbatim", Fingerprints:serviceFpHex("Workspace") == bogus)
	check("precomputed fp recorded in instFp", Fingerprints.instFp.x == bogus)
end

-- ============================================================================
-- update in place (same service, same path) is self-correcting: re-upserting the
-- SAME entry XORs the old value out and the same value back in -> unchanged.
-- ============================================================================
do
	Fingerprints:reset()
	Fingerprints:applyFpUpsert("a", entryA(), nil)
	local before = Fingerprints:serviceFpHex("Workspace")
	Fingerprints:applyFpUpsert("a", entryA(), nil) -- oldPath defaults to entry.path
	check("re-upsert same entry leaves service unchanged", Fingerprints:serviceFpHex("Workspace") == before)
end

-- ============================================================================
-- update that CHANGES the fingerprint (same service): old fp leaves, new fp enters.
-- ============================================================================
do
	Fingerprints:reset()
	Fingerprints:applyFpUpsert("a", entryA(), nil)
	local changed = entryA()
	changed.name = "A2" -- structural change -> different hash
	local fpChanged = Hash.hashInstance(changed)
	check("changed entry hashes differently", fpChanged ~= fpA)
	changed.fp = nil -- force re-hash inside applyFpUpsert
	Fingerprints:applyFpUpsert("a", changed, "Workspace/A[1]")
	check("update -> service == new fp only", Fingerprints:serviceFpHex("Workspace") == fpChanged)
	check("update -> instFp[a] == new fp", Fingerprints.instFp.a == fpChanged)
end

-- ============================================================================
-- REPARENT across services: the fingerprint must LEAVE the old service and ENTER
-- the new one (the add/remove/reparent inverse the plan calls out). Old service
-- returns to zero; new service holds the fp.
-- ============================================================================
do
	Fingerprints:reset()
	-- Start in Workspace.
	local e = entryA() -- path Workspace/A[1]
	Fingerprints:applyFpUpsert("a", e, nil)
	check("reparent: starts in Workspace", Fingerprints:serviceFpHex("Workspace") == fpA)

	-- Move to ServerStorage: new path + new fp; oldPath = the Workspace path.
	local moved = entryA()
	moved.parentId = "ss"
	moved.path = "ServerStorage/A[1]"
	moved.fp = nil
	local fpMoved = Hash.hashInstance(moved)
	Fingerprints:applyFpUpsert("a", moved, "Workspace/A[1]")

	check("reparent: old service (Workspace) back to zero", Fingerprints:serviceFpHex("Workspace") == ZERO64)
	check("reparent: new service (ServerStorage) holds moved fp", Fingerprints:serviceFpHex("ServerStorage") == fpMoved)
	check("reparent: instFp[a] == moved fp", Fingerprints.instFp.a == fpMoved)
end

-- ============================================================================
-- serviceFingerprintsWire emits { [service] = 64-hex } over every accumulator,
-- including a service that has returned to zero (monolith parity: it lingers).
-- ============================================================================
do
	Fingerprints:reset()
	Fingerprints:applyFpUpsert("a", entryA(), nil) -- Workspace
	Fingerprints:applyFpUpsert("s", { fp = string.rep("11", 32), path = "ServerScriptService/Main" }, nil)
	local wire = Fingerprints:serviceFingerprintsWire()
	check("wire has Workspace", wire.Workspace == fpA)
	check("wire has ServerScriptService", wire.ServerScriptService == string.rep("11", 32))

	-- Remove the only Workspace instance: the service lingers at zero in the wire.
	Fingerprints:applyFpRemove("a", "Workspace/A[1]")
	local wire2 = Fingerprints:serviceFingerprintsWire()
	check("wire keeps emptied Workspace at zero", wire2.Workspace == ZERO64)
end

-- ============================================================================
-- applyFpRemove for an unknown id is a no-op on the accumulator.
-- ============================================================================
do
	Fingerprints:reset()
	Fingerprints:applyFpUpsert("a", entryA(), nil)
	local before = Fingerprints:serviceFpHex("Workspace")
	Fingerprints:applyFpRemove("ghost", "Workspace/Ghost") -- never added
	check("remove unknown id no-ops accumulator", Fingerprints:serviceFpHex("Workspace") == before)
	check("remove unknown id leaves instFp[a]", Fingerprints.instFp.a == fpA)
end

-- ============================================================================
-- reset clears everything.
-- ============================================================================
do
	Fingerprints:reset()
	Fingerprints:applyFpUpsert("a", entryA(), nil)
	Fingerprints:applyFpUpsert("b", entryB(), nil)
	Fingerprints:reset()
	check("reset clears instFp", next(Fingerprints.instFp) == nil)
	check("reset clears serviceFpBytes", next(Fingerprints.serviceFpBytes) == nil)
	check("reset -> service back to zero", Fingerprints:serviceFpHex("Workspace") == ZERO64)
	check("reset -> wire empty", next(Fingerprints:serviceFingerprintsWire()) == nil)
end

-- ============================================================================
-- POST-OPS ordering sanity (the Phase-5 fix): adding a second instance changes the
-- service fingerprint (so fingerprints captured AFTER the op differ from before) —
-- mirrors the monolith's "edit tick fingerprints are post-ops" assertion.
-- ============================================================================
do
	Fingerprints:reset()
	Fingerprints:applyFpUpsert("ws", {
		fp = Hash.hashInstance({
			id = "ws", path = "Workspace", name = "Workspace", className = "Workspace",
			depth = 0, siblingIndex = 0, childCount = 0, duplicateSiblingName = false,
			properties = {}, attributes = {}, tags = {},
		} :: any),
		path = "Workspace",
	}, nil)
	local pre = Fingerprints:serviceFingerprintsWire()
	Fingerprints:applyFpUpsert("p1", {
		fp = Hash.hashInstance({
			id = "p1", path = "Workspace/Part[1]", name = "Part", className = "Part",
			depth = 1, siblingIndex = 1, childCount = 0, duplicateSiblingName = false,
			properties = {}, attributes = {}, tags = {},
		} :: any),
		path = "Workspace/Part[1]",
	}, nil)
	local post = Fingerprints:serviceFingerprintsWire()
	check("post-ops fingerprint differs from pre-ops", pre.Workspace ~= post.Workspace)
end

if failures == 0 then
	print("ALL FINGERPRINTS TESTS PASSED")
else
	print(("%d FAILURE(S)"):format(failures))
	error("Fingerprints.spec failed", 0)
end
