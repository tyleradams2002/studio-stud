--!strict
-- Headless test for Config: pins the constant values that are part of the wire /
-- behavior contract (version, protocol handshake, thresholds, service ordering),
-- verifies ROOT_SERVICE_INDEX is derived consistently from ROOT_SERVICE_ORDER,
-- that DESCENDANT_ROOT_SERVICES is a subset of the order, and exercises every
-- branch of normalizePluginAssetId (the icon-id resolver). Run:
--   lune run plugin/src/__tests__/Config.spec.luau

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

-- == Version / protocol handshake (must not drift) ==
check("PLUGIN_VERSION 0.4.23", Config.PLUGIN_VERSION == "0.4.23")
check("PROTOCOL_VERSION 2", Config.PROTOCOL_VERSION == 2)
check("MIN_DAEMON_PROTOCOL_VERSION 2", Config.MIN_DAEMON_PROTOCOL_VERSION == 2)

-- == Identity / defaults ==
check("SERVICE_NAME", Config.SERVICE_NAME == "studio-stud")
check("DEFAULT_DAEMON_URL", Config.DEFAULT_DAEMON_URL == "http://127.0.0.1:31878")
check("WELCOME_VERSION", Config.WELCOME_VERSION == "2026-06-01-stage1-v1")

-- == Settings keys (single source of truth) ==
check("SETTINGS.daemonUrl", Config.SETTINGS.daemonUrl == "StudioStudDaemonUrl")
check("SETTINGS.welcomeVersion", Config.SETTINGS.welcomeVersion == "StudioStudWelcomeVersion")
check("SETTINGS.liveCaptureEnabled", Config.SETTINGS.liveCaptureEnabled == "StudioStudLiveCaptureEnabled")
check("SETTINGS.debounceMs", Config.SETTINGS.debounceMs == "StudioStudDebounceMs")
check("SETTINGS.debugLogging", Config.SETTINGS.debugLogging == "StudioStudDebugLogging")
check("SETTINGS.panelEnabled", Config.SETTINGS.panelEnabled == "StudioStudPanelEnabled")
check("SETTINGS.writeToken", Config.SETTINGS.writeToken == "StudioStudWriteToken")

-- == Debounce bounds ==
check("DEBOUNCE_MS_MIN 100", Config.DEBOUNCE_MS_MIN == 100)
check("DEBOUNCE_MS_MAX 1000", Config.DEBOUNCE_MS_MAX == 1000)
check("DEBOUNCE_MS_DEFAULT 300", Config.DEBOUNCE_MS_DEFAULT == 300)

-- == Tick thresholds / intervals ==
check("TICK_INLINE_THRESHOLD 256KiB", Config.TICK_INLINE_THRESHOLD == 256 * 1024)
check("BASELINE_YIELD_EVERY 500", Config.BASELINE_YIELD_EVERY == 500)
check("DEFAULT_BULK_CHUNK_BYTES 900000", Config.DEFAULT_BULK_CHUNK_BYTES == 900000)
check("STARTUP_CONNECT_DELAY 1.5", Config.STARTUP_CONNECT_DELAY == 1.5)

-- == Service ordering ==
check("ROOT_SERVICE_ORDER count 51", #Config.ROOT_SERVICE_ORDER == 51)
check("ROOT_SERVICE_ORDER[1] Workspace", Config.ROOT_SERVICE_ORDER[1] == "Workspace")
check("ROOT_SERVICE_ORDER[2] ServerStorage", Config.ROOT_SERVICE_ORDER[2] == "ServerStorage")
check("ROOT_SERVICE_ORDER[last] VRService", Config.ROOT_SERVICE_ORDER[#Config.ROOT_SERVICE_ORDER] == "VRService")

-- ROOT_SERVICE_INDEX must be the exact inverse of ROOT_SERVICE_ORDER.
local indexConsistent = true
for i, name in Config.ROOT_SERVICE_ORDER do
	if Config.ROOT_SERVICE_INDEX[name] ~= i then
		indexConsistent = false
	end
end
check("ROOT_SERVICE_INDEX inverts ORDER", indexConsistent)
check("ROOT_SERVICE_INDEX.Workspace 1", Config.ROOT_SERVICE_INDEX.Workspace == 1)
check("ROOT_SERVICE_INDEX.ReplicatedStorage 5", Config.ROOT_SERVICE_INDEX.ReplicatedStorage == 5)

local indexCount = 0
for _ in Config.ROOT_SERVICE_INDEX do
	indexCount += 1
end
check("ROOT_SERVICE_INDEX size matches ORDER", indexCount == #Config.ROOT_SERVICE_ORDER)

-- DESCENDANT_ROOT_SERVICES must be a subset of the ordered services.
local descendantSubset = true
local descendantCount = 0
for name, flag in Config.DESCENDANT_ROOT_SERVICES do
	descendantCount += 1
	if flag ~= true or Config.ROOT_SERVICE_INDEX[name] == nil then
		descendantSubset = false
	end
end
check("DESCENDANT_ROOT_SERVICES subset of ORDER", descendantSubset)
check("DESCENDANT_ROOT_SERVICES count 14", descendantCount == 14)
check("DESCENDANT Workspace true", Config.DESCENDANT_ROOT_SERVICES.Workspace == true)
check("DESCENDANT TextChatService true", Config.DESCENDANT_ROOT_SERVICES.TextChatService == true)
-- A captured service that is NOT descended (leaf root) — Players is in ORDER but
-- not in the descendant subset.
check("DESCENDANT Players absent", Config.DESCENDANT_ROOT_SERVICES.Players == nil)

-- == CLASS_PROPERTIES fallback (spot-check faithful port) ==
check("CLASS_PROPERTIES.BasePart[1] CFrame", Config.CLASS_PROPERTIES.BasePart[1] == "CFrame")
check("CLASS_PROPERTIES.BasePart count 14", #Config.CLASS_PROPERTIES.BasePart == 14)
check("CLASS_PROPERTIES.ModuleScript LinkedSource", Config.CLASS_PROPERTIES.ModuleScript[1] == "LinkedSource")
check("CLASS_PROPERTIES.StringValue Value", Config.CLASS_PROPERTIES.StringValue[1] == "Value")
check("CLASS_PROPERTIES.Workspace GlobalWind", Config.CLASS_PROPERTIES.Workspace[2] == "GlobalWind")
check("CLASS_PROPERTIES.Script Enabled", Config.CLASS_PROPERTIES.Script[1] == "Enabled")
check("CLASS_PROPERTIES.Decal three", #Config.CLASS_PROPERTIES.Decal == 3)

-- == Icon ids ==
check("PLUGIN_LOGO_ASSET_ID empty default", Config.PLUGIN_LOGO_ASSET_ID == "")
check("DEFAULT_TOOLBAR_ICON", Config.DEFAULT_TOOLBAR_ICON == "rbxassetid://14978048121")
check("resolvedLogoAssetId empty when raw empty", Config.resolvedLogoAssetId == "")

-- == normalizePluginAssetId branches ==
local norm = Config.normalizePluginAssetId
check("norm empty -> empty", norm("") == "")
check("norm whitespace -> empty", norm("   ") == "")
check("norm numeric -> rbxassetid", norm("12345") == "rbxassetid://12345")
check("norm numeric trims ws", norm("  12345  ") == "rbxassetid://12345")
-- FAITHFUL-PORT semantics: the original uses string.find(raw, "^rbxassetid://", 1, true).
-- With plain=true the "^" is a LITERAL char (not an anchor), so a normal
-- "rbxassetid://N" string does NOT match the passthrough branch and falls
-- through to "" — this is a latent bug in the monolith that the port preserves
-- verbatim. These assertions pin that exact (quirky) behavior.
check("norm rbxassetid url -> empty (literal-caret quirk)", norm("rbxassetid://999") == "")
check("norm rbxasset url -> empty (literal-caret quirk)", norm("rbxasset://textures/x.png") == "")
-- Only a string actually beginning with a literal "^rbxassetid://" passes through.
check("norm literal-caret passes through", norm("^rbxassetid://999") == "^rbxassetid://999")
check("norm garbage -> empty", norm("http://example.com/a.png") == "")
check("norm alpha -> empty", norm("notanid") == "")
check("norm numeric-with-suffix -> empty", norm("123abc") == "")

if failures == 0 then
	print("ALL CONFIG TESTS PASSED")
else
	print(("%d FAILURE(S)"):format(failures))
	error("Config.spec failed", 0)
end
