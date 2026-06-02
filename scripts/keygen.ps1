<#
  Generate an ed25519 signing key pair for Studio Stud channel manifests.

  Run ONCE, then commit secrets/channel-signing.pub (the public key).
  NEVER commit secrets/channel-signing.key (private key — gitignored).

  Usage:
    .\scripts\keygen.ps1
#>
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

# Build the tiny keygen helper that ships in the workspace
Write-Host "Building keygen helper..."
Push-Location $Root
cargo run --quiet --example keygen 2>&1 | Tee-Object -Variable buildOut
if ($LASTEXITCODE -ne 0) {
    Pop-Location
    throw "Cargo build failed: $buildOut"
}
Pop-Location

# The example writes key material to stdout; parse it.
$output = cargo run --quiet --example keygen 2>$null
$privLine = $output | Where-Object { $_ -match '^PRIVATE:' } | Select-Object -First 1
$pubLine  = $output | Where-Object { $_ -match '^PUBLIC:'  } | Select-Object -First 1
if (-not $privLine -or -not $pubLine) { throw "Unexpected keygen output: $output" }

$privHex = $privLine -replace '^PRIVATE:\s*'
$pubHex  = $pubLine  -replace '^PUBLIC:\s*'

$secretsDir = Join-Path $Root 'secrets'
New-Item -ItemType Directory -Force $secretsDir | Out-Null

$privPath = Join-Path $secretsDir 'channel-signing.key'
$pubPath  = Join-Path $secretsDir 'channel-signing.pub'

Set-Content $privPath $privHex -Encoding ascii -NoNewline
Set-Content $pubPath  $pubHex  -Encoding ascii -NoNewline

Write-Host ""
Write-Host "Key pair generated:"
Write-Host "  Private key -> $privPath  (KEEP SECRET — never commit)"
Write-Host "  Public key  -> $pubPath"
Write-Host ""
Write-Host "The public key is embedded at build time via include_str! in channels.rs."
Write-Host "Both files are in secrets/ which is gitignored, EXCEPT channel-signing.pub."
Write-Host "Add it to git and commit:"
Write-Host "  git add secrets/channel-signing.pub"
Write-Host "  git commit -m 'embed ed25519 signing public key'"
