--!strict
-- Headless test for Capture's PURE surface: the parts that need no Roblox
-- DataModel — shouldYield, the base64 codec (WIRE-CRITICAL: the daemon decodes the
-- exact same alphabet/padding, so a drifted encoder corrupts every non-UTF-8
-- script source), and serializeValue over scalars / nil / nested tables / the
-- {type="Unsupported"} default. The datatype branches (Vector3/CFrame/…), the
-- curation lookups (need an Instance), readProperties/readSource/buildSnapshot and
-- buildUpsertedEntry need the engine and are covered by the in-engine SelfTest.
--
-- Wire parity for base64 is guarded against an embedded verbatim oracle (the
-- monolith's base64encode/decode copied as it stood at 0.4.21) plus known RFC-4648
-- vectors, so a refactor can never silently change the bytes the daemon sees.
-- Run:
--   lune run plugin/src/__tests__/Capture.spec.luau

local Capture = require("../Capture")

local failures = 0
local function check(label: string, cond: boolean)
	if not cond then
		failures += 1
		print("FAIL: " .. label)
	else
		print("ok: " .. label)
	end
end

-- ============================================================================
-- ORACLE: the monolith's base64 codec, copied verbatim (StudioStud.plugin.lua
-- :1810-1874 as it stood at 0.4.21). Do NOT refactor — it is the reference the
-- port must reproduce byte-for-byte.
-- ============================================================================

local ORACLE_B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function oracleEncode(raw: string): string
	local out = {}
	local i = 1
	while i <= #raw do
		local b1 = string.byte(raw, i)
		local b2 = string.byte(raw, i + 1)
		local b3 = string.byte(raw, i + 2)
		local n = (b1 or 0) * 65536 + ((b2 or 0) * 256) + (b3 or 0)
		local c1 = math.floor(n / 262144) % 64 + 1
		local c2 = math.floor(n / 4096) % 64 + 1
		local c3 = math.floor(n / 64) % 64 + 1
		local c4 = n % 64 + 1
		table.insert(out, string.sub(ORACLE_B64, c1, c1))
		table.insert(out, string.sub(ORACLE_B64, c2, c2))
		if b2 then
			table.insert(out, string.sub(ORACLE_B64, c3, c3))
		else
			table.insert(out, "=")
		end
		if b3 then
			table.insert(out, string.sub(ORACLE_B64, c4, c4))
		else
			table.insert(out, "=")
		end
		i += 3
	end
	return table.concat(out)
end

-- ============================================================================
-- Public interface presence
-- ============================================================================
check("shouldYield is a function", type(Capture.shouldYield) == "function")
check("serializeValue is a function", type(Capture.serializeValue) == "function")
check("base64encode is a function", type(Capture.base64encode) == "function")
check("base64decode is a function", type(Capture.base64decode) == "function")
check("buildUpsertedEntry is a function", type(Capture.buildUpsertedEntry) == "function")
check("buildSnapshot is a function", type(Capture.buildSnapshot) == "function")
check("getPropertyNames is a function", type(Capture.getPropertyNames) == "function")
check("curatedSet is a function", type(Capture.curatedSet) == "function")
check("readProperties is a function", type(Capture.readProperties) == "function")
check("readSource is a function", type(Capture.readSource) == "function")
check("instanceIdByRef starts a table", type(Capture.instanceIdByRef) == "table")
check("pathByRef starts a table", type(Capture.pathByRef) == "table")

-- ============================================================================
-- shouldYield — verbatim predicate
-- ============================================================================
check("shouldYield(0,500) false (count must be > 0)", Capture.shouldYield(0, 500) == false)
check("shouldYield(500,500) true", Capture.shouldYield(500, 500) == true)
check("shouldYield(1000,500) true", Capture.shouldYield(1000, 500) == true)
check("shouldYield(499,500) false", Capture.shouldYield(499, 500) == false)
check("shouldYield(501,500) false", Capture.shouldYield(501, 500) == false)
check("shouldYield(500,0) false (yieldEvery must be > 0)", Capture.shouldYield(500, 0) == false)
check("shouldYield(3,1) true (every instance)", Capture.shouldYield(3, 1) == true)

-- ============================================================================
-- serializeValue — scalars pass through unchanged
-- ============================================================================
check("serializeValue(nil) == nil", Capture.serializeValue(nil) == nil)
check("serializeValue(true) == true", Capture.serializeValue(true) == true)
check("serializeValue(false) == false", Capture.serializeValue(false) == false)
check("serializeValue(42) == 42", Capture.serializeValue(42) == 42)
check("serializeValue(-3.5) == -3.5", Capture.serializeValue(-3.5) == -3.5)
check("serializeValue('hi') == 'hi'", Capture.serializeValue("hi") == "hi")

-- ============================================================================
-- serializeValue — tables recurse (string keys via tostring), scalars preserved
-- ============================================================================
do
	local out: any = Capture.serializeValue({ a = 1, b = "x", c = true, d = false })
	check("table: a recurses to 1", out.a == 1)
	check("table: b recurses to 'x'", out.b == "x")
	check("table: c recurses to true", out.c == true)
	check("table: d recurses to false", out.d == false)
end
do
	-- numeric keys are tostring'd (the monolith's `out[tostring(key)]`).
	local out: any = Capture.serializeValue({ [1] = "first", [2] = "second" })
	check("table numeric keys stringified", out["1"] == "first" and out["2"] == "second")
end
do
	-- nested table recursion.
	local out: any = Capture.serializeValue({ outer = { inner = 7 } })
	check("table nested recurses", out.outer.inner == 7)
end

-- ============================================================================
-- serializeValue — the {type="Unsupported"} default for any unhandled typeof.
-- A function is `typeof "function"`, which no branch handles → Unsupported.
-- ============================================================================
do
	local out: any = Capture.serializeValue(function() end)
	check("function -> Unsupported", type(out) == "table" and out.type == "Unsupported")
	check("Unsupported carries reason = typeof", out.reason == "function")
end

-- ============================================================================
-- base64encode — matches the verbatim oracle on a battery of inputs (incl. the
-- non-UTF-8 high bytes that are the WHOLE REASON this path exists) + RFC vectors.
-- ============================================================================
local function parityEnc(label: string, raw: string)
	check(label .. " :: matches oracle", Capture.base64encode(raw) == oracleEncode(raw))
end
parityEnc("empty", "")
parityEnc("one byte", "M")
parityEnc("two bytes", "Ma")
parityEnc("three bytes", "Man")
parityEnc("ascii script", "print('hello world')")
parityEnc("high bytes (non-UTF-8)", string.char(0xFF, 0x00, 0x80, 0xC0, 0x01))
parityEnc("all 256 bytes", (function()
	local parts = {}
	for b = 0, 255 do
		parts[#parts + 1] = string.char(b)
	end
	return table.concat(parts)
end)())

-- Known RFC-4648 vectors (padding correctness — the daemon relies on it).
check("rfc 'f' -> 'Zg=='", Capture.base64encode("f") == "Zg==")
check("rfc 'fo' -> 'Zm8='", Capture.base64encode("fo") == "Zm8=")
check("rfc 'foo' -> 'Zm9v'", Capture.base64encode("foo") == "Zm9v")
check("rfc 'foob' -> 'Zm9vYg=='", Capture.base64encode("foob") == "Zm9vYg==")
check("rfc 'fooba' -> 'Zm9vYmE='", Capture.base64encode("fooba") == "Zm9vYmE=")
check("rfc 'foobar' -> 'Zm9vYmFy'", Capture.base64encode("foobar") == "Zm9vYmFy")

-- ============================================================================
-- base64 round-trip: decode(encode(x)) == x across the same battery, so a script
-- source survives the non-UTF-8 path intact.
-- ============================================================================
local function roundTrip(label: string, raw: string)
	check(label .. " :: round-trips", Capture.base64decode(Capture.base64encode(raw)) == raw)
end
roundTrip("empty", "")
roundTrip("one byte", "M")
roundTrip("two bytes", "Ma")
roundTrip("three bytes", "Man")
roundTrip("ascii script", "local x = 1\nprint(x)\n")
roundTrip("high bytes (non-UTF-8)", string.char(0xFF, 0x00, 0x80, 0xC0, 0x01, 0xFE))
roundTrip("all 256 bytes", (function()
	local parts = {}
	for b = 0, 255 do
		parts[#parts + 1] = string.char(b)
	end
	return table.concat(parts)
end)())

-- base64decode ignores non-alphabet chars (whitespace/newlines in transit).
check("decode strips whitespace", Capture.base64decode("Zm9v\n YmFy") == "foobar")

if failures == 0 then
	print("ALL CAPTURE TESTS PASSED")
else
	print(("%d FAILURE(S)"):format(failures))
	error("Capture.spec failed", 0)
end
