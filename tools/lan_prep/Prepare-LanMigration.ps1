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

    # v0.30.0: optional overrides from the LAN-Prep menu.
    # When the operator picked a NIC / host pair on the menu form,
    # fabriq_lanprep.ps1 forwards those choices here. Empty values
    # mean "fall back to profile values" (back-compat mode).
    [Parameter(Mandatory = $false)]
    [string]$InterfaceAlias,

    [Parameter(Mandatory = $false)]
    [string]$OldPCName,

    [Parameter(Mandatory = $false)]
    [string]$NewPCName,

    [switch]$Force,

    # v0.45.0 (P5): suppress the post-setup Backuper auto-launch
    # (network-only use / testing).
    [switch]$NoLaunchBackuper
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
. (Join-Path $script:LanPrepRoot 'lib\remote_desktop.ps1')   # v0.71.0 (t-0004 P2): RDP enable + state capture
. (Join-Path $script:LanPrepRoot 'lib\rollback_snapshot.ps1')
# v0.40.0: shared migration-path resolver (same function the Backuper
# process uses). It lives under backuper\lib so both processes share one
# source of truth; it has no common.ps1 dependency, so LAN-Prep stays lean.
. (Join-Path $script:RepoRoot 'backuper\lib\migration_paths.ps1')

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

if ($migProfile.schemaVersion -ne 2) {
    Write-Host "[FATAL] Unsupported schemaVersion: $($migProfile.schemaVersion). Expected 2." -ForegroundColor Red
    Write-Host "        (v0.40.0 hard-cut to the local operation model; re-create from migration_profile.sample.json)" -ForegroundColor DarkGray
    exit 1
}

# Reject profiles that accidentally include a password field (defence-in-depth).
$jsonText = Get-Content -LiteralPath $ProfilePath -Raw -Encoding UTF8
if ($jsonText -match '"\s*password\s*"') {
    Write-Host "[FATAL] Profile contains a 'password' key. Passwords must not be stored in JSON." -ForegroundColor Red
    exit 1
}

# v0.40.0: derive local-mode paths (share.localPath -> this PC's
# <backuper>\Backup ; backuper.backupRootUnc -> \\<target-ip>\<share> ;
# rollback.snapshotPath -> <backuper>\_lanprep\...). The share is then
# created at, and the next-step hints point at, the derived locations.
$script:LocalBackuperRoot = Join-Path $script:RepoRoot 'backuper'
$null = Resolve-MigrationPaths -MigProfile $migProfile -BackuperRoot $script:LocalBackuperRoot

$netConfig = if ($Role -eq 'source') { $migProfile.network.source } else { $migProfile.network.target }

# v0.30.0: optional interfaceAlias override from the menu form.
# Copy the PSObject first so the in-memory profile remains
# untouched (defensive; the profile object is not otherwise
# mutated, but ConvertFrom-Json returns shared sub-objects).
if (-not [string]::IsNullOrWhiteSpace($InterfaceAlias)) {
    $_overrideAlias = $InterfaceAlias
    $netConfig = $netConfig | Select-Object *
    $netConfig.interfaceAlias = $_overrideAlias
    Write-Host "[info] interfaceAlias overridden by menu selection: $_overrideAlias" -ForegroundColor DarkGray
}

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
if (-not [string]::IsNullOrWhiteSpace($OldPCName) -or -not [string]::IsNullOrWhiteSpace($NewPCName)) {
    $_hp = "{0} -> {1}" -f (
        $(if ([string]::IsNullOrWhiteSpace($OldPCName)) { '(unspecified)' } else { $OldPCName }),
        $(if ([string]::IsNullOrWhiteSpace($NewPCName)) { '(unspecified)' } else { $NewPCName })
    )
    Write-Host "  Host pair (hostlist): $_hp" -ForegroundColor Cyan
}
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "[plan] interface alias  : $($netConfig.interfaceAlias)"
Write-Host "[plan] new IP address   : $($netConfig.ipAddress) / $($netConfig.prefixLength)"
Write-Host "[plan] new gateway      : $(if ($netConfig.gateway) { $netConfig.gateway } else { '(none)' })"
Write-Host "[plan] new DNS servers  : $(if ($netConfig.dnsServers -and $netConfig.dnsServers.Count -gt 0) { $netConfig.dnsServers -join ', ' } else { '(none)' })"
Write-Host "[plan] network category : $(if ($migProfile.network.setNetworkCategoryPrivate) {'Private'} else {'(unchanged)'})"
Write-Host "[plan] firewall sharing : $(if ($migProfile.network.enableFileAndPrinterSharing) {'enable File and Printer Sharing'} else {'(unchanged)'})"
Write-Host "[plan] remote desktop   : $(if ($migProfile.network.enableRemoteDesktop) {'enable Remote Desktop (restored on revert)'} else {'(unchanged)'})"
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
    # v0.71.1 (t-0004 P3): capture the PRE-change state so Revert can restore this PC's
    # firewall posture. The snapshot carries 'fileAndPrinterSharing' ONLY when LAN-Prep
    # enabled the group (presence = changed -> Revert restores; was-OFF -> back OFF).
    $fpsBefore = Get-FileAndPrinterSharingState
    Enable-FileAndPrinterSharingRule
    $snapshot | Add-Member -NotePropertyName 'fileAndPrinterSharing' -NotePropertyValue ([pscustomobject]@{
        wasEnabled = [bool]$fpsBefore
    }) -Force
    Save-RollbackSnapshot -Snapshot $snapshot -Path $migProfile.rollback.snapshotPath
}

# v0.71.0 (t-0004 P2): opt-in Remote Desktop enable. Capture the PRE-change state,
# enable RDP, then record it in the snapshot. The snapshot carries an 'rdp' block
# ONLY when LAN-Prep enabled RDP, so Revert knows to restore exactly what it changed
# (was-OFF -> turn back OFF; was-ON -> leave ON). Best-effort; never aborts lan-prep.
# NOTE (one-shot assumption): like the network snapshot above, this captures the
# CURRENT state -- Prepare is meant to run once on a pristine machine. Re-running
# Prepare before Revert recaptures the now-enabled state as the "original" (same
# limitation the network IP snapshot already has); run Revert before re-preparing.
if ($migProfile.network.enableRemoteDesktop) {
    Write-Host ""
    Write-Host "[step] enabling Remote Desktop (opt-in)..." -ForegroundColor Cyan
    $rdpBefore = Get-RemoteDesktopState
    Enable-RemoteDesktopAccess
    $snapshot | Add-Member -NotePropertyName 'rdp' -NotePropertyValue ([pscustomobject]@{
        wasEnabled         = [bool]$rdpBefore.Enabled
        firewallWasEnabled = [bool]$rdpBefore.FirewallEnabled
    }) -Force
    Save-RollbackSnapshot -Snapshot $snapshot -Path $migProfile.rollback.snapshotPath
    Write-Host "[ok] Remote Desktop pre-state recorded in snapshot (for revert)" -ForegroundColor Green
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

# v0.45.0 (P5): hand off to Backuper. Set the role (and host, if the menu
# resolved one) in the environment -- these cross the EXE -> ps1 -> self-spawn
# boundary (same mechanism as FABRIQ_BACKUPER_SUBPROCESS), so Backuper opens
# the right screen (source->Backup, target->Restore) and pre-selects the host
# (P3 ROLE->mode, P4 COMPUTERNAME->host). The passphrase is NOT passed; the
# operator types it into Backuper's session form.
if (-not $NoLaunchBackuper) {
    $env:FABRIQ_BACKUPER_ROLE = $Role
    if (-not [string]::IsNullOrWhiteSpace($OldPCName)) {
        $env:FABRIQ_BACKUPER_AUTO_HOST = $OldPCName
    } else {
        $env:FABRIQ_BACKUPER_AUTO_HOST = $null
    }

    $backuperExe = Join-Path $script:RepoRoot 'Fabriq_BackUper.exe'
    $backuperPs1 = Join-Path $script:RepoRoot 'fabriq_backuper.ps1'
    Write-Host "[launch] starting Fabriq BackUper (role=$Role)..." -ForegroundColor Cyan
    try {
        if (Test-Path -LiteralPath $backuperExe) {
            Start-Process -FilePath $backuperExe -WorkingDirectory $script:RepoRoot
            Write-Host "[launch] Backuper launched. Enter the master passphrase in its window." -ForegroundColor Green
        }
        elseif (Test-Path -LiteralPath $backuperPs1) {
            Start-Process -FilePath 'powershell.exe' `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$backuperPs1`"") `
                -WorkingDirectory $script:RepoRoot
            Write-Host "[launch] Backuper launched (ps1 fallback). Enter the master passphrase in its window." -ForegroundColor Green
        }
        else {
            $modeWord = if ($Role -eq 'source') { 'Backup' } else { 'Restore' }
            Write-Host "[warn] Fabriq_BackUper.exe / fabriq_backuper.ps1 not found under $script:RepoRoot." -ForegroundColor Yellow
            Write-Host "       Launch Backuper manually and choose $modeWord." -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "[warn] Backuper auto-launch failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "       Launch Fabriq_BackUper.exe manually." -ForegroundColor Yellow
    }
    finally {
        # Clear from THIS process so a subsequent menu action does not carry a
        # stale role. The launched child already inherited an env snapshot at
        # Start-Process time, so clearing here does not affect it.
        $env:FABRIQ_BACKUPER_ROLE = $null
        $env:FABRIQ_BACKUPER_AUTO_HOST = $null
    }
    Write-Host ""
}

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

# v0.30.0: explicit exit 0 on the success path so the parent
# fabriq_lanprep.ps1 can rely on $LASTEXITCODE for its
# skip-Read-Host decision. Without this PowerShell leaves
# $LASTEXITCODE at whatever the last native call set it to
# (typically 0 from netsh, but the explicit return value is
# safer than relying on that side-effect).
exit 0
