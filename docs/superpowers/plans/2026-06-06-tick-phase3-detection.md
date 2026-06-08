# Phase 3 — Plugin Detection Collapse + Allow-List Consumption (Luau)

> **For Composer 2.5 (Cursor):** This is the **first Luau/plugin phase** — it works DIFFERENTLY from
> Phases 1–2. **You cannot run the plugin (no Roblox Studio in CI).** Your job: make the edits and
> add the SelfTest cases exactly as specified, keep the Luau valid, and **STOP**. The gate is run by
> the user **inside Studio** (SelfTest + a manual checklist). Do NOT claim the gate is green — you
> can't verify it. Branch: `feature/tick-phase3-detection` (already cut from `development`, plan
> committed on it). Parent design: `docs/tick-protocol-redesign-design.md` (D2, D9). Phases 1–2 are
> merged to `development` (the `/studio-stud/allowlist` endpoint exists).

**Goal:** The plugin fetches the daemon's `/allowlist` on connect and uses it as the property
capture filter (replacing the static `CLASS_PROPERTIES`), and collapses the ~20 per-instance signal
connections to ~3 by replacing the per-property `GetPropertyChangedSignal` fan-out with a single
`inst.Changed` connection (ValueBase special-cased), plus a gap-probe for uncurated properties.

**No wire/protocol change** beyond *consuming* the existing `GET /studio-stud/allowlist` (added in
Phase 2). The transport (capture/delta endpoints) is unchanged — only *detection* changes.

**Single file:** `plugin/StudioStud.plugin.lua`.

---

## How to work this phase (read first)

- **TDD doesn't apply the usual way** — Composer can't execute Luau. For each task: make the edit,
  add the SelfTest case(s) (real Luau the user will run), commit. There is **no "run the test" step
  for you.**
- **Be conservative with Luau syntax** — no linter is configured (no stylua/selene). Match the
  surrounding style (tabs, `local function`, `pcall` wrappers). Do not introduce syntax the rest of
  the file doesn't use.
- **The gate is the user's** — a "PHASE 3 VERIFICATION" section at the end lists what *they* run in
  Studio. End your work by listing exactly what changed and pointing them at that section.

### Verified scoping facts (do not re-guess — they determine where code goes)
- `debugLog(...)` is **module-scope** (line 1000).
- `Transport` module ends ~line 1190; `CapturePanel.build` starts at **1438**.
- Inside `CapturePanel.build`: `local Live` (1446, forward-declared), `local Capture = {}` (1485),
  `local instanceIdByRef = {}` (1486), `local pathByRef = {}` (1487). These are **NOT** visible at
  module scope.
- The capture handle return (line ~2962) exposes `live = Live` "for self-tests". It does **not**
  expose `Capture`.
- `SelfTest.run()` (line 3557) is module-scope; it reaches the live engine via
  `local live = Registry.getHandle("capture").live` (see line 3743-3744).
- `Transport.requestJson(method, path, body, timeoutSeconds)` returns `(ok, decoded)` (line 1043).
- `Capture.getPropertyNames(inst)` (1580) and `Capture.readProperties` (1597) drive capture;
  `Live.registerInstance(inst)` (2107) wires per-instance signals; `startupConnectAndCapture()`
  (1980) is the connect entry point.

**Therefore:** put the new `AllowList` module at **module scope** (after the Transport module,
before `CapturePanel.build`) so it's an upvalue for `Capture`/`Live` *and* directly visible to
`SelfTest`. Expose `capture = Capture` on the handle so the getPropertyNames tests are reachable.

---

## Task 3.1 — `AllowList` module: fetch + parse + cache (D9)

**Edit:** insert a new module at **module scope**, after the `Transport` module (~line 1190) and
before `CapturePanel.build` (1438).

```lua
-- == Property allow-list (fetched from daemon /allowlist; static CLASS_PROPERTIES is the fallback) ==
local AllowList = {}
AllowList.loaded = false
AllowList.version = nil
AllowList.sets = {}  -- [className] = { [propName] = readOnly(boolean) }   (O(1) membership)
AllowList.lists = {} -- [className] = { propName, ... }                    (ordered, for capture)

-- Pure: turn a decoded /allowlist response into per-class sets + ordered lists. Returns nil on bad input.
function AllowList.parse(decoded)
	if type(decoded) ~= "table" or type(decoded.classes) ~= "table" then
		return nil
	end
	local sets, lists = {}, {}
	for className, props in pairs(decoded.classes) do
		if type(props) == "table" then
			local set, list = {}, {}
			for _, entry in ipairs(props) do
				if type(entry) == "table" and type(entry.name) == "string" then
					set[entry.name] = entry.readOnly == true
					table.insert(list, entry.name)
				end
			end
			sets[className] = set
			lists[className] = list
		end
	end
	return { version = decoded.version, sets = sets, lists = lists }
end

-- Fetch from the daemon and cache. Returns true on success; leaves the static fallback in place on failure.
function AllowList.fetch()
	local ok, decoded = Transport.requestJson("GET", "/studio-stud/allowlist", nil, 15)
	if not ok then
		debugLog("allowlist: fetch failed (static fallback):", decoded and decoded.error)
		return false
	end
	local parsed = AllowList.parse(decoded)
	if not parsed then
		debugLog("allowlist: bad response (static fallback)")
		return false
	end
	AllowList.sets = parsed.sets
	AllowList.lists = parsed.lists
	AllowList.version = parsed.version
	AllowList.loaded = true
	local count = 0
	for _ in pairs(parsed.sets) do
		count += 1
	end
	debugLog("allowlist: loaded version", tostring(parsed.version), "classes", count)
	return true
end

-- Ordered property names for an exact class (nil if not loaded / class unknown).
function AllowList.namesFor(className)
	if AllowList.loaded then
		return AllowList.lists[className]
	end
	return nil
end

-- Membership set {propName = readOnly} for an exact class (nil if not loaded / class unknown).
function AllowList.setFor(className)
	if AllowList.loaded then
		return AllowList.sets[className]
	end
	return nil
end
```

**SelfTest case** — add inside `SelfTest.run()` (it's module-scope, so `AllowList` is directly
visible). Put it near the other pure-logic blocks (e.g. just before the "Edit-session gate
self-tests" block ~3780):

```lua
	-- == Phase 3: allow-list parse (pure) ==
	do
		local parsed = AllowList.parse({
			version = "1.2.3.4",
			classes = {
				Part = {
					{ name = "Transparency", readOnly = false },
					{ name = "AbsoluteSize", readOnly = true },
				},
			},
		})
		SelfTest.assert("allowlist parse version", parsed ~= nil and parsed.version == "1.2.3.4", failures)
		SelfTest.assert("allowlist parse membership", parsed ~= nil and parsed.sets.Part.Transparency == false, failures)
		SelfTest.assert("allowlist parse readOnly flag", parsed ~= nil and parsed.sets.Part.AbsoluteSize == true, failures)
		SelfTest.assert("allowlist parse ordered list", parsed ~= nil and #parsed.lists.Part == 2, failures)
		SelfTest.assert("allowlist parse rejects bad input", AllowList.parse({}) == nil, failures)
	end
```

**Commit:** `git add plugin/StudioStud.plugin.lua && git commit -m "feat(plugin): AllowList module (fetch+parse /allowlist, static fallback)"`

## Task 3.2 — Route `getPropertyNames` + add `curatedSet` through the allow-list (fallback to `CLASS_PROPERTIES`)

**Edit 1 — `Capture.getPropertyNames` (line 1580).** Prefer the fetched allow-list (per exact class,
already includes inherited props); fall back to the existing static logic:

```lua
	function Capture.getPropertyNames(inst)
		-- Phase 3: prefer the daemon allow-list (per exact ClassName, includes inherited props).
		local fromAllow = AllowList.namesFor(inst.ClassName)
		if fromAllow then
			return fromAllow
		end
		-- Fallback: static CLASS_PROPERTIES (IsA-based accumulation).
		local names = {}
		if inst:IsA("BasePart") then
			for _, name in ipairs(CLASS_PROPERTIES.BasePart) do
				table.insert(names, name)
			end
		end
		for className, props in pairs(CLASS_PROPERTIES) do
			if className ~= "BasePart" and inst:IsA(className) then
				for _, name in ipairs(props) do
					table.insert(names, name)
				end
			end
		end
		return names
	end
```

**Edit 2 — add `Capture.curatedSet` right after `getPropertyNames`:**

```lua
	-- Membership set for the inst's class (allow-list when loaded, else built from the static names).
	function Capture.curatedSet(inst)
		local fromAllow = AllowList.setFor(inst.ClassName)
		if fromAllow then
			return fromAllow
		end
		local set = {}
		for _, name in ipairs(Capture.getPropertyNames(inst)) do
			set[name] = false
		end
		return set
	end
```

**Edit 3 — expose `Capture` on the capture handle** so SelfTest can reach it. At the handle return
(~line 2962, where `live = Live,` is), add a sibling field:

```lua
		live = Live, -- exposed for self-tests and _G.StudioStud.Live
		capture = Capture, -- Phase 3: exposed for self-tests
```

**SelfTest case** — add inside `SelfTest.run()`, in the live block that already has
`local live = Registry.getHandle("capture").live` (~3743). Grab the capture handle there too:

```lua
	-- == Phase 3: getPropertyNames + curatedSet routing ==
	do
		local captureExports = Registry.getHandle("capture")
		local capture = captureExports and captureExports.capture
		if capture then
			local part = Instance.new("Part")
			-- not loaded -> static fallback includes CFrame (BasePart)
			AllowList.loaded = false
			local fallbackNames = capture.getPropertyNames(part)
			local hasCFrame = false
			for _, n in ipairs(fallbackNames) do
				if n == "CFrame" then
					hasCFrame = true
				end
			end
			SelfTest.assert("getPropertyNames fallback includes CFrame", hasCFrame, failures)
			-- loaded -> uses the allow-list
			AllowList.loaded = true
			AllowList.lists = { Part = { "Transparency" } }
			AllowList.sets = { Part = { Transparency = false } }
			local allowNames = capture.getPropertyNames(part)
			SelfTest.assert(
				"getPropertyNames uses allow-list when loaded",
				#allowNames == 1 and allowNames[1] == "Transparency",
				failures
			)
			SelfTest.assert("curatedSet membership from allow-list", capture.curatedSet(part).Transparency == false, failures)
			-- restore
			AllowList.loaded = false
			AllowList.lists = {}
			AllowList.sets = {}
			part:Destroy()
		else
			print("[Studio Stud SelfTest] SKIP: capture handle not available")
		end
	end
```

**Commit:** `feat(plugin): route property selection through the allow-list (static fallback)`

## Task 3.3 — Collapse `registerInstance` to one `inst.Changed` (+ ValueBase + gap-probe) (D2/D9)

**Edit 1 — add helpers to the `Live` table, just before `Live.registerInstance` (line 2107):**

```lua
	-- Pure: classify a Changed property for an instance. Returns "name" | "dirty" | "gap".
	function Live.classifyChangedProp(prop, curatedSet)
		if prop == "Name" then
			return "name"
		elseif curatedSet[prop] then
			return "dirty"
		else
			return "gap"
		end
	end

	-- Uncurated properties that fired, deduped, for later reporting to the daemon (Phase 5).
	Live.propGaps = {} -- [className.."/"..prop] = true
	function Live.recordPropGap(className, prop)
		local key = (className or "?") .. "/" .. tostring(prop)
		if not Live.propGaps[key] then
			Live.propGaps[key] = true
			debugLog("allowlist gap:", key)
		end
	end

	-- Shared name-change cascade (was the body of the old Name signal).
	function Live.onNameChanged(inst)
		local oldPath = pathByRef[inst] or ""
		local oldName = oldPath:match("([^%[/]+)%[%d+%]$") or inst.Name
		Live.markSubtreeUpsert(inst)
		local parent = Live.parentByInst[inst] or inst.Parent
		Live.markSiblingsDirty(parent, oldName)
		Live.markSiblingsDirty(parent, inst.Name)
	end
```

**Edit 2 — replace the body of `Live.registerInstance` (lines 2107–2177)** — keep AncestryChanged +
AttributeChanged exactly as they are; replace the Name signal + the per-property loop with one
`inst.Changed` (non-ValueBase) or explicit Name+Value signals (ValueBase):

```lua
	function Live.registerInstance(inst)
		if Live.instConns[inst] then
			return
		end
		local conns = {}

		-- AncestryChanged: intra-root reparent (fires on moved node AND each dragged descendant)
		local okA, cA = pcall(function()
			return inst.AncestryChanged:Connect(function(changedChild, newParent)
				if instanceIdByRef[inst] then
					Live.dirtyUpsert[inst] = true
				end
				if changedChild == inst then
					local oldParent = Live.parentByInst[inst]
					if oldParent ~= newParent then
						Live.markSiblingsDirty(oldParent, inst.Name)
						Live.markSiblingsDirty(newParent, inst.Name)
					end
					Live.parentByInst[inst] = newParent
				end
			end)
		end)
		if okA then
			table.insert(conns, cA)
		end

		-- AttributeChanged
		local okAt, cAt = pcall(function()
			return inst.AttributeChanged:Connect(function()
				if instanceIdByRef[inst] then
					Live.dirtyUpsert[inst] = true
				end
			end)
		end)
		if okAt then
			table.insert(conns, cAt)
		end

		if inst:IsA("ValueBase") then
			-- ValueBase fires .Changed with the VALUE, not the property name → use explicit signals.
			local okN, cN = pcall(function()
				return inst:GetPropertyChangedSignal("Name"):Connect(function()
					Live.onNameChanged(inst)
				end)
			end)
			if okN then
				table.insert(conns, cN)
			end
			local okV, cV = pcall(function()
				return inst:GetPropertyChangedSignal("Value"):Connect(function()
					if instanceIdByRef[inst] then
						Live.dirtyUpsert[inst] = true
					end
				end)
			end)
			if okV then
				table.insert(conns, cV)
			end
		else
			-- One Changed connection replaces ~N per-property signals + the Name signal.
			local curated = Capture.curatedSet(inst)
			local okC, cC = pcall(function()
				return inst.Changed:Connect(function(prop)
					local kind = Live.classifyChangedProp(prop, curated)
					if kind == "name" then
						Live.onNameChanged(inst)
					elseif kind == "dirty" then
						if instanceIdByRef[inst] then
							Live.dirtyUpsert[inst] = true
						end
					else
						Live.recordPropGap(inst.ClassName, prop)
					end
				end)
			end)
			if okC then
				table.insert(conns, cC)
			end
		end

		Live.instConns[inst] = conns
	end
```

**SelfTest cases** — add inside the live block (where `local live = ...` exists, ~3744), guarded by
`if live then`:

```lua
		-- == Phase 3: detection collapse ==
		do
			local curated = { Transparency = false }
			SelfTest.assert("classify Name -> name", live.classifyChangedProp("Name", curated) == "name", failures)
			SelfTest.assert("classify curated -> dirty", live.classifyChangedProp("Transparency", curated) == "dirty", failures)
			SelfTest.assert("classify uncurated -> gap", live.classifyChangedProp("Archivable", curated) == "gap", failures)

			-- gap-probe dedup
			live.propGaps = {}
			live.recordPropGap("Part", "Foo")
			live.recordPropGap("Part", "Foo")
			local gapCount = 0
			for _ in pairs(live.propGaps) do
				gapCount += 1
			end
			SelfTest.assert("recordPropGap dedups", gapCount == 1, failures)

			-- connection-count collapse: a Part should register ~3 connections, not ~20
			AllowList.loaded = true
			AllowList.lists = { Part = { "Transparency", "Size" } }
			AllowList.sets = { Part = { Transparency = false, Size = false } }
			local part = Instance.new("Part")
			live.registerInstance(part)
			local partConns = live.instConns[part]
			SelfTest.assert("registerInstance collapses Part to <=4 conns", partConns ~= nil and #partConns <= 4, failures)
			live.unregisterInstance(part)
			part:Destroy()

			-- ValueBase registers explicit signals (Ancestry + Attribute + Name + Value)
			local iv = Instance.new("IntValue")
			live.registerInstance(iv)
			local ivConns = live.instConns[iv]
			SelfTest.assert("ValueBase registers >=3 conns", ivConns ~= nil and #ivConns >= 3, failures)
			live.unregisterInstance(iv)
			iv:Destroy()

			AllowList.loaded = false
			AllowList.lists = {}
			AllowList.sets = {}
		end
```

**Commit:** `feat(plugin): collapse per-property signals to inst.Changed (+ValueBase, gap-probe)`

## Task 3.4 — Fetch the allow-list on connect

**Edit — `startupConnectAndCapture` (line 1980).** After the ping succeeds and before the
`sessionHasBaseline` short-circuit (between lines 1991 and 1992), load the allow-list once:

```lua
		local ping = statusFn()
		if not (ping and ping.ok) then
			return ping
		end
		if not AllowList.loaded then -- Phase 3: load once per connect (best-effort; static fallback on failure)
			AllowList.fetch()
		end
		if sessionHasBaseline or (Live and Live.liveRunning) then
			return ping
		end
```

(No SelfTest — `fetch` needs a live daemon; covered by the manual checklist. The parse path is
already tested in 3.1.)

**Commit:** `feat(plugin): fetch the allow-list once on connect`

---

## ✅ PHASE 3 VERIFICATION — run by the USER in Studio (not Composer)

Composer: after the four commits, STOP and tell the user to run these. Do **not** mark the phase
complete yourself.

1. **Plugin loads** — install the updated plugin; it loads with no Studio output errors.
2. **SelfTest** — trigger the plugin's SelfTest; all asserts PASS (including the new Phase 3 ones:
   allowlist parse, getPropertyNames routing, classify truth table, gap dedup, connection-count
   collapse, ValueBase).
3. **Allow-list fetch on connect** — with `studio-stud serve --verbose` running, connect from the
   plugin; the daemon log shows `GET /studio-stud/allowlist`, and the plugin debug log shows
   `allowlist: loaded version ...`.
4. **Capture correctness** — capture a place; spot-check via `studio-stud query <place> --class BasePart`
   (or `live-dump`) that a Part still has its expected properties (Transparency, Size, etc.).
5. **Live detection** — with live mode on: move a Part's Position → a delta fires (daemon log
   `live-delta APPLY`); change an `IntValue`'s `Value` → a delta fires; change a property NOT in the
   allow-list → NO delta (and the plugin debug log shows an `allowlist gap:` line).
6. **Offline fallback** — stop the daemon, then connect: the plugin falls back to the static
   `CLASS_PROPERTIES` (no error; capture still works on reconnect).

**Gate = all six pass in Studio.** Then the user brings the results back for review + merge to
`development`.

---

## Deferred to later phases (do NOT build here)
- Reporting `Live.propGaps` to the daemon + the daemon validating/adding discovered properties → the
  `/tick` channel (Phase 5).
- Re-registering instances if the allow-list changes mid-session (it's fetched once on connect;
  fine for now).
- Anything touching the transport/protocol (still the legacy capture/delta endpoints until Phase 5).

_Plan grounded in the real plugin scoping (Capture/Live local to CapturePanel.build; SelfTest via the
`capture` handle) and the Phase-2 `/allowlist` response shape `{version, classes:{Class:[{name,readOnly}]}}`._
