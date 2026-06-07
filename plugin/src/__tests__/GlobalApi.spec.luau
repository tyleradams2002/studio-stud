--!strict
-- This test exercises GlobalApi's `_G.StudioStud` ownership contract, so it reads
-- `_G` once by design (line below) — `global_usage` is allowed there for the same
-- reason it is in GlobalApi.luau (the slot under test IS a `_G` slot).
-- Headless test for GlobalApi. GlobalApi is pure: it touches only `_G`, `warn`,
-- and `type` — all present under lune — so its entire surface (install / owns /
-- reclaim ownership-token logic, wireCapture/installNoOps internal-handler
-- bookkeeping, and the makeDisabledFn result shape) is exercisable without Studio.
--
-- The S2 contract is the headline assertion: after install, `_G.StudioStud`
-- exposes RunSelfTest and the ownership token but NOT Sync/Capture/Status. This
-- test pins that exclusion so the hardening can't silently regress.
-- Run:
--   lune run plugin/src/__tests__/GlobalApi.spec.luau

local GlobalApi = require("../GlobalApi")

-- `_G` is untyped; read it once into a typed accessor so the assignments below are
-- plain field writes (no `(_G :: any)...` statement-start ambiguity) and so the
-- test annotates against an open table rather than `any` everywhere.
-- selene: allow(global_usage)
local g: { [string]: any } = _G :: any

local failures = 0
local function check(label: string, cond: boolean)
	if not cond then
		failures += 1
		print("FAIL: " .. label)
	else
		print("ok: " .. label)
	end
end

-- lune provides `warn`; if a runtime lacks it, install a no-op so makeDisabledFn's
-- warn call can be invoked without throwing — the test asserts the RESULT, not the
-- warn side effect.
if type(g.warn) ~= "function" and type(warn) ~= "function" then
	g.warn = function() end
end

-- == Public interface presence / arity ==
check("makeDisabledFn is a function", type(GlobalApi.makeDisabledFn) == "function")
check("installNoOps is a function", type(GlobalApi.installNoOps) == "function")
check("wireCapture is a function", type(GlobalApi.wireCapture) == "function")
check("install is a function", type(GlobalApi.install) == "function")
check("owns is a function", type(GlobalApi.owns) == "function")
check("reclaim is a function", type(GlobalApi.reclaim) == "function")

-- == makeDisabledFn: faithful disabled result shape ==
local disabled = GlobalApi.makeDisabledFn()
local result = disabled()
check("disabled result ok == false", result.ok == false)
check("disabled result error == 'panel disabled'", result.error == "panel disabled")

-- == Clean slate: nothing installed yet ==
g.StudioStud = nil
check("owns false before install", GlobalApi.owns() == false)
-- reclaim is a no-op when we do not own the slot (and must not throw).
local reclaimCleanOk = pcall(GlobalApi.reclaim)
check("reclaim before install does not throw", reclaimCleanOk)

-- == install: publishes ONLY RunSelfTest + token (S2) ==
-- SelfTestFn returns a bare boolean (monolith-faithful: SelfTest.run -> true/false).
local selfTestCalls = 0
local function fakeSelfTest(): boolean
	selfTestCalls += 1
	return true
end

GlobalApi.install(fakeSelfTest)
local slot = g.StudioStud
check("install created _G.StudioStud table", type(slot) == "table")
check("owns true after install", GlobalApi.owns() == true)
check("RunSelfTest published", slot.RunSelfTest == fakeSelfTest)

-- RunSelfTest is callable through the global and dispatches to our fn.
local stResult = slot.RunSelfTest()
check("RunSelfTest invoked via _G", selfTestCalls == 1 and stResult == true)

-- THE S2 ASSERTION: no raw capture handlers on the global.
check("S2: no Sync on _G.StudioStud", slot.Sync == nil)
check("S2: no Capture on _G.StudioStud", slot.Capture == nil)
check("S2: no Status on _G.StudioStud", slot.Status == nil)

-- == wireCapture / installNoOps: internal-only handlers, never on _G ==
local function statusFn(): { [string]: any }
	return { ok = true, kind = "status" }
end
local function syncFn(): { [string]: any }
	return { ok = true, kind = "sync" }
end

GlobalApi.wireCapture(statusFn, syncFn)
check("wireCapture stores statusFn internally", GlobalApi.statusFn == statusFn)
check("wireCapture stores syncFn internally", GlobalApi.syncFn == syncFn)
-- Still not leaked onto the global after wiring (S2 holds post-wire).
check("S2: wireCapture did not publish Sync", g.StudioStud.Sync == nil)
check("S2: wireCapture did not publish Capture", g.StudioStud.Capture == nil)
check("S2: wireCapture did not publish Status", g.StudioStud.Status == nil)

GlobalApi.installNoOps()
check("installNoOps clears statusFn", GlobalApi.statusFn == nil)
check("installNoOps clears syncFn", GlobalApi.syncFn == nil)

-- == install is idempotent: reuses the existing slot, re-stamps ownership ==
local slotBefore = g.StudioStud
GlobalApi.install(fakeSelfTest)
check("install reuses existing _G.StudioStud table", g.StudioStud == slotBefore)
check("owns still true after re-install", GlobalApi.owns() == true)

-- == install reuses a foreign pre-existing table (faithful `_G.x = _G.x or {}`) ==
g.StudioStud = nil
local foreign: { [string]: any } = { otherPluginKey = 42 }
g.StudioStud = foreign
check("owns false for foreign table (no token)", GlobalApi.owns() == false)
GlobalApi.install(fakeSelfTest)
check("install reused foreign table", g.StudioStud == foreign)
check("install preserved foreign key", g.StudioStud.otherPluginKey == 42)
check("owns true after stamping foreign table", GlobalApi.owns() == true)

-- == reclaim: nils the slot only when we own it ==
GlobalApi.reclaim()
check("reclaim niled _G.StudioStud when owned", g.StudioStud == nil)
check("owns false after reclaim", GlobalApi.owns() == false)

-- reclaim must NOT clobber a slot we do not own (later plugin replaced it).
g.StudioStud = { __studioStudOwner = {}, RunSelfTest = function() end }
local notOurs = g.StudioStud
GlobalApi.reclaim()
check("reclaim leaves a foreign-owned slot intact", g.StudioStud == notOurs)

-- clean up the global so the test leaves no residue.
g.StudioStud = nil

if failures == 0 then
	print("ALL GLOBALAPI TESTS PASSED")
else
	print(("%d FAILURE(S)"):format(failures))
	error("GlobalApi.spec failed", 0)
end
