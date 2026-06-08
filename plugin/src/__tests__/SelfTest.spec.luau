--!strict
-- Headless guard for the HASH-PARITY regression that SelfTest.run asserts in-engine.
--
-- SelfTest.luau itself is an in-engine integration harness: it requires Shell, which
-- calls plugin:CreateDockWidgetPluginGui at module load, so it cannot be required
-- under lune. But the NEW Hash-parity regression SelfTest adds — "Hash.hashInstance
-- must agree, byte-for-byte, with the 0.4.21 monolith fingerprint recipe" — has a
-- PURE kernel that CAN run headless. This spec re-embeds the exact monolith oracle
-- (copied verbatim from StudioStud.plugin.lua:2189-2302, the same oracle SelfTest.run
-- carries inline) and asserts parity over the same battery SelfTest checks in Studio,
-- so the release-blocking wire guarantee is enforced in CI without a Roblox runtime.
--
-- (This is complementary to Hash.spec — Hash.spec is the canonical Hash parity test;
-- this one specifically pins the oracle/entries SelfTest.run uses, so the in-engine
-- gate and the headless gate provably check the same recipe.)
-- Run:
--   lune run plugin/src/__tests__/SelfTest.spec.luau

local Hash = require("../Hash")

-- ============================================================================
-- ORACLE: the monolith's fingerprint algorithm, copied verbatim — the SAME oracle
-- embedded in SelfTest.luau. Do NOT refactor; it is the reference the port must
-- reproduce.
-- ============================================================================

local ORACLE_OFFSETS = { 0x811C9DC5, 0x050C5D1F, 0x9E3779B9, 0x7F4A7C15 }
local ORACLE_PRIME = 16777619

local function oracleSortedKeys(tbl: any): { string }
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
		return "b:" .. (if value then "1" else "0")
	elseif kind == "nil" then
		return "z"
	elseif kind == "table" then
		if #value > 0 then
			local parts: { string } = {}
			for _, item in ipairs(value) do
				parts[#parts + 1] = oracleSerializeScalar(item)
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local parts: { string } = {}
		for _, key in ipairs(oracleSortedKeys(value)) do
			parts[#parts + 1] = key .. "=" .. oracleSerializeScalar(value[key])
		end
		return "{" .. table.concat(parts, ";") .. "}"
	end
	return "u:" .. tostring(value)
end

local function oracleSerializeMap(map: any): string
	local parts: { string } = {}
	for _, key in ipairs(oracleSortedKeys(map or {})) do
		parts[#parts + 1] = key .. "=" .. oracleSerializeScalar(map[key])
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

local function oracleHashInstance(entry: any): string
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

-- ============================================================================
-- Harness
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

-- The exact entries SelfTest.run's Hash-parity block uses.
local full: any = {
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

check("Hash parity: full entry matches monolith oracle", Hash.hashInstance(full) == oracleHashInstance(full))
check("Hash parity: full entry is 64 lowercase hex", #Hash.hashInstance(full) == 64 and string.match(Hash.hashInstance(full), "^[0-9a-f]+$") == Hash.hashInstance(full))

-- source excluded (M3): an entry differing only by source hashes equal.
local withSource: any = table.clone(full)
withSource.source = "print('x')"
withSource.sourceEncoding = "utf8"
check("Hash parity: source excluded from hash (M3)", Hash.hashInstance(withSource) == Hash.hashInstance(full))

-- sparse defaults reproduce the monolith `or` fallbacks.
local sparse: any = { id = "sp" }
check("Hash parity: sparse defaults match oracle", Hash.hashInstance(sparse) == oracleHashInstance(sparse))

-- property key-order invariance (sorted keys).
local reordered: any = table.clone(full)
reordered.properties = {
	CFrame = { 0, 5, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 },
	Size = { type = "Vector3", x = 1, y = 2, z = 3 },
	CanCollide = false,
	Anchored = true,
	Transparency = 0.5,
}
check("Hash parity: property key-order invariant", Hash.hashInstance(reordered) == Hash.hashInstance(full))

if failures == 0 then
	print("ALL SELFTEST HASH-PARITY TESTS PASSED")
else
	print(("%d FAILURE(S)"):format(failures))
	error("SelfTest.spec failed", 0)
end
