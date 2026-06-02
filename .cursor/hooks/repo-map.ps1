#Requires -Version 7.0
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# beforeSubmitPrompt hook: keep docs/repo-map.md fresh. Must never block prompt
# submission, so any failure (missing binary, locked file, etc.) is a silent
# no-op. The committed map is used until the next successful run.
try {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)  # .cursor/hooks -> .cursor -> repo root
    $exe = Join-Path $root 'bin/studio-stud.exe'
    if (-not (Test-Path -LiteralPath $exe)) { return }
    Push-Location $root
    try {
        & $exe repo-map --if-stale --quiet 2>$null | Out-Null
    } finally {
        Pop-Location
    }
} catch {
    # Intentionally swallow: a repo-map refresh must not interrupt the user.
}
