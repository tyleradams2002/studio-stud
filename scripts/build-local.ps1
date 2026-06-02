$ErrorActionPreference = "Stop"

$Cargo = if ($env:CARGO) {
    $env:CARGO
} elseif (Get-Command cargo -ErrorAction SilentlyContinue) {
    "cargo"
} else {
    Join-Path $env:USERPROFILE ".cargo/bin/cargo.exe"
}
$Root = Split-Path -Parent $PSScriptRoot
$BinDir = Join-Path $Root "bin"
$TargetDir = Join-Path $Root "target"
$BuiltExe = Join-Path $TargetDir "release/studio-stud.exe"
$RunnableExe = Join-Path $BinDir "studio-stud.exe"

Push-Location $Root
$PreviousCargoTargetDir = $env:CARGO_TARGET_DIR
try {
    $env:CARGO_TARGET_DIR = $TargetDir
    & $Cargo build --release
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    if (-not (Test-Path $BuiltExe)) {
        throw "Expected build output was not found: $BuiltExe"
    }

    New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
    if (Test-Path $RunnableExe) {
        try {
            Copy-Item -Force $BuiltExe $RunnableExe
        } catch {
            Write-Warning "Could not overwrite $RunnableExe (is studio-stud serve running?). Stop it, then rerun this script."
            Write-Host "Fresh build is at: $BuiltExe"
            exit 1
        }
    } else {
        Copy-Item -Force $BuiltExe $RunnableExe
    }
    Write-Host "Studio Stud executable ready: $RunnableExe"
    Write-Host "Run .\studio-stud serve from the repo root. Version is shown in the serve banner (see Cargo.toml)."
}
finally {
    $env:CARGO_TARGET_DIR = $PreviousCargoTargetDir
    Pop-Location
}
