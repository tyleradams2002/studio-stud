<#
  Local install test — simulates a fresh user install using your local build.
  Lets you test the full installer flow without a clean machine or a published release.

  Usage:
    .\scripts\install-local.ps1                  # run the installer GUI against your local build
    .\scripts\install-local.ps1 -CleanFirst       # wipe existing install root first (full fresh test)
    .\scripts\install-local.ps1 -Headless         # non-interactive CLI install (skips GUI)

  What it does:
    1. cargo build --workspace  (debug build, fast)
    2. Optionally removes %LOCALAPPDATA%\studio-stud  so the installer treats this as a fresh machine.
    3. Launches dist/studio-stud-setup.exe  (the real binary) with 'install', or 'install --no-gui' for headless.
    4. Prints the install log so you can see what happened.

  Notes:
    - CleanFirst removes %LOCALAPPDATA%\studio-stud and the PATH shim.
      It does NOT touch your Roblox plugins folder.
    - Run with -CleanFirst between test iterations to keep the test deterministic.
    - The installer defaults the install root to %LOCALAPPDATA%\studio-stud — the same default
      a new user would see, so you are testing the real default path.
#>
param(
    [switch]$CleanFirst,
    [switch]$Headless
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

# Re-launch as admin if not already elevated (installer requires it).
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Not running as administrator - re-launching elevated..."
    $argList = @("-ExecutionPolicy", "Bypass", "-File", $PSCommandPath)
    if ($CleanFirst) { $argList += "-CleanFirst" }
    if ($Headless)   { $argList += "-Headless" }
    Start-Process powershell -ArgumentList $argList -Verb RunAs -Wait
    exit $LASTEXITCODE
}

# ---------- 1. Build ----------
Write-Host "[1/4] Building workspace (debug)..."
cargo build --workspace
if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }

$SetupExe = Join-Path $Root 'target\debug\studio-stud-setup.exe'
if (-not (Test-Path $SetupExe)) {
    throw "studio-stud-setup.exe not found at $SetupExe after build"
}

# ---------- 2. Optional clean ----------
if ($CleanFirst) {
    $installRoot = Join-Path $env:LOCALAPPDATA 'Programs\StudioStud'
    Write-Host "[2/4] CleanFirst: removing $installRoot ..."
    if (Test-Path $installRoot) {
        $lockFile = Join-Path $env:LOCALAPPDATA 'StudioStud\daemon.lock'
        if (Test-Path $lockFile) {
            try {
                $lock = Get-Content $lockFile | ConvertFrom-Json
                if ($lock.port) {
                    Invoke-RestMethod "http://127.0.0.1:$($lock.port)/studio-stud/admin/shutdown" `
                        -Method Post -TimeoutSec 3 | Out-Null
                    Start-Sleep -Milliseconds 800
                }
            } catch {}
        }
        Remove-Item $installRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    # Clear the registry/config too so the installer treats this as a fresh machine.
    $configDir = Join-Path $env:LOCALAPPDATA 'StudioStud'
    if (Test-Path $configDir) { Remove-Item $configDir -Recurse -Force -ErrorAction SilentlyContinue }
} else {
    Write-Host "[2/4] Skipping clean (use -CleanFirst for a fully fresh test)"
}

# ---------- 3. Launch installer ----------
Write-Host "[3/4] Launching: $SetupExe install"
Write-Host "      (This is the same binary a user would download - testing the real install path)"
Write-Host ""
if ($Headless) {
    & $SetupExe install --silent
} else {
    & $SetupExe install
}
$exitCode = $LASTEXITCODE

# ---------- 4. Refresh PATH in this session, then report ----------
Write-Host ""

# Read the freshly-written user PATH from the registry and apply it to this
# session so verification commands work without opening a new terminal.
$userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
$machinePath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
$env:PATH = "$userPath;$machinePath"

if ($exitCode -eq 0) {
    Write-Host "[4/4] Installer exited cleanly (exit 0). PATH refreshed for this session."
    Write-Host ""
    Write-Host "Verifying..."
    $ssVer = & studio-stud --version 2>&1
    Write-Host "  studio-stud --version : $ssVer"
    $health = & studio-stud-setup health 2>&1
    $health | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host "[4/4] Installer exited with code $exitCode."
}
