# ============================================================
# Fabriq LAN-Prep - Prepare-LanMigration
# Configures static IP (both roles) and SMB share (target role)
# from a shared migration_profile.json. Saves a rollback
# snapshot before applying any change.
# Comments and console output are English per project policy.
# ============================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('source', 'target')]
    [string]$Role,

    [Parameter(Mandatory = $false)]
    [string]$ProfilePath,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Resolve paths.
$script:LanPrepRoot = $PSScriptRoot
$script:RepoRoot    = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

if (-not $ProfilePath) {
    $ProfilePath = Join-Path $script:RepoRoot 'backuper\data\migration_profile.json'
}

# Load libs.
. (Join-Path $script:LanPrepRoot 'lib\network_config.ps1')
. (Join-Path $script:LanPrepRoot 'lib\share_setup.ps1')
. (Join-Path $script:LanPrepRoot 'lib\firewall.ps1')
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

if (-not (Test-Path -LiteralPath $ProfilePath)) {
    Write-Host "[FATAL] Profile not found: $ProfilePath" -ForegroundColor Red
    Write-Host "        Copy backuper\data\migration_profile.sample.json to migration_profile.json and edit it." -ForegroundColor DarkGray
    exit 1
}

$migProfile = Get-Content -LiteralPath $ProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json

if ($migProfile.schemaVersion -ne 1) {
    Write-Host "[FATAL] Unsupported schemaVersion: $($migProfile.schemaVersion). Expected 1." -ForegroundColor Red
    exit 1
}

# Reject profiles that accidentally include a password field (defence-in-depth).
$jsonText = Get-Content -LiteralPath $ProfilePath -Raw -Encoding UTF8
if ($jsonText -match '"\s*password\s*"') {
    Write-Host "[FATAL] Profile contains a 'password' key. Passwords must not be stored in JSON." -ForegroundColor Red
    exit 1
}

$netConfig = if ($Role -eq 'source') { $migProfile.network.source } else { $migProfile.network.target }

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Fabriq LAN-Prep  -  Role: $Role" -ForegroundColor Cyan
Write-Host "  Profile: $($migProfile.profileName)" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "[plan] interface alias  : $($netConfig.interfaceAlias)"
Write-Host "[plan] new IP address   : $($netConfig.ipAddress) / $($netConfig.prefixLength)"
Write-Host "[plan] new gateway      : $(if ($netConfig.gateway) { $netConfig.gateway } else { '(none)' })"
Write-Host "[plan] new DNS servers  : $(if ($netConfig.dnsServers -and $netConfig.dnsServers.Count -gt 0) { $netConfig.dnsServers -join ', ' } else { '(none)' })"
Write-Host "[plan] network category : $(if ($migProfile.network.setNetworkCategoryPrivate) {'Private'} else {'(unchanged)'})"
Write-Host "[plan] firewall sharing : $(if ($migProfile.network.enableFileAndPrinterSharing) {'enable File and Printer Sharing'} else {'(unchanged)'})"
if ($Role -eq 'target') {
    Write-Host "[plan] share name       : $($migProfile.share.shareName)"
    Write-Host "[plan] local path       : $($migProfile.share.localPath)"
    Write-Host "[plan] SMB ACL          : $(($migProfile.share.smbPermissions | ForEach-Object { "$($_.principal):$($_.access)" }) -join ', ')"
    Write-Host "[plan] NTFS ACL         : $(($migProfile.share.ntfsPermissions | ForEach-Object { "$($_.principal):$($_.access)" }) -join ', ')"
}
Write-Host "[plan] snapshot path    : $($migProfile.rollback.snapshotPath)"
Write-Host ""
Write-Host "WARNING: This changes the network configuration of THIS PC." -ForegroundColor Yellow
Write-Host "         If you are connected via Remote Desktop / SSH, you may lose access." -ForegroundColor Yellow
Write-Host ""

if (-not $Force) {
    $confirm = Read-Host "Apply the above changes? (y/N)"
    if ($confirm -notmatch '^[Yy]$') {
        Write-Host "[abort] User cancelled." -ForegroundColor Yellow
        exit 0
    }
}

# Step 1: snapshot current config.
Write-Host ""
Write-Host "[step] capturing rollback snapshot..." -ForegroundColor Cyan
$snapshot = New-RollbackSnapshot -InterfaceAlias $netConfig.interfaceAlias -Role $Role
Save-RollbackSnapshot -Snapshot $snapshot -Path $migProfile.rollback.snapshotPath
Write-Host "[ok] snapshot saved: $($migProfile.rollback.snapshotPath)" -ForegroundColor Green

# Step 2: apply network config.
Write-Host ""
Write-Host "[step] applying network configuration..." -ForegroundColor Cyan
Set-MigrationNetworkConfig -Config $netConfig
Write-Host "[ok] IP $($netConfig.ipAddress)/$($netConfig.prefixLength) assigned to $($netConfig.interfaceAlias)" -ForegroundColor Green

# Step 3: network category + firewall (best-effort, won't abort on failure).
if ($migProfile.network.setNetworkCategoryPrivate) {
    Set-MigrationNetworkCategoryPrivate -InterfaceAlias $netConfig.interfaceAlias
}
if ($migProfile.network.enableFileAndPrinterSharing) {
    Enable-FileAndPrinterSharingRule
}

# Step 4: target-only - SMB share creation.
if ($Role -eq 'target') {
    Write-Host ""
    Write-Host "[step] creating SMB share..." -ForegroundColor Cyan
    New-MigrationShare -ShareConfig $migProfile.share
    Write-Host "[ok] share \\$env:COMPUTERNAME\$($migProfile.share.shareName) ready" -ForegroundColor Green
}

# Summary + next-step hints.
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Done." -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "[next] connect both PCs via direct LAN cable or shared hub."
if ($Role -eq 'source') {
    Write-Host "[next] on this (source) PC, launch Fabriq_BackUper.exe and choose Backup."
    Write-Host "[next] backup destination (target PC share): $($migProfile.backuper.backupRootUnc)"
}
else {
    Write-Host "[next] target share UNC: $($migProfile.backuper.backupRootUnc)"
    Write-Host "[next] on the source PC, run Prepare-LanMigration.ps1 -Role source."
    Write-Host "[next] later on this (target) PC, launch Fabriq_BackUper.exe and choose Restore."
}
Write-Host ""
Write-Host "[revert] when finished:"
Write-Host "         Revert-LanMigration.ps1 -SnapshotPath `"$($migProfile.rollback.snapshotPath)`""
Write-Host ""
