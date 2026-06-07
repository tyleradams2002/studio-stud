--!strict
-- Headless WIRE-PARITY test for Hash. The release-blocking guarantee: the new
-- Hash.hashInstance must be byte-identical to the OLD monolith algorithm, or the
-- unchanged daemon sees phantom drift on every tick. We embed the monolith's
-- fingerprint code VERBATIM (copied from StudioStud.plugin.lua:2189-2302 as it
-- stood at 0.4.21) as an independent oracle and assert the two agree on a battery
-- of fixed entries — scalars, nested tables, attributes, tags, and the missing-
-- field defaults. Any mismatch fails the run (exit non-zero).
-- Run:
--   lune run plugin/src/__tests__/Hash.spec.luau

local Hash = require("../Hash")

-- ============================================================================
-- ORACLE: the monolith's fingerprint algorithm, copied verbatim. Do NOT refactor
-- this — it is the reference the port must reproduce. (lune provides bit32 /
-- string / table / typeof, matching the Roblox runtime for this pure code.)
-- ============================================================================

local FNV32_OFFSETS = { 0x811C9DC5, 0x050C5D1F, 0x9E3779B9, 0x7F4A7C15 }
local FNV32_PRIME = 16777619

local function oracleSortedKeys(tbl: any): { string }
	local keys = {}
	for key in pairs(tbl) do
		table.insert(keys, tostring(key))
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
		return "b:" .. (value and "1" or "0")
	elseif kind == "nil" then
		return "z"
	elseif kind == "table" then
		if #value > 0 then
			local parts = {}
			for _, item in ipairs(value) do
				table.insert(parts, oracleSerializeScalar(item))
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local parts = {}
		for _, key in ipairs(oracleSortedKeys(value)) do
			table.insert(parts, key .. "=" .. oracleSerializeScalar(value[key]))
		end
		return "{" .. table.concat(parts, ";") .. "}"
	end
	return "u:" .. tostring(value)
end

local function oracleSerializeMap(map: any): string
	local parts = {}
	for _, key in ipairs(oracleSortedKeys(map or {})) do
		table.insert(parts, key .. "=" .. oracleSerializeScalar(map[key]))
	end
	return table.concat(parts, ";")
end

local function oracleFnv32(str, offset)
	local h = offset
	for i = 1, #str do
		h = bit32.bxor(h, string.byte(str, i))
		h = (h * FNV32_PRIME) % 4294967296
	end
	return h
end

local function oracleHashInstance(entry: any): string
	local parts = {
		tostring(entry.className or ""),
		tostring(entry.name or ""),
		tostring(entry.parentId or ""),
		tostring(entry.path or ""),
		tostring(entry.depth or 0),
		tostring(entry.siblingIndex or 0),
		tostring(entry.childCount or 0),
		(entry.duplicateSiblingName and "1" or "0"),
		oracleSerializeMap(entry.properties),
		oracleSerializeMap(entry.attributes),
	}
	local tagParts = {}
	for _, tag in ipairs(entry.tags or {}) do
		table.insert(tagParts, tostring(tag))
	end
	table.insert(parts, table.concat(tagParts, ","))
	local canonical = table.concat(parts, "|")
	local hexParts = {}
	for lane = 1, 4 do
		local lo = oracleFnv32(canonical, FNV32_OFFSETS[lane])
		local hi = oracleFnv32(canonical .. "#" .. tostring(lane), bit32.bxor(FNV32_OFFSETS[lane], 0xA5A5A5A5))
		table.insert(hexParts, string.format("%08x%08x", lo, hi))
	end
	return table.concat(hexParts)
end

local function oracleServiceOf(path: any): string
	return string.match(path or "", "^([^/]+)") or (path or "")
end

local function oracleZeroBytes(): { number }
	return table.create(32, 0)
end

local function oracleHexToBytes(hex: string): { number }
	local bytes = table.create(32, 0)
	for i = 1, 32 do
		bytes[i] = tonumber(string.sub(hex, (i - 1) * 2 + 1, (i - 1) * 2 + 2), 16) or 0
	end
	return bytes
end

local function oracleBytesToHex(bytes: { number }): string
	local parts = table.create(32, "")
	for i = 1, 32 do
		parts[i] = string.format("%02x", bytes[i] or 0)
	end
	return table.concat(parts)
end

local function oracleXorBytes(target: { number }, source: { number })
	for i = 1, 32 do
		target[i] = bit32.bxor(target[i] or 0, source[i] or 0)
	end
end

-- ============================================================================
-- Test harness
-- ============================================================================

local failures = 0
local function check(label: string, cond: boolean)
	if not cond then
		failures += 1
		print("FAIL: " .. label)
	else
		print("ok: " .. label)
	end
end

-- == Public interface presence ==
check("hashInstance is a function", type(Hash.hashInstance) == "function")
check("serviceOf is a function", type(Hash.serviceOf) == "function")
check("fpZero is a function", type(Hash.fpZero) == "function")
check("fpHexToBytes is a function", type(Hash.fpHexToBytes) == "function")
check("fpBytesToHex is a function", type(Hash.fpBytesToHex) == "function")
check("fpXor is a function", type(Hash.fpXor) == "function")

-- ============================================================================
-- PARITY: hashInstance matches the oracle byte-for-byte across a battery of
-- entries. Each entry is hashed by both; we assert equality AND the 64-hex shape.
-- ============================================================================

local function parity(label: string, entry: any)
	local got = Hash.hashInstance(entry)
	local want = oracleHashInstance(entry)
	check(label .. " :: matches oracle", got == want)
	check(label .. " :: is 64 lowercase hex", #got == 64 and string.match(got, "^[0-9a-f]+$") == got)
end

-- A fully-populated entry: scalars of every kind, nested table props (array +
-- map), attributes, tags, duplicateSiblingName true.
parity("full entry", {
	id = "Workspace/Model/Part",
	parentId = "Workspace/Model",
	path = "Workspace/Model/Part",
	name = "Part",
	className = "Part",
	depth = 3,
	siblingIndex = 2,
	childCount = 0,
	duplicateSiblingName = true,
	properties = {
		Anchored = true,
		Transparency = 0.5,
		Name = "Part",
		Size = { type = "Vector3", x = 4, y = 1, z = 2 }, -- nested map
		CFrame = { 0, 5, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 }, -- nested array
		Material = "Plastic",
		CanCollide = false,
	},
	attributes = {
		MyTag = "hello",
		Count = 7,
		Flag = false,
	},
	tags = { "Interactable", "Spawn" },
})

-- A minimal entry: empty maps, no tags, duplicateSiblingName false, zero numbers.
parity("minimal entry", {
	id = "Lighting",
	parentId = nil,
	path = "Lighting",
	name = "Lighting",
	className = "Lighting",
	depth = 0,
	siblingIndex = 1,
	childCount = 0,
	duplicateSiblingName = false,
	properties = {},
	attributes = {},
	tags = {},
})

-- Missing-field defaults: hand the hasher a sparse entry (most fields nil) and
-- prove the new code reproduces the monolith's `or` fallbacks exactly (this is
-- why hashInstance widens to any internally).
parity("sparse entry (defaults)", {
	-- className/name/parentId/path absent -> "", numbers absent -> 0,
	-- duplicateSiblingName absent -> "0", maps/tags absent -> empty.
	id = "X",
})

-- source is EXCLUDED (M3): two entries identical except for source must hash equal.
do
	local base: any = {
		id = "ServerScriptService/Main",
		parentId = "ServerScriptService",
		path = "ServerScriptService/Main",
		name = "Main",
		className = "Script",
		depth = 1,
		siblingIndex = 1,
		childCount = 0,
		duplicateSiblingName = false,
		properties = { Enabled = true },
		attributes = {},
		tags = {},
	}
	local withSource: any = {}
	for k, v in pairs(base) do
		withSource[k] = v
	end
	withSource.source = "print('hello world')"
	withSource.sourceEncoding = "utf8"
	check("source excluded :: source-bearing entry hashes equal to base", Hash.hashInstance(base) == Hash.hashInstance(withSource))
	check("source excluded :: base equals oracle", Hash.hashInstance(base) == oracleHashInstance(base))
end

-- Sensitivity: a structural change (name) MUST change the hash (guards against a
-- degenerate constant hash that would also "match" a broken oracle).
do
	local a: any = { id = "a", path = "Workspace/A", name = "A", className = "Part", depth = 1, siblingIndex = 1, childCount = 0, duplicateSiblingName = false, properties = {}, attributes = {}, tags = {} }
	local b: any = { id = "a", path = "Workspace/A", name = "B", className = "Part", depth = 1, siblingIndex = 1, childCount = 0, duplicateSiblingName = false, properties = {}, attributes = {}, tags = {} }
	check("sensitivity :: differing name -> differing hash", Hash.hashInstance(a) ~= Hash.hashInstance(b))
end

-- Key-order independence of property maps (sorted keys): build the same map two
-- ways; hashes must be equal (and equal to the oracle).
do
	local e1: any = { id = "k", path = "Workspace/K", name = "K", className = "Part", depth = 1, siblingIndex = 1, childCount = 0, duplicateSiblingName = false, properties = { Bbb = 2, Aaa = 1, Ccc = 3 }, attributes = {}, tags = {} }
	local e2: any = { id = "k", path = "Workspace/K", name = "K", className = "Part", depth = 1, siblingIndex = 1, childCount = 0, duplicateSiblingName = false, properties = { Ccc = 3, Aaa = 1, Bbb = 2 }, attributes = {}, tags = {} }
	check("sorted keys :: insertion order irrelevant", Hash.hashInstance(e1) == Hash.hashInstance(e2))
	check("sorted keys :: equals oracle", Hash.hashInstance(e1) == oracleHashInstance(e1))
end

-- ============================================================================
-- serviceOf parity
-- ============================================================================
do
	for _, p in ipairs({ "Workspace/Model/Part", "Workspace", "ServerScriptService/Main", "/leadingslash", "" }) do
		check("serviceOf(" .. p .. ") matches oracle", Hash.serviceOf(p) == oracleServiceOf(p))
	end
	-- nil path explicitly (not in the ipairs because nil terminates the array).
	check("serviceOf(nil) == ''", Hash.serviceOf(nil) == "" and oracleServiceOf(nil) == "")
	check("serviceOf single segment == whole path", Hash.serviceOf("Workspace") == "Workspace")
	-- Leading slash: "^([^/]+)" needs >=1 non-slash char before the slash, so it
	-- matches nil and the monolith falls back to `path or ""` == the whole path.
	-- This is the verbatim behavior (NOT ""): assert the fallback, matching oracle.
	check("serviceOf leading slash -> whole path (verbatim fallback)", Hash.serviceOf("/x") == "/x" and oracleServiceOf("/x") == "/x")
end

-- ============================================================================
-- Byte helpers parity
-- ============================================================================
do
	-- fpZero: 32 zeros.
	local z = Hash.fpZero()
	check("fpZero length 32", #z == 32)
	local allZero = true
	for i = 1, 32 do
		if z[i] ~= 0 then
			allZero = false
		end
	end
	check("fpZero all zeros", allZero)
	check("fpZero matches oracle hex", Hash.fpBytesToHex(z) == oracleBytesToHex(oracleZeroBytes()))

	-- fpHexToBytes round-trips a real fingerprint and matches the oracle.
	local fp = Hash.hashInstance({ id = "rt", path = "Workspace/RT", name = "RT", className = "Part", depth = 1, siblingIndex = 1, childCount = 0, duplicateSiblingName = false, properties = {}, attributes = {}, tags = {} } :: any)
	local bytes = Hash.fpHexToBytes(fp)
	local oracleBytes = oracleHexToBytes(fp)
	local bytesMatch = (#bytes == 32)
	for i = 1, 32 do
		if bytes[i] ~= oracleBytes[i] then
			bytesMatch = false
		end
	end
	check("fpHexToBytes matches oracle", bytesMatch)
	check("fpHexToBytes -> fpBytesToHex round-trips", Hash.fpBytesToHex(bytes) == fp)

	-- bad/short hex -> zeros (tonumber fallback).
	local badBytes = Hash.fpHexToBytes("zz")
	check("fpHexToBytes bad hex -> first byte 0", badBytes[1] == 0)
	check("fpHexToBytes short hex -> zeros tail", badBytes[32] == 0)

	-- fpXor: XOR is involutive — xoring twice restores the target; matches oracle.
	local target = Hash.fpHexToBytes(fp)
	local other = Hash.fpHexToBytes(oracleBytesToHex(oracleHexToBytes("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")))
	local oTarget = oracleHexToBytes(fp)
	Hash.fpXor(target, other)
	oracleXorBytes(oTarget, oracleHexToBytes("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
	local xorMatch = true
	for i = 1, 32 do
		if target[i] ~= oTarget[i] then
			xorMatch = false
		end
	end
	check("fpXor matches oracle", xorMatch)
	-- involution: xor the same `other` back in -> original fp bytes.
	Hash.fpXor(target, other)
	check("fpXor involutive (twice -> original)", Hash.fpBytesToHex(target) == fp)
	-- fpXor returns target (call-site convenience).
	check("fpXor returns target", Hash.fpXor(Hash.fpZero(), Hash.fpZero()) ~= nil)
end

if failures == 0 then
	print("ALL HASH TESTS PASSED")
else
	print(("%d FAILURE(S)"):format(failures))
	error("Hash.spec failed", 0)
end
