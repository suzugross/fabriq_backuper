# ============================================================
# Fabriq BackUper - Main Body
# Adapted from apps/fabriq_backuper/fabriq_backuper.ps1
# (commit 7376805, 2026-05-19, v0.13.0) minus the self-spawn
# guard and the kernel/common.ps1 dot-source; both are replaced
# by the entry script + auto-discovery in this satellite-detached
# repo layout. All other behaviour is preserved verbatim.
# ============================================================

$ErrorActionPreference = 'Stop'

# Resolve repo paths.
#   $script:FabriqBackuperRoot - the backuper/ subdir containing this file
#   $script:RepoRoot           - the parent repo root (E:\fabriq_backuper)
$script:FabriqBackuperRoot = $PSScriptRoot
$script:RepoRoot           = Split-Path -Parent $PSScriptRoot

# Pre-load .NET assemblies needed by the WinForms UI BEFORE dot-sourcing
# any UI library (theme.ps1 also self-loads these defensively).
try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
}
catch {
    Write-Host "[FATAL] Failed to load WinForms / Drawing assemblies: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "        .NET Framework 4.x is required." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    return
}

# Load vendored common library (replaces fabriq main's kernel/common.ps1).
try {
    . (Join-Path $script:FabriqBackuperRoot 'common.ps1')
}
catch {
    Write-Host "[FATAL] Failed to dot-source backuper/common.ps1: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "        FabriqBackuperRoot resolved as: $script:FabriqBackuperRoot" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    return
}

# Defensive log-output suppression. Preserved from the original entry
# script as defence-in-depth: in the standalone repo none of the wrapped
# modules call these, but if a stale reference appears we want a silent
# no-op rather than a runtime "term not recognized" error.
foreach ($_logFn in @(
    'Initialize-ExecutionHistory',
    'Restore-ExecutionHistory',
    'Write-ExecutionHistory',
    'Add-ExecutionResult',
    'Export-ExecutionHistory',
    'Export-HtmlChecklist',
    'Initialize-EvidenceBasePath',
    'Capture-ScreenEvidence'
)) {
    if (-not (Get-Command $_logFn -ErrorAction SilentlyContinue)) {
        Set-Item "Function:Global:$_logFn" -Value { } -Force
    }
}

# Read VERSION (now at repo root, not next to this script).
$script:BackuperVersion = '0.0.0'
$_verFile = Join-Path $script:RepoRoot 'VERSION'
if (Test-Path $_verFile) {
    $script:BackuperVersion = (Get-Content -Path $_verFile -Raw).Trim()
}

# ============================================================
# Optional: LAN migration profile (v0.23.0)
# When backuper\data\migration_profile.json exists and validates,
# it is exposed as $script:MigrationProfile. UI surfaces (session
# form banner, backup/restore destination default, UNC dialog
# presets) read from this object when non-null. Absence is the
# expected default - no profile = traditional behaviour.
#
# Failure policy:
#   - Profile file absent           -> silent, $script:MigrationProfile stays $null
#   - schemaVersion != 2            -> warning, ignore (treat as absent)
#   - JSON parse failure            -> warning, ignore
#   - File contains a 'password' key -> FATAL (security: passwords belong in
#                                       the interactive UNC dialog only,
#                                       never in source-controlled config)
# ============================================================
$script:MigrationProfile = $null
$_profilePath = Join-Path $script:FabriqBackuperRoot 'data\migration_profile.json'
if (Test-Path -LiteralPath $_profilePath) {
    try {
        $_jsonText = Get-Content -LiteralPath $_profilePath -Raw -Encoding UTF8
        if ($_jsonText -match '"\s*password\s*"') {
            Show-Error "Migration profile contains a 'password' key. Remove it before launching backuper."
            Show-Error "  Profile: $_profilePath"
            Read-Host "Press Enter to exit"
            return
        }
        $_profileObj = $_jsonText | ConvertFrom-Json
        if ($_profileObj.schemaVersion -eq 2) {
            $script:MigrationProfile = $_profileObj
            Show-Info "Migration profile loaded: $($_profileObj.profileName)"
        }
        else {
            Show-Warning "Migration profile schemaVersion=$($_profileObj.schemaVersion) (expected 2). Profile ignored."
        }
    }
    catch {
        Show-Warning "Failed to parse migration profile (ignored): $($_.Exception.Message)"
    }
}

# Suppress per-module Confirm-ModuleExecution prompts: the FabriqBackUper
# UI is the canonical confirmation surface; wrapped modules should run
# without their own Y/N prompts.
$global:AutoPilotMode    = $true
$global:AutoPilotWaitSec = 0

# Load FabriqBackUper libraries.
$libsToLoad = @(
    'lib\migration_paths.ps1',         # v0.40.0: shared migration-path resolver (local mode)
    'lib\hostlist_reader.ps1',
    'lib\extended_hostlist.ps1',       # v0.64.0 (t-0011): per-satellite extended hostlist + UNC auto-connect seam
    'lib\manifest_aggregator.ps1',
    'lib\ui\console_menu.ps1',         # legacy console UI, kept as fallback
    'lib\engine.ps1',
    'lib\ui\theme.ps1',
    'lib\ui\fabriq_select_form.ps1',   # Phase 3B: multi-candidate fabriq root picker
    'lib\ui\session_form.ps1',         # Phase 3C: unified passphrase + host + action
    'lib\ui\csv_io.ps1',               # Phase 2.7
    'lib\ui\user_selector.ps1',        # Phase 2.7
    'lib\ui\userdata_edit_dialog.ps1', # Phase 2.7
    'lib\ui\unc_helper.ps1',
    'lib\ui\unc_connect_dialog.ps1',
    'lib\ui\backup_view.ps1',
    'lib\ui\restore_view.ps1',
    'lib\ui\progress_view.ps1',
    'lib\ui\main_form.ps1'
)
foreach ($rel in $libsToLoad) {
    $abs = Join-Path $script:FabriqBackuperRoot $rel
    try {
        . $abs
    }
    catch {
        Write-Host "[FATAL] Failed to dot-source: $rel" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "        $($_.ScriptStackTrace)" -ForegroundColor DarkGray
        Read-Host "Press Enter to exit"
        return
    }
}

# v0.40.0: resolve the new "local" operation-model paths from the migration
# profile (share.localPath -> <BackuperRoot>\Backup ; backuper.backupRootUnc
# -> \\<target-ip>\<shareName> ; rollback.snapshotPath -> <BackuperRoot>\_lanprep\...).
# Done here, after lib\migration_paths.ps1 is dot-sourced. The backup/restore
# views read the (now-derived) profile fields unchanged. Portable mode (no
# profile) is unaffected. Literal profile values still win (escape hatch).
if ($null -ne $script:MigrationProfile) {
    try {
        $null = Resolve-MigrationPaths -MigProfile $script:MigrationProfile -BackuperRoot $script:FabriqBackuperRoot
        Show-Info "Migration dest resolved: $($script:MigrationProfile.backuper.backupRootUnc)"
    }
    catch {
        Show-Warning "Migration path resolution failed (using profile values as-is): $($_.Exception.Message)"
    }
}

# ============================================================
# Auto-discover fabriq main (sibling directory containing
# kernel/csv/hostlist.csv). Replaces the original "../.." path
# math that assumed apps/fabriq_backuper layout.
# ============================================================
# Set cwd to repo root so Find-FabriqRoot's Resolve-Path "." correctly
# excludes our own directory (prevents picking ourself when our repo
# name also matches *fabriq*).
Set-Location -Path $script:RepoRoot
$parentDir = Split-Path -Parent $script:RepoRoot
$candidates = @(Find-FabriqRoot -ParentDir $parentDir)

if ($candidates.Count -eq 0) {
    Show-Error "Fabriq main directory not found under: $parentDir"
    Show-Error "Expected a sibling directory containing kernel\csv\hostlist.csv"
    Show-Error "(e.g. E:\fabriq\) so fabriq_backuper can read its hostlist + passphrase token."
    Write-Host ""
    Read-Host "Press Enter to exit"
    return
}
elseif ($candidates.Count -eq 1) {
    $script:FabriqRoot = $candidates[0].FullName
    Show-Info "Fabriq main detected: $($candidates[0].Name)"
}
else {
    # Phase 3B: lavender-styled WinForms picker for multiple candidates.
    Show-Info "Multiple fabriq candidates found ($($candidates.Count)). Opening picker."
    foreach ($c in $candidates) {
        Show-Info "  candidate: $($c.FullName)"
    }
    $picked = Show-FabriqSelectForm -Candidates $candidates
    if ([string]::IsNullOrWhiteSpace($picked)) {
        Show-Error "No fabriq root selected. Exiting."
        Read-Host "Press Enter to exit"
        return
    }
    $script:FabriqRoot = $picked
    Show-Info "Fabriq main selected: $script:FabriqRoot"
}

# ============================================================
# Welcome banner
# ============================================================
Clear-Host
Write-Host ""
Show-Separator
Write-Host "  Fabriq BackUper  v$($script:BackuperVersion)" -ForegroundColor Cyan
$kernelVerFile = Join-Path $script:FabriqRoot 'kernel\KERNEL_VERSION'
$kernelVer = if (Test-Path $kernelVerFile) { (Get-Content $kernelVerFile -Raw).Trim() } else { 'unknown' }
Write-Host "  Backup/Restore satellite over Fabriq kernel $kernelVer" -ForegroundColor DarkGray
Show-Separator
Write-Host ""

# ============================================================
# Step 1: Admin check (robocopy /B, registry HKLM write require admin)
# ============================================================
if (-not (Test-AdminPrivilege)) {
    Show-Error "Administrator privileges are required."
    Show-Info  "Please re-launch Fabriq_BackUper.exe with admin rights."
    Write-Host ""
    Read-Host "Press Enter to exit"
    return
}

# ============================================================
# Step 2 (Phase 3C): Unified session setup dialog.
# Combines passphrase entry + host selection + Backup/Restore
# action choice into one form (family pattern matching
# fabriq_operator's session_form.ps1).
#
# Hostlist load happens TWICE intentionally:
#   1. Pre-load (cold): $global:FabriqMasterPassphrase is unset,
#      so ENC: values stay as-is. Used for the session form's host
#      grid display (operator picks by row).
#   2. Post-form: $global:FabriqMasterPassphrase is now set from
#      the verified entry; Start-FabriqBackuperGui re-loads the
#      hostlist (now decrypted) and resolves the selection via
#      $InitialHostIndex.
# ============================================================
$verifyPath = Join-Path $script:FabriqRoot 'kernel\txt\passphrase_verify.txt'
if (-not (Test-Path $verifyPath)) {
    Show-Error "Passphrase verify token not found: $verifyPath"
    Show-Error "FabriqBackUper requires fabriq to be initialized first."
    Read-Host "Press Enter to exit"
    return
}

# Cold hostlist load (passphrase still unset -> ENC: values visible).
$coldHostlist = @(Get-FabriqHostlist -FabriqRoot $script:FabriqRoot)
if ($null -eq $coldHostlist -or $coldHostlist.Count -eq 0) {
    Show-Error "Hostlist is empty or unreadable: $script:FabriqRoot\kernel\csv\hostlist.csv"
    Read-Host "Press Enter to exit"
    return
}

# v0.43.0 (P3): automation handoff. LAN-Prep (P5) sets these env vars before
# launching Backuper; they cross the self-spawn boundary intact. ROLE maps to
# the session mode (source->Backup, target->Restore) and AUTO_HOST pre-selects
# the migration pair by OldPCname. The passphrase is NEVER passed via env --
# the operator still types it into the (pre-filled) session form.
$autoRole = "$env:FABRIQ_BACKUPER_ROLE".Trim().ToLower()
$autoHost = "$env:FABRIQ_BACKUPER_AUTO_HOST".Trim()
$preselectMode = switch ($autoRole) {
    'source' { 'Backup' }
    'target' { 'Restore' }
    default  { '' }
}
if ($preselectMode -ne '') {
    Show-Info "Automation handoff: role=$autoRole -> mode=$preselectMode ; host=$autoHost"
}

$sess = Show-BackuperSessionForm `
    -HostList            $coldHostlist `
    -VerifyTokenPath     $verifyPath `
    -CurrentPCName       $env:COMPUTERNAME `
    -MigrationProfile    $script:MigrationProfile `
    -PreselectMode       $preselectMode `
    -PreselectOldPcName  $autoHost

if ($sess.Cancelled) {
    Show-Info "Session cancelled. Exiting."
    return
}

$global:FabriqMasterPassphrase = $sess.MasterPassphrase
Show-Success ("Session ready: mode={0}, host-index={1}" -f $sess.Mode, $sess.SelectedHostIndex)

Write-Host ""

# ============================================================
# Step 3: Launch WinForms GUI (Phase 2.1)
# Pre-selected Mode + HostIndex from the session form are passed
# in; Start-FabriqBackuperGui no longer shows ModeSelectView.
# Legacy console menu (Show-MainMenu / Invoke-BackuperEngine)
# is still loaded above for fallback paths.
# ============================================================
try {
    Start-FabriqBackuperGui `
        -BackuperVersion   $script:BackuperVersion `
        -BackuperRoot      $script:FabriqBackuperRoot `
        -FabriqRoot        $script:FabriqRoot `
        -InitialMode       $sess.Mode `
        -InitialHostIndex  $sess.SelectedHostIndex
}
catch {
    Show-Error "GUI launch failed: $($_.Exception.Message)"
    Show-Error $_.ScriptStackTrace
    Read-Host "Press Enter to exit"
}

Write-Host ""
Show-Info "Fabriq BackUper session ended."
Write-Host ""
