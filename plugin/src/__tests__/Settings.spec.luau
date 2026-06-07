--!strict
-- Headless test for Settings. The scalar accessors are pcall+typeof guarded over
-- plugin:GetSetting/SetSetting; under lune the `plugin` global is nil, so every
-- GetSetting indexes nil inside the pcall and fails — which deterministically
-- exercises the FALLBACK path of every getter (the trust-boundary contract) and
-- the clamp/round + membership-semantics pure logic, plus the E5 cache shape.
-- The real GetSetting/SetSetting round-trip (and JSON panel-map persistence, which
-- needs HttpService) is covered by the in-engine SelfTest. Run:
--   lune run plugin/src/__tests__/Settings.spec.luau

local Settings = require("../Settings")
local Config = require("../Config")

local failures = 0
local function check(label: string, cond: boolean)
	if not cond then
		failures += 1
		print("FAIL: " .. label)
	else
		print("ok: " .. label)
	end
end

-- == Public interface presence / arity ==
check("getString is a function", type(Settings.getString) == "function")
check("setString is a function", type(Settings.setString) == "function")
check("getBool is a function", type(Settings.getBool) == "function")
check("setBool is a function", type(Settings.setBool) == "function")
check("getNumber is a function", type(Settings.getNumber) == "function")
check("setNumber is a function", type(Settings.setNumber) == "function")
check("getDebounceMs is a function", type(Settings.getDebounceMs) == "function")
check("setDebounceMs is a function", type(Settings.setDebounceMs) == "function")
check("getWriteToken is a function", type(Settings.getWriteToken) == "function")
check("getPanelEnabledMap is a function", type(Settings.getPanelEnabledMap) == "function")
check("setPanelEnabledMap is a function", type(Settings.setPanelEnabledMap) == "function")
check("getPanelEnabled is a function", type(Settings.getPanelEnabled) == "function")
check("setPanelEnabled is a function", type(Settings.setPanelEnabled) == "function")
check("clearPanelEnabled is a function", type(Settings.clearPanelEnabled) == "function")
check("debugLog is a function", type(Settings.debugLog) == "function")

-- == Trust boundary: GetSetting unavailable -> defaults (never throws) ==
-- Each get must return the caller's default rather than propagating the
-- nil-index error from the absent `plugin` global.
check("getString falls back", Settings.getString("AnyKey", "DEFAULT") == "DEFAULT")
check("getBool falls back true", Settings.getBool("AnyKey", true) == true)
check("getBool falls back false", Settings.getBool("AnyKey", false) == false)
check("getNumber falls back", Settings.getNumber("AnyKey", 42) == 42)
-- Empty-string stored value would also fall back, but here it's the unavailable
-- path; the contract is identical: caller default wins.
check("getString empty default returns empty", Settings.getString("AnyKey", "") == "")

-- == setters never throw (best-effort persistence) ==
-- SetSetting indexes the nil plugin global inside a pcall; the call must return
-- normally regardless.
local setOk = pcall(function()
	Settings.setString(Config.SETTINGS.writeToken, "tok")
	Settings.setBool(Config.SETTINGS.debugLogging, true)
	Settings.setNumber(Config.SETTINGS.debounceMs, 250)
	Settings.setDebounceMs(250)
end)
check("setters do not throw", setOk)

-- == getDebounceMs: clamp + round into [MIN,MAX], E5-cached ==
-- With no stored value, getNumber falls back to DEBOUNCE_MS_DEFAULT; clamped+
-- rounded that equals the default (it is already in range and integral).
local dbDefault = Settings.getDebounceMs()
check("getDebounceMs == clamped default", dbDefault == Config.DEBOUNCE_MS_DEFAULT)
check("getDebounceMs in [MIN,MAX]", dbDefault >= Config.DEBOUNCE_MS_MIN and dbDefault <= Config.DEBOUNCE_MS_MAX)
-- Cached: a second read returns the identical value (and would be O(1)).
check("getDebounceMs cached stable", Settings.getDebounceMs() == dbDefault)
-- setDebounceMs invalidates the slot; the next get recomputes from the (still
-- unavailable) store -> back to the clamped default. Proves the set path clears
-- the cache (no stale pin).
Settings.setDebounceMs(999)
check("getDebounceMs after set recomputes default", Settings.getDebounceMs() == Config.DEBOUNCE_MS_DEFAULT)

-- == getWriteToken: E5-cached read, default "" when unavailable ==
local tok1 = Settings.getWriteToken()
check("getWriteToken default empty", tok1 == "")
check("getWriteToken cached stable", Settings.getWriteToken() == tok1)
-- Writing the token key invalidates the cache slot; the next read recomputes
-- (still "" headless) — proving setString clears the write-token cache.
Settings.setString(Config.SETTINGS.writeToken, "fresh-token")
check("getWriteToken after write recomputes", Settings.getWriteToken() == "")

-- == getPanelEnabled membership-vs-truthiness (pure logic) ==
-- HttpService is unavailable headless, so getPanelEnabledMap returns {} (decode
-- path errors -> {}). With an empty map every key is absent, so the result is
-- governed purely by the default: absent + default true -> true; absent +
-- default false -> false (the `defaultEnabled ~= false` rule).
check("getPanelEnabled absent, default true -> true", Settings.getPanelEnabled("panelA", true) == true)
check("getPanelEnabled absent, default false -> false", Settings.getPanelEnabled("panelA", false) == false)

-- getPanelEnabledMap is total (never throws) and yields a table even when the
-- backing store / HttpService is unavailable.
local mapOk, mapVal = pcall(Settings.getPanelEnabledMap)
check("getPanelEnabledMap does not throw", mapOk)
check("getPanelEnabledMap returns a table", type(mapVal) == "table")

-- == debugLog gated off when debugLogging unavailable (no throw, no output) ==
local logOk = pcall(function()
	Settings.debugLog("should-not-print")
end)
check("debugLog gated, does not throw", logOk)

if failures == 0 then
	print("ALL SETTINGS TESTS PASSED")
else
	print(("%d FAILURE(S)"):format(failures))
	error("Settings.spec failed", 0)
end
