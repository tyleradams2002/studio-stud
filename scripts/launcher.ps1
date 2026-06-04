$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot
# Resolve the canonical daemon first; fall back to a co-located legacy bundle.
$Canonical = Join-Path $env:LOCALAPPDATA "Programs\StudioStud\bin\studio-stud.exe"
$Legacy    = Join-Path $Root ".studio-stud-tool\bin\studio-stud.exe"
if (Test-Path -LiteralPath $Canonical) {
    $StudioStudExe = $Canonical
} elseif (Test-Path -LiteralPath $Legacy) {
    $StudioStudExe = $Legacy
} else {
    Write-Error "studio-stud daemon not found at $Canonical or $Legacy. Reinstall: irm https://tyleradams2002.github.io/studio-stud/install.ps1 | iex"
    exit 1
}

$ExitCode = 0
Push-Location -LiteralPath $Root
try {
    # Re-escape any args that contain literal double-quotes so they survive PowerShell's
    # external-process argument rewriting (single-quoted JSON strings lose their inner quotes
    # when passed through @args to a native exe).
    [string[]]$PassArgs = @($args | ForEach-Object {
        if ($_ -is [string] -and $_.Contains('"')) {
            '"' + ($_ -replace '"', '\"') + '"'
        } else {
            [string]$_
        }
    })
    & $StudioStudExe @PassArgs
    $ExitCode = $LASTEXITCODE
}
finally {
    Pop-Location
}

exit $ExitCode
