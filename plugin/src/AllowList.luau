--!strict
-- AllowList — property-curation source of truth, ported faithfully from the
-- monolith's AllowList block (StudioStud.plugin.lua:1256-1323).
--
-- The daemon serves /studio-stud/allowlist: per exact ClassName, the ordered set
-- of properties capture should read (including inherited props) and whether each
-- is read-only. When that fetch succeeds, it overrides the static curation; when
-- it fails (daemon down, bad JSON, malformed body) the plugin keeps the static
-- Config.CLASS_PROPERTIES fallback and capture proceeds — a fetch failure is
-- NEVER fatal. This module owns the loaded-vs-fallback decision; capture's
-- getPropertyNames/curatedSet ask namesFor/setFor and fall back themselves when
-- those return nil.
--
-- Responsibilities (one each):
--   * parse(decoded) — PURE: a decoded /allowlist body -> { version, sets, lists }
--       or nil on bad input. The headless-testable surface (AllowList.spec).
--   * fetch() — GET /allowlist via Transport, parse, and on success swap in the
--       parsed sets/lists/version + mark loaded. On any failure: log (debug) and
--       leave the static fallback in place, returning false.
--   * namesFor(className) / setFor(className) — the per-class lookups capture
--       consumes. Both return nil unless loaded AND the exact class is present, so
--       an unknown class (even when loaded) falls through to the static list in
--       capture. This nil-on-unknown contract is load-bearing — reproduced exactly.
--
-- State model: this module carries mutable state (loaded/version/sets/lists). It
-- lives as fields on the module table (`AllowList.*`), and every method reaches
-- the state through that table — never through a forward-referenced upvalue. This
-- is the structural defense against the C1-C3 forward-reference bug class: the
-- table is a real value before any method runs, so there is no "before-local"
-- window to read a nil through.
--
-- TRUST BOUNDARY (harden once): the decoded /allowlist body is untrusted `any`.
-- parse is the single place it is validated; it walks every class/entry with
-- type guards and silently drops anything malformed, so namesFor/setFor only ever
-- hand capture well-formed ordered lists and boolean membership sets.

-- NB: this module does NOT require ./Config. The static CLASS_PROPERTIES fallback
-- is owned by Config and consumed by Capture (getPropertyNames/curatedSet) when
-- namesFor/setFor return nil — AllowList itself never reads it, so requiring
-- Config here would be a dead dependency (luau-craft: import what you use).
local Types = require("./Types")
local Settings = require("./Settings")
local Transport = require("./Transport")

type ClassPropSet = Types.ClassPropSet
type ParsedAllowList = Types.AllowList

-- == Public interface ==

export type AllowListModule = {
	-- Loaded-from-daemon flag. When false, namesFor/setFor return nil and capture
	-- uses the static Config.CLASS_PROPERTIES fallback.
	loaded: boolean,
	-- Daemon-supplied, opaque version tag (any: the daemon may use a string, a
	-- number, or omit it). Stored as-is for diagnostics/logging.
	version: any,
	-- [className] = { [propName] = readOnly } — O(1) membership, the in-handler
	-- curated filter.
	sets: { [string]: ClassPropSet },
	-- [className] = { propName, ... } — ordered, the order capture reads in.
	lists: { [string]: { string } },

	-- PURE: decode a /allowlist response into per-class sets + ordered lists.
	-- Returns nil on bad input (non-table, or no `classes` table). Malformed
	-- per-class / per-entry pieces are dropped, not rejected.
	parse: (decoded: any) -> ParsedAllowList?,

	-- Fetch from the daemon and cache. Returns true on success; on failure logs
	-- (debug) and leaves the static fallback in place (returns false). Never throws.
	fetch: () -> boolean,

	-- Ordered property names for an EXACT class (nil if not loaded / class unknown).
	namesFor: (className: string) -> { string }?,
	-- Membership set { propName = readOnly } for an EXACT class (nil if not loaded /
	-- class unknown).
	setFor: (className: string) -> ClassPropSet?,
}

-- Forward declaration of the module table so methods reference one another and
-- the mutable state through it (e.g. fetch -> parse, fetch -> AllowList.sets)
-- WITHOUT forward-referencing a not-yet-assigned local. Every cross-reference
-- goes through `AllowList.*`, which is a real table field by the time any method
-- runs — the C1/C2/C3 bug class this rewrite exists to kill.
local AllowList: AllowListModule

-- == parse (PURE — the headless-testable surface) ==

-- Turn a decoded /allowlist body into { version, sets, lists }, or nil on bad
-- input. Verbatim port: a non-table body, or one whose `classes` is not a table,
-- yields nil (caller keeps the static fallback). Each class's `props` must be a
-- table; each entry must be a table with a string `name`. readOnly defaults to
-- false unless the entry says exactly `true` (`entry.readOnly == true`), matching
-- the monolith. Anything malformed is skipped, never fatal.
local function parse(decoded: any): ParsedAllowList?
	if type(decoded) ~= "table" or type(decoded.classes) ~= "table" then
		return nil
	end
	local raw = decoded :: { classes: { [string]: any }, version: any }
	local sets: { [string]: ClassPropSet } = {}
	local lists: { [string]: { string } } = {}
	for className, props in raw.classes do
		if type(props) == "table" then
			local set: ClassPropSet = {}
			local list: { string } = {}
			for _, entry in ipairs(props :: { any }) do
				if type(entry) == "table" and type(entry.name) == "string" then
					local name: string = entry.name
					set[name] = entry.readOnly == true
					list[#list + 1] = name
				end
			end
			sets[className] = set
			lists[className] = list
		end
	end
	return { version = raw.version, sets = sets, lists = lists }
end

-- == fetch ==

-- GET /allowlist via Transport, parse, and on success swap in the parsed state.
-- On any failure (request not ok, or parse nil) log via Settings.debugLog and
-- return false, leaving loaded/sets/lists/version untouched so the static
-- fallback stays in force. Verbatim behavior of the monolith's AllowList.fetch.
local function fetch(): boolean
	local ok, decoded = Transport.requestJson("GET", "/studio-stud/allowlist", nil, 15)
	if not ok then
		Settings.debugLog("allowlist: fetch failed (static fallback):", decoded and decoded.error)
		return false
	end
	local parsed = AllowList.parse(decoded)
	if not parsed then
		Settings.debugLog("allowlist: bad response (static fallback)")
		return false
	end
	AllowList.sets = parsed.sets
	AllowList.lists = parsed.lists
	AllowList.version = parsed.version
	AllowList.loaded = true
	local count = 0
	for _ in parsed.sets do
		count += 1
	end
	Settings.debugLog("allowlist: loaded version", tostring(parsed.version), "classes", count)
	return true
end

-- == per-class lookups ==

-- Ordered property names for an exact class. nil unless loaded AND the class is
-- present in the loaded lists — an unknown class returns nil even when loaded, so
-- capture falls through to the static CLASS_PROPERTIES. (Indexing a missing class
-- yields nil; the explicit `loaded` gate matches the monolith's early-out.)
local function namesFor(className: string): { string }?
	if AllowList.loaded then
		return AllowList.lists[className]
	end
	return nil
end

-- Membership set { propName = readOnly } for an exact class. Same nil-on-unknown
-- contract as namesFor.
local function setFor(className: string): ClassPropSet?
	if AllowList.loaded then
		return AllowList.sets[className]
	end
	return nil
end

-- == Module table ==

-- Initial state mirrors the monolith: not loaded, no version, empty sets/lists.
-- While unloaded, namesFor/setFor return nil and capture uses the static
-- Config.CLASS_PROPERTIES fallback (owned by Config, applied in Capture).
AllowList = {
	loaded = false,
	version = nil,
	sets = {},
	lists = {},

	parse = parse,
	fetch = fetch,
	namesFor = namesFor,
	setFor = setFor,
}

return AllowList
