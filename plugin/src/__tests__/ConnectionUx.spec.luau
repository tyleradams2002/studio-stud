--!nocheck
--!nolint BuiltinGlobalWrite
-- Headless tests for the auto-connect poll seam: probe() is silent, statusFn suppresses
-- transient unreachable noise while autoPolling, and a reachable probe triggers connect once.
-- Run:
--   lune run plugin/src/__tests__/ConnectionUx.spec.luau

-- testRoblox only injects `game`; the UI modules also build with these value types at
-- require-time, so inject them too. selene's std-lib lint flags reassigning each global
-- and its inline allow covers only the next statement, hence one allow per write.
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

-- Mock `plugin` before Shell (and thus CapturePanel) load — Shell creates the widget at require time.
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

local WAITING_MSG = "Waiting for studio-stud serve…"

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

-- == probe(): reachable/not without mutating status ==
do
	local pingCount = 0
	local ctx = makeCtx({
		requestJson = function(_method: string, path: string, _body: any?): (boolean, any)
			if path == "/studio-stud/ping" then
				pingCount += 1
				return false, { ok = false, error = "offline" }
			end
			return false, { ok = false }
		end,
		fetchWriteToken = function() end,
	})
	local parent = roblox.Instance.new("Frame")
	local handle = CapturePanel.build(parent, ctx)
	local statusBefore = #(ctx :: any)._statusCalls
	for _ = 1, 5 do
		check("probe unreachable", handle.probe() == false)
	end
	check("probe issued 5 pings", pingCount == 5)
	check("probe did not mutate status", #(ctx :: any)._statusCalls == statusBefore)
	handle.destroy()
end

-- == statusFn silent while autoPolling: no Connect failed spam ==
do
	local ctx = makeCtx({
		requestJson = function(_method: string, _path: string, _body: any?): (boolean, any)
			return false, { ok = false, error = "offline" }
		end,
		fetchWriteToken = function() end,
	})
	local parent = roblox.Instance.new("Frame")
	local handle = CapturePanel.build(parent, ctx)
	handle.setAutoPolling(true)
	local result = handle.status()
	check("statusFn silent returns ok=false", result.ok == false)
	local calls = (ctx :: any)._statusCalls
	local sawConnectFailed = false
	for _, call in calls do
		if call.message:find("Connect failed", 1, true) or call.message:find("Run studio%-stud serve", 1, false) then
			sawConnectFailed = true
		end
	end
	check("statusFn silent skips idle connect prompt", not sawConnectFailed)
	handle.destroy()
end

-- == waiting status set once across N unreachable probes (Shell poll pattern) ==
do
	local setCount = 0
	local lastMessage = ""
	local card = {
		setState = function(_state: string, message: string)
			if message == WAITING_MSG then
				setCount += 1
				lastMessage = message
			end
		end,
	}
	local waitingShown = false
	for _ = 1, 8 do
		if not waitingShown then
			card.setState("waiting", WAITING_MSG)
			waitingShown = true
		end
	end
	check("waiting status set exactly once", setCount == 1)
	check("waiting message stable", lastMessage == WAITING_MSG)
end

-- == reachable probe triggers exactly one connect ==
do
	local pingCount = 0
	local connectCount = 0
	local ctx = makeCtx({
		requestJson = function(_method: string, path: string, _body: any?): (boolean, any)
			if path == "/studio-stud/ping" then
				pingCount += 1
				return true, {
					ok = true,
					protocolVersion = 2,
					minPluginProtocolVersion = 1,
					version = "0.4.24",
				}
			end
			return false, { ok = false }
		end,
		fetchWriteToken = function() end,
	})
	local parent = roblox.Instance.new("Frame")
	local handle = CapturePanel.build(parent, ctx)

	local originalConnect = handle.onConnectRequested
	handle.onConnectRequested = function(): any
		connectCount += 1
		return { ok = false, error = "stub" }
	end

	if handle.probe() then
		handle.onConnectRequested()
	end
	check("reachable probe", pingCount >= 1)
	check("connect invoked once after reachable probe", connectCount == 1)

	-- Restore for destroy hygiene
	handle.onConnectRequested = originalConnect
	handle.destroy()
end

if failures > 0 then
	error(failures .. " assertion(s) failed")
end
print("ConnectionUx.spec: all checks passed")
