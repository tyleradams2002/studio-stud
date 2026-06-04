# Final live-capture validation helper (Fishers Life / dev install).
# Run from any directory. Requires: daemon on 127.0.0.1:31878, Studio plugin connected + Live.

param(
    [string]$StudioStud = "$env:LOCALAPPDATA\StudioStud\bin\studio-stud.exe",
    [string]$ProjectKey = "FishersLife",
    [string]$PlaceId = "109595751023912",
    [int]$RevWaitSeconds = 12,
    [string]$TestName = ""
)

$ErrorActionPreference = "Stop"
$LogPath = "$env:LOCALAPPDATA\StudioStud\logs\daemon.log"

if (-not $TestName) {
    $TestName = "StudioStudLiveTest_{0:yyyyMMdd_HHmmss}" -f (Get-Date)
}

function Write-Section {
    param([string]$Msg)
    Write-Host ""
    Write-Host "=== $Msg ===" -ForegroundColor Cyan
}

function Get-DaemonPing {
    try {
        return Invoke-RestMethod "http://127.0.0.1:31878/studio-stud/ping" -TimeoutSec 3
    }
    catch {
        return $null
    }
}

function Get-LiveState {
    # status emits JSON by default (no --markdown); --json accepted on newer builds only
    $raw = & $StudioStud status 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "studio-stud status failed: $raw"
    }
    $j = $raw | ConvertFrom-Json
    $place = $j.places | Where-Object { $_.place -eq $PlaceId } | Select-Object -First 1
    if (-not $place -or -not $place.liveState) {
        throw "No liveState for place $PlaceId. Is the widget on Live after baseline?"
    }
    [PSCustomObject]@{
        Revision      = [int64]$place.liveState.revision
        InstanceCount = [int64]$place.liveState.instanceCount
        CaptureId     = $place.liveState.captureId
        UpdatedAtUtc  = $place.liveState.updatedAtUtc
    }
}

function Invoke-QueryCount {
    param([string]$Name)
    $raw = & $StudioStud query $PlaceId --name $Name --count-only 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "query failed: $raw"
    }
    ($raw | ConvertFrom-Json).total
}

function Wait-RevBump {
    param([int64]$BeforeRev, [int]$TimeoutSec)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 800
        $now = (Get-LiveState).Revision
        if ($now -gt $BeforeRev) {
            return $now
        }
    }
    return $BeforeRev
}

function Get-RecentLiveDeltaLines {
    param([int]$Tail = 40)
    if (-not (Test-Path $LogPath)) {
        return @()
    }
    Get-Content $LogPath -Tail $Tail | Where-Object { $_ -match '\[live-delta\]' }
}

Write-Section "Prerequisites"
if (-not (Test-Path $StudioStud)) {
    throw "Missing binary: $StudioStud"
}
$ping = Get-DaemonPing
if (-not $ping) {
    throw "Daemon not reachable at http://127.0.0.1:31878/studio-stud/ping. Start: studio-stud serve"
}
Write-Host "Daemon: $($ping.version) protocol $($ping.protocolVersion) channel $($ping.channel)"

$before = Get-LiveState
Write-Host "Baseline: rev=$($before.Revision) instances=$($before.InstanceCount) capture=$($before.CaptureId)"
Write-Host "Test object name (create in Studio under Workspace): $TestName"
Write-Host ""
Write-Host "IN STUDIO (plugin must show Live):"
Write-Host "  1) Insert a Part named exactly: $TestName"
Write-Host "  2) Press Enter here when done"
Read-Host | Out-Null

Write-Section "Test A - Add (live)"
$rev0 = $before.Revision
$rev1 = Wait-RevBump -BeforeRev $rev0 -TimeoutSec $RevWaitSeconds
$q1 = Invoke-QueryCount -Name $TestName
Write-Host "rev: $rev0 -> $rev1 (bump expected: $($rev1 -gt $rev0))"
Write-Host "query --name count: $q1 (expected: 1)"
Get-RecentLiveDeltaLines | ForEach-Object { Write-Host $_ }
if (($rev1 -le $rev0) -or ($q1 -ne 1)) {
    Write-Host "FAIL add" -ForegroundColor Red
}
else {
    Write-Host "PASS add" -ForegroundColor Green
}

Write-Host ""
Write-Host "IN STUDIO: Rename the Part to: ${TestName}_Renamed"
$revBeforeRename = (Get-LiveState).Revision
Write-Host "(rev before rename: $revBeforeRename - press Enter after rename)"
Read-Host | Out-Null

Write-Section "Test B - Rename (live)"
$rev2 = Wait-RevBump -BeforeRev $revBeforeRename -TimeoutSec $RevWaitSeconds
$qOld = Invoke-QueryCount -Name $TestName
$qNew = Invoke-QueryCount -Name "${TestName}_Renamed"
Write-Host "rev: $revBeforeRename -> $rev2 (bump: $($rev2 -gt $revBeforeRename))"
Write-Host "old name count: $qOld (expected 0) | new name count: $qNew (expected 1)"
Get-RecentLiveDeltaLines | Select-Object -Last 6 | ForEach-Object { Write-Host $_ }
if (($qOld -ne 0) -or ($qNew -ne 1)) {
    Write-Host "FAIL rename" -ForegroundColor Red
}
else {
    Write-Host "PASS rename" -ForegroundColor Green
}

Write-Host ""
Write-Host "IN STUDIO: Delete the Part (${TestName}_Renamed)"
$revBeforeDelete = (Get-LiveState).Revision
$countBeforeDelete = (Get-LiveState).InstanceCount
Write-Host "(rev before delete: $revBeforeDelete - press Enter after delete)"
Read-Host | Out-Null

Write-Section "Test C - Delete (live vs verify)"
$rev3 = Wait-RevBump -BeforeRev $revBeforeDelete -TimeoutSec $RevWaitSeconds
$qDel = Invoke-QueryCount -Name "${TestName}_Renamed"
$stateAfter = Get-LiveState
$logTail = @(Get-RecentLiveDeltaLines -Tail 15)
Write-Host "rev: $revBeforeDelete -> $rev3 (bump: $($rev3 -gt $revBeforeDelete))"
Write-Host "instances: $countBeforeDelete -> $($stateAfter.InstanceCount) (informational; query is authoritative)"
Write-Host "query deleted name count: $qDel (expected 0)"
$logTail | ForEach-Object { Write-Host $_ }
$logShowsRemove = ($logTail | Where-Object { $_ -match 'removed=1|removed id=' }).Count -gt 0
$revBump = $rev3 -gt $revBeforeDelete
# Pass if DB has no ghost row and logs show a live delete (rev bump or removed= in APPLY)
$liveDeleteOk = ($qDel -eq 0) -and ($revBump -or $logShowsRemove)
if ($liveDeleteOk) {
    Write-Host "PASS delete (live path)" -ForegroundColor Green
}
else {
    Write-Host "FAIL delete - wait ~30s for drift verify, then re-run query --count-only" -ForegroundColor Yellow
}

Write-Section "Summary"
Write-Host "Test marker: $TestName"
Write-Host "Log: $LogPath"
Write-Host "Full status: studio-stud status"
