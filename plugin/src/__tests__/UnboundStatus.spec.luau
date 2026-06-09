--!nocheck
--!nolint BuiltinGlobalWrite
-- Headless tests for unbound / no-registry status guidance in CapturePanel.statusFn.
-- Run:
--   lune run plugin/src/__tests__/UnboundStatus.spec.luau

local roblox = require("@lune/roblox")
-- selene: allow(incorrect_standard_library_use)
Color3 = roblox.Color3
-- selene: allow(incorrect_standard_library_use)
Font = roblox.Font
-- selene: allow(incorrect_standard_library_use)
Enum = roblox.Enum
-- selene: allow(incorrect_standard_library_use)
UDim2 = roblox.UDim2
-- selene: allow(incorrect_standard_library_use)
Vector2 = roblox.Vector2
-- selene: allow(incorrect_standard_library_use)
Instance = roblox.Instance
-- selene: allow(incorrect_standard_library_use)
DockWidgetPluginGuiInfo = {
	new = function(_a: any, _b: any, _c: any, _d: any, _e: any, _f: any, _g: any): any
		return {}
	end,
} :: any
require("./testRoblox")()

-- selene: allow(incorrect_standard_library_use)
plugin = {
	CreateDockWidgetPluginGui = function(_id: string, _info: any): DockWidgetPluginGui
		return {
			Enabled = true,
			Title = "Studio Stud",
		} :: any
	end,
	CreateToolbar = function(_name: string): PluginToolbar
		return {
			CreateButton = function(_title: string, _tooltip: string, _icon: string): PluginToolbarButton
				return {
					ClickableWhenViewportHidden = false,
				} :: any
			end,
		} :: any
	end,
} :: any

local CapturePanel = require("../ui/CapturePanel")
local Shell = require("../ui/Shell")

local failures = 0
local function check(label: string, cond: boolean)
	if not cond then
		failures += 1
		print("FAIL: " .. label)
	else
		print("ok: " .. label)
	end
end

local function makeCtx(transport: any): Shell.ShellContext
	local statusCalls: { { state: string, message: string } } = {}
	return {
		theme = {} :: any,
		ui = {} :: any,
		transport = transport,
		settings = { debugLog = function() end } :: any,
		plugin = plugin,
		widget = Shell.widget,
		setStatus = function(state: string, message: string)
			statusCalls[#statusCalls + 1] = { state = state, message = message }
		end,
		setStats = function(_text: string?) end,
		isConnected = function(): boolean
			return Shell.connected
		end,
		setConnected = function(value: boolean)
			Shell.connected = value
		end,
		_statusCalls = statusCalls,
	} :: any
end

local function pingTransport(contextStatus: string): any
	return {
		requestJson = function(_method: string, path: string, _body: any?): (boolean, any)
			if path == "/studio-stud/ping" then
				return true, {
					ok = true,
					protocolVersion = 2,
					minPluginProtocolVersion = 1,
					version = "0.5.1",
				}
			end
			if path:find("/studio-stud/context", 1, true) then
				return true, {
					ok = true,
					status = contextStatus,
					placeId = 12345,
				}
			end
			return false, { ok = false }
		end,
		fetchWriteToken = function() end,
	}
end

-- == unbound place shows actionable guidance ==
do
	local ctx = makeCtx(pingTransport("unbound"))
	local parent = roblox.Instance.new("Frame")
	local handle = CapturePanel.build(parent, ctx)
	local result = handle.status()
	check("unbound status returns ok=false", result.ok == false)
	check("unbound error tag", result.error == "unbound")
	local calls = (ctx :: any)._statusCalls
	local last = calls[#calls]
	check("unbound status state", last.state == "unbound")
	check(
		"unbound status message mentions add-repo",
		last.message:find("add%-repo", 1, false) ~= nil
	)
	check("not connected when unbound", Shell.connected == false)
	handle.destroy()
end

-- == no registry shows actionable guidance ==
do
	local ctx = makeCtx(pingTransport("noRegistry"))
	local parent = roblox.Instance.new("Frame")
	local handle = CapturePanel.build(parent, ctx)
	local result = handle.status()
	check("noRegistry status returns ok=false", result.ok == false)
	check("noRegistry error tag", result.error == "noRegistry")
	local calls = (ctx :: any)._statusCalls
	local last = calls[#calls]
	check("noRegistry status state", last.state == "unbound")
	check(
		"noRegistry message mentions add-repo",
		last.message:find("add%-repo", 1, false) ~= nil
	)
	handle.destroy()
end

-- == bound place stays connected ==
do
	local ctx = makeCtx(pingTransport("bound"))
	local parent = roblox.Instance.new("Frame")
	local handle = CapturePanel.build(parent, ctx)
	local result = handle.status()
	check("bound status returns ok=true", result.ok == true)
	check("connected when bound", Shell.connected == true)
	handle.destroy()
end

if failures > 0 then
	error(failures .. " assertion(s) failed")
end
print("UnboundStatus.spec: all checks passed")
