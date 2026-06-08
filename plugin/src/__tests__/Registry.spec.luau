--!strict
-- Headless test for Registry. Registry's READ/array surface (register / list /
-- firstEnabledId / snapshotIds / countIds / selected / getHandle / the select
-- early-returns / setEnabled's unknown-id reject / teardownAll with no handles)
-- is pure: it touches no Roblox API. Under lune the `plugin` global is nil, so
-- Settings.getPanelEnabled falls back to its default for every panel (Settings's
-- read path is pcall-guarded → empty map → absent key → `defaultEnabled ~= false`);
-- that makes enabled-state fully deterministic here and lets us assert register
-- order, duplicate rejection, descriptor validation, and resolved enabled state
-- without Studio.
--
-- Deliberately NOT exercised headless (faithful boundary, not a gap): any path
-- that PERSISTS a panel setting — setEnabled's disable branch, unregister's
-- Settings.clearPanelEnabled, and select's build branch — routes through
-- Settings.setPanelEnabledMap, whose JSONEncode (and select's Instance.new) need
-- HttpService / a DataModel that lune does not provide. The monolith's write path
-- is itself unguarded there, so reproducing it headless would throw exactly as it
-- does in the engine. Those paths are covered by the in-engine SelfTest
-- (Workstream Registry: select lifecycle, disable→reselect, unregister cleanup) —
-- the same split Settings.spec uses for panel-map persistence.
-- Run:
--   lune run plugin/src/__tests__/Registry.spec.luau

local Registry = require("../Registry")

local failures = 0
local function check(label: string, cond: boolean)
	if not cond then
		failures += 1
		print("FAIL: " .. label)
	else
		print("ok: " .. label)
	end
end

-- A minimal descriptor whose build returns a handle (mirrors the monolith SelfTest
-- dummy). build is never invoked here (we never reach the host-wired select build
-- path headless), but it must be a real function so register's validation passes.
-- Typed as Registry.PanelDescriptor so the literal is checked at this boundary
-- (where optional handle fields are correctly satisfiable by absence), and the
-- closure's PanelHandle? return is annotated so it unifies with the descriptor type.
local function makeDummy(id: string, title: string): Registry.PanelDescriptor
	local descriptor: Registry.PanelDescriptor = {
		id = id,
		title = title,
		defaultEnabled = true,
		build = function(parent: Frame, _ctx: any): Registry.PanelHandle?
			return { frame = parent }
		end,
	}
	return descriptor
end

-- == Public interface presence / arity ==
check("setHost is a function", type(Registry.setHost) == "function")
check("register is a function", type(Registry.register) == "function")
check("unregister is a function", type(Registry.unregister) == "function")
check("list is a function", type(Registry.list) == "function")
check("setEnabled is a function", type(Registry.setEnabled) == "function")
check("selected is a function", type(Registry.selected) == "function")
check("teardownAll is a function", type(Registry.teardownAll) == "function")
check("select is a function", type(Registry.select) == "function")
check("getHandle is a function", type(Registry.getHandle) == "function")
check("firstEnabledId is a function", type(Registry.firstEnabledId) == "function")
check("countIds is a function", type(Registry.countIds) == "function")
check("snapshotIds is a function", type(Registry.snapshotIds) == "function")

-- == Empty initial state ==
check("starts empty (countIds)", Registry.countIds() == 0)
check("starts with no selection", Registry.selected() == nil)
check("firstEnabledId nil when empty", Registry.firstEnabledId() == nil)
check("snapshotIds empty", #Registry.snapshotIds() == 0)

-- == register: validation (trust boundary for descriptors) ==
local okBadTable, errBadTable = Registry.register((nil :: any) :: any)
check("reject non-table descriptor", not okBadTable and errBadTable == "invalid descriptor")
local okNoId = Registry.register(({ title = "x", build = function() end } :: any))
check("reject missing id", not okNoId)
local okEmptyId = Registry.register(({ id = "", title = "x", build = function() end } :: any))
check("reject empty id", not okEmptyId)
local okNoTitle = Registry.register(({ id = "a", build = function() end } :: any))
check("reject missing title", not okNoTitle)
local okNoBuild = Registry.register(({ id = "a", title = "x" } :: any))
check("reject missing build", not okNoBuild)
check("rejected descriptors did not register", Registry.countIds() == 0)

-- == register: success, order, duplicate rejection ==
local dummyA = makeDummy("__spec_a", "Spec A")
local dummyB = makeDummy("__spec_b", "Spec B")

local okA = Registry.register(dummyA)
check("register dummy A", okA)
local okDup, errDup = Registry.register(dummyA)
check("reject duplicate id", not okDup and errDup == "duplicate id")
local okB = Registry.register(dummyB)
check("register dummy B", okB)
check("countIds after two registers", Registry.countIds() == 2)

local idsAfter = Registry.snapshotIds()
check("snapshotIds sorted contains both", idsAfter[1] == "__spec_a" and idsAfter[2] == "__spec_b")

-- registration order preserved in list() (descriptors are an ordered array).
local list = Registry.list()
check("list preserves registration order", list[1].id == "__spec_a" and list[2].id == "__spec_b")

-- == list(): resolved enabled state honours defaultEnabled ==
-- Headless, Settings has no stored map, so enabled == (defaultEnabled ~= false).
check("list enabled true for defaultEnabled=true", list[1].enabled == true)
check("list carries title", list[1].title == "Spec A")
check("list carries descriptor", list[1].descriptor == dummyA)

-- defaultEnabled = false resolves to disabled.
local dummyC = makeDummy("__spec_c", "Spec C")
dummyC.defaultEnabled = false
Registry.register(dummyC)
local cItem = nil
for _, item in Registry.list() do
	if item.id == "__spec_c" then
		cItem = item
	end
end
check("defaultEnabled=false resolves disabled", cItem ~= nil and cItem.enabled == false)

-- == firstEnabledId: first enabled in registration order ==
check("firstEnabledId is first enabled", Registry.firstEnabledId() == "__spec_a")

-- == select early-returns (host unwired) ==
-- No setHost called, so select must return false without touching Instance.new.
check("select returns false when host unwired", Registry.select("__spec_a") == false)
check("selection unchanged after failed select", Registry.selected() == nil)

-- == setEnabled: unknown id rejected BEFORE any persistence ==
-- The unknown-id guard returns false before reaching Settings.setPanelEnabled, so
-- this is safe headless and proves the membership check.
check("setEnabled unknown id -> false", Registry.setEnabled("__nope", true) == false)
check("setEnabled unknown id did not change selection", Registry.selected() == nil)

-- == getHandle: nil for never-built panel ==
check("getHandle nil when never selected", Registry.getHandle("__spec_a") == nil)

-- == teardownAll: clears selection, no handles to destroy ==
-- No handles were ever built, so the destroy loop is empty (no Roblox API hit).
local tearOk = pcall(Registry.teardownAll)
check("teardownAll does not throw", tearOk)
check("selection nil after teardownAll", Registry.selected() == nil)
check("teardownAll leaves descriptors intact", Registry.countIds() == 3)

if failures == 0 then
	print("ALL REGISTRY TESTS PASSED")
else
	print(("%d FAILURE(S)"):format(failures))
	error("Registry.spec failed", 0)
end
