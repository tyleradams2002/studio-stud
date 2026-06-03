<#
.SYNOPSIS
  Build the release binary and assemble the runtime bundle + version manifests.

.DESCRIPTION
  Produces:
    dist/.studio-stud-tool/bin/studio-stud.exe
    dist/.studio-stud-tool/plugin/StudioStud.plugin.lua
    dist/.studio-stud-tool/version.json
    dist/StudioStud.plugin.lua          (release asset)
    dist/studio-stud.exe                (release asset)
    site/latest.json                    (Pages version manifest)

  Version source of truth: Cargo.toml (daemon), PLUGIN_VERSION (plugin),
  PROTOCOL_VERSION / MIN_PLUGIN_PROTOCOL_VERSION (src/util.rs),
  MIN_DAEMON_PROTOCOL_VERSION (plugin).
#>
param(
    [string]$Repo   = "tyleradams2002/studio-stud",
    [string]$PagesBase = "https://tyleradams2002.github.io/studio-stud",
    [switch]$SkipBuild
)
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot

function Get-Match([string]$Path, [string]$Pattern) {
    $m = Select-String -Path $Path -Pattern $Pattern | Select-Object -First 1
    if (-not $m) { throw "Pattern not found in ${Path}: $Pattern" }
    return $m.Matches[0].Groups[1].Value
}

$cargoToml  = Join-Path $Root "Cargo.toml"
$utilRs     = Join-Path $Root "src/util.rs"
$pluginLua  = Join-Path $Root "plugin/StudioStud.plugin.lua"
$exePath    = Join-Path $Root "bin/studio-stud.exe"

$daemonVersion  = Get-Match $cargoToml '^version\s*=\s*"([^"]+)"'
$protocol       = [int](Get-Match $utilRs 'PROTOCOL_VERSION:\s*i64\s*=\s*(\d+)')
$minPlugin      = [int](Get-Match $utilRs 'MIN_PLUGIN_PROTOCOL_VERSION:\s*i64\s*=\s*(\d+)')
$pluginVersion  = Get-Match $pluginLua 'PLUGIN_VERSION\s*=\s*"([^"]+)"'
try { $minDaemon = [int](Get-Match $pluginLua 'MIN_DAEMON_PROTOCOL_VERSION\s*=\s*(\d+)') } catch { $minDaemon = 1 }

Write-Host "daemon=$daemonVersion plugin=$pluginVersion protocol=$protocol minPlugin=$minPlugin minDaemon=$minDaemon"

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot "build-local.ps1")
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Push-Location $Root
    cargo build --release -p studio-stud-setup
    if ($LASTEXITCODE -ne 0) { Pop-Location; exit $LASTEXITCODE }
    Pop-Location
}
if (-not (Test-Path $exePath)) { throw "Missing built exe: $exePath" }
$setupBuilt = Join-Path $Root "target/release/studio-stud-setup.exe"
if (-not (Test-Path $setupBuilt)) { throw "Missing setup exe: $setupBuilt" }

$dist   = Join-Path $Root "dist"
$tool   = Join-Path $dist ".studio-stud-tool"
if (Test-Path $dist) { Remove-Item -Recurse -Force $dist }
New-Item -ItemType Directory -Force "$tool/bin","$tool/plugin","$tool/addons" | Out-Null

Copy-Item $exePath   "$tool/bin/studio-stud.exe" -Force
Copy-Item $pluginLua "$tool/plugin/StudioStud.plugin.lua" -Force
Copy-Item $exePath   "$dist/studio-stud.exe" -Force
Copy-Item $pluginLua "$dist/StudioStud.plugin.lua" -Force
Copy-Item $setupBuilt "$dist/studio-stud-setup.exe" -Force

$addonSrc = Join-Path $Root "addon-plugins"
if (Test-Path $addonSrc) {
    Get-ChildItem $addonSrc -Directory | ForEach-Object {
        if ($_.Name -eq 'sdk' -or $_.Name.StartsWith('_')) { return }
        Copy-Item $_.FullName (Join-Path "$tool/addons" $_.Name) -Recurse -Force
    }
}

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

$now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$versionJson = [ordered]@{
    daemonVersion           = $daemonVersion
    pluginVersion           = $pluginVersion
    protocolVersion         = $protocol
    minPluginProtocolVersion = $minPlugin
    minDaemonProtocolVersion = $minDaemon
    source                  = "https://github.com/$Repo"
    installedAt             = $now
}
$versionJson | ConvertTo-Json | Set-Content "$tool/version.json" -Encoding utf8

$tag = "v$daemonVersion"

# Release channelSequence: read live manifest so CI increments monotonically (not hardcoded 1).
$prevSeq = 0
try {
  $live = Invoke-RestMethod "$PagesBase/latest.json" -ErrorAction Stop
  if ($live.channelSequence) { $prevSeq = [int]$live.channelSequence }
} catch { $prevSeq = 0 }
$nextSeq = $prevSeq + 1

$latest = [ordered]@{
    daemonVersion            = $daemonVersion
    pluginVersion            = $pluginVersion
    protocolVersion          = $protocol
    minPluginProtocolVersion = $minPlugin
    minDaemonProtocolVersion = $minDaemon
    binaryUrl                = "https://github.com/$Repo/releases/download/$tag/studio-stud.exe"
    pluginUrl                = "https://github.com/$Repo/releases/download/$tag/StudioStud.plugin.lua"
    setupUrl                 = "https://github.com/$Repo/releases/download/$tag/studio-stud-setup.exe"
    bundleUrl                = "https://github.com/$Repo/releases/download/$tag/studio-stud-bundle.zip"
    installUrl               = "$PagesBase/install.ps1"
    channelSequence          = $nextSeq
    releasedAt               = $now
}
New-Item -ItemType Directory -Force (Join-Path $Root "site") | Out-Null
[System.IO.File]::WriteAllText((Join-Path $Root "site/latest.json"), ($latest | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Bundle assembled under: $tool"
Write-Host "Pages manifest written: site/latest.json (tag $tag)"
