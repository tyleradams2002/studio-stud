# Phase 7 — Docs & orphan cleanup (optional)

> Hand Composer: this file + `docs/REVIEW_2026-06-02.md`. Branch: **`development`**.
> Depends on: **Phase 5** (so docs describe the final, working distribution model).
> **Optional / non-functional** — do this once the functional phases are green.

## Goal
Bring the prose in line with the as-built tool and delete files no longer used, so the next reader (human
or AI) isn't misled by stale instructions.

## Pre-flight
```powershell
git switch development
```

---

## G-D1 — Rewrite stale docs + delete orphans  [M]

### 1. `docs/usage.md`
**File:** `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\docs\usage.md`
Fix the stale sections:
- Lines 11-19 + 42-44 + 147: replace the per-repo `.studio-stud-tool/` layout + `studio-stud.ps1`/`.cmd`
  launcher model with the global install model: tool under `%LOCALAPPDATA%\Programs\StudioStud`, core
  plugin auto-installed to `%LOCALAPPDATA%\Roblox\Plugins`, `studio-stud` / `studio-stud-setup` on PATH,
  per-repo files limited to `.studio-stud/` (policy + addons + managed `.gitignore`).
- Line 51: rename the live DB from `live.db` to **`syncs.db`** (matches `src/storage.rs`).
- Lines 137-147 ("Remote check"): replace the "daemon checks `latest.json` at launch and self-updates …
  downloads a newer release as `studio-stud.exe.new`" description with the real model: **the daemon only
  applies a previously staged swap on boot**; `studio-stud-setup update [--check]` is the sole update
  owner; the plugin shows an update chip from the daemon ping (`src/update.rs:1-10`, decision D6).

### 2. `MIGRATION_PLAN.md`
**File:** `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\MIGRATION_PLAN.md`
Move to `docs/history/MIGRATION_PLAN.md` and add a one-line header: "Historical — describes the original
v0.4.0 vendored `.studio-stud-tool/` migration, superseded by the `setup/` + channels model. See
`docs/REVIEW_2026-06-02.md` and `docs/phases/` for current state."

### 3. Delete orphaned launchers
Delete `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\scripts\launcher.ps1` and
`C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\scripts\launcher.cmd` — no code copies them into
consumer repos in the current PATH-based install model. (Confirm with `rg launcher` first.)

### 4. README touch-ups
**File:** `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\README.md`
- Update the "Releasing" section to the Phase-5 flow: bump `Cargo.toml` + `setup/Cargo.toml` +
  `PLUGIN_VERSION`, push `main` (Pages manifest) **and** tag `v<ver>` (Release uploads the bundle).
- Add a one-liner that auto-update is `channelSequence`-driven (dev pushes deliver without a version bump).

### 5. `version-compat.md` / `docs/version-compat.md`
Confirm the "Setup" row is real after Phase 6 G18 (populated `versions.setup`).

**Acceptance:**
- `rg "studio-stud-tool"` returns only `LEGACY_TOOL_DIR` migration code in `src/setup_core/install.rs`,
  not install instructions.
- `rg "live\.db"` returns nothing in `docs/`.
- `rg launcher scripts/` returns nothing (files deleted).
- `MIGRATION_PLAN.md` no longer at repo root.

---

## Verification (return to Claude)
```powershell
rg "studio-stud-tool" docs/ README.md      # only code refs, no install instructions
rg "live\.db" docs/                          # empty
git status                                   # launcher.* deleted, MIGRATION_PLAN moved
```
Skim `docs/usage.md` with Claude to confirm it matches the as-built install/update flow.

## Done when
Docs describe the global install + channels + staged-swap update model, no `.studio-stud-tool/` install
instructions remain, and the orphaned launchers are gone.
