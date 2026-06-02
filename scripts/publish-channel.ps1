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
    throw "Missing $secretsPath — fill in beta/dev passwords first."
}
$secrets = Get-Content $secretsPath -Raw | ConvertFrom-Json
$password = $secrets.$Channel
if (-not $password) { throw "No password for channel '$Channel' in secrets file. Fill it in." }

$signingKeyPath = Join-Path $Root 'secrets/channel-signing.key'
if (-not (Test-Path $signingKeyPath)) {
    throw "Missing $signingKeyPath — run .\scripts\keygen.ps1 first."
}
$privKeyHex = (Get-Content $signingKeyPath -Raw).Trim()
if ($privKeyHex -like 'PLACEHOLDER*') {
    throw "signing key is still a placeholder — run .\scripts\keygen.ps1 first."
}

# ---------- 2. Build ----------
& (Join-Path $PSScriptRoot 'package-release.ps1')
$dist = Join-Path $Root 'dist'
$setupExe = Join-Path $dist 'studio-stud-setup.exe'
if (-not (Test-Path $setupExe)) { throw 'package-release.ps1 did not produce dist/studio-stud-setup.exe' }

# ---------- 3. Encrypt setup exe with AEAD ----------
Write-Host "Encrypting $Channel artifact..."
$outDir = Join-Path $Root "site/$Channel"
New-Item -ItemType Directory -Force $outDir | Out-Null
$encPath = Join-Path $outDir 'studio-stud-setup.exe.enc'

# Call the encrypt-artifact Rust example (reads stdin, writes stdout)
$encOutput = cargo run --quiet --example encrypt-artifact -- `
    --password $password `
    --input $setupExe `
    --output $encPath 2>&1
if ($LASTEXITCODE -ne 0) { throw "encrypt-artifact failed: $encOutput" }

# ---------- 4. Determine next channelSequence ----------
$baseManifestPath = Join-Path $Root 'site/latest.json'
$baseManifest = Get-Content $baseManifestPath -Raw | ConvertFrom-Json
$channelManifestPath = Join-Path $outDir 'latest.json'
$prevSeq = 0
if (Test-Path $channelManifestPath) {
    $prev = Get-Content $channelManifestPath -Raw | ConvertFrom-Json
    if ($prev.channelSequence) { $prevSeq = [int]$prev.channelSequence }
}
$nextSeq = $prevSeq + 1

# ---------- 5. Build unsigned manifest ----------
$manifest = $baseManifest | Select-Object *
$manifest | Add-Member -NotePropertyName channelSequence -NotePropertyValue $nextSeq -Force
$manifest | Add-Member -NotePropertyName setupEncUrl -NotePropertyValue "$PagesBase/$Channel/studio-stud-setup.exe.enc" -Force
# Remove plain setupUrl so clients don't accidentally use unencrypted path
$manifest.PSObject.Properties.Remove('setupUrl')

# Canonical JSON (sorted keys) for signing
$canonicalJson = $manifest | ConvertTo-Json -Compress -Depth 10

# ---------- 6. Sign manifest ----------
Write-Host "Signing manifest..."
$signOutput = cargo run --quiet --example sign-manifest -- `
    --privkey $privKeyHex `
    --payload $canonicalJson 2>&1
if ($LASTEXITCODE -ne 0) { throw "sign-manifest failed: $signOutput" }
$sigB64 = $signOutput.Trim()

$manifest | Add-Member -NotePropertyName signature -NotePropertyValue $sigB64 -Force
$manifest | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $outDir 'latest.json') -Encoding utf8

Write-Host ""
Write-Host "Published $Channel channel to $outDir"
Write-Host "  channelSequence : $nextSeq"
Write-Host "  enc artifact    : $encPath"
Write-Host "  manifest        : $(Join-Path $outDir 'latest.json')"
Write-Host ""
Write-Host "Push the site/ folder to the gh-pages branch (or let CI pick it up)."
