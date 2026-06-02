<#
  Studio Stud installer. Downloads the latest release runtime into a clean
  .studio-stud-tool/ folder inside the target repo and drops a root launcher.

  Usage:
    irm https://tyleradams2002.github.io/studio-stud/install.ps1 | iex
    & ([scriptblock]::Create((irm https://tyleradams2002.github.io/studio-stud/install.ps1))) -WithCursorRule
#>
param(
    [string]$Dir,
    [switch]$WithCursorRule,
    [string]$PagesBase = "https://tyleradams2002.github.io/studio-stud",
    [string]$RawBase   = "https://raw.githubusercontent.com/tyleradams2002/studio-stud/main"
)
$ErrorActionPreference = "Stop"
# Ensure TLS 1.2 on Windows PowerShell 5.1 (no-op / already default on PS 7+).
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

if (-not $Dir) {
    try { $Dir = (& git rev-parse --show-toplevel 2>$null) } catch { $Dir = $null }
    if (-not $Dir) { $Dir = (Get-Location).Path }
}
$Dir  = (Resolve-Path $Dir).Path
$tool = Join-Path $Dir ".studio-stud-tool"
New-Item -ItemType Directory -Force "$tool\bin","$tool\plugin" | Out-Null

Write-Host "Studio Stud -> $tool"
$latest = Invoke-RestMethod "$PagesBase/latest.json"
Write-Host "Release: daemon $($latest.daemonVersion), plugin $($latest.pluginVersion)"

Invoke-WebRequest $latest.binaryUrl -OutFile "$tool\bin\studio-stud.exe"
Invoke-WebRequest $latest.pluginUrl -OutFile "$tool\plugin\StudioStud.plugin.lua"

$now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
[ordered]@{
    daemonVersion            = $latest.daemonVersion
    pluginVersion            = $latest.pluginVersion
    protocolVersion          = $latest.protocolVersion
    minPluginProtocolVersion = $latest.minPluginProtocolVersion
    minDaemonProtocolVersion = $latest.minDaemonProtocolVersion
    source                   = "https://github.com/tyleradams2002/studio-stud"
    installedAt              = $now
} | ConvertTo-Json | Set-Content "$tool\version.json" -Encoding utf8

# --- Root launchers (.\studio-stud) ---
$launcherPs1 = @'
$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
$StudioStudExe = Join-Path $Root ".studio-stud-tool/bin/studio-stud.exe"
if (-not (Test-Path -LiteralPath $StudioStudExe)) {
    Write-Error "Studio Stud executable not found: $StudioStudExe. Reinstall with: irm https://tyleradams2002.github.io/studio-stud/install.ps1 | iex"
    exit 1
}
$ExitCode = 0
Push-Location -LiteralPath $Root
try {
    [string[]]$PassArgs = @($args | ForEach-Object {
        if ($_ -is [string] -and $_.Contains('"')) { '"' + ($_ -replace '"', '\"') + '"' } else { [string]$_ }
    })
    & $StudioStudExe @PassArgs
    $ExitCode = $LASTEXITCODE
} finally { Pop-Location }
exit $ExitCode
'@
Set-Content (Join-Path $Dir "studio-stud.ps1") $launcherPs1 -Encoding utf8

$launcherCmd = @'
@echo off
setlocal
set "ROOT=%~dp0"
set "STUDIO_STUD_EXE=%ROOT%.studio-stud-tool\bin\studio-stud.exe"
if not exist "%STUDIO_STUD_EXE%" (
    echo Studio Stud executable not found: "%STUDIO_STUD_EXE%" 1>&2
    exit /b 1
)
pushd "%ROOT%" >nul
"%STUDIO_STUD_EXE%" %*
set "STUDIO_STUD_EXIT=%ERRORLEVEL%"
popd >nul
exit /b %STUDIO_STUD_EXIT%
'@
Set-Content (Join-Path $Dir "studio-stud.cmd") $launcherCmd -Encoding ascii

# --- Starter policy (least privilege) ---
$policyDir = Join-Path $Dir ".studio-stud"
$policyPath = Join-Path $policyDir "policy.json"
if (-not (Test-Path $policyPath)) {
    New-Item -ItemType Directory -Force $policyDir | Out-Null
    [ordered]@{
        version                  = 1
        allowedPlaceIds          = @()
        allowedWritePaths        = @()
        requireGeneratedHeaderPaths = @()
        maxPatchBytes            = 1048576
        maxPatchItems            = 500
        maxDeleteCount           = 50
    } | ConvertTo-Json | Set-Content $policyPath -Encoding utf8
    Write-Host "Wrote starter policy: .studio-stud/policy.json (allowlist empty; edit before enabling writes)"
}

# --- Optional AI workflow rule + command ---
if ($WithCursorRule) {
    New-Item -ItemType Directory -Force "$Dir\.cursor\rules","$Dir\.cursor\commands" | Out-Null
    Invoke-WebRequest "$RawBase/consumer-template/.cursor/rules/studio-stud.mdc" -OutFile "$Dir\.cursor\rules\studio-stud.mdc"
    Invoke-WebRequest "$RawBase/consumer-template/.cursor/commands/studio-stud.md" -OutFile "$Dir\.cursor\commands\studio-stud.md"
    Write-Host "Installed .cursor/rules/studio-stud.mdc + .cursor/commands/studio-stud.md"
}

Write-Host ""
Write-Host "Done. Next:"
Write-Host "  1) Add '.studio-stud-tool/' to .gitignore if you don't want to commit the binary."
Write-Host "  2) In Studio: enable HTTP requests, load .studio-stud-tool/plugin/StudioStud.plugin.lua"
Write-Host "  3) .\studio-stud doctor   then   .\studio-stud serve   (separate terminal)   then   .\studio-stud capture"
