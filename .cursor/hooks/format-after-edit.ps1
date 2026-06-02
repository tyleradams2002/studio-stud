#Requires -Version 7.0
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Cursor passes the hook payload as JSON on stdin (file_path, hook_event_name, ...).
$payload = $input | Out-String
if ([string]::IsNullOrWhiteSpace($payload)) { return }

try { $event = $payload | ConvertFrom-Json } catch { return }
$path = $event.file_path
if (-not $path -or -not (Test-Path -LiteralPath $path)) { return }

switch -Regex ($path) {
    '\.rs$' {
        if (Get-Command rustfmt -ErrorAction SilentlyContinue) { rustfmt "$path" }
    }
    '\.luau?$' {
        if (Get-Command stylua -ErrorAction SilentlyContinue) { stylua "$path" }
    }
    default { }
}
