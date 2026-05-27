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

# Pre-flight: verify the configured interfaceAlias actually exists on this
# PC. Without this check, Get-NetIPInterface inside New-RollbackSnapshot
# throws "No matching MSFT_NetIPInterface objects found" after the operator
# already pressed Y, and (in EXE-launched conhost) the window closes before
# the error is readable. Failing here lets us list available adapters and
# point at the profile field to fix.
$_aliasOk = $false
try {
    $null = Get-NetAdapter -Name $netConfig.interfaceAlias -ErrorAction Stop
    $_aliasOk = $true
} catch {
    # fall through to the reporting block below
}
if (-not $_aliasOk) {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Red
    Write-Host "[FATAL] interfaceAlias '$($netConfig.interfaceAlias)' not found on this PC." -ForegroundColor Red
    Write-Host "================================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "Available network adapters on this PC:" -ForegroundColor Yellow
    try {
        Get-NetAdapter | Sort-Object Name | ForEach-Object {
            Write-Host ("  - {0,-30}  Status={1,-12}  Media={2}" -f $_.Name, $_.Status, $_.MediaConnectState) -ForegroundColor Cyan
        }
    } catch {
        Write-Host "  (failed to enumerate adapters: $($_.Exception.Message))" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "Fix:" -ForegroundColor Yellow
    Write-Host "  1. Pick the adapter name you want to use from the list above" -ForegroundColor Yellow
    Write-Host "     (typical examples: 'Ethernet', 'Ethernet0', 'イーサネット')" -ForegroundColor Yellow
    Write-Host "  2. Edit  $ProfilePath" -ForegroundColor Yellow
    Write-Host "     and set both network.source.interfaceAlias and" -ForegroundColor Yellow
    Write-Host "     network.target.interfaceAlias to the chosen name." -ForegroundColor Yellow
    Write-Host "  3. Re-run Fabriq_LanPrep.exe (or this script)." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}

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

# Steps 1-4 are wrapped in try/catch so that any throw inside snapshot
# capture / netsh / share creation surfaces a readable error message and
# keeps the console open. Without this, an EXE-launched conhost window
# closed immediately on terminating errors and the operator never saw why.
try {

# Step 1: snapshot current config.
Write-Host ""
Write-Host "[step] capturing rollback snapshot..." -ForegroundColor Cyan
$snapshot = New-RollbackSnapshot -InterfaceAlias $netConfig.interfaceAlias -Role $Role
Save-RollbackSnapshot -Snapshot $snapshot -Path $migProfile.rollback.snapshotPath
Write-Host "[ok] snapshot saved: $($migProfile.rollback.snapshotPath)" -ForegroundColor Green

# v0.28.0: deploy KeepAwake utility into FabriqMigration so operator
# can suppress sleep on this PC independently (USB-shared backuper /
# staggered source/target rollout scenarios). Copy here -- after the
# snapshot is on disk, before any network change can fail -- so the
# files are present regardless of subsequent step outcomes.
$keepAwakeDest = Split-Path -Parent $migProfile.rollback.snapshotPath
$assetSrc      = Join-Path $script:LanPrepRoot 'assets'
try {
    Copy-Item -Path (Join-Path $assetSrc 'KeepAwake.bat') -Destination $keepAwakeDest -Force -ErrorAction Stop
    Copy-Item -Path (Join-Path $assetSrc 'KeepAwake.ps1') -Destination $keepAwakeDest -Force -ErrorAction Stop
    Write-Host "[ok] KeepAwake deployed to: $keepAwakeDest" -ForegroundColor Green
} catch {
    Write-Host "[warn] KeepAwake deploy failed: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "       (lan-prep continues; sleep suppression must be handled manually)" -ForegroundColor Yellow
}

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

# v0.28.0: auto-launch KeepAwake.bat now that all setup steps succeeded.
# This pops a separate console window that holds SetThreadExecutionState
# active for as long as it stays open. Operator can immediately start
# backup/restore in another window without remembering this step. We
# put it AFTER Step 4 (success path only) so failure paths (caught
# below) do not spawn an extra orphan window.
$keepAwakeBat = Join-Path $keepAwakeDest 'KeepAwake.bat'
if (Test-Path -LiteralPath $keepAwakeBat) {
    try {
        Start-Process -FilePath $keepAwakeBat -WindowStyle Normal
        Write-Host ""
        Write-Host "[ok] KeepAwake.bat auto-launched (sleep suppression active)" -ForegroundColor Green
    } catch {
        Write-Host ""
        Write-Host "[warn] KeepAwake auto-launch failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "       Double-click manually: $keepAwakeBat" -ForegroundColor Yellow
    }
} else {
    Write-Host ""
    Write-Host "[info] KeepAwake.bat not present at $keepAwakeBat -- sleep suppression skipped" -ForegroundColor DarkGray
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

}
catch {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Red
    Write-Host "[FATAL] LAN-Prep failed during apply." -ForegroundColor Red
    Write-Host "================================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "Error message:" -ForegroundColor Yellow
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Stack trace:" -ForegroundColor DarkGray
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Notes:" -ForegroundColor Yellow
    Write-Host "  - The rollback snapshot may have been written to:" -ForegroundColor Yellow
    Write-Host "      $($migProfile.rollback.snapshotPath)" -ForegroundColor Yellow
    Write-Host "    If yes, you can revert with:" -ForegroundColor Yellow
    Write-Host "      Revert-LanMigration.ps1 -SnapshotPath `"$($migProfile.rollback.snapshotPath)`"" -ForegroundColor Cyan
    Write-Host "  - Common causes:" -ForegroundColor Yellow
    Write-Host "      * netsh failed (run 'netsh interface ipv4 show config' to diagnose)" -ForegroundColor Yellow
    Write-Host "      * New-SmbShare rejected the path/permissions" -ForegroundColor Yellow
    Write-Host "      * NTFS ACL principal not resolvable" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}
