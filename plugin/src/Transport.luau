--!strict
-- Transport — all HTTP to the daemon, plus the JSON-safety net, ported faithfully
-- from the monolith's Transport block (StudioStud.plugin.lua:1006-1254).
--
-- Responsibilities (one each):
--   * daemon-URL parse/build/current  (parseDaemonUrl/buildDaemonUrl/currentUrl)
--   * JSON safety net  (sanitizeJsonValue/safeEncode) — PORTED VERBATIM, proven:
--       a capture can never hard-fail HttpService:JSONEncode.
--   * request primitives  (requestJson, requestJsonAuthed with write-token header,
--       requestBody for pre-encoded bulk chunks)
--   * write-token fetch/cache  (fetchWriteToken; the E5 cache lives in Settings)
--   * S1 loopback guard  — a capture/source upload only ever talks to a loopback
--       daemon (127.0.0.1 / localhost / ::1 / 127/8). Refuse anything else BEFORE
--       any data leaves the machine.
--
-- TRUST BOUNDARY (harden once, here): every daemon response is decoded `any`. The
-- request helpers return (ok, table) where the table is the decoded body on
-- success or a `{ error = ... }` shape on failure; `hardenTickResponse` coerces a
-- decoded body into the typed TickResponse the live engine consumes, so nothing
-- downstream re-validates the wire. The daemon is not trusted to send well-typed
-- JSON.
--
-- luau-craft notes:
--   * Settings owns the write-token cache (E5); Transport reads via getWriteToken
--     and writes via setString (which invalidates that slot) — single source of
--     truth, no second cache here.
--   * `_selfTestLastRequest` is the one observable seam the SelfTest reads to
--     assert the write-token header was attached; it is part of the typed
--     interface, not a stray global.

local Types = require("./Types")
local Config = require("./Config")
local Settings = require("./Settings")

type TickResponse = Types.TickResponse
type ApplyScript = Types.ApplyScript

local SETTINGS = Config.SETTINGS
local DEFAULT_DAEMON_URL = Config.DEFAULT_DAEMON_URL

-- == Internal HTTP request/response shapes ==

-- The request table we hand to HttpService:RequestAsync. The engine's typed
-- HttpRequestOptions requires a non-optional Compress field; the monolith never
-- set it (it defaults to None on the engine). We build a plain typed table and
-- cast at the single RequestAsync boundary so the rest of the module stays
-- strict without scattering `any`.
type RequestTable = {
	Url: string,
	Method: string,
	Headers: { [string]: string },
	Timeout: number,
	Body: string?,
}

-- Structural mirror of the engine's HttpResponseData (a non-exported local type
-- in globalTypes.d.luau, so we cannot name it). Pinned here for the RequestAsync
-- result and the shared decoder.
type HttpResponse = {
	Success: boolean,
	StatusCode: number,
	StatusMessage: string,
	Headers: { [string]: string },
	Body: string?,
}

-- A decoded daemon body or a synthesized failure shape. Deliberately open: the
-- body is untrusted JSON, and failure shapes carry an ad-hoc set of diagnostic
-- fields (error/statusCode/body/blockedReason). Callers harden before use.
export type ResponseTable = {
	error: string?,
	statusCode: number?,
	body: string?,
	blockedReason: string?,
	token: string?,
	[string]: any,
}

-- == Public interface ==

export type TransportModule = {
	-- Daemon-URL plumbing (verbatim port).
	parseDaemonUrl: (url: string?) -> (string, string),
	buildDaemonUrl: (host: string?, port: string?) -> string,
	currentUrl: () -> string,

	-- S1 loopback guard. `isLoopbackHost` is the pure predicate; the *Loopback
	-- helpers operate on the configured daemon URL. `assertCaptureAllowed` is the
	-- gate the capture/source-upload paths call before any data leaves the box:
	-- returns (true) when loopback, else (false, reason) — never sends.
	isLoopbackHost: (host: string?) -> boolean,
	currentUrlIsLoopback: () -> boolean,
	assertCaptureAllowed: () -> (boolean, string?),

	-- JSON safety net (PORTED VERBATIM — proven).
	sanitizeJsonValue: (value: any, path: string, report: { string }, seen: { [any]: boolean }?) -> any,
	safeEncode: (value: any, label: string?) -> (boolean, string),

	-- Request primitives. Each returns (ok, ResponseTable): decoded body on
	-- success, a `{ error = ... }` shape on failure.
	requestJson: (method: string, path: string, body: any?, timeoutSeconds: number?) -> (boolean, ResponseTable),
	requestJsonAuthed: (method: string, path: string, body: any?, timeoutSeconds: number?) -> (boolean, ResponseTable),
	requestBody: (path: string, body: string) -> (boolean, ResponseTable),

	-- Write-token plumbing. buildAuthedHeaders is exposed for the SelfTest; the
	-- E5 token cache itself lives in Settings.
	buildAuthedHeaders: (token: string) -> { [string]: string },
	fetchWriteToken: () -> string,

	-- Trust boundary: coerce a decoded tick body into the typed TickResponse the
	-- live engine consumes. Harden-once for the daemon wire.
	hardenTickResponse: (decoded: any) -> TickResponse,

	-- SelfTest seam: the last request table built by requestJsonAuthed, so the
	-- gate can assert the write-token header was attached.
	_selfTestLastRequest: RequestTable?,
}

-- == Engine handles ==

-- HttpService is the only engine global Transport touches. Resolve-and-cache on
-- first use (cache-at-event) so module load order never matters.
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

-- Forward declaration of the module table so methods can reference one another
-- through it (e.g. requestJson -> safeEncode) WITHOUT forward-referencing a
-- not-yet-assigned local — the C1/C2/C3 bug class this rewrite exists to kill.
-- Every cross-call goes through `Transport.*`, which is a real table field by the
-- time any of these functions run.
local Transport: TransportModule

-- == Daemon URL (verbatim port) ==

local function parseDaemonUrl(url: string?): (string, string)
	if typeof(url) ~= "string" or url == "" then
		return "127.0.0.1", "31878"
	end
	local matchedHost: string?, matchedPort: string? = url:match("^https?://([^:/]+):?(%d*)/?$")
	if not matchedHost then
		matchedHost, matchedPort = url:match("^([^:/]+):?(%d*)$")
	end
	if not matchedHost or matchedHost == "" then
		return "127.0.0.1", "31878"
	end
	local port: string = matchedPort or ""
	if port == "" then
		port = "31878"
	end
	return matchedHost, port
end

local function buildDaemonUrl(host: string?, port: string?): string
	local trimmedHost = string.gsub(host or "", "%s+", "")
	local trimmedPort = string.gsub(port or "", "%s+", "")
	if trimmedHost == "" then
		trimmedHost = "127.0.0.1"
	end
	if trimmedPort == "" then
		trimmedPort = "31878"
	end
	return ("http://%s:%s"):format(trimmedHost, trimmedPort)
end

local function currentUrl(): string
	return Settings.getString(SETTINGS.daemonUrl, DEFAULT_DAEMON_URL)
end

-- == S1 loopback guard ==

-- Pure predicate: is `host` a loopback address the daemon may run on? Accepts the
-- canonical forms and the whole 127/8 range (and the bracketed IPv6 form Studio
-- could hand back from a URL). Comparison is case-insensitive for "localhost".
-- Anything else — a LAN IP, a public host, an empty/garbage host — is rejected,
-- so capture/source never leaves this machine.
local function isLoopbackHost(host: string?): boolean
	if typeof(host) ~= "string" or host == "" then
		return false
	end
	local lowered = string.lower(host)
	-- Strip an IPv6 bracket form, e.g. "[::1]" -> "::1".
	if string.sub(lowered, 1, 1) == "[" and string.sub(lowered, -1) == "]" then
		lowered = string.sub(lowered, 2, -2)
	end
	if lowered == "localhost" or lowered == "::1" or lowered == "0:0:0:0:0:0:0:1" then
		return true
	end
	-- IPv4 loopback is the entire 127.0.0.0/8 block.
	local a, b, c, d = string.match(lowered, "^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if a then
		local octets = { tonumber(a), tonumber(b), tonumber(c), tonumber(d) }
		if octets[1] ~= 127 then
			return false
		end
		for _, octet in octets do
			if octet == nil or octet < 0 or octet > 255 then
				return false
			end
		end
		return true
	end
	return false
end

local function currentUrlIsLoopback(): boolean
	local host = parseDaemonUrl(currentUrl())
	return isLoopbackHost(host)
end

-- The gate every capture / source-upload path calls before sending. Returns
-- (true) when the configured daemon is loopback, else (false, humanReason) and
-- sends nothing — the S1 contract.
local function assertCaptureAllowed(): (boolean, string?)
	if currentUrlIsLoopback() then
		return true
	end
	local host = parseDaemonUrl(currentUrl())
	return false,
		("refusing capture: daemon host %q is not loopback (127.0.0.1/localhost/::1 only)"):format(host)
end

-- == JSON safety net (PORTED VERBATIM) ==

-- Make a value JSON-safe IN PLACE so HttpService:JSONEncode can never hard-fail a
-- capture:
--   * non-finite numbers (NaN / ±inf) -> 0   (corrupted physics can yield these in CFrame fields)
--   * invalid-UTF-8 strings            -> valid prefix + U+FFFD  (script Source, captured in 0.4.17+)
--   * cyclic tables                    -> dropped
--   * userdata / function / thread     -> {type="Unsupported"}   (defensive; serializeValue normally
--                                                                  converts these already)
-- Appends a human-readable description of every offender to `report` so the cause is logged.
local function sanitizeJsonValue(value: any, path: string, report: { string }, seen: { [any]: boolean }?): any
	local t = type(value)
	if t == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			report[#report + 1] = path .. "=" .. tostring(value)
			return 0
		end
		return value
	elseif t == "string" then
		local len, firstBad = utf8.len(value)
		if len == nil then
			report[#report + 1] = path .. " (invalid utf-8, " .. #value .. "B)"
			return string.sub(value, 1, ((firstBad :: number?) or 1) - 1) .. utf8.char(0xFFFD)
		end
		return value
	elseif t == "table" then
		seen = seen or {}
		local seenSet = seen :: { [any]: boolean }
		if seenSet[value] then
			report[#report + 1] = path .. " (cyclic)"
			return nil
		end
		seenSet[value] = true
		for key, item in pairs(value) do
			value[key] = sanitizeJsonValue(item, path .. "." .. tostring(key), report, seenSet)
		end
		seenSet[value] = nil
		return value
	elseif t == "boolean" or t == "nil" then
		return value
	end
	report[#report + 1] = path .. " (type=" .. typeof(value) .. ")"
	return { type = "Unsupported", reason = typeof(value) }
end

-- Encode, but never crash the capture on a stray non-encodable value: on failure,
-- sanitize in place (logging exactly which fields were wrong) and retry. Zero
-- overhead on clean payloads. Returns (ok, jsonTextOrError) just like a guarded
-- pcall(JSONEncode).
local function safeEncode(value: any, label: string?): (boolean, string)
	local http = getHttpService()
	local okEnc, encoded = pcall(function(): string
		return http:JSONEncode(value)
	end)
	if okEnc then
		return true, encoded
	end
	local report: { string } = {}
	sanitizeJsonValue(value, label or "root", report, nil)
	warn(
		("[StudioStud] safeEncode: %s had %d non-JSON value(s), sanitized: %s"):format(
			tostring(label),
			#report,
			table.concat(report, ", ")
		)
	)
	return pcall(function(): string
		return http:JSONEncode(value)
	end)
end

-- == Request primitives ==

-- Shared response decoder: turn an HttpResponseData into (ok, ResponseTable),
-- exactly as the monolith's three near-identical inline blocks did. Single recipe
-- (DRY) — on a non-Success response, surface the daemon's JSON error body with
-- its statusCode attached; on a JSON parse failure, surface a synthetic error.
local function decodeResponse(response: HttpResponse): (boolean, ResponseTable)
	local http = getHttpService()
	local body = response.Body or ""
	if not response.Success then
		local decodedOk, decoded = pcall(function(): any
			return http:JSONDecode(body)
		end)
		if decodedOk and type(decoded) == "table" then
			local errTable = decoded :: ResponseTable
			errTable.statusCode = response.StatusCode
			return false, errTable
		end
		return false, { error = response.StatusMessage, statusCode = response.StatusCode, body = response.Body }
	end
	local decodedOk, decoded = pcall(function(): any
		return http:JSONDecode(body)
	end)
	if not decodedOk then
		return false, { error = "Bad daemon JSON: " .. tostring(decoded) }
	end
	return true, decoded :: ResponseTable
end

-- Send a fully-built request table, hardening the RequestAsync call itself.
local function sendRequestTable(request: RequestTable): (boolean, ResponseTable)
	local http = getHttpService()
	local ok, response = pcall(function(): HttpResponse
		-- HttpRequestOptions requires a Compress field the monolith never set;
		-- cast at this single boundary (the engine defaults Compress to None).
		return http:RequestAsync(request :: any) :: HttpResponse
	end)
	if not ok then
		return false, { error = tostring(response) }
	end
	return decodeResponse(response :: HttpResponse)
end

local function requestJson(method: string, path: string, body: any?, timeoutSeconds: number?): (boolean, ResponseTable)
	local request: RequestTable = {
		Url = currentUrl() .. path,
		Method = method,
		Headers = { ["Content-Type"] = "application/json" },
		Timeout = timeoutSeconds or 30,
	}
	if body ~= nil then
		local encOk, encoded = safeEncode(body, path)
		if not encOk then
			warn("[StudioStud] JSONEncode failed for", path, ":", encoded)
			return false, { error = "JSONEncode: " .. tostring(encoded) }
		end
		request.Body = encoded
	end
	return sendRequestTable(request)
end

local function buildAuthedHeaders(token: string): { [string]: string }
	return {
		["Content-Type"] = "application/json",
		["X-StudioStud-Token"] = token,
	}
end

local function fetchWriteToken(): string
	local ok, result = requestJson("GET", "/studio-stud/write/token", nil)
	if ok and type(result) == "table" and type(result.token) == "string" and result.token ~= "" then
		-- setString invalidates the Settings E5 token slot, so getWriteToken sees
		-- this immediately on the next read (single source of truth for the cache).
		Settings.setString(SETTINGS.writeToken, result.token)
		return result.token
	end
	return ""
end

local function requestJsonAuthed(
	method: string,
	path: string,
	body: any?,
	timeoutSeconds: number?
): (boolean, ResponseTable)
	local function sendRequest(token: string): (boolean, ResponseTable)
		local request: RequestTable = {
			Url = currentUrl() .. path,
			Method = method,
			Headers = buildAuthedHeaders(token),
			Timeout = timeoutSeconds or 30,
		}
		Transport._selfTestLastRequest = request
		if body ~= nil then
			local encOk, encoded = safeEncode(body, path)
			if not encOk then
				warn("[StudioStud] JSONEncode failed for", path, ":", encoded)
				return false, { error = "JSONEncode: " .. tostring(encoded) }
			end
			request.Body = encoded
		end
		return sendRequestTable(request)
	end

	-- Read the cached token (Settings E5); fetch on a miss.
	local token = Settings.getWriteToken()
	if token == "" then
		token = fetchWriteToken()
	end
	if token == "" then
		return false, { error = "write token unavailable", blockedReason = "tokenInvalid" }
	end

	local ok, result = sendRequest(token)
	-- One refresh-and-retry on a 401 (the token rotated under us).
	if not ok and result.statusCode == 401 then
		token = fetchWriteToken()
		if token ~= "" then
			ok, result = sendRequest(token)
		end
	end
	return ok, result
end

-- Pre-encoded body path (the daemon's chunked /tick/bulk upload sends raw JSON
-- chunk strings, already encoded by the caller). 60s timeout, no Content-Type
-- token — verbatim port of the monolith's requestBody.
local function requestBody(path: string, body: string): (boolean, ResponseTable)
	local request: RequestTable = {
		Url = currentUrl() .. path,
		Method = "POST",
		Headers = { ["Content-Type"] = "application/json" },
		Body = body,
		Timeout = 60,
	}
	return sendRequestTable(request)
end

-- == Trust boundary: harden the tick response (harden once) ==

-- Coerce a decoded `any` daemon body into a typed TickResponse. Each field is
-- type-checked and defaulted; a non-table or absent `ok` collapses to
-- `{ ok = false }`. Downstream (the live engine) trusts the result and never
-- re-validates the wire.
local function hardenTickResponse(decoded: any): TickResponse
	if type(decoded) ~= "table" then
		return { ok = false }
	end
	local raw = decoded :: { [string]: any }

	local driftServices: { string }? = nil
	if type(raw.driftServices) == "table" then
		local cleaned: { string } = {}
		for _, name in ipairs(raw.driftServices) do
			if type(name) == "string" then
				cleaned[#cleaned + 1] = name
			end
		end
		driftServices = cleaned
	end

	local applyScripts: { ApplyScript }? = nil
	if type(raw.applyScripts) == "table" then
		local cleaned: { ApplyScript } = {}
		for _, entry in ipairs(raw.applyScripts) do
			if type(entry) == "table" then
				local e = entry :: { [string]: any }
				if
					type(e.studioPath) == "string"
					and type(e.newSource) == "string"
					and type(e.expectedPriorHash) == "string"
				then
					cleaned[#cleaned + 1] = {
						studioPath = e.studioPath,
						newSource = e.newSource,
						expectedPriorHash = e.expectedPriorHash,
					}
				end
			end
		end
		applyScripts = cleaned
	end

	local revision: number? = nil
	if type(raw.revision) == "number" then
		revision = raw.revision
	end
	local instanceCount: number? = nil
	if type(raw.instanceCount) == "number" then
		instanceCount = raw.instanceCount
	end
	local errorText: string? = nil
	if type(raw.error) == "string" then
		errorText = raw.error
	end

	return {
		ok = raw.ok == true,
		revision = revision,
		instanceCount = instanceCount,
		driftServices = driftServices,
		request = raw.request,
		applyScripts = applyScripts,
		error = errorText,
	}
end

-- == Module table ==

Transport = {
	parseDaemonUrl = parseDaemonUrl,
	buildDaemonUrl = buildDaemonUrl,
	currentUrl = currentUrl,

	isLoopbackHost = isLoopbackHost,
	currentUrlIsLoopback = currentUrlIsLoopback,
	assertCaptureAllowed = assertCaptureAllowed,

	sanitizeJsonValue = sanitizeJsonValue,
	safeEncode = safeEncode,

	requestJson = requestJson,
	requestJsonAuthed = requestJsonAuthed,
	requestBody = requestBody,

	buildAuthedHeaders = buildAuthedHeaders,
	fetchWriteToken = fetchWriteToken,

	hardenTickResponse = hardenTickResponse,

	_selfTestLastRequest = nil,
}

return Transport
