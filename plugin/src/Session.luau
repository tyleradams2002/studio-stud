--!strict
-- Session — edit-vs-play mode detection. Ported faithfully from the monolith's
-- Session block (StudioStud.plugin.lua:25-48).
--
-- Studio Stud must talk to the daemon ONLY during a genuine edit session. Code
-- running in a play/run DataModel (Play Solo / F8 Run, or a stray copy embedded
-- in the place) reports IsRunning()=true / IsEdit()=false and is gated to "play".
-- The real plugin runs in the edit DataModel; during an F5 playtest (a separate
-- DataModel) it stays "edit" and never sees the running game, so there is nothing
-- to capture there.
--
-- `decide` is a PURE function (no DataModel reads) so its truth table stays
-- unit-testable headless. The only impure surface is `signals()`, the single
-- read point for the live RunService state.

local Types = require("./Types")

type SessionMode = Types.SessionMode

-- The live edit/play signals read off RunService. Cached at no point — these are
-- cheap engine reads and must reflect the CURRENT DataModel state every call (a
-- play DataModel and an edit DataModel each run their own copy).
export type Signals = {
	isEdit: boolean,
	isRunning: boolean,
}

-- == Public interface ==

export type SessionModule = {
	-- The pure truth table. The ONLY mode that ships traffic is edit, defined as
	-- "Studio is in edit AND the game is not running". Every other combination is
	-- a play/run DataModel and gates to "play" (a pure keepalive). Faithful port
	-- of `(sig.isEdit and not sig.isRunning) and "edit" or "play"`, written as an
	-- explicit if/else (the old `a and b or c` form was only safe because "edit"
	-- is truthy; the if/else removes that footgun without changing the result).
	decide: (isEdit: boolean, isRunning: boolean) -> SessionMode,

	-- Signal accessor: the single point that reads live RunService state. Impure
	-- by design; everything downstream consumes the typed table or `decide`.
	signals: () -> Signals,

	-- Current mode = decide(signals()). Convenience composition of the two above.
	mode: () -> SessionMode,

	-- True iff the current mode is "edit". The gate every traffic path checks.
	isEdit: () -> boolean,
}

-- == Engine handle ==

-- `game` is a plugin/Studio global typed via globalTypes.d.luau under the
-- analyzer. Resolution is LAZY (and cached) rather than at module load so the
-- pure `decide` half can be required headlessly (lune has no `game`) for the
-- truth-table test. The first impure call (`signals`) narrows GetService's
-- Instance result to RunService exactly once — the single trust point for the
-- engine handle; every later call reuses the cached handle (cache-at-event).
local runService: RunService? = nil
local function getRunService(): RunService
	local cached = runService
	if cached then
		return cached
	end
	local resolved = game:GetService("RunService") :: RunService
	runService = resolved
	return resolved
end

-- == Implementation ==

local function decide(isEdit: boolean, isRunning: boolean): SessionMode
	if isEdit and not isRunning then
		return "edit"
	end
	return "play"
end

local function signals(): Signals
	local rs = getRunService()
	return {
		isEdit = rs:IsEdit(),
		isRunning = rs:IsRunning(),
	}
end

local function mode(): SessionMode
	local sig = signals()
	return decide(sig.isEdit, sig.isRunning)
end

local function isEdit(): boolean
	return mode() == "edit"
end

-- == Module table ==

local Session: SessionModule = {
	decide = decide,
	signals = signals,
	mode = mode,
	isEdit = isEdit,
}

return Session
