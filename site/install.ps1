<#
  Studio Stud bootstrap installer.

  Release  (no password):  irm https://tyleradams2002.github.io/studio-stud/install.ps1      | iex
  Beta     (password req):  irm https://tyleradams2002.github.io/studio-stud/install-beta.ps1 | iex
  Dev      (password req):  irm https://tyleradams2002.github.io/studio-stud/install-dev.ps1  | iex

  Local dev test:  .\scripts\install-local.ps1

  MANUAL TEST (fallback): install on dev/beta before that channel's first publish — should fall
  back to beta/release manifest and succeed (plain setup when release manifest resolves).
#>
param(
    [ValidateSet('release', 'beta', 'dev')]
    [string]$Channel = 'release',
    [string]$PagesBase = 'https://tyleradams2002.github.io/studio-stud'
)
$ErrorActionPreference = 'Stop'
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

# ── Fetch manifest (dev→beta→release fallback) ───────────────────────────────
$urls = switch ($Channel) {
    'dev'  { @("$PagesBase/dev/latest.json", "$PagesBase/beta/latest.json", "$PagesBase/latest.json") }
    'beta' { @("$PagesBase/beta/latest.json", "$PagesBase/latest.json") }
    default { @("$PagesBase/latest.json") }
}
Write-Host "Studio Stud installer  (channel: $Channel)"
$manifest = $null
$resolvedUrl = $null
foreach ($u in $urls) {
    try {
        $manifest = Invoke-RestMethod $u -ErrorAction Stop
        $resolvedUrl = $u
        break
    } catch {}
}
if (-not $manifest) {
    throw "No manifest reachable for channel '$Channel' (tried: $($urls -join ', '))."
}
if ($resolvedUrl -ne $urls[0]) {
    Write-Host "note: channel '$Channel' not yet published — using manifest at $resolvedUrl"
}

$dest = Join-Path $env:TEMP 'studio-stud-setup.exe'

# ── Plain release artifact (setupUrl present) ────────────────────────────────
if ($manifest.setupUrl) {
    $url = $manifest.setupUrl
    Write-Host "Downloading installer..."
    Invoke-WebRequest $url -OutFile $dest -UseBasicParsing
    Write-Host "Launching installer..."
    Start-Process -FilePath $dest -ArgumentList 'install' -Wait
    exit 0
}

# ── Beta / dev channel: encrypted artifact, inline PBKDF2+AES-CBC decrypt ────
$encUrl = $manifest.setupEncUrl
if (-not $encUrl) { throw "Manifest missing setupUrl and setupEncUrl." }

# Prompt for password (masked)
$secure = Read-Host "Enter $Channel channel password" -AsSecureString
$bstr   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try   { $password = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
if (-not $password) { Write-Host "Cancelled."; exit 1 }

Write-Host "Downloading encrypted installer..."
$encPath = Join-Path $env:TEMP 'studio-stud-setup.exe.enc'
Invoke-WebRequest $encUrl -OutFile $encPath -UseBasicParsing

Write-Host "Decrypting..."
$blob = [System.IO.File]::ReadAllBytes($encPath)

if ($blob.Length -lt 64) { throw "Encrypted blob is too short - file may be corrupt." }

$salt       = $blob[0..15]
$iv         = $blob[16..31]
$storedMac  = $blob[32..63]
$ciphertext = $blob[64..($blob.Length - 1)]

# PBKDF2-SHA256 × 200 000 → 64 bytes  [enc_key 0..31][mac_key 32..63]
$rfc = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
    $password,
    $salt,
    200000,
    [System.Security.Cryptography.HashAlgorithmName]::SHA256
)
$encKey = $rfc.GetBytes(32)
$macKey = $rfc.GetBytes(32)
$rfc.Dispose()

# Verify HMAC-SHA256 over (salt ‖ iv ‖ ciphertext) before decrypting
$hmac = New-Object System.Security.Cryptography.HMACSHA256
$hmac.Key = $macKey
$authData  = $salt + $iv + $ciphertext
$computed  = $hmac.ComputeHash($authData)
$hmac.Dispose()

$mismatch = $false
for ($i = 0; $i -lt 32; $i++) {
    if ($computed[$i] -ne $storedMac[$i]) { $mismatch = $true; break }
}
if ($mismatch) {
    Write-Host "Wrong password or file corrupted. Aborting." -ForegroundColor Red
    exit 1
}

# AES-256-CBC decrypt
$aes = New-Object System.Security.Cryptography.AesCryptoServiceProvider
$aes.KeySize = 256
$aes.Key     = $encKey
$aes.IV      = $iv
$aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
$aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
$dec = $aes.CreateDecryptor()
$aes.Dispose()
$plain = $dec.TransformFinalBlock($ciphertext, 0, $ciphertext.Length)
$dec.Dispose()

[System.IO.File]::WriteAllBytes($dest, $plain)
Remove-Item $encPath -Force -ErrorAction SilentlyContinue

Write-Host "Launching installer..."
Start-Process -FilePath $dest -ArgumentList 'install' -Wait
