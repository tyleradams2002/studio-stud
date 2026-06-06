<#
.SYNOPSIS
  Atomically bump the daemon (Cargo.toml) and plugin (PLUGIN_VERSION) to the same version.

.EXAMPLE
  .\scripts\bump-version.ps1 0.4.13
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Version
)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version must be X.Y.Z (got '$Version')"
}
$root   = Split-Path -Parent $PSScriptRoot
$cargo  = Join-Path $root 'Cargo.toml'
$plugin = Join-Path $root 'plugin/StudioStud.plugin.lua'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Cargo.toml — replace the first package `version = "..."` (workspace block has none).
$cargoText = [System.IO.File]::ReadAllText($cargo)
$cargoRx   = [regex]'(?m)^version\s*=\s*"[^"]+"'
if ($cargoRx.Matches($cargoText).Count -lt 1) { throw "No package version line found in Cargo.toml" }
$cargoText = $cargoRx.Replace($cargoText, "version = `"$Version`"", 1)
[System.IO.File]::WriteAllText($cargo, $cargoText, $utf8NoBom)

# plugin — replace PLUGIN_VERSION = "..."
$pluginText = [System.IO.File]::ReadAllText($plugin)
$pluginRx   = [regex]'PLUGIN_VERSION\s*=\s*"[^"]+"'
if ($pluginRx.Matches($pluginText).Count -lt 1) { throw "No PLUGIN_VERSION line found in plugin" }
$pluginText = $pluginRx.Replace($pluginText, "PLUGIN_VERSION = `"$Version`"", 1)
[System.IO.File]::WriteAllText($plugin, $pluginText, $utf8NoBom)

Write-Host "Bumped Cargo.toml + plugin to $Version"
