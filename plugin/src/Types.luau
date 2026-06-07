--!strict
-- Types — shared type aliases for the strict-typed plugin rewrite.
-- Single source of truth for the protocol-v2 wire shapes, fingerprint byte
-- arrays, and live-engine state. No logic, no constants, no runtime values:
-- every other module imports these and annotates against them so the wire
-- format is pinned in exactly one place.

-- == Primitive aliases ==

-- A fingerprint hex string: 64 lowercase hex chars (4-lane FNV-32 → 64-hex).
-- Kept a plain `string` alias for self-documentation at call sites; the length
-- invariant is enforced by Hash, not the type system.
export type Hex64 = string

-- A fingerprint byte array: exactly 32 bytes (0..255), the unpacked form of a
-- Hex64 used by the per-service XOR accumulators.
export type Bytes = { number }

-- The two live session modes carried on every tick (D1/D3). Edit ships ops;
-- play is a pure keepalive.
export type SessionMode = "edit" | "play"

-- Source text encoding tag for a LuaSourceContainer's `source` (utf8 inline, or
-- base64 when the source is not valid UTF-8).
export type SourceEncoding = "utf8" | "base64"

-- == Capture maps ==

-- Serialized property values keyed by property name. Values are the output of
-- `serializeValue` (scalars or tagged datatype tables incl. {type="Unsupported"}),
-- so the value type is intentionally open.
export type PropertyMap = { [string]: any }

-- Instance attributes (captured wholesale, no whitelist) keyed by attribute name.
export type AttributeMap = { [string]: any }

-- CollectionService tags on an instance, in capture order.
export type Tags = { string }

-- == Instance entry (the wire shape) ==

-- A single captured instance as it appears in a tick packet's `ops.upserted`
-- and in the baseline tree. This is the NON-NEGOTIABLE wire contract: the field
-- set is pinned (className|name|parentId|path|depth|siblingIndex|childCount|
-- duplicateSiblingName|properties|attributes|tags|fp, with optional source/
-- sourceEncoding). `source` is EXCLUDED from the drift hash by design (M3) — see
-- Hash; it rides the entry but is not hashed.
export type InstanceEntry = {
	id: string,
	parentId: string?, -- nil at a captured root
	path: string,
	name: string,
	className: string,
	depth: number,
	siblingIndex: number,
	childCount: number,
	duplicateSiblingName: boolean,
	properties: PropertyMap,
	attributes: AttributeMap,
	tags: Tags,
	fp: Hex64,
	source: string?, -- LuaSourceContainer text; absent for non-script instances
	sourceEncoding: SourceEncoding?, -- present iff `source` is present
}

-- == Ops / tick packet (protocol v2, design §4.1) ==

-- Accumulated changes since the previous tick. Sent inline when small; spilled
-- to a chunked bulk upload (referenced by TickPacket.bulkRef) when over threshold.
export type Ops = {
	upserted: { InstanceEntry },
	removed: { string }, -- removed instance ids
}

-- The POST /studio-stud/tick request body.
export type TickPacket = {
	placeId: string,
	sessionMode: SessionMode,
	baseRevision: number,
	serviceFingerprints: { [string]: Hex64 }, -- per captured root service
	ops: Ops,
	bulkRef: string?, -- set instead of fresh ops when payload spilled to chunks
}

-- A single pending Studio mutation in a tick response (reserved write seam;
-- empty until the write half is built).
export type ApplyScript = {
	studioPath: string,
	newSource: string,
	expectedPriorHash: string,
}

-- The daemon → plugin tick response. Fields beyond `ok` are optional because
-- error responses (`{ ok=false, error=... }`) and partial acks omit them; this
-- is the trust boundary shape — Transport hardens it once before downstream use.
export type TickResponse = {
	ok: boolean,
	revision: number?,
	instanceCount: number?,
	driftServices: { string }?, -- services whose fingerprint disagreed (usually nil/[])
	request: any?, -- AI-queued job, e.g. { reason = "rebaseline" }
	applyScripts: { ApplyScript }?, -- downstream write channel (reserved)
	error: string?, -- set on a non-ok response (e.g. "no_baseline")
}

-- == Allow-list (property curation) ==

-- Membership set for one class: propName → readOnly. O(1) lookup used as the
-- in-handler curated filter.
export type ClassPropSet = { [string]: boolean }

-- The parsed /allowlist response: per-class membership sets + ordered name lists
-- (the order capture reads properties in). `version` is daemon-supplied and
-- opaque to the plugin.
export type AllowList = {
	version: any,
	sets: { [string]: ClassPropSet }, -- [className] = { [propName] = readOnly }
	lists: { [string]: { string } }, -- [className] = { propName, ... }
}

-- == Live-engine state ==

-- Mutable state owned by the Live module: dirty sets, monotonic edit stamps
-- (the no-data-loss invariant — edits mid-tick are not lost), per-instance and
-- per-service fingerprint accumulators, and revision/count bookkeeping. Held as
-- explicit typed fields (NOT a giant closure) so the C1–C3 bug class is
-- structurally impossible.
export type LiveState = {
	liveRunning: boolean,
	currentRevision: number,
	liveInstanceCount: number,
	networkErrorCount: number,
	dirtyStamp: number, -- monotonic edit counter
	dirtyUpsert: { [Instance]: boolean },
	dirtyRemoved: { [string]: boolean }, -- [id] = true
	upsertStamp: { [Instance]: number }, -- stamp at last mark
	removedStamp: { [string]: number }, -- [id] = stamp at last mark
	instFp: { [string]: Hex64 }, -- [id] = current entry fingerprint
	serviceFpBytes: { [string]: Bytes }, -- [service] = 32-byte XOR accumulator
}

-- This module is types-only; nothing to instantiate. The empty table keeps it a
-- valid ModuleScript whose exported types are imported via `require`.
return {}
