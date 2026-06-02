--!strict
-- Addon Template — a Studio Stud addon plugin.
--
-- HOW TO USE:
--   1. Copy this whole folder to addon-plugins/<your-addon-id>/.
--   2. Rename this file to <YourAddon>.plugin.lua and edit addon.json.
--   3. Keep AddonSdk.lua (sibling ModuleScript) in sync with ../sdk/AddonSdk.lua.
--   4. Replace the demo body with your feature.
--
-- PORTABILITY: do not hardcode PlaceIds, instance paths, or asset ids. Read any
-- project specifics from plugin settings / a project config / daemon policy.

local AddonSdk = require(script.Parent:WaitForChild("AddonSdk"))

local ADDON_NAME = "Addon Template"
local MIN_CORE_PROTOCOL_VERSION = 1

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

	-- Core daemon is reachable and protocol-compatible. Build your feature here:
	-- open a DockWidget, author instances behind ChangeHistoryService, call the
	-- daemon's write API, etc.
	print(("[%s] core OK (protocol %d). Replace this with your feature."):format(ADDON_NAME, status.coreProtocol or -1))

	button:SetActive(false)
end

button.Click:Connect(onActivated)

plugin.Unloading:Connect(function()
	-- Disconnect events and destroy any widgets created above.
end)
