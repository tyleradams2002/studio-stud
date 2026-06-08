--!strict
-- Hash — the fingerprint recipe, ported VERBATIM from the monolith's Live
-- fingerprint block (StudioStud.plugin.lua:2189-2302). This is FP-1, the
-- plugin-authoritative drift hash: the daemon stores and XORs whatever value the
-- plugin emits, so the hash bytes MUST be byte-identical to the old plugin or
-- every tick reports phantom drift. NOTHING here may be "improved" — the canonical
-- string, the lane offsets, the FNV multiply/mod, and the hex layout are the wire.
--
-- This module is the SINGLE SOURCE OF TRUTH for the one fingerprint recipe used by
-- both the per-op entry hash (Fingerprints.applyFpUpsert) and the per-service XOR
-- accumulator (Fingerprints byte ops). It owns:
--   * hashInstance(entry) -> Hex64 — the 4-lane FNV-32 → 64-hex canonical hash.
--   * serviceOf(path) -> string — the leading path segment (service name).
--   * the byte helpers fpZero / fpHexToBytes / fpBytesToHex / fpXor used by the
--     XOR accumulators. (Named fpZero/fpXor here, matching the contract; the
--     monolith's locals were fpZeroBytes/fpXorBytes.)
--
-- M3 (by design): `source` is EXCLUDED from the canonical string. A script's text
-- edit changes `source` but NOT its fingerprint, so source-only edits do not show
-- as structural drift; the source rides the entry (Types.InstanceEntry.source) but
-- is never hashed. The canonical field order is, verbatim:
--   className | name | parentId | path | depth | siblingIndex | childCount |
--   duplicateSiblingName(0/1) | properties | attributes | tags
-- with map keys sorted and tags joined by ",".
--
-- PURE: no DataModel reads, no module state, no upvalue forward references. Every
-- function is a plain local assigned into the module table before return, so there
-- is no before-local window (the C1-C3 bug class this rewrite exists to kill).

local Types = require("./Types")

type Hex64 = Types.Hex64
type Bytes = Types.Bytes
type InstanceEntry = Types.InstanceEntry

-- == Public interface ==

export type HashModule = {
	-- The drift fingerprint of an instance entry: a 64-char lowercase-hex string
	-- (4 lanes × 16 hex). VERBATIM 4-lane FNV-32 over the canonical pipe string
	-- (source EXCLUDED). Byte-identical to the monolith's Live.hashInstance.
	hashInstance: (entry: InstanceEntry) -> Hex64,

	-- The service (root) name of a path: the leading segment before the first "/"
	-- (the whole path when there is no "/"). Empty string for a nil/"" path. Used
	-- to bucket fingerprints into per-service XOR accumulators.
	serviceOf: (path: string?) -> string,

	-- A fresh 32-zero byte array (one service's empty XOR accumulator).
	fpZero: () -> Bytes,
	-- Unpack a 64-hex fingerprint into its 32 bytes (0..255). Out-of-range / bad
	-- hex pairs become 0 (tonumber fallback), matching the monolith.
	fpHexToBytes: (hex: string) -> Bytes,
	-- Pack a 32-byte array back into 64 lowercase hex (nil bytes → "00").
	fpBytesToHex: (bytes: Bytes) -> Hex64,
	-- In-place XOR of `source` into `target` over 32 bytes (the accumulator op).
	-- nil entries on either side are treated as 0. Mutates and returns `target`.
	fpXor: (target: Bytes, source: Bytes) -> Bytes,
}

-- == FNV constants (the wire — do not touch) ==

-- Four lane offsets (monolith :2189). Lane i hashes the canonical string with
-- offset[i] for the low word and a derived offset for the high word.
local FNV32_OFFSETS = { 0x811C9DC5, 0x050C5D1F, 0x9E3779B9, 0x7F4A7C15 }
-- The 32-bit FNV prime (monolith :2190).
local FNV32_PRIME = 16777619
-- 2^32, the FNV-32 modulus. Named so the hot multiply reads as a masking step.
local FNV32_MOD = 4294967296
-- High-word offset perturbation: lane offset XOR this constant (monolith :2267).
local HI_OFFSET_XOR = 0xA5A5A5A5

-- == Canonical-string serialization (verbatim) ==

-- Sorted string keys of a table. Every key is tostring'd first so mixed key types
-- order deterministically, then table.sort'd (monolith :2192). Returns a fresh
-- ordered array — the canonical map serialization iterates this, never raw pairs,
-- so the byte order is stable across runs.
local function fpSortedKeys(tbl: { [any]: any }): { string }
	local keys: { string } = {}
	for key in pairs(tbl) do
		keys[#keys + 1] = tostring(key)
	end
	table.sort(keys)
	return keys
end

-- Forward declaration so fpSerializeScalar can recurse into nested tables without
-- referencing a not-yet-assigned local (it calls itself; declaring the type up
-- front keeps the recursion strict-typed and avoids a before-local read).
local fpSerializeScalar: (value: any) -> string

-- Serialize one scalar value to its canonical token (monolith :2201). typeof-based
-- so it matches the engine's runtime type of captured property values:
--   string  -> "s:" .. value
--   number  -> "n:" .. tostring(value)
--   boolean -> "b:1" / "b:0"
--   nil     -> "z"
--   table   -> array form "[a,b,...]" when #value > 0, else map form "{k=v;...}"
--   else    -> "u:" .. tostring(value)  (userdata/datatypes etc.)
-- Recurses for nested tables (arrays and maps) exactly as the monolith did.
function fpSerializeScalar(value: any): string
	local kind = typeof(value)
	if kind == "string" then
		return "s:" .. value
	elseif kind == "number" then
		return "n:" .. tostring(value)
	elseif kind == "boolean" then
		-- Real if/else over the boolean — not the and/or trap (luau-craft).
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
				parts[#parts + 1] = fpSerializeScalar(item)
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local parts: { string } = {}
		for _, key in ipairs(fpSortedKeys(tbl)) do
			parts[#parts + 1] = key .. "=" .. fpSerializeScalar(tbl[key])
		end
		return "{" .. table.concat(parts, ";") .. "}"
	end
	return "u:" .. tostring(value)
end

-- Serialize a property/attribute map to "key=scalar;key=scalar;..." with keys
-- sorted (monolith :2228). A nil map serializes as the empty string.
local function fpSerializeMap(map: { [string]: any }?): string
	local source: { [any]: any } = map or {}
	local parts: { string } = {}
	for _, key in ipairs(fpSortedKeys(source)) do
		parts[#parts + 1] = key .. "=" .. fpSerializeScalar(source[key])
	end
	return table.concat(parts, ";")
end

-- == FNV-32 core (verbatim) ==

-- One lane of FNV-32 over a string from a given offset (monolith :2236).
-- h := offset; for each byte: h = ((h XOR byte) * PRIME) mod 2^32. Hot path:
-- one xor + one multiply + one mod per character, no allocation.
local function fnv32(str: string, offset: number): number
	local h = offset
	for i = 1, #str do
		h = bit32.bxor(h, string.byte(str, i))
		h = (h * FNV32_PRIME) % FNV32_MOD
	end
	return h
end

-- == hashInstance (the FP-1 recipe — byte-identical to the monolith) ==

-- Build the canonical pipe string and hash it across 4 lanes into 64 hex chars.
-- VERBATIM port of Live.hashInstance (monolith :2245). Field order and defaults
-- are the wire: each missing field falls back exactly as the old code did
-- (className/name/parentId/path -> "", depth/siblingIndex/childCount -> 0,
-- duplicateSiblingName -> "1"/"0"). `source` is NOT included (M3). For each lane,
-- the low word hashes the canonical string from the lane offset and the high word
-- hashes canonical .. "#" .. lane from (offset XOR 0xA5A5A5A5); the lane emits
-- "%08x%08x" (lo then hi), and the four lanes concatenate to 64 hex.
local function hashInstance(entry: InstanceEntry): Hex64
	-- entry is typed, but the monolith hashed `entry.x or default` on raw capture
	-- output; widen to `any` for the exact tostring/or fallbacks so the bytes match
	-- even if a field arrives nil off an untrusted/partial entry.
	local e = entry :: any
	local parts: { string } = {
		tostring(e.className or ""),
		tostring(e.name or ""),
		tostring(e.parentId or ""),
		tostring(e.path or ""),
		tostring(e.depth or 0),
		tostring(e.siblingIndex or 0),
		tostring(e.childCount or 0),
		(if e.duplicateSiblingName then "1" else "0"),
		fpSerializeMap(e.properties),
		fpSerializeMap(e.attributes),
	}
	local tagParts: { string } = {}
	for _, tag in ipairs(e.tags or {}) do
		tagParts[#tagParts + 1] = tostring(tag)
	end
	parts[#parts + 1] = table.concat(tagParts, ",")

	local canonical = table.concat(parts, "|")
	local hexParts: { string } = {}
	for lane = 1, 4 do
		local lo = fnv32(canonical, FNV32_OFFSETS[lane])
		local hi = fnv32(canonical .. "#" .. tostring(lane), bit32.bxor(FNV32_OFFSETS[lane], HI_OFFSET_XOR))
		hexParts[#hexParts + 1] = string.format("%08x%08x", lo, hi)
	end
	return table.concat(hexParts)
end

-- == serviceOf ==

-- Leading path segment before the first "/", or the whole path when there is no
-- "/". A nil path is treated as "" (monolith :2300): match returns nil, so we
-- fall back to "" — preserving the old `... or (path or "")` chain.
local function serviceOf(path: string?): string
	local p = path or ""
	return string.match(p, "^([^/]+)") or p
end

-- == Byte helpers (32-byte XOR accumulator primitives) ==

-- A fresh 32-zero byte array (monolith fpZeroBytes :2273).
local function fpZero(): Bytes
	return table.create(32, 0)
end

-- Unpack 64 hex chars into 32 bytes. Each byte is the value of a 2-char hex pair;
-- a bad/short pair yields 0 via the tonumber fallback (monolith fpHexToBytes :2278).
local function fpHexToBytes(hex: string): Bytes
	local bytes: Bytes = table.create(32, 0)
	for i = 1, 32 do
		bytes[i] = tonumber(string.sub(hex, (i - 1) * 2 + 1, (i - 1) * 2 + 2), 16) or 0
	end
	return bytes
end

-- Pack 32 bytes into 64 lowercase hex (nil entries → "00"; monolith fpBytesToHex
-- :2286).
local function fpBytesToHex(bytes: Bytes): Hex64
	local parts: { string } = table.create(32, "")
	for i = 1, 32 do
		parts[i] = string.format("%02x", bytes[i] or 0)
	end
	return table.concat(parts)
end

-- In-place 32-byte XOR of `source` into `target` (monolith fpXorBytes :2294).
-- nil entries on either side count as 0. Returns target for call-site convenience
-- (the monolith mutated in place; returning it changes nothing for in-place uses).
local function fpXor(target: Bytes, source: Bytes): Bytes
	for i = 1, 32 do
		target[i] = bit32.bxor(target[i] or 0, source[i] or 0)
	end
	return target
end

-- == Module table ==

-- Assembled as a real value before return; every cross-reference above is a plain
-- local, so there is no forward-reference-before-local read anywhere in the module.
local Hash: HashModule = {
	hashInstance = hashInstance,
	serviceOf = serviceOf,
	fpZero = fpZero,
	fpHexToBytes = fpHexToBytes,
	fpBytesToHex = fpBytesToHex,
	fpXor = fpXor,
}

return Hash
