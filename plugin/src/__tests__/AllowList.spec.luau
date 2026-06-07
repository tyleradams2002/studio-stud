--!strict
-- Headless test for AllowList's pure surface: parse (the decoded /allowlist body
-- -> { version, sets, lists } transform, incl. its drop-malformed trust-boundary
-- behavior) plus the not-loaded contract of namesFor/setFor. fetch needs the
-- HttpService/RequestAsync stack and is covered by the in-engine SelfTest; here we
-- exercise everything that is pure logic.
-- Run:
--   lune run plugin/src/__tests__/AllowList.spec.luau

local AllowList = require("../AllowList")

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
check("parse is a function", type(AllowList.parse) == "function")
check("fetch is a function", type(AllowList.fetch) == "function")
check("namesFor is a function", type(AllowList.namesFor) == "function")
check("setFor is a function", type(AllowList.setFor) == "function")
check("loaded starts false", AllowList.loaded == false)
check("version starts nil", AllowList.version == nil)
check("sets starts empty table", type(AllowList.sets) == "table" and next(AllowList.sets) == nil)
check("lists starts empty table", type(AllowList.lists) == "table" and next(AllowList.lists) == nil)

-- == parse: bad input -> nil (caller keeps static fallback) ==
check("parse nil -> nil", AllowList.parse(nil) == nil)
check("parse number -> nil", AllowList.parse(7) == nil)
check("parse string -> nil", AllowList.parse("nope") == nil)
check("parse empty table (no classes) -> nil", AllowList.parse({}) == nil)
check("parse classes-not-table -> nil", AllowList.parse({ classes = "x" }) == nil)

-- == parse: well-formed body ==
do
	-- Inner arrays typed `{ any }`: real /allowlist bodies are heterogeneous JSON
	-- (entries with and without readOnly), so model them as wire-shaped `any`
	-- rather than letting the analyzer unify the literals into one strict shape.
	local partEntries: { any } = {
		{ name = "Transparency", readOnly = false },
		{ name = "Anchored" }, -- no readOnly -> defaults false
		{ name = "Position", readOnly = true },
	}
	local soundEntries: { any } = {
		{ name = "Volume", readOnly = false },
	}
	local decoded: any = {
		version = "2026-06-07-v1",
		classes = {
			Part = partEntries,
			Sound = soundEntries,
		},
	}
	local parsed = AllowList.parse(decoded)
	check("parse well-formed -> non-nil", parsed ~= nil)
	if parsed then
		check("parse keeps version verbatim", parsed.version == "2026-06-07-v1")

		-- Ordered list preserves entry order.
		local partList = parsed.lists.Part
		check("Part list present", partList ~= nil)
		check("Part list length 3", partList ~= nil and #partList == 3)
		check(
			"Part list order preserved",
			partList ~= nil
				and partList[1] == "Transparency"
				and partList[2] == "Anchored"
				and partList[3] == "Position"
		)

		-- Membership set with readOnly semantics: explicit true is true; explicit
		-- false and absent both -> false (entry.readOnly == true).
		local partSet = parsed.sets.Part
		check("Part set present", partSet ~= nil)
		check("Part Transparency writable (false)", partSet ~= nil and partSet.Transparency == false)
		check("Part Anchored absent-readOnly -> false", partSet ~= nil and partSet.Anchored == false)
		check("Part Position readOnly -> true", partSet ~= nil and partSet.Position == true)
		check("Part unknown prop -> nil membership", partSet ~= nil and partSet.Nonexistent == nil)

		-- Second class also parsed.
		check("Sound list present", parsed.lists.Sound ~= nil and #parsed.lists.Sound == 1)
		check("Sound Volume writable", parsed.sets.Sound ~= nil and parsed.sets.Sound.Volume == false)
	end
end

-- == parse: trust boundary — malformed pieces dropped, not fatal ==
do
	-- Deliberately malformed wire: mixed strings/tables/numbers in one array, and a
	-- non-table `props`. Typed `any`/`{ any }` so the analyzer doesn't unify the
	-- bad literals — the whole point is to prove parse drops them at the trust
	-- boundary, modeling "this came off the wire as any".
	local mixedEntries: { any } = {
		"loose string", -- not a table -> dropped
		{ readOnly = true }, -- no name -> dropped
		{ name = 123 }, -- non-string name -> dropped
		{ name = "Good", readOnly = false }, -- kept
		42, -- not a table -> dropped
		{ name = "AlsoGood", readOnly = true }, -- kept
	}
	local decoded: any = {
		-- version omitted -> nil, still valid.
		classes = {
			-- props not a table -> whole class skipped.
			BadClass = "not a table",
			-- entries that aren't tables, or lack a string name, are skipped; valid
			-- ones survive in order.
			Mixed = mixedEntries,
			-- empty props table -> empty (present) list/set.
			Empty = {},
		},
	}
	local parsed = AllowList.parse(decoded)
	check("parse malformed -> non-nil (not fatal)", parsed ~= nil)
	if parsed then
		check("absent version -> nil", parsed.version == nil)
		-- BadClass props was a non-table -> class dropped entirely.
		check("BadClass dropped (props not table)", parsed.lists.BadClass == nil and parsed.sets.BadClass == nil)
		-- Mixed: only the two well-formed entries survive, in order.
		local mixedList = parsed.lists.Mixed
		check("Mixed keeps only 2 valid entries", mixedList ~= nil and #mixedList == 2)
		check(
			"Mixed order: Good then AlsoGood",
			mixedList ~= nil and mixedList[1] == "Good" and mixedList[2] == "AlsoGood"
		)
		check("Mixed Good writable", parsed.sets.Mixed ~= nil and parsed.sets.Mixed.Good == false)
		check("Mixed AlsoGood readOnly", parsed.sets.Mixed ~= nil and parsed.sets.Mixed.AlsoGood == true)
		-- Empty class is present but empty.
		check("Empty class present, empty list", parsed.lists.Empty ~= nil and #parsed.lists.Empty == 0)
		check("Empty class present, empty set", parsed.sets.Empty ~= nil and next(parsed.sets.Empty) == nil)
	end
end

-- == namesFor / setFor: not-loaded contract (nil before any fetch) ==
-- Module starts not loaded; both lookups must return nil regardless of class, so
-- capture falls through to the static CLASS_PROPERTIES. parse is pure and does NOT
-- mutate module state, so loaded is still false here.
check("namesFor nil when not loaded (Part)", AllowList.namesFor("Part") == nil)
check("setFor nil when not loaded (Part)", AllowList.setFor("Part") == nil)
check("loaded still false after parse calls", AllowList.loaded == false)

-- == namesFor / setFor: loaded contract (simulate a loaded state) ==
-- The SelfTest does this in-engine; here we pin the exact-class / nil-on-unknown
-- contract by simulating the post-fetch state directly (parse output assigned to
-- the module fields, loaded flipped — exactly what fetch does on success).
do
	AllowList.loaded = true
	AllowList.lists = { Part = { "Transparency" } }
	AllowList.sets = { Part = { Transparency = false } }

	local names = AllowList.namesFor("Part")
	check("namesFor returns exact-class list when loaded", names ~= nil and #names == 1 and names[1] == "Transparency")
	check("setFor returns exact-class set when loaded", AllowList.setFor("Part") ~= nil)
	check("setFor Part Transparency writable", (AllowList.setFor("Part") :: any).Transparency == false)
	-- Unknown class even when loaded -> nil (falls through to static in capture).
	check("namesFor unknown class -> nil even when loaded", AllowList.namesFor("Frame") == nil)
	check("setFor unknown class -> nil even when loaded", AllowList.setFor("Frame") == nil)

	-- Restore not-loaded state (good hygiene; the module is a singleton).
	AllowList.loaded = false
	AllowList.lists = {}
	AllowList.sets = {}
end

if failures == 0 then
	print("ALL ALLOWLIST TESTS PASSED")
else
	print(("%d FAILURE(S)"):format(failures))
	error("AllowList.spec failed", 0)
end
