# ============================================================
# Fabriq LAN-Prep - Revert-LanMigration
# Restores the network configuration captured by Prepare-
# LanMigration and (for target role) removes the SMB share.
# Comments and console output are English per project policy.
# ============================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SnapshotPath,

    [Parameter(Mandatory = $false)]
    [string]$ProfilePath,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$script:LanPrepRoot = $PSScriptRoot
$script:RepoRoot    = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

if (-not $ProfilePath) {
    $ProfilePath = Join-Path $script:RepoRoot 'backuper\data\migration_profile.json'
}

. (Join-Path $script:LanPrepRoot 'lib\network_config.ps1')
. (Join-Path $script:LanPrepRoot 'lib\share_setup.ps1')
. (Join-Path $script:LanPrepRoot 'lib\rollback_snapshot.ps1')

function Test-LanPrepIsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-LanPrepIsAdmin)) {
    Write-Host "[FATAL] Administrator privileges are required." -ForegroundColor Red
    exit 1
}

try {
    $snapshot = Read-RollbackSnapshot -Path $SnapshotPath
}
catch {
    Write-Host ""
    Write-Host "[FATAL] Failed to read snapshot file: $SnapshotPath" -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}

# Optional: load the migration profile to know the share name we may need to remove.
$migProfile = $null
if (Test-Path -LiteralPath $ProfilePath) {
    try {
        $migProfile = Get-Content -LiteralPath $ProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Host "[warn] Failed to parse profile (continuing with snapshot-only revert): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# Pre-flight: warn if the snapshot's interfaceAlias no longer exists. We
# don't abort because revert may still be partially useful (DNS reset etc.),
# but the operator should know.
try {
    $null = Get-NetAdapter -Name $snapshot.interfaceAlias -ErrorAction Stop
}
catch {
    Write-Host ""
    Write-Host "[warn] Adapter '$($snapshot.interfaceAlias)' (recorded in snapshot) is not present on this PC." -ForegroundColor Yellow
    Write-Host "       The snapshot may have been captured on a different machine, or the adapter was renamed." -ForegroundColor Yellow
    Write-Host "       Available adapters:" -ForegroundColor Yellow
    try {
        Get-NetAdapter | Sort-Object Name | ForEach-Object {
            Write-Host ("         - {0,-30}  Status={1,-12}  Media={2}" -f $_.Name, $_.Status, $_.MediaConnectState) -ForegroundColor Cyan
        }
    } catch {}
    Write-Host ""
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Fabriq LAN-Prep  -  Revert" -ForegroundColor Cyan
Write-Host "  Snapshot role : $($snapshot.role)" -ForegroundColor Cyan
Write-Host "  Captured at   : $($snapshot.capturedAt)" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "[plan] interface alias  : $($snapshot.interfaceAlias)"
Write-Host "[plan] restore mode     : $(if ($snapshot.dhcpEnabled) {'DHCP'} else {'Static'})"
if (-not $snapshot.dhcpEnabled) {
    foreach ($a in $snapshot.ipAddresses) {
        Write-Host "[plan]   IP             : $($a.address) / $($a.prefixLength)"
    }
    Write-Host "[plan]   gateway        : $(if ($snapshot.defaultGateway) { $snapshot.defaultGateway } else { '(none)' })"
    Write-Host "[plan]   DNS            : $(if ($snapshot.dnsServers -and $snapshot.dnsServers.Count -gt 0) { $snapshot.dnsServers -join ', ' } else { '(none)' })"
}
Write-Host "[plan] network category : $(if ($snapshot.networkCategory) { $snapshot.networkCategory } else { '(unchanged)' })"
$willRemoveShare = ($snapshot.role -eq 'target' -and $null -ne $migProfile -and $migProfile.share.shareName -and $migProfile.rollback.removeShare)
if ($willRemoveShare) {
    Write-Host "[plan] remove share     : $($migProfile.share.shareName)"
}
Write-Host ""

if (-not $Force) {
    $confirm = Read-Host "Revert to the above state? (y/N)"
    if ($confirm -notmatch '^[Yy]$') {
        Write-Host "[abort] User cancelled." -ForegroundColor Yellow
        exit 0
    }
}

# Steps wrapped in try/catch so that an EXE-launched conhost window stays
# open on terminating errors (e.g. netsh failure).
try {

Write-Host ""
Write-Host "[step] restoring network configuration..." -ForegroundColor Cyan
Restore-MigrationNetworkConfig -Snapshot $snapshot
Write-Host "[ok] network restored" -ForegroundColor Green

if ($willRemoveShare) {
    Write-Host ""
    Write-Host "[step] removing migration share..." -ForegroundColor Cyan
    Remove-MigrationShare -ShareName $migProfile.share.shareName
}

# v0.34.0: drop a revert-completion marker next to the snapshot. Revert
# intentionally does NOT delete the LAN-Prep folder / snapshot (see the
# note below), so Fabriq BackUper's Cleanup view uses this marker as the
# trustworthy signal that the folder is now safe to bulk-delete. Share
# removal and IP restoration are NOT reliable signals (removeShare is
# conditional and the snapshot persists). ASCII-only per CLAUDE.md rule 5.
try {
    $revertDir = Split-Path -Parent $SnapshotPath
    if ($revertDir -and (Test-Path -LiteralPath $revertDir)) {
        $revertDone = [ordered]@{
            schemaVersion  = 1
            manifestType   = 'fabriq-lanprep-revert-done'
            revertedAt     = (Get-Date).ToString('o')
            role           = "$($snapshot.role)"
            interfaceAlias = "$($snapshot.interfaceAlias)"
            revertedOnHost = "$env:COMPUTERNAME"
        }
        $rdPath = Join-Path $revertDir '_revert_done.json'
        $rdJson = $revertDone | ConvertTo-Json -Depth 5
        $rdUtf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($rdPath, $rdJson, $rdUtf8NoBom)
        Write-Host "[ok] revert marker written: $rdPath" -ForegroundColor Green
    }
}
catch {
    Write-Host "[warn] could not write revert marker: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Revert complete." -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
if ($snapshot.role -eq 'target' -and $migProfile -and $migProfile.share.localPath) {
    Write-Host "[note] local path '$($migProfile.share.localPath)' was NOT removed."
    Write-Host "       Delete it manually once backup data is no longer needed."
    Write-Host ""
}

}
catch {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Red
    Write-Host "[FATAL] Revert failed." -ForegroundColor Red
    Write-Host "================================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "Error message:" -ForegroundColor Yellow
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Stack trace:" -ForegroundColor DarkGray
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}
