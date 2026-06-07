--!strict
-- Settings — typed wrappers over plugin:GetSetting/SetSetting, ported faithfully
-- from the monolith's Settings block (StudioStud.plugin.lua:903-1005).
--
-- Two trust boundaries are hardened here, ONCE:
--   1. plugin:GetSetting returns `any` (persisted JSON the user/Studio can corrupt).
--      Every read is pcall-guarded AND type-checked, falling back to the caller's
--      default — so the rest of the plugin only ever sees the requested scalar type.
--   2. plugin:SetSetting can throw (e.g. unserializable value); writes are
--      pcall-swallowed exactly as the monolith did (best-effort persistence).
--
-- E5 (cache-at-event): `getDebounceMs` and the write token are read on hot paths
-- (the tick interval, every authed request). Both are memoized and the cache slot
-- is invalidated at the single write boundary (`setString`/`setNumber`) when the
-- matching key is written — so a value read once is O(1) thereafter, and a change
-- is reflected immediately without a stale window. The setting KEYS are the single
-- source of truth (Config.SETTINGS); the cache keys off those same constants.
--
-- panelEnabled is JSON-encoded into one string setting (a map), matching the
-- monolith — HttpService does the encode/decode, hardened with pcall + type check.

-- NB: this module imports no shared aliases from ./Types — every value it
-- persists is a scalar or a JSON map it declares locally (PanelEnabledMap). It
-- depends only on Config for the setting-key/threshold single source of truth, so
-- requiring ./Types would be a dead dependency. (Per luau-craft: import what you
-- use; the wire types live with the modules that emit the wire.)
local Config = require("./Config")

local SETTINGS = Config.SETTINGS
local DEBOUNCE_MS_MIN = Config.DEBOUNCE_MS_MIN
local DEBOUNCE_MS_MAX = Config.DEBOUNCE_MS_MAX
local DEBOUNCE_MS_DEFAULT = Config.DEBOUNCE_MS_DEFAULT

-- == Public interface ==

-- A decoded panel-enabled map: panelId -> enabled. The monolith stores `any`
-- values (JSON booleans), so the value type stays open; consumers compare
-- `== true` (see getPanelEnabled). Kept distinct from a strict boolean map to
-- preserve the exact membership-vs-truthiness semantics of the original.
export type PanelEnabledMap = { [string]: any }

export type SettingsModule = {
	-- Typed scalar accessors. Each get is pcall + typeof guarded; on any failure,
	-- wrong stored type, or (for string) an empty value, the default is returned.
	getString: (key: string, defaultValue: string) -> string,
	setString: (key: string, value: string) -> (),
	getBool: (key: string, defaultValue: boolean) -> boolean,
	setBool: (key: string, value: boolean) -> (),
	getNumber: (key: string, defaultValue: number) -> number,
	setNumber: (key: string, value: number) -> (),

	-- Debounce (= tick interval ms). get clamps+rounds into [MIN,MAX]; both the
	-- get result and the value written by set are clamped identically. E5-cached.
	getDebounceMs: () -> number,
	setDebounceMs: (value: number) -> (),

	-- The daemon write token. E5-cached read over getString(SETTINGS.writeToken).
	-- The cache is the same slot setString invalidates, so a freshly-fetched token
	-- (Transport.fetchWriteToken calls setString) is visible on the next read.
	getWriteToken: () -> string,

	-- Panel enabled-state, persisted as one JSON-encoded map string.
	getPanelEnabledMap: () -> PanelEnabledMap,
	setPanelEnabledMap: (map: PanelEnabledMap) -> (),
	getPanelEnabled: (panelId: string, defaultEnabled: boolean) -> boolean,
	setPanelEnabled: (panelId: string, enabled: boolean) -> (),
	clearPanelEnabled: (panelId: string) -> (),

	-- Debug logging gate: warn(...) iff the debugLogging setting is true.
	debugLog: (...any) -> (),
}

-- == Engine handles ==

-- `plugin` and `game` are Studio/plugin globals typed via globalTypes.d.luau under
-- the analyzer. Capture `plugin` into a local once (single trust point for the
-- settings store); HttpService is resolved lazily-and-cached on first JSON use
-- (cache-at-event) so the scalar accessors never touch it.
local pluginHandle: Plugin = plugin

local httpService: HttpService? = nil
local function getHttpService(): HttpService
	local cached = httpService
	if cached then
		return cached
	end
	local resolved = game:GetService("HttpService") :: HttpService
	httpService = resolved
	return resolved
end

-- == E5 cache (cache-at-event) ==

-- Memoized hot-path reads. `nil` means "not yet computed"; the next get populates
-- it, and setString/setNumber clear the matching slot when their key is written.
-- Single source of truth: keyed off Config.SETTINGS, not literal strings.
local cachedDebounceMs: number? = nil
local cachedWriteToken: string? = nil

-- == Scalar accessors (trust boundary: GetSetting returns `any`) ==

local function getString(key: string, defaultValue: string): string
	local ok, value = pcall(function()
		return pluginHandle:GetSetting(key)
	end)
	if ok and typeof(value) == "string" and value ~= "" then
		return value
	end
	return defaultValue
end

local function setString(key: string, value: string): ()
	-- Invalidate the matching E5 slot BEFORE the write so a concurrent reader can
	-- never observe a stale cache paired with the new stored value.
	if key == SETTINGS.writeToken then
		cachedWriteToken = nil
	end
	pcall(function()
		pluginHandle:SetSetting(key, value)
	end)
end

local function getBool(key: string, defaultValue: boolean): boolean
	local ok, value = pcall(function()
		return pluginHandle:GetSetting(key)
	end)
	if ok and typeof(value) == "boolean" then
		return value
	end
	return defaultValue
end

local function setBool(key: string, value: boolean): ()
	pcall(function()
		pluginHandle:SetSetting(key, value)
	end)
end

local function getNumber(key: string, defaultValue: number): number
	local ok, value = pcall(function()
		return pluginHandle:GetSetting(key)
	end)
	if ok and typeof(value) == "number" then
		return value
	end
	return defaultValue
end

local function setNumber(key: string, value: number): ()
	if key == SETTINGS.debounceMs then
		cachedDebounceMs = nil
	end
	pcall(function()
		pluginHandle:SetSetting(key, value)
	end)
end

-- == Debounce (E5-cached) ==

-- Clamp+round a raw ms value into [MIN,MAX]. Single recipe shared by get and set
-- so the value read back always equals the value written (the SelfTest round-trip
-- invariant). `math.floor(value + 0.5)` is the monolith's round-half-up.
local function clampDebounceMs(value: number): number
	return math.clamp(math.floor(value + 0.5), DEBOUNCE_MS_MIN, DEBOUNCE_MS_MAX)
end

local function getDebounceMs(): number
	local cached = cachedDebounceMs
	if cached then
		return cached
	end
	local computed = clampDebounceMs(getNumber(SETTINGS.debounceMs, DEBOUNCE_MS_DEFAULT))
	cachedDebounceMs = computed
	return computed
end

local function setDebounceMs(value: number): ()
	-- setNumber clears the cache slot; recompute lazily on the next get.
	setNumber(SETTINGS.debounceMs, clampDebounceMs(value))
end

-- == Write token (E5-cached) ==

local function getWriteToken(): string
	local cached = cachedWriteToken
	if cached then
		return cached
	end
	local token = getString(SETTINGS.writeToken, "")
	cachedWriteToken = token
	return token
end

-- == Panel enabled map (JSON-encoded single setting) ==

local function getPanelEnabledMap(): PanelEnabledMap
	local raw = getString(SETTINGS.panelEnabled, "{}")
	local ok, decoded = pcall(function()
		return getHttpService():JSONDecode(raw)
	end)
	if ok and type(decoded) == "table" then
		return decoded
	end
	return {}
end

local function setPanelEnabledMap(map: PanelEnabledMap): ()
	-- Faithful to the monolith: encode unguarded by pcall (a panel map is always
	-- a plain {string:boolean} table, so JSONEncode cannot fail here), then route
	-- through setString. setString itself swallows SetSetting errors.
	setString(SETTINGS.panelEnabled, getHttpService():JSONEncode(map))
end

local function getPanelEnabled(panelId: string, defaultEnabled: boolean): boolean
	local map = getPanelEnabledMap()
	local value = map[panelId]
	-- Membership-first semantics (matches the monolith): absent key -> default
	-- (default true unless explicitly false); present key -> strict `== true`.
	if value == nil then
		return defaultEnabled ~= false
	end
	return value == true
end

local function setPanelEnabled(panelId: string, enabled: boolean): ()
	local map = getPanelEnabledMap()
	map[panelId] = enabled
	setPanelEnabledMap(map)
end

local function clearPanelEnabled(panelId: string): ()
	local map = getPanelEnabledMap()
	map[panelId] = nil
	setPanelEnabledMap(map)
end

-- == Debug logging gate ==

local function debugLog(...: any): ()
	if getBool(SETTINGS.debugLogging, false) then
		warn("[StudioStud]", ...)
	end
end

-- == Module table ==

local Settings: SettingsModule = {
	getString = getString,
	setString = setString,
	getBool = getBool,
	setBool = setBool,
	getNumber = getNumber,
	setNumber = setNumber,

	getDebounceMs = getDebounceMs,
	setDebounceMs = setDebounceMs,
	getWriteToken = getWriteToken,

	getPanelEnabledMap = getPanelEnabledMap,
	setPanelEnabledMap = setPanelEnabledMap,
	getPanelEnabled = getPanelEnabled,
	setPanelEnabled = setPanelEnabled,
	clearPanelEnabled = clearPanelEnabled,

	debugLog = debugLog,
}

return Settings
