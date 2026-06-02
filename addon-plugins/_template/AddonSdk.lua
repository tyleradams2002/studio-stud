--!strict
-- Studio Stud — Addon SDK
--
-- Shared, dependency-free helpers for addon plugins that build on the core
-- Studio Stud plugin + daemon. The integration point between an addon and the
-- core is the local daemon's HTTP API (the same daemon the core plugin talks
-- to); this SDK wraps reaching it and performing the version handshake.
--
-- Loading:
--   * Folder plugin (recommended for development): keep a copy of this module
--     next to your addon's main script and `require(script.Parent.AddonSdk)`.
--   * Single-file plugin: inline this module's contents at the top of your
--     `<Addon>.plugin.lua`.
--
-- Portability rule: this SDK hardcodes nothing about any specific game or
-- project, and addons must not either. Host/port and any paths are
-- configuration, never baked in.

local HttpService = game:GetService("HttpService")

local AddonSdk = {}
AddonSdk.__index = AddonSdk

AddonSdk.SDK_VERSION = "0.1.0"

local DEFAULT_HOST = "127.0.0.1"
local DEFAULT_PORT = "31878"
local API_PREFIX = "/studio-stud"

-- Parse "1.2.3" -> {1, 2, 3}. Non-numeric / missing parts are ignored.
local function parseVersion(v: string?): { number }
	local out = {}
	for part in tostring(v or ""):gmatch("%d+") do
		table.insert(out, tonumber(part) or 0)
	end
	return out
end

-- Strictly-newer semantic version compare (works for "a.b.c" of any length).
function AddonSdk.isNewer(candidate: string?, current: string?): boolean
	local a, b = parseVersion(candidate), parseVersion(current)
	for i = 1, math.max(#a, #b) do
		local x, y = a[i] or 0, b[i] or 0
		if x ~= y then
			return x > y
		end
	end
	return false
end

export type Config = { host: string?, port: string?, name: string? }

function AddonSdk.new(config: Config?)
	local cfg = config or {}
	return setmetatable({
		host = cfg.host or DEFAULT_HOST,
		port = cfg.port or DEFAULT_PORT,
		name = cfg.name or "addon",
	}, AddonSdk)
end

function AddonSdk:baseUrl(): string
	return ("http://%s:%s"):format(self.host, self.port)
end

-- Generic JSON request against the core daemon.
-- Returns (ok: boolean, decodedBodyOrErrorString).
function AddonSdk:requestJson(method: string, path: string, body: any?): (boolean, any)
	local request: any = { Url = self:baseUrl() .. path, Method = method }
	if body ~= nil then
		local encOk, encoded = pcall(function()
			return HttpService:JSONEncode(body)
		end)
		if not encOk then
			return false, "encode failed: " .. tostring(encoded)
		end
		request.Body = encoded
		request.Headers = { ["Content-Type"] = "application/json" }
	end

	local ok, response = pcall(function()
		return HttpService:RequestAsync(request)
	end)
	if not ok then
		return false, tostring(response)
	end
	if not response.Success then
		return false, ("http %d: %s"):format(response.StatusCode, tostring(response.StatusMessage))
	end
	if response.Body == nil or response.Body == "" then
		return true, nil
	end

	local decOk, decoded = pcall(function()
		return HttpService:JSONDecode(response.Body)
	end)
	if not decOk then
		return false, "decode failed: " .. tostring(decoded)
	end
	return true, decoded
end

-- Ping the core daemon. On success returns its manifest, which includes
-- `protocolVersion` and `minPluginProtocolVersion`.
function AddonSdk:pingCore(): (boolean, any)
	return self:requestJson("GET", API_PREFIX .. "/ping", nil)
end

export type Compatibility = {
	ok: boolean,
	reachable: boolean,
	reason: string,
	coreProtocol: number?,
}

-- Confirm the core daemon is reachable AND new enough for this addon.
-- `requirements.minCoreProtocolVersion` is the lowest daemon protocol the addon
-- supports. Mirrors the core plugin <-> daemon handshake so an addon can tell
-- the user when the core needs updating.
function AddonSdk:checkCoreCompatibility(requirements: { minCoreProtocolVersion: number }): Compatibility
	local ok, manifest = self:pingCore()
	if not ok then
		return { ok = false, reachable = false, reason = "core daemon not reachable: " .. tostring(manifest) }
	end

	local coreProtocol = tonumber(manifest and manifest.protocolVersion) or 0
	local need = requirements.minCoreProtocolVersion or 1
	if coreProtocol < need then
		return {
			ok = false,
			reachable = true,
			coreProtocol = coreProtocol,
			reason = ("core protocol %d is older than required %d — update Studio Stud"):format(coreProtocol, need),
		}
	end

	return { ok = true, reachable = true, coreProtocol = coreProtocol, reason = "compatible" }
end

return AddonSdk
