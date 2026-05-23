# ============================================================
# Fabriq LAN-Prep - Entry Script (v0.24.2)
# Called from Fabriq_LanPrep.exe (admin-elevated via manifest).
# Shows a WinForms menu (lavender accent) with 4 actions:
#   - "移行先として設定"   -> Prepare-LanMigration.ps1 -Role target
#   - "移行元として設定"   -> Prepare-LanMigration.ps1 -Role source
#   - "元に戻す"           -> Revert-LanMigration.ps1 -SnapshotPath ...
#   - "終了"               -> exit
#
# v0.24.2 hardening:
#   - Start-Transcript writes every line of console output to
#     %TEMP%\fabriq_lanprep_<timestamp>.log so the operator can
#     still read the error even if the conhost window closes.
#   - Top-level trap catches any uncaught terminating error and
#     forces a Read-Host before exit.
#   - finally{} block guarantees Read-Host + Stop-Transcript even
#     on success path.
# Comments and console output are English per project policy.
# ============================================================

$ErrorActionPreference = 'Stop'

$script:RepoRoot       = $PSScriptRoot
$script:LanPrepRoot    = Join-Path $PSScriptRoot 'tools\lan_prep'
$script:BackuperLib    = Join-Path $PSScriptRoot 'backuper'

# ============================================================
# Transcript logging (the very first thing we do, so even
# Add-Type / dot-source failures get captured).
# ============================================================
$logDir = $env:TEMP
if ([string]::IsNullOrWhiteSpace($logDir) -or -not (Test-Path -LiteralPath $logDir)) {
    $logDir = $script:RepoRoot
}
$script:TranscriptPath = Join-Path $logDir ("fabriq_lanprep_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
$script:TranscriptStarted = $false
try {
    Start-Transcript -Path $script:TranscriptPath -Force | Out-Null
    $script:TranscriptStarted = $true
    Write-Host "[transcript] $script:TranscriptPath" -ForegroundColor DarkGray
}
catch {
    Write-Host "[warn] Start-Transcript failed (continuing without log): $($_.Exception.Message)" -ForegroundColor Yellow
}

# ============================================================
# Top-level trap: last-resort handler for any terminating error
# that escapes the try/catch blocks below. Without this, an EXE-
# launched conhost window closes the instant the script
# terminates, and the operator never gets to read the error.
# ============================================================
trap {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Red
    Write-Host "[TRAP] Uncaught terminating error reached the top-level trap:" -ForegroundColor Red
    Write-Host "================================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "Error message:" -ForegroundColor Yellow
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    if ($_.InvocationInfo -and $_.InvocationInfo.ScriptName) {
        Write-Host ""
        Write-Host "Location:" -ForegroundColor Yellow
        Write-Host ("  {0}:{1}" -f $_.InvocationInfo.ScriptName, $_.InvocationInfo.ScriptLineNumber) -ForegroundColor Red
        if ($_.InvocationInfo.Line) {
            Write-Host ("  >> " + $_.InvocationInfo.Line.Trim()) -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    Write-Host "Stack trace:" -ForegroundColor Yellow
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    Write-Host ""
    if ($script:TranscriptStarted) {
        Write-Host "Full log saved to:" -ForegroundColor Yellow
        Write-Host "  $script:TranscriptPath" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Please share that log file when reporting the issue." -ForegroundColor Yellow
    }
    Write-Host ""
    Read-Host "Press Enter to close this window"
    if ($script:TranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch {}
    }
    break
}

# ============================================================
# Main body wrapped in try/finally so the Read-Host always runs
# even on early-return paths (e.g. profile parse fatal).
# ============================================================
try {

# Pre-load WinForms assemblies.
try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing       -ErrorAction Stop
}
catch {
    Write-Host "[FATAL] Failed to load WinForms / Drawing assemblies: $($_.Exception.Message)" -ForegroundColor Red
    return
}

# Load backuper common.ps1 for Show-* helpers + theme constants.
try {
    . (Join-Path $script:BackuperLib 'common.ps1')
    . (Join-Path $script:BackuperLib 'lib\ui\theme.ps1')
}
catch {
    Write-Host "[FATAL] Failed to dot-source common.ps1 / theme.ps1: $($_.Exception.Message)" -ForegroundColor Red
    return
}

# Load the menu form.
try {
    . (Join-Path $script:LanPrepRoot 'lib\menu_form.ps1')
}
catch {
    Write-Host "[FATAL] Failed to load menu_form.ps1: $($_.Exception.Message)" -ForegroundColor Red
    return
}

# Read VERSION (shared with backuper - both live at repo root).
$script:LanPrepVersion = '0.0.0'
$_verFile = Join-Path $script:RepoRoot 'VERSION'
if (Test-Path $_verFile) {
    $script:LanPrepVersion = (Get-Content -Path $_verFile -Raw).Trim()
}

# Optional: read migration_profile.json so the menu can show a banner
# and Revert can resolve the snapshot path. Same load policy as backuper:
#   - file absent           -> $script:MigrationProfile = $null (silent)
#   - schemaVersion mismatch -> warning, ignore
#   - parse failure          -> warning, ignore
#   - 'password' key present -> FATAL (defence-in-depth)
$script:MigrationProfile = $null
$_profilePath = Join-Path $script:BackuperLib 'data\migration_profile.json'
if (Test-Path -LiteralPath $_profilePath) {
    try {
        $_jsonText = Get-Content -LiteralPath $_profilePath -Raw -Encoding UTF8
        if ($_jsonText -match '"\s*password\s*"') {
            Show-Error "Migration profile contains a 'password' key. Remove it before launching LAN-Prep."
            Show-Error "  Profile: $_profilePath"
            return
        }
        $_profileObj = $_jsonText | ConvertFrom-Json
        if ($_profileObj.schemaVersion -eq 1) {
            $script:MigrationProfile = $_profileObj
            Show-Info "Migration profile loaded: $($_profileObj.profileName)"
        }
        else {
            Show-Warning "Migration profile schemaVersion=$($_profileObj.schemaVersion) (expected 1). Profile ignored."
        }
    }
    catch {
        Show-Warning "Failed to parse migration profile (ignored): $($_.Exception.Message)"
    }
}

# Welcome banner.
Write-Host ""
Show-Separator
Write-Host "  Fabriq LAN-Prep  v$($script:LanPrepVersion)" -ForegroundColor Cyan
Write-Host "  LAN-direct migration prep: static IP + SMB share in one click" -ForegroundColor DarkGray
Show-Separator
Write-Host ""

# Show the menu (modal). Returns 'target' / 'source' / 'revert' / 'exit'.
$action = Show-LanPrepMenu `
    -Version          $script:LanPrepVersion `
    -MigrationProfile $script:MigrationProfile

switch ($action) {
    'target' {
        Show-Info "Running Prepare-LanMigration.ps1 -Role target ..."
        Write-Host ""
        & (Join-Path $script:LanPrepRoot 'Prepare-LanMigration.ps1') -Role target
    }
    'source' {
        Show-Info "Running Prepare-LanMigration.ps1 -Role source ..."
        Write-Host ""
        & (Join-Path $script:LanPrepRoot 'Prepare-LanMigration.ps1') -Role source
    }
    'revert' {
        if ($null -eq $script:MigrationProfile) {
            Show-Error "Cannot revert without a migration profile (snapshot path is read from profile.rollback.snapshotPath)."
            Show-Info  "Place a valid migration_profile.json at: $_profilePath"
        }
        else {
            $snapshotPath = $script:MigrationProfile.rollback.snapshotPath
            if ([string]::IsNullOrWhiteSpace($snapshotPath)) {
                Show-Error "profile.rollback.snapshotPath is empty."
            }
            elseif (-not (Test-Path -LiteralPath $snapshotPath)) {
                Show-Error "Snapshot file not found: $snapshotPath"
                Show-Info  "Run 'Prepare-LanMigration' first; it writes the snapshot on apply."
            }
            else {
                Show-Info "Running Revert-LanMigration.ps1 -SnapshotPath `"$snapshotPath`" ..."
                Write-Host ""
                & (Join-Path $script:LanPrepRoot 'Revert-LanMigration.ps1') -SnapshotPath $snapshotPath
            }
        }
    }
    'exit' {
        Show-Info "Menu cancelled. Exiting."
    }
    default {
        Show-Warning "Unknown menu action: $action"
    }
}

}
finally {
    Write-Host ""
    if ($script:TranscriptStarted) {
        Write-Host "Log saved: $script:TranscriptPath" -ForegroundColor DarkGray
    }
    Read-Host "Press Enter to close this window"
    if ($script:TranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch {}
    }
}
