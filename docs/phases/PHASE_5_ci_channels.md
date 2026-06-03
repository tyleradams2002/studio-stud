# Phase 5 — CI manifest delivery + beta channel

> Hand Composer: this file + `docs/REVIEW_2026-06-02.md`. Branch: **`development`** (CI YAML changes flow
> to `main` via your normal promotion).
> Depends on: **Phase 4** (bundle + `bundleUrl`).

## Goal
Make CI publish the **regenerated** manifest (not the stale committed file), attach the bundle to tagged
releases, and add the missing **beta** publish job so `install-beta.ps1` has something to install.

## Pre-flight
- Phase 4 merged; `scripts\package-release.ps1` produces `dist\studio-stud-bundle.zip` + a `site\latest.json`
  with `bundleUrl` + `channelSequence`.
- One-time: run `scripts\package-release.ps1` locally and **commit the regenerated `site\latest.json`** so
  the dev/beta jobs (which read it as their base) start from the correct shape.

---

## G14 — Publish the regenerated release manifest + bundle  [M]
**File:** `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\.github\workflows\deploy.yml`

### 14a. `build` job — upload the generated manifest as an artifact
After the `Upload dist artifacts` step, add:
```yaml
      - name: Upload generated manifest
        uses: actions/upload-artifact@v4
        with:
          name: manifest-${{ github.sha }}
          path: site/latest.json
          retention-days: 7
```

### 14b. `deploy-release` job — use the generated manifest before publishing
After `Download dist`, add:
```yaml
      - name: Download generated manifest
        uses: actions/download-artifact@v4
        with:
          name: manifest-${{ github.sha }}
          path: manifest/

      - name: Use generated manifest (overwrite committed)
        run: cp manifest/latest.json site/latest.json
```
The existing `peaceiris/actions-gh-pages` step (publish_dir: site) now serves the regenerated
`latest.json` (with `bundleUrl` + `channelSequence`, no `signature` → release stays unsigned per D2).

### 14c. `github-release` job (tags) — attach the bundle
In the `Publish release` step `files:` list, add the bundle:
```yaml
          files: |
            dist/studio-stud.exe
            dist/studio-stud-setup.exe
            dist/StudioStud.plugin.lua
            dist/studio-stud-bundle.zip
```

**Release flow (document in README later):** bump `version` in `Cargo.toml` + `setup/Cargo.toml` +
`PLUGIN_VERSION`, push to `main` (Pages manifest updates) **and** push tag `v<ver>` (Release uploads the
bundle the manifest points at). Push them together so `bundleUrl` resolves.

**Acceptance:** after a `main` push, `https://tyleradams2002.github.io/studio-stud/latest.json` contains
`bundleUrl` + `channelSequence` and no `signature`; after the matching tag, the release has
`studio-stud-bundle.zip`.

---

## G15 — Add the beta publish job  [M]
**Files:** `.github/workflows/deploy.yml`; GitHub repo secret `BETA_CHANNEL_PASSWORD`.

Add a `deploy-beta` job mirroring `deploy-dev`, gated on the `beta` branch:
```yaml
  deploy-beta:
    name: Publish → beta channel
    needs: build
    if: github.ref == 'refs/heads/beta'
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
      - name: Encrypt bundle
        shell: pwsh
        run: |
          New-Item -ItemType Directory -Force site/beta | Out-Null
          cargo run --quiet --example encrypt-artifact -- `
            --password "$env:BETA_CHANNEL_PASSWORD" `
            --input  dist/studio-stud-bundle.zip `
            --output site/beta/studio-stud-bundle.zip.enc
        env:
          BETA_CHANNEL_PASSWORD: ${{ secrets.BETA_CHANNEL_PASSWORD }}
      - name: Build + sign manifest
        shell: pwsh
        run: |
          $prevSeq = 0
          try {
            $live = Invoke-RestMethod 'https://tyleradams2002.github.io/studio-stud/beta/latest.json' -ErrorAction Stop
            if ($live.channelSequence) { $prevSeq = [int]$live.channelSequence }
          } catch { $prevSeq = 0 }
          $nextSeq = $prevSeq + 1
          $base = Get-Content site/latest.json -Raw | ConvertFrom-Json
          $pagesBase = 'https://tyleradams2002.github.io/studio-stud'
          $manifest = $base | Select-Object *
          $manifest | Add-Member -NotePropertyName channelSequence -NotePropertyValue $nextSeq -Force
          $manifest | Add-Member -NotePropertyName bundleEncUrl -NotePropertyValue "$pagesBase/beta/studio-stud-bundle.zip.enc" -Force
          $manifest.PSObject.Properties.Remove('setupUrl')
          $unsigned = 'site/beta/latest.unsigned.json'
          $manifest | ConvertTo-Json -Depth 10 | Set-Content $unsigned -Encoding utf8
          $sigB64 = cargo run --quiet --example sign-manifest -- `
            --privkey "$env:CHANNEL_SIGNING_KEY" --manifest $unsigned
          if ($LASTEXITCODE -ne 0) { throw "sign-manifest failed" }
          $manifest | Add-Member -NotePropertyName signature -NotePropertyValue $sigB64.Trim() -Force
          $manifest | ConvertTo-Json -Depth 10 | Set-Content site/beta/latest.json -Encoding utf8
          Remove-Item $unsigned -ErrorAction SilentlyContinue
        env:
          CHANNEL_SIGNING_KEY: ${{ secrets.CHANNEL_SIGNING_KEY }}
      - name: Deploy site/beta to gh-pages/beta
        uses: peaceiris/actions-gh-pages@v4
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          publish_branch: gh-pages
          publish_dir: site/beta
          destination_dir: beta
          keep_files: true
```
Add `BETA_CHANNEL_PASSWORD` under repo Settings → Secrets → Actions. Note it in `deploy.yml`'s header
comment alongside `DEV_CHANNEL_PASSWORD`, and mention it in `scripts/configure-github.ps1` output.

**Acceptance:** a push to `beta` publishes `site/beta/studio-stud-bundle.zip.enc` + a signed
`site/beta/latest.json`; `install-beta.ps1` installs against it.

---

## Verification (return to Claude)
- Static: `cargo build --workspace` still green (no Rust change here, but confirm nothing broke).
- After a `development` push: check `…/dev/latest.json` has `bundleEncUrl` + a `signature`; on a dev
  install `studio-stud-setup update --check --json` returns without a signature error (proves Phase 2+5).
- After a `main` push + tag: on a clean VM run the release one-liner
  `irm https://tyleradams2002.github.io/studio-stud/install.ps1 | iex` → installs end-to-end.
- After a `beta` push: `install-beta.ps1` prompts for the beta password and installs.
- Then run **review-doc section H** (full in-Studio parity) against the freshly-installed build.

## Done when
The release one-liner completes on a clean machine, dev/beta updates verify their signatures, and
`channelSequence`-driven auto-update fires after a same-version republish.
