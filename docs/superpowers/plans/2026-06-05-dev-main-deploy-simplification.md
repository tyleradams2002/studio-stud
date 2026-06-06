# Dev→Main Deployment Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse the three-channel (dev/beta/release) deploy to two (dev + release), make dev auto-update work by persisting the channel key at install, and make the dev→main merge a single ordered pipeline that auto-tags, builds, and publishes — with CI enforcing a matching version bump on every PR.

**Architecture:** Beta is made *dormant* — its CI jobs, install script, and promotion option are removed, but `Channel::Beta` stays in Rust so it's revivable. The dev auto-update fix threads the install password (already captured by `install.ps1`) into `setup.exe` via an environment variable, where a new pure helper DPAPI-protects it into `config.json`; the existing update path then decrypts correctly. The release path becomes one ordered `main`-push job that creates the tag + GitHub Release + assets atomically (`gh release create`) before publishing the manifest, and a PR gate enforces that `Cargo.toml` and the plugin version match and exceed the last release.

**Tech Stack:** Rust (workspace lib `studio-stud` + `setup` binary, clap, anyhow, serde, windows DPAPI), PowerShell (install + packaging scripts), GitHub Actions (Windows + Ubuntu runners, `gh` CLI, `peaceiris/actions-gh-pages`).

---

## File Structure

**Modified:**
- `setup/src/install_flow.rs` — `run_install_headless` reads `STUDIO_STUD_CHANNEL_PASSWORD` and calls the new persistence helper before `save_config`.
- `src/setup_core/config.rs` — new pure `store_channel_key_if_encrypted(cfg, channel, password)` helper + unit tests.
- `site/install.ps1` — pass the captured password to `setup.exe` via env var; drop the `beta` one-liner mention in the header.
- `.github/workflows/deploy.yml` — remove `deploy-beta` + `github-release` jobs + the `v*` tag trigger + `beta` branch trigger; rewrite `deploy-release` as one ordered job.
- `.github/workflows/ci.yml` — gate PRs to `main` only; add a version-bump gate job.
- `.github/workflows/promote.yml` — collapse to a single development → main promotion.

**Created:**
- `scripts/bump-version.ps1` — atomically bump `Cargo.toml` + plugin `PLUGIN_VERSION`.
- `docs/deploy-flow.md` — short operator doc for the new dev→main flow + one-time dev reinstall.

**Deleted:**
- `site/install-beta.ps1`.

**Untouched (intentionally):** `src/setup_core/channels.rs` (`Channel::Beta` stays), `setup/src/update_apply.rs` (the read path already works once the key is stored), `setup/src/main.rs` / `setup/src/gui.rs` (both install paths funnel through `run_install_headless`, so no call-site edits are needed).

---

## Phase 1 — Fix dev auto-update (password-gap)

### Task 1: Pure helper to persist the channel key

**Files:**
- Modify: `src/setup_core/config.rs` (add imports near top; add function after `populate_install_fields` ~line 121; add tests in the `#[cfg(test)] mod tests` block)

- [ ] **Step 1: Write the failing tests**

Add these three tests inside the existing `mod tests` block in `src/setup_core/config.rs` (after `populate_install_fields_fills_all`):

```rust
    #[test]
    fn store_channel_key_persists_for_encrypted_channel() {
        let mut cfg = StudioStudConfig::default();
        store_channel_key_if_encrypted(&mut cfg, "dev", Some("hunter2")).unwrap();
        let stored = cfg
            .channel_key_dpapi
            .expect("key should be stored for an encrypted channel");
        let plain = crate::setup_core::crypto::dpapi_unprotect(&stored).unwrap();
        assert_eq!(plain, b"hunter2");
    }

    #[test]
    fn store_channel_key_skips_release_channel() {
        let mut cfg = StudioStudConfig::default();
        store_channel_key_if_encrypted(&mut cfg, "release", Some("hunter2")).unwrap();
        assert!(cfg.channel_key_dpapi.is_none());
    }

    #[test]
    fn store_channel_key_preserves_existing_when_no_password() {
        let mut cfg = StudioStudConfig {
            channel_key_dpapi: Some("existing".into()),
            ..Default::default()
        };
        store_channel_key_if_encrypted(&mut cfg, "dev", None).unwrap();
        assert_eq!(cfg.channel_key_dpapi.as_deref(), Some("existing"));
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p studio-stud store_channel_key`
Expected: FAIL — `cannot find function store_channel_key_if_encrypted in this scope`.

- [ ] **Step 3: Add imports and implement the helper**

At the top of `src/setup_core/config.rs`, alongside the existing `use super::install::default_install_root;` (line 8), add:

```rust
use super::channels::Channel;
use super::crypto::dpapi_protect;
```

Then add this function immediately after `populate_install_fields` (after line 121):

```rust
/// Store the channel decryption password (DPAPI-protected) so self-update can decrypt the
/// bundle later. No-op for the unencrypted `release` channel or when no password is supplied
/// (so reinstall/repair without a password preserves any previously stored key).
pub fn store_channel_key_if_encrypted(
    cfg: &mut StudioStudConfig,
    channel: &str,
    password: Option<&str>,
) -> Result<()> {
    if let Some(pw) = password.filter(|p| !p.is_empty()) {
        if Channel::from_str(channel).is_encrypted() {
            cfg.channel_key_dpapi = Some(dpapi_protect(pw.as_bytes())?);
        }
    }
    Ok(())
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p studio-stud store_channel_key`
Expected: PASS (3 tests). On Windows these exercise real DPAPI; on other platforms the base64 fallback round-trips identically.

- [ ] **Step 5: Commit**

```bash
git add src/setup_core/config.rs
git commit -m "feat(setup): add store_channel_key_if_encrypted helper"
```

---

### Task 2: Persist the key during headless install

**Files:**
- Modify: `setup/src/install_flow.rs:56-78` (inside `run_install_headless`, between `populate_install_fields(...)` and `save_config(&cfg)?`)

- [ ] **Step 1: Wire the env-var read into `run_install_headless`**

In `setup/src/install_flow.rs`, the `populate_install_fields(...)` call ends at line 64. Immediately after it (before the `if params.install_repos {` block at line 65), insert:

```rust
    // Persist the channel password so self-update can decrypt the bundle later. install.ps1
    // captures the password and forwards it via this env var; both the GUI and silent install
    // paths funnel through here, so this is the single seam that needs it.
    let channel_password = std::env::var("STUDIO_STUD_CHANNEL_PASSWORD").ok();
    studio_stud::setup_core::config::store_channel_key_if_encrypted(
        &mut cfg,
        &channel,
        channel_password.as_deref(),
    )?;
```

(The `channel` local is already defined at lines 52–55, and `cfg` is `mut`. `save_config(&cfg)?` at line 78 then persists the new field.)

- [ ] **Step 2: Build to verify it compiles**

Run: `cargo build -p studio-stud-setup`
Expected: builds clean (no unused-import or borrow errors).

- [ ] **Step 3: Run the workspace tests**

Run: `cargo test --workspace`
Expected: PASS — existing tests plus Task 1's three new tests.

- [ ] **Step 4: Commit**

```bash
git add setup/src/install_flow.rs
git commit -m "fix(setup): store channel key at install so dev auto-update can decrypt"
```

---

### Task 3: Forward the password from install.ps1

**Files:**
- Modify: `site/install.ps1:81-95` (the encrypted-bundle branch) and the header comment block `:1-12`

- [ ] **Step 1: Pass the password via env var around `Invoke-Setup`**

In `site/install.ps1`, the encrypted branch currently reads (lines 90–94):

```powershell
    Write-Host "Decrypting..."
    Get-Decrypted $enc $zip $password
    Expand-Archive -Path $zip -DestinationPath $work -Force
    Invoke-Setup $work
    exit 0
```

Replace those five lines with:

```powershell
    Write-Host "Decrypting..."
    Get-Decrypted $enc $zip $password
    Expand-Archive -Path $zip -DestinationPath $work -Force
    # Forward the password to setup.exe (inherited by the child process) so it can store the
    # DPAPI-protected key for self-update. Cleared immediately after the installer returns.
    $env:STUDIO_STUD_CHANNEL_PASSWORD = $password
    try { Invoke-Setup $work }
    finally { Remove-Item Env:\STUDIO_STUD_CHANNEL_PASSWORD -ErrorAction SilentlyContinue }
    exit 0
```

- [ ] **Step 2: Update the header comment (drop the beta one-liner)**

In the header block, replace line 5:

```powershell
  Beta     (password req):  irm https://tyleradams2002.github.io/studio-stud/install-beta.ps1 | iex
```

with:

```powershell
  (beta channel retired — dev + release only)
```

- [ ] **Step 3: Lint the script for syntax**

Run:
```powershell
powershell -NoProfile -Command "$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path 'site/install.ps1'), [ref]$null, [ref]$e); if ($e) { $e; exit 1 } else { 'parsed ok' }"
```
Expected: prints `parsed ok` (and exits 0). If there are syntax errors it prints them and exits 1.

- [ ] **Step 4: Commit**

```bash
git add site/install.ps1
git commit -m "fix(install): forward channel password to setup.exe for key persistence"
```

> **Manual acceptance (run once after this ships to the dev channel):** reinstall dev via
> `irm https://tyleradams2002.github.io/studio-stud/install-dev.ps1 | iex`, confirm
> `%LOCALAPPDATA%\StudioStud\config.json` now contains a `channelKeyDpapi` value, then run
> `studio-stud-setup update --check` and confirm it no longer errors with "channel password
> not stored". This is captured as an acceptance step, not an automated test.

---

## Phase 2 — Release pipeline + version enforcement

### Task 4: Atomic version-bump script

**Files:**
- Create: `scripts/bump-version.ps1`

- [ ] **Step 1: Write the script**

Create `scripts/bump-version.ps1` with exactly:

```powershell
<#
.SYNOPSIS
  Atomically bump the daemon (Cargo.toml) and plugin (PLUGIN_VERSION) to the same version.

.EXAMPLE
  .\scripts\bump-version.ps1 0.4.13
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Version
)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version must be X.Y.Z (got '$Version')"
}
$root   = Split-Path -Parent $PSScriptRoot
$cargo  = Join-Path $root 'Cargo.toml'
$plugin = Join-Path $root 'plugin/StudioStud.plugin.lua'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Cargo.toml — replace the first package `version = "..."` (workspace block has none).
$cargoText = [System.IO.File]::ReadAllText($cargo)
$cargoRx   = [regex]'(?m)^version\s*=\s*"[^"]+"'
if ($cargoRx.Matches($cargoText).Count -lt 1) { throw "No package version line found in Cargo.toml" }
$cargoText = $cargoRx.Replace($cargoText, "version = `"$Version`"", 1)
[System.IO.File]::WriteAllText($cargo, $cargoText, $utf8NoBom)

# plugin — replace PLUGIN_VERSION = "..."
$pluginText = [System.IO.File]::ReadAllText($plugin)
$pluginRx   = [regex]'PLUGIN_VERSION\s*=\s*"[^"]+"'
if ($pluginRx.Matches($pluginText).Count -lt 1) { throw "No PLUGIN_VERSION line found in plugin" }
$pluginText = $pluginRx.Replace($pluginText, "PLUGIN_VERSION = `"$Version`"", 1)
[System.IO.File]::WriteAllText($plugin, $pluginText, $utf8NoBom)

Write-Host "Bumped Cargo.toml + plugin to $Version"
```

- [ ] **Step 2: Test it against a throwaway version, then revert**

Run:
```powershell
.\scripts\bump-version.ps1 9.9.9
Select-String -Path Cargo.toml -Pattern '^version\s*=\s*"9\.9\.9"'
Select-String -Path plugin/StudioStud.plugin.lua -Pattern 'PLUGIN_VERSION\s*=\s*"9\.9\.9"'
```
Expected: each `Select-String` prints one match line (both files updated to 9.9.9).

- [ ] **Step 3: Confirm the workspace still parses, then revert the version change**

Run:
```powershell
cargo metadata --no-deps --format-version 1 > $null; if ($?) { 'cargo parses' }
git checkout -- Cargo.toml plugin/StudioStud.plugin.lua
```
Expected: prints `cargo parses`, then the two files are restored to `0.4.12`.

- [ ] **Step 4: Commit (script only — no version change)**

```bash
git add scripts/bump-version.ps1
git commit -m "feat(scripts): add bump-version.ps1 to bump daemon+plugin together"
```

---

### Task 5: Rewrite deploy.yml (remove beta, ordered release pipeline)

**Files:**
- Modify: `.github/workflows/deploy.yml` (full-file replacement)

- [ ] **Step 1: Replace the entire file**

Overwrite `.github/workflows/deploy.yml` with exactly:

```yaml
name: Deploy

# Runs on every push to either permanent branch.
#   development → encrypts + publishes dev channel    (site/dev/)
#   main        → creates the GitHub Release (tag + assets) then publishes
#                 the release channel manifest        (site/)
# (beta channel retired — Channel::Beta remains in code, dormant)
#
# Required GitHub Actions secrets (Settings → Secrets → Actions):
#   CHANNEL_SIGNING_KEY  — 64-byte ed25519 private key in hex (from scripts/keygen.ps1)
#   DEV_CHANNEL_PASSWORD — password dev testers use at install time
#   (main/release needs no password — artifacts are public)

on:
  push:
    branches: [main, development]
  workflow_dispatch:

permissions:
  contents: write
  pages: write
  id-token: write

concurrency:
  group: deploy-${{ github.ref }}
  cancel-in-progress: false

# ──────────────────────────────────────────────
jobs:

  # ── 1. Build ─────────────────────────────────
  build:
    name: Build & Test
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Rust
        uses: dtolnay/rust-toolchain@stable

      - uses: Swatinem/rust-cache@v2

      - name: Build workspace + package
        shell: pwsh
        run: ./scripts/package-release.ps1

      - name: Run tests
        run: cargo test --workspace

      - name: Upload dist artifacts
        uses: actions/upload-artifact@v4
        with:
          name: dist-${{ github.sha }}
          path: dist/
          retention-days: 7

      - name: Upload generated manifest
        uses: actions/upload-artifact@v4
        with:
          name: manifest-${{ github.sha }}
          path: site/latest.json
          retention-days: 7

  # ── 2a. Publish release channel (main) ───────
  # One ordered pipeline: create the tag + GitHub Release + assets atomically,
  # verify the assets resolve, THEN publish the manifest. Removes the old
  # tag-before-merge race that caused install 404s.
  deploy-release:
    name: Publish → release channel
    needs: build
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    env:
      GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    steps:
      - uses: actions/checkout@v4

      - name: Download dist
        uses: actions/download-artifact@v4
        with:
          name: dist-${{ github.sha }}
          path: dist/

      - name: Download generated manifest
        uses: actions/download-artifact@v4
        with:
          name: manifest-${{ github.sha }}
          path: manifest/

      - name: Use generated manifest (overwrite committed)
        run: cp manifest/latest.json site/latest.json

      - name: Create or update the GitHub Release (tag + assets, atomic)
        run: |
          set -euo pipefail
          VER=$(jq -r .daemonVersion site/latest.json)
          TAG="v$VER"
          echo "Publishing $TAG from $GITHUB_SHA"
          ASSETS="dist/studio-stud.exe dist/studio-stud-setup.exe dist/StudioStud.plugin.lua dist/studio-stud-bundle.zip"
          if gh release view "$TAG" >/dev/null 2>&1; then
            echo "Release $TAG already exists — re-uploading assets (clobber)."
            gh release upload "$TAG" $ASSETS --clobber
          else
            echo "Creating release $TAG."
            gh release create "$TAG" --target "$GITHUB_SHA" --title "$TAG" --notes "Release $TAG" $ASSETS
          fi

      - name: Verify all release assets are downloadable
        run: |
          set -euo pipefail
          VER=$(jq -r .daemonVersion site/latest.json)
          TAG="v$VER"
          MISSING=0
          for ASSET in studio-stud.exe studio-stud-setup.exe StudioStud.plugin.lua studio-stud-bundle.zip; do
            URL="https://github.com/${{ github.repository }}/releases/download/$TAG/$ASSET"
            CODE=000
            for i in 1 2 3 4 5; do
              CODE=$(curl -s -o /dev/null -w '%{http_code}' -L "$URL")
              [ "$CODE" = "200" ] && break
              sleep 5
            done
            if [ "$CODE" = "200" ]; then
              echo "  ok    $ASSET"
            else
              echo "  MISS  $ASSET (HTTP $CODE)"
              MISSING=1
            fi
          done
          if [ "$MISSING" -ne 0 ]; then
            echo "::error::Release $TAG is missing assets — refusing to publish the manifest."
            exit 1
          fi
          echo "All $TAG assets present — safe to publish manifest."

      - name: Deploy site/ to gh-pages (release channel root)
        uses: peaceiris/actions-gh-pages@v4
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          publish_branch: gh-pages
          publish_dir: site
          destination_dir: .
          keep_files: true

  # ── 2b. Publish dev channel ──────────────────
  deploy-dev:
    name: Publish → dev channel
    needs: build
    if: github.ref == 'refs/heads/development'
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Rust
        uses: dtolnay/rust-toolchain@stable

      - uses: Swatinem/rust-cache@v2

      - name: Download dist
        uses: actions/download-artifact@v4
        with:
          name: dist-${{ github.sha }}
          path: dist/

      - name: Download generated manifest
        uses: actions/download-artifact@v4
        with:
          name: manifest-${{ github.sha }}
          path: manifest/

      - name: Encrypt artifact
        shell: pwsh
        run: |
          New-Item -ItemType Directory -Force site/dev | Out-Null
          cargo run --quiet --example encrypt-artifact -- `
            --password "$env:DEV_CHANNEL_PASSWORD" `
            --input  dist/studio-stud-bundle.zip `
            --output site/dev/studio-stud-bundle.zip.enc
        env:
          DEV_CHANNEL_PASSWORD: ${{ secrets.DEV_CHANNEL_PASSWORD }}

      - name: Build + sign manifest
        shell: pwsh
        run: |
          # Read live gh-pages sequence — repo checkout never stores the previous manifest.
          $prevSeq = 0
          try {
            $live = Invoke-RestMethod 'https://tyleradams2002.github.io/studio-stud/dev/latest.json' -ErrorAction Stop
            if ($live.channelSequence) { $prevSeq = [int]$live.channelSequence }
          } catch { $prevSeq = 0 }
          $nextSeq = $prevSeq + 1

          # Base off the CI-generated manifest (actual built version), not the committed file.
          $base     = Get-Content manifest/latest.json -Raw | ConvertFrom-Json
          $pagesBase = 'https://tyleradams2002.github.io/studio-stud'

          $manifest = $base | Select-Object *
          $manifest | Add-Member -NotePropertyName channelSequence -NotePropertyValue $nextSeq     -Force
          $manifest | Add-Member -NotePropertyName bundleEncUrl    -NotePropertyValue "$pagesBase/dev/studio-stud-bundle.zip.enc" -Force
          $manifest.PSObject.Properties.Remove('setupUrl')
          $manifest.PSObject.Properties.Remove('bundleUrl')

          $unsigned = 'site/dev/latest.unsigned.json'
          $manifest | ConvertTo-Json -Depth 10 | Set-Content $unsigned -Encoding utf8
          $sigB64 = cargo run --quiet --example sign-manifest -- `
            --privkey "$env:CHANNEL_SIGNING_KEY" `
            --manifest $unsigned
          if ($LASTEXITCODE -ne 0) { throw "sign-manifest failed" }

          $manifest | Add-Member -NotePropertyName signature -NotePropertyValue $sigB64.Trim() -Force
          $manifest | ConvertTo-Json -Depth 10 | Set-Content site/dev/latest.json -Encoding utf8
          Remove-Item site/dev/latest.unsigned.json -ErrorAction SilentlyContinue
          Write-Host "Dev manifest written (seq $nextSeq)"
        env:
          CHANNEL_SIGNING_KEY: ${{ secrets.CHANNEL_SIGNING_KEY }}

      - name: Deploy site/dev to gh-pages/dev
        uses: peaceiris/actions-gh-pages@v4
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          publish_branch: gh-pages
          publish_dir: site/dev
          destination_dir: dev
          keep_files: true
```

- [ ] **Step 2: Validate the YAML parses**

Run:
```powershell
python -c "import yaml,sys; yaml.safe_load(open('.github/workflows/deploy.yml')); print('deploy.yml ok')"
```
Expected: prints `deploy.yml ok`. (If `python` is unavailable, use `python3`.)

- [ ] **Step 3: Confirm the beta job, release job, and tag trigger are gone**

Run (targets the specific removed identifiers, not the word "beta" — the header comment still documents that `Channel::Beta` is dormant):
```powershell
Select-String -Path .github/workflows/deploy.yml -Pattern 'deploy-beta','github-release','refs/tags','BETA_CHANNEL_PASSWORD'
```
Expected: **no matches** (empty output).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/deploy.yml
git commit -m "ci(deploy): single ordered main pipeline; drop beta + tag-trigger jobs"
```

---

### Task 6: CI PR gate — main-only + version enforcement

**Files:**
- Modify: `.github/workflows/ci.yml` (full-file replacement)

- [ ] **Step 1: Replace the entire file**

Overwrite `.github/workflows/ci.yml` with exactly:

```yaml
name: CI

# Runs on pull requests into main — gates merges. Branch pushes are handled by deploy.yml.
on:
  pull_request:
    branches: [main]

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build-test:
    name: Build & Test
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Rust
        uses: dtolnay/rust-toolchain@stable

      - uses: Swatinem/rust-cache@v2

      - name: Build workspace
        shell: pwsh
        run: ./scripts/package-release.ps1

      - name: Run tests
        run: cargo test --workspace

  version-gate:
    name: Version bump gate
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Enforce matching, incremented version
        run: |
          set -euo pipefail
          CARGO=$(grep -m1 -oP '^version\s*=\s*"\K[^"]+' Cargo.toml)
          PLUGIN=$(grep -m1 -oP 'PLUGIN_VERSION\s*=\s*"\K[^"]+' plugin/StudioStud.plugin.lua)
          echo "Cargo=$CARGO  Plugin=$PLUGIN"
          if [ "$CARGO" != "$PLUGIN" ]; then
            echo "::error::Cargo.toml ($CARGO) and plugin PLUGIN_VERSION ($PLUGIN) must match. Use scripts/bump-version.ps1."
            exit 1
          fi
          git fetch --tags --quiet || true
          if git rev-parse -q --verify "refs/tags/v$CARGO" >/dev/null; then
            echo "::error::Tag v$CARGO already exists — bump the version before this PR can merge."
            exit 1
          fi
          LATEST=$(git tag -l 'v*' | sed 's/^v//' | sort -V | tail -1)
          LATEST=${LATEST:-0.0.0}
          HIGHEST=$(printf '%s\n%s\n' "$LATEST" "$CARGO" | sort -V | tail -1)
          if [ "$CARGO" = "$LATEST" ] || [ "$HIGHEST" != "$CARGO" ]; then
            echo "::error::Version $CARGO must be strictly greater than the last release v$LATEST."
            exit 1
          fi
          echo "Version gate passed: $CARGO > $LATEST"
```

- [ ] **Step 2: Validate the YAML parses**

Run:
```powershell
python -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml')); print('ci.yml ok')"
```
Expected: prints `ci.yml ok`.

- [ ] **Step 3: Dry-run the version-gate logic locally (current tree must pass)**

Run in Bash (this mirrors the gate; current tree is `0.4.12` and the last release tag is `v0.4.10`):
```bash
CARGO=$(grep -m1 -oP '^version\s*=\s*"\K[^"]+' Cargo.toml)
PLUGIN=$(grep -m1 -oP 'PLUGIN_VERSION\s*=\s*"\K[^"]+' plugin/StudioStud.plugin.lua)
echo "Cargo=$CARGO Plugin=$PLUGIN"; [ "$CARGO" = "$PLUGIN" ] && echo "match ok"
LATEST=$(git tag -l 'v*' | sed 's/^v//' | sort -V | tail -1); echo "latest=$LATEST"
HIGHEST=$(printf '%s\n%s\n' "${LATEST:-0.0.0}" "$CARGO" | sort -V | tail -1); echo "highest=$HIGHEST"
```
Expected: `Cargo=0.4.12 Plugin=0.4.12`, `match ok`, `latest=0.4.10` (or current highest tag), `highest=0.4.12` — i.e. the gate would pass for the first cutover PR.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: gate PRs to main only + enforce matching, incremented version"
```

---

### Task 7: Collapse promote.yml to dev→main

**Files:**
- Modify: `.github/workflows/promote.yml` (full-file replacement)

- [ ] **Step 1: Replace the entire file**

Overwrite `.github/workflows/promote.yml` with exactly:

```yaml
name: Promote

# Opens (or refreshes) the development → main release PR. Merging it triggers the
# ordered release pipeline in deploy.yml. Remember to bump the version on development
# first: .\scripts\bump-version.ps1 <X.Y.Z>
on:
  workflow_dispatch:

permissions:
  contents: write
  pull-requests: write

jobs:
  open-pr:
    name: Open development → main PR
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Check for diff
        id: diff
        run: |
          COUNT=$(git rev-list --count origin/main..origin/development)
          echo "commits=$COUNT" >> $GITHUB_OUTPUT
          echo "$COUNT commit(s) ahead of main"

      - name: Abort if nothing to promote
        if: steps.diff.outputs.commits == '0'
        run: |
          echo "::notice::development is already up to date with main — nothing to promote."
          exit 0

      - name: Open PR (or update existing)
        if: steps.diff.outputs.commits != '0'
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          COMMITS=${{ steps.diff.outputs.commits }}
          LOG=$(git log --oneline origin/main..origin/development | head -30)
          BODY="## Release promotion

          Promoting **\`development\`** → **\`main\`** ($COMMITS commit(s)).

          <details><summary>Commit log</summary>

          \`\`\`
          $LOG
          \`\`\`

          </details>

          ## Checklist
          - [ ] Version bumped on development (\`.\scripts\bump-version.ps1 <X.Y.Z>\`) — CI version-gate enforces this
          - [ ] CI passes on \`development\`
          - [ ] Manually tested locally (\`.\scripts\install-local.ps1 -CleanFirst\`)"

          EXISTING=$(gh pr list --head development --base main --state open --json number --jq '.[0].number' 2>/dev/null || echo "")
          if [ -n "$EXISTING" ]; then
            echo "::notice::PR #$EXISTING already exists — updated body."
            gh pr edit "$EXISTING" --body "$BODY"
          else
            gh pr create --head development --base main --title "Release: development → main ($COMMITS commits)" --body "$BODY"
          fi
```

- [ ] **Step 2: Validate the YAML parses**

Run:
```powershell
python -c "import yaml; yaml.safe_load(open('.github/workflows/promote.yml')); print('promote.yml ok')"
```
Expected: prints `promote.yml ok`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/promote.yml
git commit -m "ci(promote): collapse to a single development -> main promotion"
```

---

## Phase 3 — Beta dormancy cleanup

### Task 8: Delete the beta install script

**Files:**
- Delete: `site/install-beta.ps1`

- [ ] **Step 1: Confirm nothing functional references install-beta**

Run (git grep recurses the tracked tree; `:!docs/` excludes this plan/spec):
```bash
git grep -n "install-beta" -- ':!docs/'
```
Expected: **no output** — no references in `site/`, `scripts/`, or `.github/`. (The `install.ps1` header reference was already removed in Task 3.)

- [ ] **Step 2: Delete the file**

```bash
git rm site/install-beta.ps1
```

- [ ] **Step 3: Commit**

```bash
git commit -m "chore(install): remove beta one-liner (channel dormant)"
```

---

## Phase 4 — Operator docs

### Task 9: Document the new flow

**Files:**
- Create: `docs/deploy-flow.md`

- [ ] **Step 1: Write the doc**

Create `docs/deploy-flow.md` with exactly:

```markdown
# Deployment flow (dev → main)

Two channels: **dev** (private, encrypted, auto-updates on every commit) and **release**
(public, shipped by PR). The `beta` channel is retired but `Channel::Beta` remains in code
so it can be revived.

## Day-to-day

- Commit to `development` freely. Each push republishes the dev channel and bumps
  `channelSequence`, so dev installs auto-update. **Do not change the version number for
  normal work.**

## Shipping a release

1. On `development`, bump the version (daemon + plugin together):
   `.\scripts\bump-version.ps1 <X.Y.Z>` — must be greater than the last `v*` tag.
2. Commit + push the bump to `development`.
3. Run the **Promote** workflow (Actions tab) to open the `development → main` PR, or open
   it manually.
4. CI runs `build-test` and `version-gate` (rejects a missing/mismatched/non-incremented
   bump). Approve and **merge with a merge commit** (not squash).
5. The merge triggers `deploy-release`: it creates the `v<X.Y.Z>` tag + GitHub Release +
   assets atomically, verifies the assets resolve, then publishes the release manifest.
   No manual tagging; 404s are impossible because the manifest publishes only after assets exist.

## One-time after the password-gap fix ships

Reinstall dev once so the channel key is stored:
`irm https://tyleradams2002.github.io/studio-stud/install-dev.ps1 | iex`
Then `studio-stud-setup update --check` should work without the "channel password not
stored" error. After that, dev auto-update is permanent.

## First cutover

The first release PR under this system ships `0.4.12` (where dev already sits); `v0.4.11`
is skipped — semver need not be contiguous.

## Reviving beta later

Restore the `deploy-beta` job and `github-release`/tag wiring in `deploy.yml`, re-add the
beta option to `promote.yml`, and recreate `site/install-beta.ps1`. `Channel::Beta` and its
`BETA_CHANNEL_PASSWORD` secret were never removed.
```

- [ ] **Step 2: Commit**

```bash
git add docs/deploy-flow.md
git commit -m "docs: describe the dev->main deployment flow"
```

---

## Self-Review notes (spec coverage)

- Spec §1 (topology) → Tasks 5, 7 (branch triggers, promotion).
- Spec §2 (ordered 404-proof pipeline) → Task 5 `deploy-release`.
- Spec §3 (bump + enforcement) → Tasks 4, 6.
- Spec §4 (password-gap fix) → Tasks 1, 2, 3 (+ manual acceptance step).
- Spec §5 (beta dormancy) → Tasks 3 (header), 5 (jobs/triggers), 7 (promote), 8 (install-beta).
- Spec §6 (first cutover + rollback) → Task 9 doc; cutover happens when the operator runs the
  first promotion (no code task — it's the `0.4.12` ship, which the version-gate already permits).

## Verification before declaring done

- [ ] `cargo test --workspace` passes (Tasks 1–2).
- [ ] All three workflow YAMLs parse (Tasks 5–7).
- [ ] `Select-String` finds no `beta` / `refs/tags` / `github-release` in `deploy.yml` (Task 5).
- [ ] `bump-version.ps1` round-trips and reverts cleanly; tree still at `0.4.12` (Task 4).
- [ ] Manual: dev reinstall seeds `channelKeyDpapi`; `update --check` no longer errors (Task 3).
```
