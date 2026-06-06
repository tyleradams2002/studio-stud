<#
  Studio Stud bootstrap installer.

  Release  (no password):  irm https://tyleradams2002.github.io/studio-stud/install.ps1      | iex
  (beta channel retired — dev + release only)
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

$work = Join-Path $env:TEMP 'studio-stud-install'
if (Test-Path $work) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $work | Out-Null

function Invoke-Setup($dir) {
    $exe = Join-Path $dir 'studio-stud-setup.exe'
    if (-not (Test-Path $exe)) { throw "bundle missing studio-stud-setup.exe" }
    Write-Host "Launching installer..."
    # Pass the channel so the install is recorded against it (not the release default).
    Start-Process -FilePath $exe -ArgumentList 'install', '--channel', $Channel -Wait
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

# Encrypted channels (beta/dev) first: a fallback-to-release manifest has only bundleUrl,
# so this never shadows the plain path — but an encrypted manifest must win over any plain
# bundleUrl it may also carry.
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
    # Forward the password to setup.exe (inherited by the child process) so it can store the
    # DPAPI-protected key for self-update. Cleared immediately after the installer returns.
    $env:STUDIO_STUD_CHANNEL_PASSWORD = $password
    try { Invoke-Setup $work }
    finally { Remove-Item Env:\STUDIO_STUD_CHANNEL_PASSWORD -ErrorAction SilentlyContinue }
    exit 0
}
if ($manifest.bundleUrl) {
    $zip = Join-Path $work 'bundle.zip'
    Write-Host "Downloading bundle..."
    Invoke-WebRequest $manifest.bundleUrl -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $work -Force
    Invoke-Setup $work
    exit 0
}
# Legacy fallback: setup-only artifact (pre-bundle manifests)
if ($manifest.setupUrl) {
    $dest = Join-Path $work 'studio-stud-setup.exe'
    Invoke-WebRequest $manifest.setupUrl -OutFile $dest -UseBasicParsing
    Start-Process -FilePath $dest -ArgumentList 'install', '--channel', $Channel -Wait
    exit 0
}
throw "Manifest has no bundleUrl/bundleEncUrl/setupUrl."
