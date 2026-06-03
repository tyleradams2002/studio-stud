<#
  LOCAL publish for beta/dev channels only. CI never runs this (no channel passwords in CI).
  Requires secrets/channel-passwords.json (gitignored) on your machine.
  Requires secrets/channel-signing.key  (gitignored) — run .\scripts\keygen.ps1 first.

  Usage:
    .\scripts\publish-channel.ps1 -Channel beta
    .\scripts\publish-channel.ps1 -Channel dev
#>
param(
    [Parameter(Mandatory)]
    [ValidateSet('beta', 'dev')]
    [string]$Channel,
    [string]$Repo = 'tyleradams2002/studio-stud',
    [string]$PagesBase = 'https://tyleradams2002.github.io/studio-stud'
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

# ---------- 1. Load secrets ----------
$secretsPath = Join-Path $Root 'secrets/channel-passwords.json'
if (-not (Test-Path $secretsPath)) {
    throw "Missing $secretsPath - fill in beta/dev passwords first."
}
$secrets = Get-Content $secretsPath -Raw | ConvertFrom-Json
$password = $secrets.$Channel
if (-not $password) { throw "No password for channel '$Channel' in secrets file. Fill it in." }

$signingKeyPath = Join-Path $Root 'secrets/channel-signing.key'
if (-not (Test-Path $signingKeyPath)) {
    throw "Missing $signingKeyPath - run .\scripts\keygen.ps1 first."
}
$privKeyHex = (Get-Content $signingKeyPath -Raw).Trim()
if ($privKeyHex -like 'PLACEHOLDER*') {
    throw "signing key is still a placeholder - run .\scripts\keygen.ps1 first."
}

# ---------- 2. Build ----------
& (Join-Path $PSScriptRoot 'package-release.ps1')
$dist = Join-Path $Root 'dist'
$setupExe = Join-Path $dist 'studio-stud-setup.exe'
if (-not (Test-Path $setupExe)) { throw 'package-release.ps1 did not produce dist/studio-stud-setup.exe' }

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

# ---------- 4. Determine next channelSequence (live gh-pages floor) ----------
$baseManifestPath = Join-Path $Root 'site/latest.json'
$baseManifest = Get-Content $baseManifestPath -Raw | ConvertFrom-Json
$liveUrl = "$PagesBase/$Channel/latest.json"
$prevSeq = 0
try {
  $live = Invoke-RestMethod $liveUrl -ErrorAction Stop
  if ($live.channelSequence) { $prevSeq = [int]$live.channelSequence }
} catch { $prevSeq = 0 }
$nextSeq = $prevSeq + 1

# ---------- 5. Build unsigned manifest ----------
$manifest = $baseManifest | Select-Object *
$manifest | Add-Member -NotePropertyName channelSequence -NotePropertyValue $nextSeq -Force
$manifest | Add-Member -NotePropertyName bundleEncUrl -NotePropertyValue "$PagesBase/$Channel/studio-stud-bundle.zip.enc" -Force
$manifest.PSObject.Properties.Remove('setupUrl')
$manifest.PSObject.Properties.Remove('setupEncUrl')

# ---------- 6. Sign manifest (Rust canonicalizes — pass the unsigned manifest file) ----------
$unsignedPath = Join-Path $outDir 'latest.unsigned.json'
$manifest | ConvertTo-Json -Depth 10 | Set-Content $unsignedPath -Encoding utf8
Write-Host "Signing manifest..."
$signOutput = cargo run --quiet --example sign-manifest -- `
    --privkey $privKeyHex `
    --manifest $unsignedPath 2>&1
if ($LASTEXITCODE -ne 0) { throw "sign-manifest failed: $signOutput" }
$sigB64 = $signOutput.Trim()

$manifest | Add-Member -NotePropertyName signature -NotePropertyValue $sigB64 -Force
$manifest | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $outDir 'latest.json') -Encoding utf8
Remove-Item $unsignedPath -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Published $Channel channel to $outDir"
Write-Host "  channelSequence : $nextSeq"
Write-Host "  enc artifact    : $encPath"
Write-Host "  manifest        : $(Join-Path $outDir 'latest.json')"
Write-Host ""
Write-Host "Push the site/ folder to the gh-pages branch (or let CI pick it up)."
