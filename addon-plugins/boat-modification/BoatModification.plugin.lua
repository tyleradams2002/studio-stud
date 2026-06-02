--!strict
-- Boat Modification — a Studio Stud addon plugin.
--
-- STATUS: SKELETON. The authoring UI is not implemented yet; this file wires up
-- the toolbar entry and the core handshake so the feature can be built on top.
-- See README.md for the design intent.
--
-- PORTABILITY: the target config path and any schema specifics must be
-- configuration (plugin settings / project config / daemon policy), NOT
-- hardcoded to any one game.

local AddonSdk = require(script.Parent:WaitForChild("AddonSdk"))

local ADDON_NAME = "Boat Modification"
local MIN_CORE_PROTOCOL_VERSION = 1

-- TODO: read from plugin settings / project config instead of a constant.
-- The default is a relative, project-agnostic location; the daemon's write
-- policy must allow it before writes succeed.
local DEFAULT_CONFIG_PATH = "boat-modification/BoatAuthoringConfig.json"

local sdk = AddonSdk.new({ name = ADDON_NAME })

local toolbar = plugin:CreateToolbar("Studio Stud Addons")
local button = toolbar:CreateButton(ADDON_NAME, "Open " .. ADDON_NAME, "")
button.ClickableWhenViewportHidden = true

local function onActivated()
	button:SetActive(true)

	local status = sdk:checkCoreCompatibility({ minCoreProtocolVersion = MIN_CORE_PROTOCOL_VERSION })
	if not status.ok then
		warn(("[%s] %s"):format(ADDON_NAME, status.reason))
		button:SetActive(false)
		return
	end

	-- TODO: open the Boat Modification authoring DockWidget here.
	--   * Read the current config (daemon read API or project file).
	--   * Edit slots / tier limits / allowed-item whitelists / mount metadata.
	--   * Persist via the daemon write API to DEFAULT_CONFIG_PATH (policy-gated).
	print(("[%s] core OK (protocol %d). Authoring panel not built yet."):format(ADDON_NAME, status.coreProtocol or -1))
	print(("[%s] target config: %s"):format(ADDON_NAME, DEFAULT_CONFIG_PATH))

	button:SetActive(false)
end

button.Click:Connect(onActivated)

plugin.Unloading:Connect(function()
	-- Disconnect events and destroy any widgets created above.
end)
