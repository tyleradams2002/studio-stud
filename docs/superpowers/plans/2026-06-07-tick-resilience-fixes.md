# Tick Resilience + SelfTest Wiring + Auto-Connect — Implementation Plan

> **For agentic workers:** implement task-by-task; each task is TDD where testable headlessly + the Studio gate for runtime. Steps use `- [ ]`. Apply the **luau-craft** skill.

**Goal:** Fix the three issues the 0.4.22 Studio gate surfaced — the ConnectFail/re-baseline loop, the unwired SelfTest, and the auto-connect race — then redeploy **0.4.23**.

**Branch:** `feature/plugin-rewrite-strict` (continue on it; it holds the modular rewrite + toolchain).

**Tech stack:** Luau modules under `plugin/src/` (bundled by darklua to `plugin/StudioStud.plugin.lua`); selene + luau-lsp `--!strict` gate; lune headless tests; unchanged Rust daemon.

---

## Root causes (confirmed from the daemon log + code — do not re-investigate)

1. **ConnectFail / re-baseline loop (main).** `Live.runTick` (`plugin/src/Live.luau:958`) guards on `syncInFlight` but **not** `baselineInProgress`. `triggerFullBaseline` (`:903-920`) sets `baselineInProgress=true` and uploads the bulk in a `task.spawn`; meanwhile the tick loop keeps firing `/tick` every ~0.3s **concurrently with the bulk chunk uploads**, which collide with the place's single writer lane (the daemon log shows a 3.17s window handling zero requests during the `materialize`). Those concurrent ticks `ConnectFail` → `networkErrorCount` reaches 4 → `teardown` (`:1037-1044`) → reconnect → another full re-baseline → loop. It only self-healed after ~3 min when a baseline happened to commit. (The `syncInFlight` guard already protects the commit-tick/materialize window, so only the upload window needs guarding.)

2. **SelfTest not wired.** `SelfTest.luau` is fully written but `init.luau:87-90` is a hardcoded placeholder (`runSelfTest` warns "not installed") and **nothing `require`s `SelfTest`**, so darklua never bundles it → `_G.StudioStud.RunSelfTest()` reports "not installed."

3. **Auto-connect race (minor).** `init.start` defers `Shell.onWidgetEnabled()` once (`:159-161`); if `serve` isn't up yet the single attempt `ConnectFail`s and there's no retry.

---

### Task 1: Live engine resilience (the loop)

**Files:** Modify `plugin/src/Live.luau`. Test: `plugin/src/__tests__/Live.spec.luau`.

- [ ] **Step 1 — failing SelfTest assertions** (use the existing Live host-injection harness in `Live.spec.luau`; mock `host.transport.requestJson` to count calls):
  - `runTick` is a **no-op while a baseline is in flight**: set `self.baselineInProgress = true`, call `runTick(self,"edit")`, assert `host.transport.requestJson` was **not** called and the dirty set is untouched.
  - **teardown is suppressed during recovery**: set `self.pendingBulkRef = "x"`, `self.networkErrorCount = 3`, make `requestJson` return `(false, nil)` (a ConnectFail), call `runTick`; assert `liveRunning` stays `true` (no teardown) and `networkErrorCount == 4`.
  - Run: `lune run plugin/src/__tests__/Live.spec.luau` → expect FAIL.

- [ ] **Step 2 — guard ticks during a baseline upload.** In `runTick` (`:958`):

```lua
	if not self.liveRunning or self.syncInFlight or self.baselineInProgress then
		return
	end
```

(`baselineInProgress` is `false` again once the upload finishes and `pendingBulkRef` is set, so the **commit tick still fires**; `syncInFlight` continues to protect the ~3s materialize window. This stops concurrent upload+tick HTTP — the loop trigger.)

- [ ] **Step 3 — don't teardown on transient errors during recovery.** In the error branch (`:1037`):

```lua
		if self.networkErrorCount >= 4 and not self.pendingBulkRef and not self.baselineInProgress then
			self:teardown()
			self.host.setConnected(false)
			self.host.setBaseline(false)
			self.host.setConnectButtonState()
			self.host.setStatus("error", "Daemon offline — reconnecting automatically")
			self.host.setStats("")
		end
```

(A short stall during a re-baseline no longer tears down + reconnects + re-baselines. `networkErrorCount` still increments; a genuine sustained outage with no pending bulk still tears down.)

- [ ] **Step 4 — run tests + analyzers.** `lune run plugin/src/__tests__/Live.spec.luau` → PASS. `selene --config plugin/selene.toml plugin/src` → 0/0/0. `luau-lsp analyze --defs=plugin/globalTypes.d.luau --base-luaurc=plugin/.luaurc plugin/src` → 0 errors.

- [ ] **Step 5 — commit.** `git commit -m "fix(plugin): don't fire ticks during a bulk upload or teardown during recovery (ConnectFail loop)"`

### Task 2: Wire SelfTest into the bundle

**Files:** Modify `plugin/src/init.luau` (`:87-90`, and wherever `runSelfTest` is passed to `GlobalApi.install`, `:147`).

- [ ] **Step 1 — read `plugin/src/SelfTest.luau`'s exported interface** to learn how `run` is obtained and whether it needs dependencies injected (host/modules). The Live module test-harness pattern shows how modules are wired.

- [ ] **Step 2 — replace the placeholder.** Remove the stand-in `runSelfTest` (`:87-90`) and bind the real one. If `SelfTest.run` is self-contained:

```lua
local SelfTest = require("@src/SelfTest")
-- ...later, where the placeholder was used:
GlobalApi.install(SelfTest.run)
```

If `SelfTest.run` requires injected deps, construct them exactly as `SelfTest.luau`'s interface specifies and pass a `runSelfTest(): boolean` wrapper. Keep the bare-boolean return contract (`true`=pass).

- [ ] **Step 3 — verify it bundles.** `darklua process --config plugin/.darklua.json plugin/src/init.luau plugin/StudioStud.plugin.lua`; then `grep -c 'SelfTest' plugin/StudioStud.plugin.lua` is **> 0** (the module is now reachable/bundled) and the bundle still compiles (lune `luau.compile`). selene + luau-lsp still clean.

- [ ] **Step 4 — commit.** `git commit -m "fix(plugin): wire SelfTest into init so RunSelfTest works"`

### Task 3: Auto-connect retry (minor)

**Files:** Modify `plugin/src/ui/Shell.luau` (`onWidgetEnabled` / the connect path).

- [ ] **Step 1 — add a bounded retry/backoff.** When the initial connect attempt fails because the daemon is unreachable, retry a few times with a short backoff (e.g. up to ~6 attempts over ~12s, `task.wait` between), stopping as soon as it connects or the widget is disabled. Don't spin forever; don't block the frame (run in a `task.spawn`). This lets `serve` started a few seconds after the plugin still auto-connect.

- [ ] **Step 2 — analyzers clean** (selene + luau-lsp). Commit: `git commit -m "fix(plugin): retry auto-connect so a late-started daemon still connects"`

### Task 4: Bundle + version + redeploy

- [ ] **Step 1 — bump version.** `plugin/src/Config.luau` `PLUGIN_VERSION = "0.4.23"`; `Cargo.toml` `version = "0.4.23"`; `cargo update -p studio-stud --precise 0.4.23`.
- [ ] **Step 2 — regenerate the bundle.** `darklua process --config plugin/.darklua.json plugin/src/init.luau plugin/StudioStud.plugin.lua`; confirm `PLUGIN_VERSION = "0.4.23"` in the bundle, 0 `require`s, compiles.
- [ ] **Step 3 — full gate.** `selene --config plugin/selene.toml plugin/src` 0/0/0; `luau-lsp analyze ... plugin/src` 0 errors; all `plugin/src/__tests__/*.spec.luau` lune tests pass; `cargo test --workspace -- --test-threads=1` green (daemon unchanged).
- [ ] **Step 4 — commit.** `git commit -m "chore: bundle + bump 0.4.23 (tick resilience + SelfTest wiring + auto-connect)"`. **Do NOT merge** — the controller merges to `development` after review.

---

## ✅ GATE
- Headless: selene 0/0/0, luau-lsp `--!strict` 0 errors, lune specs pass (incl. the two new Live resilience assertions), bundle compiles + contains SelfTest, `cargo test` green.
- Studio (human, after redeploy): connect to the daemon (stale state still present) → **one** re-baseline that heals in seconds (no ConnectFail loop, no repeated re-baselines in `daemon.log`) → `_G.StudioStud.RunSelfTest()` runs and reports pass/fail (no "not installed") → live edit ships a delta → empty ticks cheap.

## Out of scope (deferred follow-up)
- **Daemon-side non-blocking materialize:** the bulk-commit `materialize` still blocks the place's writer for ~3s; the plugin fix tolerates it (no loop), but a deeper fix would let the daemon answer keepalive ticks via the reader during a materialize. Only build if soak shows it still hurts.
- `darklua`/analyzer wiring into CI; `bump-version.ps1 → Config.luau` (tracked separately).

## Self-review
- **Root cause → fix mapping:** loop → Task 1 (guard ticks during `baselineInProgress` + don't teardown during recovery); SelfTest → Task 2 (require + bind); race → Task 3 (retry). ✓
- **No placeholders:** exact files/lines + the precise guard expressions are given; Task 2 is conditional on `SelfTest.luau`'s interface (Composer reads it — flagged, not vague). ✓
- **Faithfulness:** Task 1 only ADDS guards (`baselineInProgress`, pending checks); it doesn't change the wire/behavior otherwise. The `syncInFlight`/materialize protection is preserved. ✓
