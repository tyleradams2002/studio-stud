--!strict
-- Headless test for Transport's pure surface: the daemon-URL parse/build, the S1
-- loopback guard, sanitizeJsonValue (the proven JSON safety net), the tick-response
-- hardening (trust boundary), and the authed-header builder. The HTTP request
-- helpers need HttpService/RequestAsync and are covered by the in-engine SelfTest;
-- here we exercise everything that is pure logic plus the loopback/default-URL
-- behavior (Settings falls back to DEFAULT_DAEMON_URL headless, which is loopback).
-- Run:
--   lune run plugin/src/__tests__/Transport.spec.luau

local Transport = require("../Transport")
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

-- == Public interface presence ==
check("parseDaemonUrl is a function", type(Transport.parseDaemonUrl) == "function")
check("buildDaemonUrl is a function", type(Transport.buildDaemonUrl) == "function")
check("currentUrl is a function", type(Transport.currentUrl) == "function")
check("isLoopbackHost is a function", type(Transport.isLoopbackHost) == "function")
check("currentUrlIsLoopback is a function", type(Transport.currentUrlIsLoopback) == "function")
check("assertCaptureAllowed is a function", type(Transport.assertCaptureAllowed) == "function")
check("sanitizeJsonValue is a function", type(Transport.sanitizeJsonValue) == "function")
check("safeEncode is a function", type(Transport.safeEncode) == "function")
check("requestJson is a function", type(Transport.requestJson) == "function")
check("requestJsonAuthed is a function", type(Transport.requestJsonAuthed) == "function")
check("requestBody is a function", type(Transport.requestBody) == "function")
check("buildAuthedHeaders is a function", type(Transport.buildAuthedHeaders) == "function")
check("fetchWriteToken is a function", type(Transport.fetchWriteToken) == "function")
check("hardenTickResponse is a function", type(Transport.hardenTickResponse) == "function")

-- == parseDaemonUrl (verbatim port) ==
local h, p = Transport.parseDaemonUrl(nil)
check("parse nil -> 127.0.0.1:31878", h == "127.0.0.1" and p == "31878")
h, p = Transport.parseDaemonUrl("")
check("parse empty -> default", h == "127.0.0.1" and p == "31878")
h, p = Transport.parseDaemonUrl("http://127.0.0.1:31878")
check("parse full url", h == "127.0.0.1" and p == "31878")
h, p = Transport.parseDaemonUrl("http://127.0.0.1:31999/")
check("parse url trailing slash + custom port", h == "127.0.0.1" and p == "31999")
h, p = Transport.parseDaemonUrl("http://localhost")
check("parse url no port -> default port", h == "localhost" and p == "31878")
h, p = Transport.parseDaemonUrl("127.0.0.1:1234")
check("parse bare host:port", h == "127.0.0.1" and p == "1234")
h, p = Transport.parseDaemonUrl("myhost")
check("parse bare host -> default port", h == "myhost" and p == "31878")
h, p = Transport.parseDaemonUrl("https://127.0.0.1:8080")
check("parse https scheme", h == "127.0.0.1" and p == "8080")

-- == buildDaemonUrl (verbatim port) ==
check("build host+port", Transport.buildDaemonUrl("127.0.0.1", "31878") == "http://127.0.0.1:31878")
check("build empty host -> default host", Transport.buildDaemonUrl("", "9000") == "http://127.0.0.1:9000")
check("build empty port -> default port", Transport.buildDaemonUrl("10.0.0.5", "") == "http://10.0.0.5:31878")
check("build nil both -> defaults", Transport.buildDaemonUrl(nil, nil) == "http://127.0.0.1:31878")
check("build trims whitespace", Transport.buildDaemonUrl("  127.0.0.1  ", "  31878  ") == "http://127.0.0.1:31878")

-- == S1 loopback guard ==
check("loopback 127.0.0.1", Transport.isLoopbackHost("127.0.0.1") == true)
check("loopback localhost", Transport.isLoopbackHost("localhost") == true)
check("loopback LOCALHOST (case-insensitive)", Transport.isLoopbackHost("LOCALHOST") == true)
check("loopback ::1", Transport.isLoopbackHost("::1") == true)
check("loopback [::1] bracketed", Transport.isLoopbackHost("[::1]") == true)
check("loopback 0:0:0:0:0:0:0:1 expanded", Transport.isLoopbackHost("0:0:0:0:0:0:0:1") == true)
check("loopback 127.5.5.5 (127/8)", Transport.isLoopbackHost("127.5.5.5") == true)
check("loopback 127.255.255.255 (127/8 top)", Transport.isLoopbackHost("127.255.255.255") == true)
-- Rejections — these must never receive capture/source.
check("non-loopback 192.168.1.10", Transport.isLoopbackHost("192.168.1.10") == false)
check("non-loopback 10.0.0.1", Transport.isLoopbackHost("10.0.0.1") == false)
check("non-loopback 8.8.8.8", Transport.isLoopbackHost("8.8.8.8") == false)
check("non-loopback 128.0.0.1 (not 127)", Transport.isLoopbackHost("128.0.0.1") == false)
check("non-loopback example.com", Transport.isLoopbackHost("example.com") == false)
check("non-loopback empty", Transport.isLoopbackHost("") == false)
check("non-loopback nil", Transport.isLoopbackHost(nil) == false)
check("non-loopback octet overflow 127.300.0.0", Transport.isLoopbackHost("127.300.0.0") == false)
check("non-loopback malformed 127.0.0", Transport.isLoopbackHost("127.0.0") == false)

-- Default daemon URL is loopback, so headless (Settings falls back to it) the
-- capture gate must permit. (This also pins DEFAULT_DAEMON_URL as loopback.)
local defHost = Transport.parseDaemonUrl(Config.DEFAULT_DAEMON_URL)
check("DEFAULT_DAEMON_URL host is loopback", Transport.isLoopbackHost(defHost) == true)
check("currentUrlIsLoopback true (default)", Transport.currentUrlIsLoopback() == true)
local allowed, reason = Transport.assertCaptureAllowed()
check("assertCaptureAllowed permits default (loopback)", allowed == true and reason == nil)

-- == buildAuthedHeaders (write-token header) ==
local hdrs = Transport.buildAuthedHeaders("tok-123")
check("authed header content-type", hdrs["Content-Type"] == "application/json")
check("authed header write token", hdrs["X-StudioStud-Token"] == "tok-123")

-- == sanitizeJsonValue (PORTED VERBATIM) ==
do
	local report: { string } = {}
	-- NaN / inf -> 0, with a report entry each.
	check("sanitize NaN -> 0", Transport.sanitizeJsonValue(0 / 0, "nan", report, nil) == 0)
	check("sanitize +inf -> 0", Transport.sanitizeJsonValue(math.huge, "pinf", report, nil) == 0)
	check("sanitize -inf -> 0", Transport.sanitizeJsonValue(-math.huge, "ninf", report, nil) == 0)
	check("sanitize finite passes", Transport.sanitizeJsonValue(3.5, "n", report, nil) == 3.5)
	check("sanitize reports 3 non-finite", #report == 3)
end
do
	-- Valid UTF-8 string passes through unchanged.
	local report: { string } = {}
	check("sanitize valid utf8 passes", Transport.sanitizeJsonValue("hello", "s", report, nil) == "hello")
	check("sanitize valid utf8 no report", #report == 0)
	-- Invalid UTF-8 -> valid prefix + U+FFFD, with a report entry.
	local bad = "ok" .. string.char(0xFF) .. "tail"
	local fixed = Transport.sanitizeJsonValue(bad, "bad", report, nil)
	check("sanitize invalid utf8 keeps prefix", string.sub(fixed, 1, 2) == "ok")
	check("sanitize invalid utf8 appends U+FFFD", string.find(fixed, utf8.char(0xFFFD), 1, true) ~= nil)
	check("sanitize invalid utf8 reported", #report == 1)
end
do
	-- Booleans / nil pass through.
	local report: { string } = {}
	check("sanitize true passes", Transport.sanitizeJsonValue(true, "b", report, nil) == true)
	check("sanitize false passes", Transport.sanitizeJsonValue(false, "b", report, nil) == false)
	check("sanitize nil passes", Transport.sanitizeJsonValue(nil, "z", report, nil) == nil)
end
do
	-- Nested table sanitizes in place; cyclic reference is dropped (returns nil for
	-- the cyclic slot) and reported.
	local report: { string } = {}
	local t: { [string]: any } = { a = math.huge, b = { c = "fine" } }
	local out = Transport.sanitizeJsonValue(t, "root", report, nil)
	check("sanitize table in place", out == t)
	check("sanitize nested NaN field -> 0", t.a == 0)
	check("sanitize nested ok field kept", t.b.c == "fine")

	local cyc: { [string]: any } = {}
	cyc.self = cyc
	local report2: { string } = {}
	Transport.sanitizeJsonValue(cyc, "cyc", report2, nil)
	check("sanitize cyclic dropped", cyc.self == nil)
	local sawCyclic = false
	for _, line in report2 do
		if string.find(line, "cyclic", 1, true) then
			sawCyclic = true
		end
	end
	check("sanitize cyclic reported", sawCyclic)
end
do
	-- Unsupported value type (function) -> {type="Unsupported"} + report.
	local report: { string } = {}
	local out = Transport.sanitizeJsonValue(check, "fn", report, nil)
	check("sanitize function -> Unsupported", type(out) == "table" and out.type == "Unsupported")
	check("sanitize function reported", #report == 1)
end

-- == hardenTickResponse (trust boundary) ==
do
	local r = Transport.hardenTickResponse(nil)
	check("harden nil -> ok=false", r.ok == false)
	r = Transport.hardenTickResponse("not a table")
	check("harden string -> ok=false", r.ok == false)
	r = Transport.hardenTickResponse({})
	check("harden empty -> ok=false (no ok field)", r.ok == false)
	r = Transport.hardenTickResponse({ ok = "yes" })
	check("harden ok non-boolean -> false", r.ok == false)

	-- Intentionally malformed wire (mixed-type drift list, an incomplete applyScript,
	-- a wrong-typed error) — the whole point is to prove hardening coerces untrusted
	-- JSON. Each heterogeneous piece is built as `any` so it models "this came off
	-- the wire as any", without the analyzer unifying the deliberately-bad literals.
	local mixedDrift: { any } = { "Workspace", 5, "Lighting" }
	local mixedApply: { any } = {
		{ studioPath = "a", newSource = "src", expectedPriorHash = "h" },
		{ studioPath = "b" }, -- incomplete -> dropped
	}
	local malformed: any = {
		ok = true,
		revision = 7,
		instanceCount = 42,
		driftServices = mixedDrift,
		applyScripts = mixedApply,
		error = 123, -- wrong type -> nil
		request = { reason = "rebaseline" },
	}
	r = Transport.hardenTickResponse(malformed)
	check("harden ok=true", r.ok == true)
	check("harden revision", r.revision == 7)
	check("harden instanceCount", r.instanceCount == 42)
	check("harden driftServices filters non-strings", r.driftServices ~= nil and #(r.driftServices :: { string }) == 2)
	check(
		"harden driftServices values",
		r.driftServices ~= nil
			and (r.driftServices :: { string })[1] == "Workspace"
			and (r.driftServices :: { string })[2] == "Lighting"
	)
	check("harden applyScripts drops incomplete", r.applyScripts ~= nil and #(r.applyScripts :: any) == 1)
	check(
		"harden applyScript fields",
		r.applyScripts ~= nil
			and (r.applyScripts :: any)[1].studioPath == "a"
			and (r.applyScripts :: any)[1].newSource == "src"
			and (r.applyScripts :: any)[1].expectedPriorHash == "h"
	)
	check("harden error wrong-type -> nil", r.error == nil)
	check("harden request passes through", type(r.request) == "table" and (r.request :: any).reason == "rebaseline")

	r = Transport.hardenTickResponse({ ok = false, error = "no_baseline" })
	check("harden error string passes", r.error == "no_baseline")
	check("harden revision absent -> nil", r.revision == nil)
end

if failures == 0 then
	print("ALL TRANSPORT TESTS PASSED")
else
	print(("%d FAILURE(S)"):format(failures))
	error("Transport.spec failed", 0)
end
