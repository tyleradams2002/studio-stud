# Post-soak log analyzer for tick-protocol Phase 6.
# Parses daemon.log and asserts steady-state is delta-dominated (not periodic full rebaseline).
# Run after a long Studio edit session with Live capture enabled.

param(
    [string]$LogPath = "$env:LOCALAPPDATA\StudioStud\logs\daemon.log",
    [int]$TailLines = 5000,
    [double]$MaxBulkRatio = 0.15,
    [string]$DaemonUrl = "http://127.0.0.1:31878/studio-stud/ping"
)

$ErrorActionPreference = "Stop"

function Write-Section {
    param([string]$Msg)
    Write-Host ""
    Write-Host "=== $Msg ===" -ForegroundColor Cyan
}

if (-not (Test-Path $LogPath)) {
    throw "Log not found: $LogPath (run a soak session first)"
}

Write-Section "Load log tail ($TailLines lines)"
$lines = @(Get-Content $LogPath -Tail $TailLines)

$tickHttp = @($lines | Where-Object { $_ -match '\[http\].*POST /studio-stud/tick' })
$tickEmpty = @($lines | Where-Object { $_ -match '\[http\].*POST /studio-stud/tick.*"ops":\{"upserted":\[\],"removed":\[\]\}' })
$liveDelta = @($lines | Where-Object { $_ -match '\[live-delta\]' })
$materialize = @($lines | Where-Object { $_ -match '\[telemetry\].*materialize|\[capture\].*materialize|materialize_ingest' })
$driftEvents = @($lines | Where-Object { $_ -match '\[drift\]' })
$bulkStart = @($lines | Where-Object { $_ -match 'POST /studio-stud/tick/bulk/start' })

$tickCount = $tickHttp.Count
$deltaCount = $liveDelta.Count
$bulkCount = $bulkStart.Count
$matCount = $materialize.Count
$driftCount = $driftEvents.Count

Write-Section "Traffic summary (log tail)"
Write-Host "tick POST requests:     $tickCount"
Write-Host "tick empty/cheap hints: $($tickEmpty.Count)"
Write-Host "live-delta apply lines: $deltaCount"
Write-Host "tick/bulk/start:        $bulkCount"
Write-Host "materialize telemetry:  $matCount"
Write-Host "drift events:           $driftCount"

Write-Section "Drift telemetry"
if ($driftCount -eq 0) {
    Write-Host "No drift events in tail (good for steady edit, or soak too short)."
}
else {
    $driftEvents | ForEach-Object { Write-Host $_ }
}

try {
    $ping = Invoke-RestMethod $DaemonUrl -TimeoutSec 3
    if ($ping.driftTelemetry) {
        Write-Host ""
        Write-Host "Daemon ping driftTelemetry (cumulative, in-memory):"
        $ping.driftTelemetry | ConvertTo-Json -Depth 4 | Write-Host
    }
}
catch {
    Write-Host "Daemon ping unavailable (driftTelemetry requires running serve): $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Section "Assertions"
$failures = @()

if ($tickCount -lt 10) {
    $failures += "Expected >=10 tick POST lines in tail (got $tickCount) - soak may be too short"
}

if ($bulkCount -gt 0 -and $tickCount -gt 0) {
    $bulkRatio = $bulkCount / $tickCount
    Write-Host "bulk/tick ratio: $([math]::Round($bulkRatio, 3)) (max $MaxBulkRatio)"
    if ($bulkRatio -gt $MaxBulkRatio) {
        $failures += "bulk/tick ratio $bulkRatio exceeds $MaxBulkRatio - possible periodic full-rebaseline pattern"
    }
}

if ($matCount -gt 5) {
    $failures += "materialize telemetry count $matCount > 5 - investigate unexpected full rebaselines"
}

if ($deltaCount -eq 0 -and $tickCount -gt 50) {
    Write-Host "NOTE: no [live-delta] lines - tick path may log under [http] only (protocol v2)." -ForegroundColor Yellow
}

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "SOAK ANALYSIS FAILED:" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host ""
Write-Host "SOAK ANALYSIS PASSED" -ForegroundColor Green
Write-Host "Log: $LogPath"
