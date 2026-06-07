# Plugin Rewrite — Strict-Typed, Modular, Production-Grade Luau

> **For agentic workers:** REQUIRED SUB-SKILL: use superpowers:subagent-driven-development to implement this plan module-by-module with review between modules. Also apply the **luau-craft** skill while writing every module. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Replace the single 4,613-line `plugin/StudioStud.plugin.lua` with a modular, fully `--!strict`-typed Luau codebase, bundled back to one distributable file, that **reproduces the exact protocol-v2 behavior the unchanged daemon already expects** — while making the C1–C3 bug class (forward-reference scope errors, infinite recursion) structurally impossible and catching it in CI.

**Architecture:** Many small `--!strict` ModuleScripts under `plugin/src/`, each with one responsibility and an explicit typed interface, bundled by **darklua** into `dist/StudioStud.plugin.lua`. A real Luau analyzer (**luau-lsp analyze** with Roblox type defs) + **selene** lint run in CI and locally as the guardrail. The daemon does not change; the new plugin is verified by the **existing daemon protocol-v2 integration tests** plus an expanded in-engine SelfTest and the Studio gate.

**Tech Stack:** Luau (`--!strict`), darklua (bundler), luau-lsp + selene (static analysis), Roblox Studio plugin APIs, the existing Rust daemon (unchanged) as the protocol contract.

---

## NON-NEGOTIABLE: the behavioral contract (what must NOT be lost)

This is a *re-architecture that preserves behavior*, not a blank slate. The daemon is fixed at protocol v2; the new plugin must be byte-compatible on the wire and reproduce every proven behavior. **Every item below is a regression if it changes.** Source of truth for each is the current plugin + `docs/tick-protocol-redesign-design.md` + `docs/plugin-review-secure-smart-efficient.md` ("What's solid").

**Protocol / wire (must be identical — the daemon's tests pin these):**
- `POST /studio-stud/tick?placeId=&projectKey=` packet shape (design §4.1): `placeId, sessionMode, baseRevision, serviceFingerprints{}, ops{upserted[],removed[]}, bulkRef`; response `{ok, revision, instanceCount, driftServices[], request, applyScripts[]}`.
- `/tick/bulk/{start,chunk,complete}` chunked upload; `bulkRef` commit on the next tick.
- `PROTOCOL_VERSION = 2`, `MIN_DAEMON_PROTOCOL_VERSION = 2`; the mutual handshake (current `:2078`).
- Instance entry shape: `id, parentId, path, name, className, depth, siblingIndex, childCount, duplicateSiblingName, properties, attributes, tags, fp, source?, sourceEncoding?`.

**Fingerprints (FP-1, plugin-authoritative — daemon stores/XORs the plugin's value):**
- `hashInstance` = the **exact** 4-lane FNV-32 → 64-hex over the canonical string (className|name|parentId|path|depth|siblingIndex|childCount|0/1|props|attrs|tags, keys sorted, `source` EXCLUDED). **The hash bytes must be identical** or every tick reports drift. Port the algorithm verbatim.
- Per-service XOR accumulators (`serviceFpBytes`) with correct add/remove/reparent inverse; `serviceFingerprintsWire` emits 64-hex.
- Each upserted entry carries `fp`; the accumulator is updated when the entry is built (post-ops ordering — fingerprints computed AFTER collecting ops, the Phase-5 fix).

**Live engine behavior:**
- One `inst.Changed` connection (collapsed) with `classifyChangedProp` (the `~= nil` membership fix; `Name`→name, `Source`→dirty, curated→dirty, else→gap); ValueBase special-case (explicit Name+Value signals); `AncestryChanged`/`AttributeChanged`; `DescendantAdded`/`DescendantRemoving`.
- Lazy dirty marking (handlers set dirty only; values read at tick time). Stamp-based `clearSentDirty` (edits mid-tick not lost — the no-data-loss invariant).
- One fixed-interval tick loop replacing the old 3 loops; ops capped per tick (`TICK_INLINE_THRESHOLD`, forward-progress so a solo over-threshold op still ships); `bulkRef` baseline spill; **no partial `materialize`** (delta-only recovery).
- Drift → full-rebaseline recovery (with the yield, the Q1 fix); `historyDirty`→rebaseline on undo/redo.
- Session gating: edit→play teardown (no traffic during play); play→edit catch-up/resume (the C2 path, now fixed). Graceful behavior preserved.
- Baseline: first connect → full tree → `/tick/bulk`; `no_baseline` → trigger baseline.

**Capture:**
- Yielding baseline walk (`shouldYield` every N); optimistic batch-`pcall` property read with per-property fallback; `readSource` for `LuaSourceContainer` with base64 for non-UTF-8 (`sourceEncoding`); Model bounding-box/pivot; attributes (all, no whitelist) + tags.
- `serializeValue` for all datatypes with the `{type="Unsupported"}` default; the allow-list-driven `getPropertyNames`/`curatedSet` with static `CLASS_PROPERTIES` fallback.

**Safety / transport:**
- `sanitizeJsonValue` + `safeEncode` (NaN/inf→0, invalid-UTF-8→prefix+U+FFFD, cyclic→dropped, userdata→Unsupported) — a capture can never hard-fail JSON encode.
- `requestJson`/`requestJsonAuthed` with write-token header; daemon-URL parsing; allow-list fetch with static fallback.

**Session / misc:** `Session.decide` pure truth-table (edit/play); plugin-vs-game-script guard (current `:12`); toolbar/widget bootstrap with auto-connect.

**SelfTest:** every existing assertion must port and pass (Workstreams E, Phase 3/4/5C, JSON-safety, edit-gate) — PLUS new regressions for C1–C3 (see P7).

> **Improvements folded in from the review (do during the rewrite, not after):** S1 loopback-only daemon URL before any source upload; S2 expose only `RunSelfTest` (+ a namespaced token) on `_G`, not raw `Sync/Capture`; E1 incremental byte-sizing (no O(K²) re-encode); E2 per-parent sibling-index memo (no O(N²)); E3 single connect walk (no discard-then-rewalk); E5 cache `getDebounceMs`/token; S4 refuse live at `PlaceId == 0` (or namespace it); M3 comment that `source` is excluded from the drift hash by design.

---

## Architecture (luau-craft "plan-time" lens)

**Module layout (`plugin/src/`, each a `--!strict` ModuleScript):**

| Module | Responsibility | Ported from |
|---|---|---|
| `Types.luau` | All shared type aliases (`TickPacket`, `InstanceEntry`, `Ops`, `AllowList`, `LiveState`, `ServiceFp`, byte-array alias). No logic. | new (the contract above) |
| `Config.luau` | Constants: version, `PROTOCOL_VERSION`, service order/index, `CLASS_PROPERTIES`, thresholds, intervals, icon ids. Single source of truth. | `:49–504` Config |
| `Session.luau` | Pure `decide(isEdit,isRunning)` + signal wiring; `mode()/isEdit()`. | `:25–48` Session |
| `Settings.luau` | Typed get/set over `plugin:GetSetting/SetSetting`; cache debounce + token (E5). | `:903–1005` Settings |
| `Transport.luau` | HTTP (`requestJson`/`requestJsonAuthed`), `sanitizeJsonValue`/`safeEncode`, daemon-URL parse + **loopback guard (S1)**, token fetch/cache. Trust boundary: daemon responses hardened once here. | `:1006–1254` Transport |
| `AllowList.luau` | Fetch `/allowlist`, parse, static `CLASS_PROPERTIES` fallback; `namesFor/setFor`. | `:1255–1323` AllowList |
| `Hash.luau` | `hashInstance` (4-lane FNV → 64-hex), byte helpers (`fpZero/fpHexToBytes/fpBytesToHex/fpXor`), `serviceOf`. **Verbatim algorithm.** | `Capture`/`Live` fp code |
| `Capture.luau` | `serializeValue`, yielding walk, `readProperties` (batch-pcall), `readSource` (+base64), `buildSnapshot`, `buildUpsertedEntry`, `getPropertyNames/curatedSet`. Pure-ish (DataModel reads). | `CapturePanel.build` Capture.* |
| `Fingerprints.luau` | `instFp`, `serviceFpBytes`, `applyFpUpsert/applyFpRemove/reset`, `serviceFingerprintsWire`. | `CapturePanel.build` Live fp |
| `Live.luau` | The engine: dirty sets + stamps, signal handlers (`registerInstance`), `classifyChangedProp`, `collectOpsFromDirty` (capped, E1 incremental sizing), `buildTickBody`, `runTick`, `startTickLoop`, drift recovery, `triggerFullBaseline`, `teardown`, session transitions, connect/baseline. **No giant closure — explicit module state + typed methods.** | `CapturePanel.build` Live.* |
| `GlobalApi.luau` | `_G.StudioStud` wiring — **expose only `RunSelfTest`** + namespaced token (S2). | `:1324–1353` GlobalApi |
| `ui/Theme.luau`, `ui/Ui.luau`, `ui/Shell.luau`, `ui/CapturePanel.luau` | Theme, primitives (track+disconnect `UserInputService`, M4), tab shell, the capture panel **view only** (logic lives in `Live`/`Capture`). | `:505–902`, `:3347–3917`, panel UI |
| `Registry.luau` | Panel/tab registry. | `:1354–1563` Registry |
| `SelfTest.luau` | All ported assertions + new C1–C3 regressions. | `:3918–4571` SelfTest |
| `init.server.luau` (or `init.luau`) | Bootstrap: plugin guard, toolbar/widget, auto-connect, wires modules. Bundler entry. | `:1–24`, `:4572–4613` |

**Hot paths (budget `O(1)`, no needless alloc, cache-at-event):**
- `Live.runTick` (≤2×/sec) and `collectOpsFromDirty` — E1: encode each entry once, running byte sum; no `trialUpserted` copy per op.
- Signal handlers (`Changed`/`AncestryChanged`/…) — lazy: set dirty only, no reads. `classifyChangedProp` is `O(1)` table lookup.
- `buildUpsertedEntry` sibling index — E2: memoize per-parent `siblingCounts` within a tick.
- `Hash.hashInstance` — runs per dirty instance per tick and over the whole tree on baseline/drift; keep it allocation-lean; **yield** the baseline rebuild loop (Q1).

**Trust boundaries (harden once):** daemon HTTP responses (Transport); `plugin:GetSetting` values (Settings); the daemon URL (loopback guard, Transport); `PlaceId` (S4). Everything downstream trusts the typed result.

**Single source of truth:** `Config` (constants), `AllowList` (curated props — never a parallel hardcoded list), `Hash` (the one fingerprint recipe used by both op-build and the live accumulator).

---

## Build & analysis infra (this is what makes C1–C3 impossible)

### Task 0.1: darklua bundler
- [ ] Add `darklua` (via `rokit`/aftman — there's already a rokit toolchain; add `darklua` and `luau-lsp`, `selene`). Create `plugin/.darklua.json` with the bundle + (optional) minify rules.
- [ ] Build command: `darklua process plugin/src/init.luau dist/StudioStud.plugin.lua`. Verify the output is a single self-contained file with no `require` left.
- [ ] **Test:** bundle, then `lune luau.compile` (or luau-lsp) the bundled output → COMPILE OK; diff that the bundle contains the bootstrap + all modules.

### Task 0.2: luau-lsp strict analysis + selene
- [ ] Add `plugin/.luaurc` → `{ "languageMode": "strict", "lint": { ... } }`.
- [ ] Fetch Roblox type definitions (`luau-lsp` ships/accepts `globalTypes.d.luau` + an API-dump-based defs file) into `plugin/types/`.
- [ ] CI/local command: `luau-lsp analyze --defs=plugin/types/globalTypes.d.luau --sourcemap ... plugin/src/` → **zero errors**. Add `selene plugin/src/` (with the roblox std) for lint.
- [ ] **Prove it catches the class:** temporarily reintroduce the C1 self-call and a forward-ref → analyzer errors ("recursive without progress"/"unknown global"). Revert. This is the regression guarantee.

### Task 0.3: wire analysis + bundle into CI/deploy
- [ ] `ci.yml` (and the plugin packaging in `deploy.yml`): run `selene` + `luau-lsp analyze` on `plugin/src/`, then `darklua process` to produce `dist/StudioStud.plugin.lua`, and package THAT. Build fails on any analyzer error.
- [ ] Update the install/packaging path to ship `dist/StudioStud.plugin.lua` (the bundled artifact) instead of the hand-written file.

---

## Implementation phases (module-by-module; each: `--!strict`, analyzer-clean, tests)

Each module task follows the same shape — written here once, applied to every module (DRY for the plan reader):
> **Per-module steps:** (1) write `Types`-backed `--!strict` module skeleton with the typed interface; (2) port the proven logic from the named source section, applying luau-craft (cache-at-event, harden-once, real ternary, hot-path budget); (3) `luau-lsp analyze` + `selene` clean; (4) port/extend the SelfTest assertions for that module and run `_G.StudioStud.RunSelfTest()` (in Studio) — for pure modules, also run them headless via `lune` where no Roblox API is needed; (5) commit.

- **P1 — Foundation:** `Types`, `Config`, `Session`, `Settings`. (Session/Config are pure → lune-testable headless.)
- **P2 — IO:** `Transport` (incl. S1 loopback guard, sanitize/safeEncode ported verbatim — these are proven), `AllowList`. Trust-boundary hardening lives here.
- **P3 — Capture & Hash:** `Hash` (verbatim FNV + byte helpers — **add a headless lune test that the hash of a fixed entry equals the current plugin's output**, guaranteeing wire parity), `Capture` (serializeValue, walk, readProperties, readSource+base64, buildSnapshot, buildUpsertedEntry).
- **P4 — Live engine:** `Fingerprints`, then `Live` (the big one). Explicit module state (no 1,800-line closure). Port: dirty/stamps, registerInstance signals, classifyChangedProp, collectOpsFromDirty (E1 incremental sizing + cap + forward-progress), runTick (post-ops fingerprints), startTickLoop, drift recovery (full-rebaseline + yield), teardown, session transitions, connect/baseline.
- **P5 — UI:** `Theme`, `Ui` (fix M4 UIS leak: track+disconnect), `Registry`, `Shell`, `ui/CapturePanel` (view only — calls `Live`/`Capture`).
- **P6 — Wiring:** `GlobalApi` (S2: only `RunSelfTest` + token), `init` bootstrap (plugin guard, toolbar/widget, auto-connect, module wiring).
- **P7 — SelfTest + regressions:** port every existing assertion; ADD: `markDirtyUpsert` sets `dirtyUpsert[inst]` without recursion (C1); a simulated connect passes a non-nil `onReturnToEdit` to `startTickLoop` (C2); `Sync()` before live mode doesn't nil-call (C3). Add the `Hash` parity test to the gate.
- **P8 — Cutover:** bundle → analyzer-clean → SelfTest green → run the **existing daemon protocol-v2 integration tests against the new plugin's output** (capture a fixture, assert identical tick packets/fingerprints) → Studio gate (real connect, edit storm, drift, play/stop, soak) → bump version → replace the old file with the bundled artifact → delete `plugin/StudioStud.plugin.lua` (old monolith).

---

## ✅ GATE (the rewrite is done only when ALL hold)
- `luau-lsp analyze` (strict) + `selene` = **zero errors/warnings** on `plugin/src/`; darklua bundle compiles.
- The reintroduce-C1/C2/C3 check proves the analyzer flags them (Task 0.2).
- **Wire parity:** the `Hash` headless test matches the current algorithm; a captured fixture produces tick packets/fingerprints byte-identical to the old plugin (so the unchanged daemon tests pass unchanged).
- Full SelfTest green incl. the new C1–C3 regressions.
- Studio gate: real connect → baseline → edit storm (deltas, C1 path alive) → drift recovery → play/stop resume (C2 path alive) → `_G.StudioStud.Sync()` pre-live works (C3 path) → soak shows delta-dominated traffic.
- `cargo test --workspace` still green (daemon unchanged; new plugin speaks the same protocol).

## Risk controls (because this is a from-scratch rewrite)
- **Keep the current plugin (0.4.21) as the reference + fallback** on the branch until P8 cutover passes the full gate. Do not delete it until parity is proven.
- **Contract-first:** the "NON-NEGOTIABLE contract" section above is the acceptance spec; every module task cites which contract items it owns.
- **Parity over cleverness:** port proven algorithms (Hash, sanitize, classify, FP-1, drift) verbatim; re-architect *structure*, not *behavior*. luau-craft Doctrine 1 — reason from the context that exists.
- Branch: `feature/plugin-rewrite-strict`. Land only after the gate; ship the bundled `dist/` artifact.

---

## Self-review
- **Contract coverage:** every "What's solid" item + every protocol/FP/engine/capture/safety behavior is listed in the contract and assigned to a module. ✓
- **C-class prevention:** modular interfaces (no giant closure) + `luau-lsp analyze`/`--!strict` in CI + the reintroduce-check + C1–C3 regression tests = four independent guards. ✓
- **Review findings folded in:** C1–C3 (structure), E1/E2/E3/E5 (hot-path), S1/S2/S4 (trust boundaries), M3/M4/M1 (docs/leak/analyzer). E4 stays Phase-7 (Merkle). ✓
- **No placeholders that matter:** infra tasks (bundler, analyzer, CI) have concrete commands; module tasks cite exact source sections + the shared per-module step shape; verbatim-port items (Hash, sanitize) are called out so wire parity is preserved. The per-module bodies are written at execution against the named source — appropriate for a 4.6k-line rewrite where inlining every line here would duplicate the codebase. ✓
