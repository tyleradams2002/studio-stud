# Dev→Main Deployment Simplification — Design

**Date:** 2026-06-05
**Status:** Approved (design); pending implementation plan
**Author:** Tyler Adams (w/ Claude)

## Problem

The current release process has three channels (`dev` / `beta` / `release`) wired to
three branches (`development` / `beta` / `main`). This triples the surface area and is
the source of recurring pain:

- **Tag-before-merge footgun.** Shipping requires pushing a `v<version>` git tag *before*
  merging to `main`. Two decoupled CI triggers — asset creation (on tag) and manifest
  deploy (on `main` push) — must be sequenced by hand, and getting it wrong produces
  install 404s.
- **Version drift.** `Cargo.toml` / plugin are at **0.4.12** (dev) while the `release`
  manifest on `main` is still **0.4.10** — two versions of dev work sitting unreleased.
- **Broken dev auto-update.** `channel_key_dpapi` is never stored at install time, so
  `studio-stud-setup update` cannot decrypt the encrypted dev bundle. Updates have been
  done manually via `scripts/install-local.ps1`.
- **Beta adds a manual promotion hop** that is not currently needed.

## Goals

1. Collapse to **two channels**: `dev` (private, encrypted) and `release` (public).
2. **Dev auto-update works** on every commit, with no manual `install-local.ps1`.
3. **Every PR to `main` carries a version bump** that matches across daemon and plugin,
   enforced by CI.
4. Merging a dev→main PR **auto-tags, builds, and publishes** in one ordered, 404-proof
   pipeline — no hand-tagging.
5. Keep it **reversible**: beta is made dormant, not deleted.

## Non-Goals

- No changes to daemon/plugin *feature* behavior. The only application-code change is the
  install-time password persistence fix (Section 4), explicitly approved.
- Not removing `Channel::Beta` from Rust. Beta stays revivable.
- Not migrating version storage to a tag-derived model (versions stay committed in files).

## Locked Decisions

| # | Decision | Choice |
|---|----------|--------|
| D1 | Beta removal aggressiveness | **Process-only, beta dormant** — stop using the branch/channel; leave `Channel::Beta` in Rust untouched |
| D2 | Tag flow | **Auto-tag on merge** — one ordered pipeline reads the version, creates tag + release + assets, then publishes manifest |
| D3 | Version bump location | **PR bumps it** — day-to-day dev commits don't change the version (channelSequence drives dev auto-update); the bump lives in the dev→main PR |
| D4 | Dev encryption | **Keep encrypted, fix the password-gap bug** — persist `channel_key_dpapi` at install so update can decrypt |

## The New Model

Two branches, two channels:

- `development` → **dev** channel: private (encrypted + signed), republished on **every
  push**, auto-update driven by monotonic `channelSequence`. The version number does **not**
  change during normal work.
- `main` → **release** channel: public (unsigned, plain ZIP), shipped only by merging a
  dev→main PR. The PR carries the version bump; the merge runs the release pipeline.

Between ships, `development` sits at the **same version number as `main`**. The version
only moves inside a shipping PR — eliminating drift.

```
            ┌───────────────────── development branch ─────────────────────┐
 commit ─▶ commit ─▶ commit ─▶ (bump-version) ─▶ open PR ─▶ approve+merge ─▶ main
   │         │         │                                                      │
   └─ each push auto-publishes the DEV channel (channelSequence++);           │
      dev testers auto-update; version number unchanged                       ▼
                                              merge → release pipeline (Section 2)
```

### Version lifecycle (worked example)

1. `main` and `development` both at `0.4.12` (in lockstep after a ship).
2. Feature commits land on `development`. Version stays `0.4.12`; each push bumps only
   `channelSequence`. Dev testers auto-update.
3. Ready to ship: run `scripts/bump-version.ps1 0.4.13` as the final dev commit → push.
   Dev channel now serves `0.4.13` as a last pre-release test build.
4. Open PR `development → main`. CI gate verifies version invariants (Section 3).
5. Approve + merge → release pipeline creates `v0.4.13`, builds, publishes `release`
   manifest at `0.4.13`. `main` and `development` back in lockstep at `0.4.13`.

---

## Section 1 — Branch / Channel Topology

- **Branches kept:** `development`, `main`, `gh-pages`. `beta` branch left in place but
  receives no CI trigger (dormant; optional later deletion).
- **Channels active:** `dev`, `release`. `beta` channel machinery remains in Rust but is
  never published.
- **Merge style for dev→main:** **merge commit** (not squash). Squash would make `main`
  diverge from `development`, causing every subsequent PR to re-diff the entire branch.
  A merge commit keeps the trees in lockstep.

## Section 2 — Release Pipeline (auto-tag, ordered, 404-proof)

Replace the two decoupled triggers with a **single ordered job on push to `main`** in
`.github/workflows/deploy.yml` (`deploy-release` path):

1. Build + test via `scripts/package-release.ps1` → produces `dist/` assets +
   `site/latest.json`.
2. Read version from `Cargo.toml` (regex `^version\s*=\s*"([^"]+)"`).
3. **Guard:** fail if tag `v<version>` already exists (signals the version wasn't bumped).
4. `gh release create v<version> --target <merge-sha>` uploading all four assets
   (`studio-stud.exe`, `studio-stud-setup.exe`, `StudioStud.plugin.lua`,
   `studio-stud-bundle.zip`). This creates the **tag + Release + assets atomically**.
5. Verify all four assets are present on the Release (retains the existing 404 safeguard).
6. Publish the unsigned `release` manifest to gh-pages **root**, pointing
   `binaryUrl` / `pluginUrl` / `setupUrl` / `bundleUrl` at the `v<version>` Release assets.

The standalone tag-push trigger (`refs/tags/v*` → `github-release` job) is removed; tag
creation now happens *inside* the ordered pipeline, so there is nothing to sequence by hand.

## Section 3 — Version Bump + Enforcement

- **New `scripts/bump-version.ps1 <version>`:** updates both version sources atomically:
  - `Cargo.toml` line 3 `version = "<version>"`
  - `plugin/StudioStud.plugin.lua` `PLUGIN_VERSION = "<version>"` (≈ line 51)
  - (Optional) prints a reminder if `PROTOCOL_VERSION` in `src/util.rs` may need a manual
    bump — protocol versioning stays a deliberate human decision, not automated.
- **New PR gate in `.github/workflows/ci.yml`** (PRs targeting `main` only) that fails unless:
  1. `Cargo.toml` version **==** plugin `PLUGIN_VERSION`.
  2. New version **>** latest `v*` git tag (semver compare).
  3. Tag `v<version>` does not already exist.

This makes "every PR has a matching daemon+plugin version bump" a hard CI invariant.

## Section 4 — Fix Dev Auto-Update (password-gap)

**Root cause (confirmed):** `site/install.ps1` reads the channel password, decrypts the
bundle *in PowerShell*, then calls `studio-stud-setup.exe install --channel <ch>` **without
the password**. The setup binary never sees the plaintext, so `channel_key_dpapi` is never
written. Later, `setup/src/update_apply.rs::channel_password()` finds `None` and errors
("channel password not stored — reinstall ...").

**Fix (the single approved application-code change):**

1. `site/install.ps1` → `Invoke-Setup`: pass the plaintext password to `setup.exe` via a
   non-visible channel (stdin pipe or environment variable — **not** a visible CLI arg, to
   avoid process-list/secrets exposure).
2. `setup/src/main.rs`: accept the password on the `Install` command (read env/stdin).
3. `setup/src/install_flow.rs::run_install_headless()`: add the password to
   `HeadlessInstallParams`; just before `save_config(&cfg)?`, set
   `cfg.channel_key_dpapi = Some(dpapi_protect(password.as_bytes())?)` using the existing
   `src/setup_core/crypto.rs::dpapi_protect`.
4. The update path (`update_apply.rs::channel_password` → `dpapi_unprotect`) already works
   once the field is populated — no change there.

**Affected anchors (current):**
- `src/setup_core/config.rs` — `channel_key_dpapi: Option<String>` (struct ~L29–39); `save_config` (~L100), `load_config_or_default` (~L115)
- `src/setup_core/crypto.rs` — `dpapi_protect` (~L15), `dpapi_unprotect` (~L26), `channel_decrypt` (~L73)
- `setup/src/install_flow.rs` — `run_install_headless` (~L27–68), `save_config` call (~L65)
- `setup/src/update_apply.rs` — `channel_password` (~L92–109), `download_extract_bundle_paths` (~L78–91)
- `site/install.ps1` — password prompt (~L130–134), `Invoke-Setup` (~L100–105)

**One-time operator step after this ships:** reinstall dev once via the updated
`install-dev.ps1` to seed `channel_key_dpapi`. Auto-update is permanent thereafter.

## Section 5 — Beta Dormancy (exact touches)

- `.github/workflows/deploy.yml`: remove the `deploy-beta` job and the `beta` entry from
  the push trigger.
- `.github/workflows/promote.yml`: collapse the dispatch options to a single
  **development → main**.
- `.github/workflows/ci.yml`: gate PRs to `main` only (drop `beta` from the PR trigger).
- Delete `site/install-beta.ps1`.
- **Keep** `Channel::Beta` in `src/setup_core/channels.rs` and the `beta` value in
  `site/install.ps1`'s `ValidateSet` — dormant and revivable.
- Leave the `beta` branch and `BETA_CHANNEL_PASSWORD` secret in place but unused (harmless
  once the trigger is removed). Optional later cleanup.

Note: the dev fallback chain in `channels.rs` (`Dev → Beta → Release`) is left intact —
it's harmless and supports revival; changing it is out of scope.

## Section 6 — First Cutover + Rollback

- **First ship under the new system:** the cutover PR bumps to **0.4.12** (where dev
  already sits), tags `v0.4.12`, and publishes the `release` manifest at `0.4.12`.
  `v0.4.11` is skipped — semver need not be contiguous.
- **Rollback:** because beta is only dormant, reverting means restoring the `deploy-beta`
  job and the `promote.yml` beta option. No daemon/plugin code is deleted.

## Risks / Edge Cases

- **Password handoff secrecy.** Passing the password via visible CLI args would leak it to
  the process list; use stdin or env var. The setup binary must clear/avoid logging it.
- **`gh release create` permissions.** The job needs `contents: write` to create tags and
  releases (already used by the current `github-release` job).
- **Double-trigger avoidance.** With the standalone `v*` tag trigger removed, the
  tag created inside the pipeline must not re-fire the workflow. Confirm `deploy.yml`'s
  `on:` no longer listens for `refs/tags/v*`.
- **First-cutover key seeding.** Dev auto-update only becomes correct after one reinstall
  with the fixed `install.ps1`; document this clearly.
- **Semver compare in CI** must handle the `0.4.10 → 0.4.12` jump (skipped `0.4.11`)
  correctly — compare as semver, not string/contiguity.

## Acceptance Criteria

1. Pushing to `development` republishes the dev channel and bumps `channelSequence`; a dev
   install auto-updates **without** running `install-local.ps1`.
2. A PR to `main` that does **not** bump the version (or mismatches daemon vs plugin) is
   **rejected** by CI.
3. Merging a compliant dev→main PR results in: a new `v<version>` tag, a GitHub Release
   with all four assets, and a published `release` manifest pointing at them — **no 404**,
   no manual tagging.
4. No `beta` deploys occur on any push; `promote.yml` offers only development → main.
5. `Channel::Beta` still compiles and exists in the Rust enum.
6. `Cargo.toml` and `plugin/StudioStud.plugin.lua` versions are always equal after a ship,
   and equal to the latest `v*` tag.
