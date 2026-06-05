# ============================================================
# Fabriq BackUper - Migration path resolver (v0.40.0)
#
# Single shared source of truth for the "local" operation model's derived
# paths. Used by BOTH the Backuper process (backuper/main.ps1) and the
# LAN-Prep processes (fabriq_lanprep.ps1 + tools/lan_prep/Prepare-LanMigration.ps1).
#
# Lives in a small dedicated lib (NOT common.ps1) on purpose: the lean
# Prepare-LanMigration.ps1 is intentionally common.ps1-free, so the resolver
# must have ZERO dependency on common.ps1 (base PowerShell only).
#
# Local operation model (migration_profile schemaVersion 2):
#   * The TARGET PC shares its OWN <BackuperRoot>\Backup folder.
#   * The SOURCE PC writes over the LAN into \\<target-ip>\<shareName>,
#     which lands in the target's <BackuperRoot>\Backup -- i.e. the share
#     IS the target's restore-source folder.
#   * The rollback snapshot stays on local disk OUTSIDE the shared Backup
#     folder so the captured network config is not exposed over SMB.
#
# Derivation (blank or the literal "<AUTO>" -> derived; any other literal
# value wins, so an operator can still override by hand):
#   share.localPath        : <AUTO> -> <BackuperRoot>\Backup
#   backuper.backupRootUnc  : <AUTO> -> \\<network.target.ipAddress>\<share.shareName>
#   rollback.snapshotPath   : <AUTO> -> <BackuperRoot>\_lanprep\_rollback_snapshot.json
#
# The function mutates the passed profile object in place AND returns it,
# so callers can use either style.
# ============================================================

function global:Resolve-MigrationPaths {
    [CmdletBinding()]
    param(
        # The parsed migration_profile object (PSCustomObject from ConvertFrom-Json).
        # NOTE: named $MigProfile, not $Profile, to avoid shadowing the
        # automatic $PROFILE variable (PowerShell is case-insensitive).
        [Parameter(Mandatory = $true)]$MigProfile,
        # The LOCAL machine's backuper root (the dir that contains 'Backup').
        [Parameter(Mandatory = $true)][string]$BackuperRoot
    )

    $backupDir = Join-Path $BackuperRoot 'Backup'

    # --- share.localPath: the folder the TARGET shares (= its own Backup
    # root, which is also where Restore discovers the incoming backup). ---
    if ($null -ne $MigProfile.share) {
        $lp = $MigProfile.share.localPath
        if ([string]::IsNullOrWhiteSpace($lp) -or ("$lp".Trim() -ieq '<AUTO>')) {
            $MigProfile.share.localPath = $backupDir
        }
    }

    # --- backuper.backupRootUnc: the SOURCE's destination = the target's
    # shared Backup folder over the LAN (\\<target-ip>\<shareName>). ---
    if ($null -ne $MigProfile.backuper) {
        $unc = $MigProfile.backuper.backupRootUnc
        if ([string]::IsNullOrWhiteSpace($unc) -or ("$unc".Trim() -ieq '<AUTO>')) {
            $targetIp = $null
            if ($null -ne $MigProfile.network -and $null -ne $MigProfile.network.target) {
                $targetIp = $MigProfile.network.target.ipAddress
            }
            $shareName = if ($null -ne $MigProfile.share) { $MigProfile.share.shareName } else { $null }
            if (-not [string]::IsNullOrWhiteSpace($targetIp) -and -not [string]::IsNullOrWhiteSpace($shareName)) {
                $MigProfile.backuper.backupRootUnc = "\\$targetIp\$shareName"
            }
        }
    }

    # --- rollback.snapshotPath: a LOCAL per-PC path OUTSIDE the shared
    # Backup folder. Save-RollbackSnapshot creates the parent dir. ---
    if ($null -ne $MigProfile.rollback) {
        $sp = $MigProfile.rollback.snapshotPath
        if ([string]::IsNullOrWhiteSpace($sp) -or ("$sp".Trim() -ieq '<AUTO>')) {
            $MigProfile.rollback.snapshotPath = Join-Path (Join-Path $BackuperRoot '_lanprep') '_rollback_snapshot.json'
        }
    }

    return $MigProfile
}
