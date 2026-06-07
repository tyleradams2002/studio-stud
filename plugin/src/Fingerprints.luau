--!strict
-- Fingerprints — the live per-service XOR accumulators, ported faithfully from the
-- monolith's Live fingerprint block (StudioStud.plugin.lua: instFp/serviceFpBytes
-- :2183-2184, serviceFpHex :2304, serviceFingerprintsWire :2312, applyFpUpsert
-- :2320, applyFpRemove :2337, resetFingerprints :2348). This is the FP-1 live half:
-- the daemon stores and XORs whatever per-service fingerprint the plugin emits, so
-- the accumulator math (and the recipe behind it) MUST be byte-identical to the old
-- plugin or every tick reports phantom drift.
--
-- The recipe itself (the 4-lane FNV → 64-hex hash and the 32-byte XOR primitives)
-- lives in Hash — the single source of truth. This module owns ONLY the per-service
-- accumulation: which fingerprint belongs to which service, and the add / remove /
-- REPARENT inverse (XOR the old fingerprint out of the old service, XOR the new
-- fingerprint into the new service). It never re-derives the hash math.
--
-- The accumulator is XOR-based, so it is order-independent and self-inverse:
--   * add A, add B            -> serviceFp == hash(A) XOR hash(B)
--   * remove A                -> serviceFp == hash(B)        (A XOR'd back out)
--   * re-add A                -> serviceFp == hash(A) XOR hash(B)  (restored)
-- A reparent is just remove-from-old + add-to-new in one call: applyFpUpsert with a
-- distinct oldPath XORs the stored fingerprint out of serviceOf(oldPath) and the new
-- fingerprint into serviceOf(entry.path).
--
-- STATE: instFp ([id] = current 64-hex fingerprint) and serviceFpBytes ([service] =
-- 32-byte XOR accumulator) are module fields on the Fingerprints table — every method
-- reaches them through `Fingerprints.*`, never a forward-referenced upvalue, so there
-- is no before-local window (the C1-C3 bug class this rewrite exists to kill). The
-- monolith held the same two tables on its giant Live closure; here they are explicit
-- typed fields the Live engine can also read (Types.LiveState pins their shape).
--
-- M3 (by design): a fingerprint never includes `source` (Hash excludes it), so a
-- script-only edit does not change the per-service accumulator — no phantom drift.

local Types = require("./Types")
local Hash = require("./Hash")

type Hex64 = Types.Hex64
type Bytes = Types.Bytes

-- The minimal entry shape applyFpUpsert needs: an optional precomputed fingerprint
-- and the path (for the new service). It is a structural SUBSET of Types.InstanceEntry
-- so a real entry satisfies it, but the monolith's tests also pass partials like
-- `{ fp = ..., path = ... }` — accepting `FpEntry` keeps those strict-clean while the
-- field set stays pinned. `fp` is optional: when absent we hash the (full) entry, so a
-- partial entry MUST carry `fp` or it will be hashed with empty/default fields.
export type FpEntry = {
	fp: Hex64?,
	path: string,
	-- The remaining InstanceEntry fields are read ONLY when fp is nil (Hash widens to
	-- any internally and applies the same `x or default` fallbacks the monolith used),
	-- so they are optional here.
	className: string?,
	name: string?,
	parentId: string?,
	depth: number?,
	siblingIndex: number?,
	childCount: number?,
	duplicateSiblingName: boolean?,
	properties: { [string]: any }?,
	attributes: { [string]: any }?,
	tags: { string }?,
}

-- == Public interface ==

export type FingerprintsModule = {
	-- [id] = the instance's current 64-hex fingerprint (the value last XOR'd into a
	-- service accumulator for that id). Read by the Live engine for removal bookkeeping;
	-- mutated only through applyFpUpsert / applyFpRemove / reset.
	instFp: { [string]: Hex64 },
	-- [service] = the 32-byte XOR accumulator of every live instance's fingerprint in
	-- that service. serviceFingerprintsWire emits these as 64-hex on each tick.
	serviceFpBytes: { [string]: Bytes },

	-- The 64-hex fingerprint of one service: 64 zeros when the service has no
	-- accumulator yet, else its bytes packed to hex. (Monolith Live.serviceFpHex.)
	serviceFpHex: (self: FingerprintsModule, service: string) -> Hex64,

	-- The serviceFingerprints wire map: { [service] = 64-hex } over every service that
	-- has an accumulator. This is the TickPacket.serviceFingerprints field.
	-- (Monolith Live.serviceFingerprintsWire.)
	serviceFingerprintsWire: (self: FingerprintsModule) -> { [string]: Hex64 },

	-- Add / update / REPARENT one instance's fingerprint. newFp = entry.fp or
	-- Hash.hashInstance(entry); MUTATES entry.fp to that value (the monolith did, and
	-- callers rely on the entry carrying its fp onto the wire). XORs the previously
	-- stored fingerprint (if any) out of serviceOf(oldPath or entry.path), XORs newFp
	-- into serviceOf(entry.path), and records instFp[id] = newFp. Pass oldPath when the
	-- instance moved services (reparent) so the old fingerprint leaves the OLD service.
	-- (Monolith Live.applyFpUpsert(id, entry, oldPath).)
	applyFpUpsert: (self: FingerprintsModule, id: string, entry: FpEntry, oldPath: string?) -> (),

	-- Remove one instance's fingerprint: XOR its stored fingerprint out of
	-- serviceOf(path) and clear instFp[id]. No-op on the accumulator if the id was
	-- never recorded. (Monolith Live.applyFpRemove(id, path).)
	applyFpRemove: (self: FingerprintsModule, id: string, path: string?) -> (),

	-- Drop ALL fingerprint state (instFp + serviceFpBytes) — used on full rebaseline /
	-- drift recovery / teardown so the next baseline rebuilds accumulators from scratch.
	-- (Monolith Live.resetFingerprints.)
	reset: (self: FingerprintsModule) -> (),
}

-- Forward declaration of the module table so methods reach the shared state through
-- it (Fingerprints.instFp / Fingerprints.serviceFpBytes) WITHOUT a forward-referenced
-- upvalue. Fingerprints.* is a real table field by the time any method runs.
local Fingerprints: FingerprintsModule

-- == serviceFpHex ==

-- 64-hex of a service's accumulator, or 64 zeros when none exists yet. VERBATIM
-- port of Live.serviceFpHex (monolith :2304): the bytes-missing branch returns
-- string.rep("0", 64), NOT fpZero packed (same value, but the monolith short-circuited
-- before allocating a byte array — preserved here).
local function serviceFpHex(self: FingerprintsModule, service: string): Hex64
	local bytes = self.serviceFpBytes[service]
	if not bytes then
		return string.rep("0", 64)
	end
	return Hash.fpBytesToHex(bytes)
end

-- == serviceFingerprintsWire ==

-- The per-service wire map { [service] = 64-hex } over every service with an
-- accumulator. VERBATIM port of Live.serviceFingerprintsWire (monolith :2312):
-- iterate serviceFpBytes keys, emit serviceFpHex for each. Only services that have
-- ever held a fingerprint appear (a service that was added then fully removed stays
-- in the map with a 64-zero value — exactly as the monolith left it, because
-- applyFpRemove never deletes the serviceFpBytes entry).
local function serviceFingerprintsWire(self: FingerprintsModule): { [string]: Hex64 }
	local out: { [string]: Hex64 } = {}
	for service in pairs(self.serviceFpBytes) do
		out[service] = self:serviceFpHex(service)
	end
	return out
end

-- == applyFpUpsert (add / update / reparent) ==

-- VERBATIM port of Live.applyFpUpsert (monolith :2320). Order matters and is
-- preserved exactly:
--   1. newFp = entry.fp or Hash.hashInstance(entry); write it back onto entry.fp.
--   2. newService = serviceOf(entry.path).
--   3. If an old fingerprint exists for this id, XOR it OUT of serviceOf(oldPath or
--      entry.path) — the reparent inverse. (oldPath defaults to entry.path, so a
--      same-service update XORs the old value out of the same service it goes back in.)
--   4. XOR newFp INTO newService.
--   5. instFp[id] = newFp.
-- A fresh service accumulator is fpZero() (lazily created), matching the monolith's
-- `Live.serviceFpBytes[...] or fpZeroBytes()`.
local function applyFpUpsert(self: FingerprintsModule, id: string, entry: FpEntry, oldPath: string?): ()
	-- Real if/else over the optional fp (luau-craft: no `a or b` where b can throw /
	-- allocate unconditionally — though here both are values, the monolith's `or` is
	-- a cheap fallback so we keep the same single-evaluation semantics).
	local newFp: Hex64
	if entry.fp then
		newFp = entry.fp
	else
		newFp = Hash.hashInstance(entry :: any)
	end
	entry.fp = newFp

	local newService = Hash.serviceOf(entry.path)
	local oldFp = self.instFp[id]
	if oldFp then
		local oldService = Hash.serviceOf(oldPath or entry.path)
		local svcBytes = self.serviceFpBytes[oldService]
		if not svcBytes then
			svcBytes = Hash.fpZero()
		end
		Hash.fpXor(svcBytes, Hash.fpHexToBytes(oldFp))
		self.serviceFpBytes[oldService] = svcBytes
	end

	local newBytes = self.serviceFpBytes[newService]
	if not newBytes then
		newBytes = Hash.fpZero()
	end
	Hash.fpXor(newBytes, Hash.fpHexToBytes(newFp))
	self.serviceFpBytes[newService] = newBytes

	self.instFp[id] = newFp
end

-- == applyFpRemove ==

-- VERBATIM port of Live.applyFpRemove (monolith :2337). XOR the stored fingerprint
-- out of serviceOf(path) and clear instFp[id]. If the id has no stored fingerprint,
-- only the (no-op) clear runs — the accumulator is untouched. The serviceFpBytes
-- entry is NOT deleted even when it returns to all-zero (monolith parity: the empty
-- service lingers in serviceFingerprintsWire as 64 zeros).
local function applyFpRemove(self: FingerprintsModule, id: string, path: string?): ()
	local oldFp = self.instFp[id]
	if oldFp then
		local service = Hash.serviceOf(path or "")
		local svcBytes = self.serviceFpBytes[service]
		if not svcBytes then
			svcBytes = Hash.fpZero()
		end
		Hash.fpXor(svcBytes, Hash.fpHexToBytes(oldFp))
		self.serviceFpBytes[service] = svcBytes
	end
	self.instFp[id] = nil
end

-- == reset ==

-- Drop all fingerprint state by replacing both tables with fresh empties. VERBATIM
-- port of Live.resetFingerprints (monolith :2348): new tables, not table.clear, so
-- any reference held to the OLD tables (e.g. a wire map already emitted) is unaffected.
local function reset(self: FingerprintsModule): ()
	self.instFp = {}
	self.serviceFpBytes = {}
end

-- == Module table ==

-- Assembled as a real value before return; the state tables start empty and every
-- method above reaches them via `self`, so there is no forward-reference-before-local
-- read anywhere in the module.
Fingerprints = {
	instFp = {},
	serviceFpBytes = {},
	serviceFpHex = serviceFpHex,
	serviceFingerprintsWire = serviceFingerprintsWire,
	applyFpUpsert = applyFpUpsert,
	applyFpRemove = applyFpRemove,
	reset = reset,
}

return Fingerprints
