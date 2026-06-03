# Phase 4 — Self-contained channel bundle

> Hand Composer: this file + `docs/REVIEW_2026-06-02.md`. Branch: **`development`**.
> Depends on: **Phase 2** (verify) + **Phase 3** (seq trigger).

## Goal
Ship **one artifact per channel** — a ZIP containing `studio-stud-setup.exe` + `studio-stud.exe` +
`StudioStud.plugin.lua` + `addons/` — encrypted on beta/dev. This makes a clean-machine fresh install
self-contained (the daemon/plugin are siblings of the extracted setup.exe, so `resolve_daemon_src`/
`resolve_plugin_src` find them) and lets dev/beta deliver a coherent, fully-locked daemon set.

## Pre-flight
```powershell
git switch development
cargo build --workspace && cargo test --workspace
```

---

## G9 — `package-release.ps1` produces the bundle + `bundleUrl`  [M]
**File:** `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\scripts\package-release.ps1`

**Add, after the `Copy-Item $setupBuilt "$dist/studio-stud-setup.exe"` line (~66) and the addon copy
block:** build the bundle ZIP from the staged tool tree:
```powershell
# ---- Bundle: one zip carrying setup + daemon + plugin + addons ----
$bundleStage = Join-Path $dist 'bundle'
New-Item -ItemType Directory -Force $bundleStage | Out-Null
Copy-Item "$dist/studio-stud-setup.exe"     "$bundleStage/studio-stud-setup.exe" -Force
Copy-Item "$dist/studio-stud.exe"           "$bundleStage/studio-stud.exe" -Force
Copy-Item "$dist/StudioStud.plugin.lua"     "$bundleStage/StudioStud.plugin.lua" -Force
if (Test-Path "$tool/addons") { Copy-Item "$tool/addons" "$bundleStage/addons" -Recurse -Force }
$bundleZip = Join-Path $dist 'studio-stud-bundle.zip'
if (Test-Path $bundleZip) { Remove-Item $bundleZip -Force }
Compress-Archive -Path "$bundleStage/*" -DestinationPath $bundleZip -Force
Remove-Item $bundleStage -Recurse -Force
```

**In the `$latest = [ordered]@{ … }` block (~99-111), add `bundleUrl`:**
```powershell
    setupUrl                 = "https://github.com/$Repo/releases/download/$tag/studio-stud-setup.exe"
    bundleUrl                = "https://github.com/$Repo/releases/download/$tag/studio-stud-bundle.zip"
    installUrl               = "$PagesBase/install.ps1"
```

**Acceptance:** `scripts\package-release.ps1` emits `dist\studio-stud-bundle.zip` containing the three
binaries (+ `addons/`), and `site\latest.json` now carries `bundleUrl` + `channelSequence`.

---

## G10 — Encrypt the bundle for beta/dev + manifest fields  [S/M]
**Files:**
- `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\src\setup_core\channels.rs` (ChannelManifest + helper)
- `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\scripts\publish-channel.ps1`
- `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\.github\workflows\deploy.yml` (dev job)

### 10a. Manifest fields + helper (channels.rs)
In `struct ChannelManifest`, add:
```rust
    #[serde(default)]
    pub bundle_url: Option<String>,
    #[serde(default)]
    pub bundle_enc_url: Option<String>,
```
Add a resolver beside `setup_artifact_url`:
```rust
/// URL for the channel BUNDLE zip (plain on release, encrypted on beta/dev).
pub fn bundle_artifact_url(resolved: Channel, manifest: &ChannelManifest) -> Result<String> {
    if resolved.is_encrypted() {
        manifest
            .bundle_enc_url
            .clone()
            .ok_or_else(|| anyhow!("manifest missing bundleEncUrl for {}", resolved.as_str()))
    } else {
        manifest
            .bundle_url
            .clone()
            .ok_or_else(|| anyhow!("manifest missing bundleUrl for {}", resolved.as_str()))
    }
}
```
Update the `sample_manifest()` test helper to set `bundle_url`/`bundle_enc_url` to `Some(...)` so existing
tests still construct a full struct.

### 10b. publish-channel.ps1 — encrypt the bundle, not the setup exe
Replace the "Encrypt setup exe" block (lines ~44-55) so it encrypts `dist/studio-stud-bundle.zip`:
```powershell
# ---------- 3. Encrypt the bundle zip ----------
Write-Host "Encrypting $Channel bundle..."
$outDir = Join-Path $Root "site/$Channel"
New-Item -ItemType Directory -Force $outDir | Out-Null
$bundleZip = Join-Path $dist 'studio-stud-bundle.zip'
if (-not (Test-Path $bundleZip)) { throw 'package-release.ps1 did not produce dist/studio-stud-bundle.zip' }
$encPath = Join-Path $outDir 'studio-stud-bundle.zip.enc'
$encOutput = cargo run --quiet --example encrypt-artifact -- `
    --password $password `
    --input $bundleZip `
    --output $encPath 2>&1
if ($LASTEXITCODE -ne 0) { throw "encrypt-artifact failed: $encOutput" }
```
In the manifest-build block (~68-73), set `bundleEncUrl` and drop the setup-only enc:
```powershell
$manifest | Add-Member -NotePropertyName channelSequence -NotePropertyValue $nextSeq -Force
$manifest | Add-Member -NotePropertyName bundleEncUrl -NotePropertyValue "$PagesBase/$Channel/studio-stud-bundle.zip.enc" -Force
$manifest.PSObject.Properties.Remove('setupUrl')
$manifest.PSObject.Properties.Remove('setupEncUrl')
```
(Signing stays as updated in Phase 2 step 7d.)

### 10c. deploy.yml dev job — encrypt the bundle
In `deploy-dev` → `Encrypt artifact` step (lines ~101-108), change input/output to the bundle:
```yaml
          cargo run --quiet --example encrypt-artifact -- `
            --password "$env:DEV_CHANNEL_PASSWORD" `
            --input  dist/studio-stud-bundle.zip `
            --output site/dev/studio-stud-bundle.zip.enc
```
In the manifest step, set `bundleEncUrl` instead of `setupEncUrl`:
```yaml
          $manifest | Add-Member -NotePropertyName bundleEncUrl -NotePropertyValue "$pagesBase/dev/studio-stud-bundle.zip.enc" -Force
          $manifest.PSObject.Properties.Remove('setupUrl')
```
(The signing swap from Phase 2 step 7e stays.)

**Acceptance:** `scripts\publish-channel.ps1 -Channel dev` writes `site\dev\studio-stud-bundle.zip.enc` and
a signed `site\dev\latest.json` carrying `bundleEncUrl`.

---

## G11 — `install.ps1` extracts the bundle  [M]
**File:** `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\site\install.ps1`

Replace the artifact-acquisition section (everything from `$dest = Join-Path $env:TEMP …` through the end)
with a bundle-first flow that falls back to the old setup-only path:
```powershell
$work = Join-Path $env:TEMP 'studio-stud-install'
if (Test-Path $work) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $work | Out-Null

function Invoke-Setup($dir) {
    $exe = Join-Path $dir 'studio-stud-setup.exe'
    if (-not (Test-Path $exe)) { throw "bundle missing studio-stud-setup.exe" }
    Write-Host "Launching installer..."
    Start-Process -FilePath $exe -ArgumentList 'install' -Wait
}

# Decrypt helper (PBKDF2-SHA256x200000 -> AES-256-CBC + HMAC), matches examples/encrypt-artifact.rs.
function Get-Decrypted($encPath, $outPath, $password) {
    $blob = [System.IO.File]::ReadAllBytes($encPath)
    if ($blob.Length -lt 64) { throw "Encrypted blob too short." }
    $salt=$blob[0..15]; $iv=$blob[16..31]; $mac=$blob[32..63]; $ct=$blob[64..($blob.Length-1)]
    $rfc = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($password,$salt,200000,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $encKey=$rfc.GetBytes(32); $macKey=$rfc.GetBytes(32); $rfc.Dispose()
    $h = New-Object System.Security.Cryptography.HMACSHA256; $h.Key=$macKey
    $calc = $h.ComputeHash($salt+$iv+$ct); $h.Dispose()
    for ($i=0;$i -lt 32;$i++){ if ($calc[$i] -ne $mac[$i]){ throw "Wrong password or corrupt file." } }
    $aes = New-Object System.Security.Cryptography.AesCryptoServiceProvider
    $aes.KeySize=256; $aes.Key=$encKey; $aes.IV=$iv
    $aes.Mode=[System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding=[System.Security.Cryptography.PaddingMode]::PKCS7
    $dec=$aes.CreateDecryptor(); $aes.Dispose()
    [System.IO.File]::WriteAllBytes($outPath, $dec.TransformFinalBlock($ct,0,$ct.Length)); $dec.Dispose()
}

if ($manifest.bundleUrl) {
    $zip = Join-Path $work 'bundle.zip'
    Write-Host "Downloading bundle..."
    Invoke-WebRequest $manifest.bundleUrl -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $work -Force
    Invoke-Setup $work
    exit 0
}
if ($manifest.bundleEncUrl) {
    $secure = Read-Host "Enter $Channel channel password" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $password = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if (-not $password) { Write-Host "Cancelled."; exit 1 }
    $enc = Join-Path $work 'bundle.zip.enc'; $zip = Join-Path $work 'bundle.zip'
    Write-Host "Downloading encrypted bundle..."
    Invoke-WebRequest $manifest.bundleEncUrl -OutFile $enc -UseBasicParsing
    Write-Host "Decrypting..."
    Get-Decrypted $enc $zip $password
    Expand-Archive -Path $zip -DestinationPath $work -Force
    Invoke-Setup $work
    exit 0
}
# Legacy fallback: setup-only artifact (pre-bundle manifests)
if ($manifest.setupUrl) {
    $dest = Join-Path $work 'studio-stud-setup.exe'
    Invoke-WebRequest $manifest.setupUrl -OutFile $dest -UseBasicParsing
    Start-Process -FilePath $dest -ArgumentList 'install' -Wait
    exit 0
}
throw "Manifest has no bundleUrl/bundleEncUrl/setupUrl."
```
> Keep the existing channel/manifest-fallback header (lines 13-45) unchanged. The old inline decrypt block
> for `setupEncUrl` is replaced by `Get-Decrypted` + the bundle path above.

**Acceptance:** against a manifest with `bundleUrl`, `install.ps1` downloads + expands the zip and launches
the extracted setup, which finds `studio-stud.exe`/`StudioStud.plugin.lua` as siblings.

---

## G12 — `update_apply.rs` extracts the bundle  [M]
**Files:**
- `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\setup\Cargo.toml` (add dep)
- `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\setup\src\update_apply.rs`

### 12a. Add the zip dependency (setup/Cargo.toml `[dependencies]`)
```toml
zip = "2.2"
```

### 12b. Rewrite `apply_channel_update` to download+extract the bundle
Replace the daemon/plugin URL download with a bundle fetch+extract. New body:
```rust
use studio_stud::setup_core::channels::{
    Channel, ChannelManifest, bundle_artifact_url, record_channel_sequence,
};
use studio_stud::setup_core::crypto::{channel_decrypt, dpapi_unprotect};

pub fn apply_channel_update(
    cfg: &StudioStudConfig,
    manifest: &ChannelManifest,
    resolved: Channel,
) -> Result<()> {
    stop_running_daemon(cfg)?;

    let temp = std::env::temp_dir().join(format!("studio-stud-update-{}", std::process::id()));
    let extract = temp.join("bundle");
    let _ = fs::remove_dir_all(&temp);
    fs::create_dir_all(&extract).with_context(|| format!("create {}", extract.display()))?;

    let url = bundle_artifact_url(resolved, manifest)?;
    let zip_path = temp.join("bundle.zip");
    if resolved.is_encrypted() {
        let enc = temp.join("bundle.zip.enc");
        update::download_to(&url, &enc)?;
        let password = channel_password(cfg)?;
        let blob = fs::read(&enc)?;
        let plain = channel_decrypt(&password, &blob)
            .map_err(|_| anyhow!("could not decrypt channel bundle — reinstall via your channel installer"))?;
        fs::write(&zip_path, plain)?;
    } else {
        update::download_to(&url, &zip_path)?;
    }
    extract_zip(&zip_path, &extract)?;

    let daemon_path = extract.join("studio-stud.exe");
    let plugin_path = extract.join("StudioStud.plugin.lua");
    if !daemon_path.is_file() || !plugin_path.is_file() {
        return Err(anyhow!("bundle missing studio-stud.exe or StudioStud.plugin.lua"));
    }

    let mut updated_cfg = cfg.clone();
    record_channel_sequence(&mut updated_cfg, resolved, manifest.channel_sequence);
    run_update_headless(
        &updated_cfg,
        &daemon_path,
        &plugin_path,
        &manifest.daemon_version,
        &manifest.plugin_version,
        resolved.as_str(),
        &updated_cfg.last_channel_sequence,
    )?;
    save_config(&updated_cfg)?;
    Ok(())
}

fn channel_password(cfg: &StudioStudConfig) -> Result<String> {
    let dpapi = cfg.channel_key_dpapi.as_deref().ok_or_else(|| {
        anyhow!("channel password not stored — reinstall via install-beta.ps1 / install-dev.ps1")
    })?;
    String::from_utf8(dpapi_unprotect(dpapi)?).map_err(|_| anyhow!("stored channel password is invalid"))
}

fn extract_zip(zip_path: &std::path::Path, dest: &std::path::Path) -> Result<()> {
    let file = fs::File::open(zip_path)?;
    let mut archive = zip::ZipArchive::new(file)?;
    archive.extract(dest)?;
    Ok(())
}
```
Remove the now-unused `required_binary_url`/`required_plugin_url` imports and the old
`decrypt_setup_smoke_check` helper. (Leave `required_binary_url`/`required_plugin_url` in `channels.rs` for
back-compat unless nothing references them — then delete.)

**Acceptance:** `studio-stud-setup update` on a published-newer channel downloads the bundle, extracts it,
and `…\Programs\StudioStud\bin\studio-stud.exe` reflects the new daemon version.

---

## G13 — Fresh-install fallback download  [S]
**Files:** `C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\setup\src\gui.rs` (`run_install`, ~602-616);
`C:\Users\tyler\OneDrive\Documents\GitHub\studio-stud\setup\src\main.rs` (`cmd_install_silent`, ~99-104).

**Why:** if someone runs `studio-stud-setup.exe install` from a folder with no bundle siblings (not via
`install.ps1`), don't dead-end — fetch the channel bundle first.

**Change:** extract the bundle fetch+extract from G12 into a reusable
`pub fn fetch_channel_bundle(cfg: &StudioStudConfig) -> Result<(PathBuf /*daemon*/, PathBuf /*plugin*/)>`
in `update_apply.rs` (fetch manifest with the cfg channel, resolve `bundle_artifact_url`, download/decrypt,
extract, return the two paths). Then in `run_install`/`cmd_install_silent`, when
`resolve_daemon_src()`/`resolve_plugin_src()` return `None`, call `fetch_channel_bundle` before erroring;
only error if offline.

**Acceptance:** running `studio-stud-setup.exe install` from an empty temp dir with network connectivity
still installs (downloads + extracts the bundle).

---

## Verification (return to Claude)
```powershell
cargo build --workspace
cargo test --workspace
scripts\package-release.ps1          # emits dist\studio-stud-bundle.zip + site\latest.json w/ bundleUrl
```
- Inspect `dist\studio-stud-bundle.zip` contains setup + daemon + plugin (+ addons).
- **Clean-ish install sim:** `Expand-Archive dist\studio-stud-bundle.zip <temp>`, run
  `<temp>\studio-stud-setup.exe install --silent`, then `studio-stud --version` after PATH refresh.
- **Update sim** (needs a dev publish via Phase 5 or `publish-channel.ps1`): bump dev `channelSequence`,
  `studio-stud-setup update` → confirm the bundled daemon version lands under `…\Programs\StudioStud\bin`.
- Then run **review-doc section H** steps 1-2 to confirm a bundle-installed daemon serves + captures.

## Done when
`cargo test --workspace` green; a bundle install on a clean folder produces a working `studio-stud` on PATH;
`studio-stud-setup update` swaps the bundled daemon. No capture/live/write code changed.
