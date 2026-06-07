--!strict
-- Headless test for Session: pins the full decide() truth table (the edit/play
-- gate) and the derived shape of the module's public interface. `decide` is pure
-- so it runs entirely headless; `signals`/`mode`/`isEdit` touch RunService and so
-- are only checked for presence/type here (they are exercised in the in-engine
-- SelfTest). Run:
--   lune run plugin/src/__tests__/Session.spec.luau

local Session = require("../Session")

local failures = 0
local function check(label: string, cond: boolean)
	if not cond then
		failures += 1
		print("FAIL: " .. label)
	else
		print("ok: " .. label)
	end
end

-- == decide() truth table ==
-- Only (isEdit=true, isRunning=false) is "edit"; every other row is "play". This
-- is the NON-NEGOTIABLE gate — a regression here ships traffic from a play
-- DataModel (or silences a real edit session).
check("edit & not running -> edit", Session.decide(true, false) == "edit")
check("edit & running -> play", Session.decide(true, true) == "play")
check("not edit & not running -> play", Session.decide(false, false) == "play")
check("not edit & running -> play", Session.decide(false, true) == "play")

-- decide is total over the boolean domain — only the two literal modes appear.
for _, isEdit in { true, false } do
	for _, isRunning in { true, false } do
		local m = Session.decide(isEdit, isRunning)
		check(
			("decide(%s,%s) is a valid mode"):format(tostring(isEdit), tostring(isRunning)),
			m == "edit" or m == "play"
		)
	end
end

-- == Public interface presence ==
check("decide is a function", type(Session.decide) == "function")
check("signals is a function", type(Session.signals) == "function")
check("mode is a function", type(Session.mode) == "function")
check("isEdit is a function", type(Session.isEdit) == "function")

if failures == 0 then
	print("ALL SESSION TESTS PASSED")
else
	print(("%d FAILURE(S)"):format(failures))
	error("Session.spec failed", 0)
end
