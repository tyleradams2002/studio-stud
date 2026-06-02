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
