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
    3. Launches dist/studio-stud-setup.exe  (the real binary) with --install, or --install --no-gui for headless.
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

# ---------- 1. Build ----------
Write-Host "[1/4] Building workspace (debug)..."
cargo build --workspace 2>&1 | Where-Object { $_ -notmatch '^\s*Compiling' } | Write-Host
if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }

$SetupExe = Join-Path $Root 'target\debug\studio-stud-setup.exe'
if (-not (Test-Path $SetupExe)) {
    throw "studio-stud-setup.exe not found at $SetupExe after build"
}

# ---------- 2. Optional clean ----------
if ($CleanFirst) {
    $installRoot = Join-Path $env:LOCALAPPDATA 'studio-stud'
    Write-Host "[2/4] CleanFirst: removing $installRoot ..."
    if (Test-Path $installRoot) {
        # Gracefully stop the daemon first if it's running
        $lockFile = Join-Path $installRoot 'daemon.lock'
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
        Write-Host "    Removed $installRoot"
    }
    # Remove PATH shim if present
    $shimDir = Join-Path $env:LOCALAPPDATA 'studio-stud-bin'
    if (Test-Path $shimDir) {
        Remove-Item $shimDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "    Removed PATH shim dir $shimDir"
    }
} else {
    Write-Host "[2/4] Skipping clean (use -CleanFirst for a fully fresh test)"
}

# ---------- 3. Launch installer ----------
$args_ = if ($Headless) { @('--install', '--no-gui') } else { @('--install') }
Write-Host "[3/4] Launching: $SetupExe $args_"
Write-Host "      (This is the same binary a user would download — testing the real install path)"
Write-Host ""
& $SetupExe @args_
$exitCode = $LASTEXITCODE

# ---------- 4. Report ----------
Write-Host ""
if ($exitCode -eq 0) {
    Write-Host "[4/4] Installer exited cleanly (exit 0)."
    Write-Host "      studio-stud should now be in your PATH (open a new terminal to verify)."
    Write-Host "      Run: studio-stud --version"
    Write-Host "      Run: studio-stud-setup health"
} else {
    Write-Host "[4/4] Installer exited with code $exitCode."
}
