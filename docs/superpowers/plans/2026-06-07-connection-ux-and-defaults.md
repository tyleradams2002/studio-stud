# Connection-UX Overhaul + Defaults + Update-Banner Fix — 0.4.24 Implementation Plan

> **For agentic workers:** implement task-by-task; TDD where headlessly testable + the Studio gate for runtime. Steps use `- [ ]`. Apply the **luau-craft** skill for Luau; standard Rust TDD for the daemon/setup tasks.

**Context:** 0.4.23 is validated in Studio — SelfTest 100% green, live sync commits the baseline, only one drift→recovery (no ConnectFail loop). This round is gate-feedback polish **plus** the root-cause fix for the perpetual "update available" banner.

**Goal:** (1) make the panel's connection lifecycle a calm, never-give-up auto-connect; (2) strip vestigial/erroring UI; (3) fix the heartbeat default; (4) **fix the "update available" banner** so it reflects reality on dev *and* prod. Ship **0.4.24**.

**Branch:** continue on `development`. **Tech:** Luau modules under `plugin/src/` → darklua bundle `plugin/StudioStud.plugin.lua`; gate selene + luau-lsp `--!strict` + lune. Rust daemon/setup under `src/`+`setup/`; install script `site/install.ps1`.

**NON-NEGOTIABLE:** do not regress the tick engine, SelfTest, the no-data-loss invariant, or the dev-main deploy/anti-rollback behavior. Tasks 1–4 are UI + one constant; Task 5 is a small, additive install-time change.

---

## Track A — Plugin connection UX

### Task 1 — Connection lifecycle: infinite 1s poll, stable "waiting" status, no flip-flop

**Why:** today `Shell.onWidgetEnabled` (`Shell.luau:696-742`) does a bounded `{2,2,2,2,2}` retry then gives up, and each failed probe runs the full `statusFn` whose idle branch (`CapturePanel.luau:316-320`) sets `"Run studio-stud serve, then Connect"` + a `"Connect failed"` error — so the status oscillates and then stops. The user wants: a single stable orange **"Waiting for studio-stud serve…"**, a silent 1 s poll, **never** turning auto-connect off, and **no flip-flop**.

**Files:** `plugin/src/ui/Shell.luau` (`onWidgetEnabled`), `plugin/src/ui/CapturePanel.luau` (reachability probe + idle/`statusFn` behavior).

- [ ] **Step 1 — lightweight reachability probe.** On the `CapturePanel` handle, expose `probe(): boolean` — `GET /studio-stud/ping`, returns reachable/not, **without** mutating status or the error label.
- [ ] **Step 2 — one persistent poll loop** in `onWidgetEnabled`, generation-guarded (re-enable replaces, never stacks). While the widget is enabled and this generation is current:
  - connected (`ctx.isConnected()`) → idle: `task.wait(1)`, continue (do NOT re-handshake; the tick loop owns liveness).
  - disconnected → set the stable waiting status **once** (only if not already that text): `setStatus("idle"/orange, "Waiting for studio-stud serve…")`. Then `probe()`:
    - reachable → run the real connect+baseline (`onConnectRequested()` → `startupConnectAndCapture`); on success `statusFn` sets `"connected … listening"`.
    - unreachable → keep the waiting status, **suppress** the `"Connect failed"` error label, `task.wait(1)`, continue.
  - after a live session drops (teardown → `setConnected(false)`), the next iteration resumes automatically — auto-connect is never turned off.
- [ ] **Step 3 — kill the flip-flop in `statusFn`.** Thread a `silent` flag (`statusFn(self, {silent=true})` or a `panel.autoPolling` field) so the transient-unreachable idle branch (`:316-320`) is quiet. **Keep** genuine protocol-mismatch errors (daemon/plugin outdated, `:264-296`) loud.
- [ ] **Step 4 — tests + analyzers.** lune spec: (a) waiting status text stable across N unreachable probes (set once); (b) a reachable probe triggers exactly one connect. selene `--config plugin/selene.toml plugin/src` 0/0/0; luau-lsp 0 errors. Commit.

### Task 2 — Remove the "Capture / Query" action button

**Why:** sync is fully automatic (Task 1 + tick engine). The manual `connectButton` is vestigial.

**Files:** `plugin/src/ui/CapturePanel.luau` (`setConnectButtonState` `:238-252`, the `connectButton` creation + `MouseButton1Click` wiring).

- [ ] Remove the `connectButton` widget, `setConnectButtonState`, and every call site. **Keep** `startupConnectAndCapture`/`syncFn`/`triggerFullBaseline`/`onConnectRequested` (driven by the auto-poll, `_G`, SelfTest). Keep the connection LED / status line. selene + luau-lsp clean; SelfTest green. Commit.

### Task 3 — Remove the "Addon plugins" settings section

**Why:** it surfaces the `"Could not load addons (is studio-stud serve running?)"` error and isn't core to live sync.

**Files:** `plugin/src/ui/Shell.luau` (`:443`→ "Addon plugins" `makeSectionLabel`, `addonsNote`, `addonsList`, `renderAddons`, caller).

- [ ] Remove the whole section, reclaim its `y` offset, drop now-unused refs. selene + luau-lsp clean. Commit.

### Task 4 — Defaults

**Files:** `plugin/src/Config.luau` (`:103`), `plugin/src/Settings.luau` (`getDebounceMs`).

- [ ] **Heartbeat default 300 → 500.** `DEBOUNCE_MS_DEFAULT = 500`; confirm `Settings.getDebounceMs()` falls back to it so a fresh install reads **500 ms**. (Existing installs keep their saved value — that's the user's current 450.)
- [ ] **Debug logging — NO code change.** Already defaults `false` (`Shell.luau:432`, `Settings.luau:240`); the user sees ON only because it was toggled on in a prior session (persisted key `StudioStudDebugLogging`). Leave the default. Commit.

---

## Track B — "Update available" banner fix (the identified issue)

### Task 5 — Record the installed build's channelSequence at install time

**Root cause (confirmed, do not re-investigate):** the banner = `channel_update_available_seq(manifest_seq > last_seen_seq)` via `ChannelUpdateCache` → `/ping` → plugin `checkRemoteUpdate`. `last_channel_sequence[channel]` only advances on (a) first install (`record_install_baseline_seq`, which **no-ops when a baseline exists** — `channels.rs:267`) or (b) a successful `studio-stud-setup update`. The user updates by re-running the `install-dev.ps1` one-liner, which records nothing → the recorded seq is frozen while every deploy bumps the manifest seq → perpetual banner even on the latest build. Same on prod.

**Fix:** the one-liner already fetches the manifest and knows `$manifest.channelSequence`. Forward it to `setup.exe` (mirroring the existing `STUDIO_STUD_CHANNEL_PASSWORD` pattern) and record it directly at install — so **every** install records the installed build's seq. Banner clears when current; shows only when a genuinely newer build publishes. Deterministic, offline-safe, no change to the existing `record_install_baseline_seq` path.

**Files:** `site/install.ps1`; `setup/src/install_flow.rs`; tests in `setup` / `src/setup_core/channels.rs`.

- [ ] **Step 1 — forward the seq from `install.ps1`.** Next to each `Invoke-Setup`/password-forward (both the `bundleEncUrl` *and* `bundleUrl` paths), set `$env:STUDIO_STUD_CHANNEL_SEQUENCE = [string]$manifest.channelSequence` when the manifest carries `channelSequence`, and clear it in the `finally`/after the installer returns (same lifetime as the password env var). If the manifest lacks `channelSequence` (legacy), set nothing.
- [ ] **Step 2 — record it in `install_flow.rs`.** In `run_install_headless` (where `STUDIO_STUD_CHANNEL_PASSWORD` is read, `:69-70`), after a successful install and BEFORE `record_install_baseline_seq`, read `STUDIO_STUD_CHANNEL_SEQUENCE`; if set and it parses to `u64 > 0`, call `record_channel_sequence(&mut cfg, Channel::from_str(&channel), seq)` (unconditional — installing brings you to that published build). If the env var is absent/invalid, fall through to the existing `record_install_baseline_seq(&mut cfg)` (unchanged offline-safe behavior). Anti-rollback is preserved: the one-liner always fetches the *current* manifest, so the recorded seq is monotonic-forward; `check_anti_rollback`'s floor still blocks downgrades.
- [ ] **Step 3 — tests.** Add a pure/deterministic unit test (no network) for the new env-driven path: with `STUDIO_STUD_CHANNEL_SEQUENCE` set, `last_channel_sequence[channel]` is overwritten to that value even when a prior baseline exists; with it unset, behavior is unchanged. Keep `install_baseline_preserves_existing_sequence` (`channels.rs:393`) green (the `record_install_baseline_seq` path is untouched). `cargo test --workspace -- --test-threads=1` green.
- [ ] **Step 4 — commit** `fix(update): record installed build's channelSequence at install so the update banner reflects reality`.

---

## Track C — Ship

### Task 6 — Bundle + bump 0.4.24 + full gate + deploy

- [ ] `plugin/src/Config.luau` `PLUGIN_VERSION = "0.4.24"`; `Cargo.toml` version `0.4.24` (the CI version-bump gate requires plugin == Cargo).
- [ ] `darklua process --config plugin/.darklua.json plugin/src/init.luau plugin/StudioStud.plugin.lua` → 0 `require`s, compiles, version string present.
- [ ] Full gate: selene 0/0/0; luau-lsp 0 errors; all lune specs pass (incl. SelfTest); `cargo test --workspace -- --test-threads=1` green (the 3 wall-clock `serve_workers_http` tests stay `#[ignore]`).
- [ ] Commit `chore: connection-ux + defaults + update-banner fix (0.4.24)`. **Do NOT merge** — controller merges to `development`.

---

## ✅ GATE
**Headless:** selene 0/0/0; luau-lsp 0 errors; lune specs pass; `cargo test --workspace` green incl. the new install-seq test; bundle compiles + contains SelfTest.

**Studio (human, fresh settings state):**
- Panel with `serve` **down** → stable orange **"Waiting for studio-stud serve…"**, silent 1 s poll, **no** flip-flop, **no** Capture/Query button, **no** addons error.
- Start `serve` → auto-connects + baselines within ~1 s; status → "connected … listening".
- Kill `serve` mid-session → "Waiting…"; restart → auto-reconnects (no manual action).
- SYNC DEBOUNCE reads **500 ms** by default; Debug logs **OFF** by default (no `allowlist gap` spam).
- `_G.StudioStud.RunSelfTest()` green; live edit ships a delta.

**Update banner (human):** after 0.4.24 ships, install via the one-liner → the daemon's "Daemon X.Y.Z — Update available…" banner is **gone** (you're on the current build); it returns only after the *next* deploy and clears again on the next install.

## Out of scope (deliberate — separate decision, NOT this run)
- **Fully hands-off auto-apply** (a background updater that runs `studio-stud-setup update` automatically and restarts the daemon). The apply mechanism already works (`studio-stud-setup update`, signature-verified, channelKeyDpapi seeded by the dev-main fix); Task 5 makes the *banner* accurate so it's a trustworthy nudge. A silent auto-exec+restart updater is a security/UX behavior change to design deliberately with the user, not to drop into an autonomous run.
- The tick-protocol phases (6 soak, 7 Merkle) are unrelated.

## Self-review
- Feedback → task map: #5 poll/no-flip-flop → Task 1; #4/#7 button + connect prompt → Tasks 1+2; #6 addons error → Task 3; #2 heartbeat → Task 4; #3 debug → Task 4 (already correct); **#1 update banner → Task 5 (root-caused: install never advances the seq; fix forwards `channelSequence` at install)**. ✓
- Risk: Task 5 is additive (env-var path; existing baseline path untouched), preserves anti-rollback, deterministic test. ✓
