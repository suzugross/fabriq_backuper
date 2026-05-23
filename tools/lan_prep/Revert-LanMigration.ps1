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

$snapshot = Read-RollbackSnapshot -Path $SnapshotPath

# Optional: load the migration profile to know the share name we may need to remove.
$migProfile = $null
if (Test-Path -LiteralPath $ProfilePath) {
    $migProfile = Get-Content -LiteralPath $ProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json
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

Write-Host ""
Write-Host "[step] restoring network configuration..." -ForegroundColor Cyan
Restore-MigrationNetworkConfig -Snapshot $snapshot
Write-Host "[ok] network restored" -ForegroundColor Green

if ($willRemoveShare) {
    Write-Host ""
    Write-Host "[step] removing migration share..." -ForegroundColor Cyan
    Remove-MigrationShare -ShareName $migProfile.share.shareName
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
