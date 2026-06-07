--!nocheck
--!nolint BuiltinGlobalWrite
-- Minimal @lune/roblox DataModel bootstrap for headless specs that exercise code
-- paths reading the Studio `game` global (PlaceId, HttpService).

local roblox = require("@lune/roblox")

return function(): DataModel
	local dm = roblox.Instance.new("DataModel")
	;(dm :: any).PlaceId = 0
	-- selene: allow(incorrect_standard_library_use)
	game = dm
	pcall(function()
		return (dm :: any).Shutdown
	end)
	return dm
end
