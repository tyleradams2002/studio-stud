--!strict
-- `global_usage` is allowed (via per-`_G`-access `-- selene: allow(global_usage)`
-- comments below) for one deliberate reason: GlobalApi's entire contract IS owning
-- the shared `_G.StudioStud` slot (the trust boundary documented below). Every `_G`
-- access is a guarded read/write through the typed `globalSlot()` accessor + the
-- ownership token — not the accidental global the lint guards against. Suppressing
-- the rule at each site (vs. restructuring `_G` away) keeps the module faithful to
-- its purpose while clearing the tree-wide zero-warnings gate.
-- GlobalApi — the `_G.StudioStud` wiring, ported from the monolith's GlobalApi
-- block (StudioStud.plugin.lua:1324-1353) and its bootstrap install/teardown
-- (the `_G.StudioStud.RunSelfTest = SelfTest.run` line at :4574-4579 and the
-- `plugin.Unloading` reclaim at :4593-4598).
--
-- WHAT THIS OWNS (the contract): the single, deliberately small global surface the
-- plugin publishes for in-Studio operators and self-tests. The monolith published
-- `RunSelfTest` PLUS the live `Status`/`Sync`/`Capture` capture handlers directly
-- onto `_G.StudioStud`. This rewrite folds in review finding **S2**: expose ONLY
-- `RunSelfTest` (and a namespaced ownership token) on `_G.StudioStud` — NOT the raw
-- `Sync`/`Capture`/`Status` handlers. Those live capture handlers are still wired
-- internally (so the panel and SelfTest can call them), but they are no longer
-- reachable from the global namespace, which was an unrestricted command channel
-- onto the live DataModel. See the DEVIATION note below for the precise behavior
-- delta versus the monolith.
--
-- Structure note (the bug class this rewrite kills): every method is a field on the
-- single `GlobalApi` module table and reaches sibling state through `GlobalApi.*` —
-- a field read resolved at call time — so there is no forward-referenced upvalue
-- read before its `local` is assigned (C1-C3). The monolith already used a
-- module-table shape here; this port keeps that shape and only adds the explicit
-- typed interface and the S2 hardening.
--
-- Trust boundary: `_G` is a shared, untyped, plugin-global namespace — other
-- plugins can read/write it. We harden once at the read edge: every access checks
-- the slot is the table we created (via the ownership token) before trusting or
-- mutating it, and reclaim on unload only nils the slot when WE still own it (so a
-- later-loaded plugin that overwrote `_G.StudioStud` is never clobbered). This is
-- the same ownership-identity guard the monolith used (`RunSelfTest == SelfTest.run`),
-- generalized to a dedicated namespaced token so the identity check no longer
-- depends on a particular function value surviving.
--
-- Dependency note: GlobalApi's surface is capture-handler/self-test shaped and
-- traffics in no protocol-v2 wire aliases, so — like Registry — it imports nothing
-- from ./Types (luau-craft: import what you use). The capture handlers it stores
-- return open result tables; their inner shapes are owned by Capture/Live.

-- A live capture handler: the panel's `status`/`sync` callbacks. They take no args
-- and return an open result table (`{ ok = ..., ... }`). Kept internal — never
-- published to `_G` (S2). Mirrors the monolith's statusFn/syncFn shape.
export type CaptureHandler = () -> { [string]: any }

-- The self-test entry point published as `_G.StudioStud.RunSelfTest`. Returns a bare
-- boolean (true = all checks passed), faithful to the monolith's `SelfTest.run`
-- (StudioStud.plugin.lua:4566/:4569 `return true`/`return false`).
export type SelfTestFn = () -> boolean

-- The published global table. Intentionally minimal (S2): the self-test entry point
-- plus the ownership token. NO `Sync`/`Capture`/`Status`. `[string]: any` keeps it
-- a valid shared `_G` slot (other plugins may add their own keys to a table they
-- think is theirs) without weakening the two fields we own.
export type StudioStudGlobal = {
	RunSelfTest: SelfTestFn?,
	__studioStudOwner: {}?, -- ownership token (our private table identity)
	[string]: any,
}

-- == Public interface ==

export type GlobalApiModule = {
	-- Internal live handlers, held on the table so the panel can wire them and the
	-- SelfTest can read them WITHOUT exposing them on `_G` (S2). nil until wired;
	-- reset to nil by installNoOps. These are the single source of truth for the
	-- current capture handlers — the panel reads `GlobalApi.statusFn`/`.syncFn`
	-- rather than reaching back into `_G`.
	statusFn: CaptureHandler?,
	syncFn: CaptureHandler?,

	-- Build the "panel disabled" stand-in handler (faithful to the monolith's
	-- makeDisabledFn): warns once per call and returns `{ ok = false, error = ... }`.
	-- Retained so the panel/SelfTest can present a uniform disabled result; NOT
	-- published to `_G`.
	makeDisabledFn: () -> CaptureHandler,

	-- Clear the internal live handlers (the disabled state). Faithful to the
	-- monolith's installNoOps EXCEPT it no longer writes `Sync`/`Capture`/`Status`
	-- onto `_G` (S2) — there is nothing to publish, so it just drops the internal
	-- references. Safe to call when no global is installed.
	installNoOps: () -> (),

	-- Wire the live capture handlers internally. Faithful to the monolith's
	-- wireCapture EXCEPT it stores them on `GlobalApi` instead of publishing
	-- `Sync`/`Capture`/`Status` onto `_G` (S2).
	wireCapture: (statusFn: CaptureHandler, syncFn: CaptureHandler) -> (),

	-- Install the minimal global surface: create/reuse `_G.StudioStud`, stamp our
	-- ownership token, and publish `RunSelfTest`. Idempotent. Mirrors the bootstrap
	-- lines `_G.StudioStud = _G.StudioStud or {}` + `_G.StudioStud.RunSelfTest = ...`.
	install: (runSelfTest: SelfTestFn) -> (),

	-- True iff `_G.StudioStud` exists AND carries our ownership token (i.e. we still
	-- own the slot; nobody overwrote it). The trust-boundary read for the global.
	owns: () -> boolean,

	-- Reclaim on unload: nil `_G.StudioStud` ONLY if we still own it (token match),
	-- so a later plugin that replaced the slot is never clobbered. Faithful to the
	-- monolith's `if RunSelfTest == SelfTest.run then _G.StudioStud = nil`.
	reclaim: () -> (),
}

-- == Module table ==

-- Single table; methods reach siblings/state via `GlobalApi.*` (call-time field
-- reads), never via a forward-referenced local. Internal handlers start nil
-- (disabled), matching the monolith pre-wire state.
local GlobalApi = {} :: GlobalApiModule
GlobalApi.statusFn = nil
GlobalApi.syncFn = nil

-- Our private ownership token: a fresh table whose identity is unique to this
-- module instance. Stamped into `_G.StudioStud.__studioStudOwner` on install and
-- compared on owns()/reclaim(). Using a table identity (not a string/function)
-- means no other plugin can forge or accidentally collide with it.
local OWNER_TOKEN: {} = {}

-- `_G` is the untyped shared plugin global. Read it through one typed accessor so
-- the rest of the module annotates against StudioStudGlobal instead of `any`. This
-- is the trust boundary: `_G.StudioStud` is whatever some other plugin may have
-- left there, so it is `any` here and only trusted after the token check in owns().
local function globalSlot(): StudioStudGlobal?
	-- luau-lsp does not model `_G` as a typed table; treat the lookup as `any` once,
	-- here, rather than disabling checks (M1).
	-- selene: allow(global_usage)
	local slot = (_G :: any).StudioStud
	if type(slot) == "table" then
		return slot :: StudioStudGlobal
	end
	return nil
end

-- The write side of the same trust boundary: assign `_G.StudioStud` through one
-- typed accessor (a clean, non-`;`-prefixed statement) so install/reclaim never
-- inline a `_G` write and the `global_usage` suppression lives in exactly one place.
local function setGlobalSlot(value: StudioStudGlobal?): ()
	-- selene: allow(global_usage)
	local globals = _G :: any
	globals.StudioStud = value
end

function GlobalApi.makeDisabledFn(): CaptureHandler
	return function(): { [string]: any }
		warn("[Studio Stud] Capture/Query panel is disabled")
		return { ok = false, error = "panel disabled" }
	end
end

function GlobalApi.installNoOps(): ()
	-- S2: nothing is published to `_G`, so disabling is purely dropping the internal
	-- references. (The monolith set `_G.StudioStud.{Status,Sync,Capture}` to the
	-- disabled fn; those keys no longer exist on the global.)
	GlobalApi.statusFn = nil
	GlobalApi.syncFn = nil
end

function GlobalApi.wireCapture(statusFn: CaptureHandler, syncFn: CaptureHandler): ()
	-- S2: store internally instead of publishing onto `_G`. The monolith mapped both
	-- `Sync` and `Capture` to syncFn; here a single internal `syncFn` is the source
	-- of truth and any caller (panel/SelfTest) reads it off `GlobalApi.syncFn`.
	GlobalApi.statusFn = statusFn
	GlobalApi.syncFn = syncFn
end

function GlobalApi.install(runSelfTest: SelfTestFn): ()
	-- Faithful to `_G.StudioStud = _G.StudioStud or {}`: reuse an existing table if a
	-- prior load (or another plugin) left one, otherwise create ours. Then stamp the
	-- ownership token and publish the single allowed entry point (S2). `slot` is a
	-- non-optional local so the analyzer can prove the field writes below are safe
	-- (no giant closure, no nilable narrowing dance).
	local slot: StudioStudGlobal = globalSlot() or {} :: StudioStudGlobal
	setGlobalSlot(slot)
	slot.__studioStudOwner = OWNER_TOKEN
	slot.RunSelfTest = runSelfTest
end

function GlobalApi.owns(): boolean
	local slot = globalSlot()
	return slot ~= nil and slot.__studioStudOwner == OWNER_TOKEN
end

function GlobalApi.reclaim(): ()
	-- Only nil the slot when WE still own it (token match), faithful to the
	-- monolith's `RunSelfTest == SelfTest.run` ownership identity guard — a later
	-- plugin that overwrote `_G.StudioStud` keeps its slot.
	if GlobalApi.owns() then
		setGlobalSlot(nil)
	end
end

return GlobalApi
