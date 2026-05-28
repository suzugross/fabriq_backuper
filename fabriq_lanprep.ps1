# ============================================================
# Fabriq LAN-Prep - Entry Script (v0.30.0)
# Called from Fabriq_LanPrep.exe (admin-elevated via manifest).
# Shows a WinForms menu (lavender accent) with action buttons:
#   - "移行先として設定"   -> Prepare-LanMigration.ps1 -Role target
#   - "移行元として設定"   -> Prepare-LanMigration.ps1 -Role source
#   - "元に戻す"           -> Revert-LanMigration.ps1 -SnapshotPath ...
#   - "終了"               -> exit
#
# v0.30.0 changes:
#   - Find-FabriqRoot is now REQUIRED (was unused). Failure aborts
#     lan-prep just like backuper itself does, because the menu now
#     surfaces a hostlist combo to drive PC-pair selection.
#   - Hostlist is loaded via Get-FabriqHostlist (read-only). If any
#     row contains ENC: encrypted values a passphrase prompt is
#     shown; cancel drops back into back-compat mode (= empty host
#     list, profile drives everything as in v0.29.0).
#   - Get-NetAdapter results are passed into the menu so the
#     interfaceAlias used by Prepare-LanMigration is selected on
#     the form rather than hardcoded in profile.json.
#   - Menu returns a pscustomobject; the chosen NIC name and host
#     pair are forwarded to the child .ps1 as optional parameters,
#     overriding the profile values in-memory.
#
# v0.24.2 hardening (still active):
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

# Declare $result up-front so the finally block can reference it
# even when an early return aborts before Show-LanPrepMenu sets it
# (e.g. fabriq main not found, dot-source failure). $null here means
# "menu never ran", which the finally block treats as a failure path
# and keeps the Read-Host so the operator can read the error.
$result = $null

# Pre-load WinForms assemblies.
try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing       -ErrorAction Stop
}
catch {
    Write-Host "[FATAL] Failed to load WinForms / Drawing assemblies: $($_.Exception.Message)" -ForegroundColor Red
    return
}

# Load backuper common.ps1 + theme + hostlist reader + multi-fabriq picker.
# Order matters: common (Find-FabriqRoot, Test-MasterPassphrase, Show-*) ->
# theme (style helpers used by every WinForms call below) -> fabriq picker
# (uses theme) -> hostlist reader (uses common) -> menu form (uses
# everything above).
try {
    . (Join-Path $script:BackuperLib 'common.ps1')
    . (Join-Path $script:BackuperLib 'lib\ui\theme.ps1')
    . (Join-Path $script:BackuperLib 'lib\ui\fabriq_select_form.ps1')
    . (Join-Path $script:BackuperLib 'lib\hostlist_reader.ps1')
}
catch {
    Write-Host "[FATAL] Failed to dot-source backuper libraries: $($_.Exception.Message)" -ForegroundColor Red
    return
}

# Load the menu form (defines Show-LanPrepMenu + Show-LanPrepPassphrasePrompt).
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

# ============================================================
# Fabriq main discovery (v0.30.0, REQUIRED)
# Same auto-discovery logic as backuper/main.ps1: scan sibling
# directories for one containing kernel/csv/hostlist.csv. Single
# candidate -> auto-select; multiple -> Show-FabriqSelectForm.
# Absence is fatal because the menu now needs hostlist.csv to
# populate the host-pair combo.
# ============================================================
Set-Location -Path $script:RepoRoot
$_parentDir = Split-Path -Parent $script:RepoRoot
$_candidates = @(Find-FabriqRoot -ParentDir $_parentDir)
if ($_candidates.Count -eq 0) {
    Show-Error "Fabriq main directory not found under: $_parentDir"
    Show-Error "Expected a sibling directory containing kernel\csv\hostlist.csv"
    Show-Error "(e.g. E:\fabriq\) so Fabriq_LanPrep can read its hostlist."
    return
}
elseif ($_candidates.Count -eq 1) {
    $script:FabriqRoot = $_candidates[0].FullName
    Show-Info "Fabriq main detected: $($_candidates[0].Name)"
}
else {
    Show-Info "Multiple fabriq candidates found ($($_candidates.Count)). Opening picker."
    $_picked = Show-FabriqSelectForm -Candidates $_candidates
    if ([string]::IsNullOrWhiteSpace($_picked)) {
        Show-Error "No fabriq root selected. Exiting."
        return
    }
    $script:FabriqRoot = $_picked
    Show-Info "Fabriq main selected: $script:FabriqRoot"
}

# ============================================================
# Hostlist load (v0.30.0)
# Read hostlist.csv via the backuper hostlist_reader (which uses
# Import-ModuleCsv internally). Import-ModuleCsv transparently
# decrypts ENC: values only when $global:FabriqMasterPassphrase
# is set; otherwise ENC: strings are returned verbatim. We probe
# the first load for ENC: residue and, on detection, prompt the
# operator for the passphrase and re-load.
#
# Failure / cancel policy (back-compat mode):
#   - hostlist file absent / parse error -> warning, HostRows=@()
#   - ENC: detected + passphrase cancelled -> warning, HostRows=@()
#   - ENC: detected + verify fails repeatedly -> operator can cancel
# In all failure paths the menu still opens; role buttons remain
# usable as long as migration_profile.json is present (= profile
# drives everything just like v0.29.0).
# ============================================================
$script:HostRows = @()
$_hostsRaw = Get-FabriqHostlist -FabriqRoot $script:FabriqRoot
if ($null -ne $_hostsRaw -and $_hostsRaw.Count -gt 0) {
    # Detect ENC: residue (Import-ModuleCsv left them undecrypted).
    $_needsPp = $false
    foreach ($_r in $_hostsRaw) {
        foreach ($_p in $_r.PSObject.Properties) {
            if ($_p.Value -is [string] -and $_p.Value.StartsWith('ENC:')) { $_needsPp = $true; break }
        }
        if ($_needsPp) { break }
    }
    if ($_needsPp) {
        $_verifyToken = Join-Path $script:FabriqRoot 'kernel\txt\passphrase_verify.txt'
        Show-Info "Hostlist contains ENC: encrypted fields. Prompting for master passphrase..."
        $_pp = Show-LanPrepPassphrasePrompt -VerifyTokenPath $_verifyToken
        if ([string]::IsNullOrWhiteSpace($_pp)) {
            Show-Warning "Passphrase prompt cancelled. Hostlist combo disabled (back-compat mode)."
        }
        else {
            $global:FabriqMasterPassphrase = $_pp
            $_hostsRaw = Get-FabriqHostlist -FabriqRoot $script:FabriqRoot
            if ($null -ne $_hostsRaw) {
                $script:HostRows = @($_hostsRaw)
                Show-Success "Hostlist decrypted: $($script:HostRows.Count) row(s)"
            }
        }
    }
    else {
        $script:HostRows = @($_hostsRaw)
        Show-Success "Hostlist loaded: $($script:HostRows.Count) row(s) (no ENC: fields)"
    }
}
else {
    Show-Warning "Hostlist empty or unreadable. Hostlist combo will be disabled (back-compat mode)."
}

# ============================================================
# NIC enumeration (v0.30.0)
# Get-NetAdapter on a fresh PC may return adapters in any state
# (Up/Down, Connected/Disconnected). We do not filter here -
# kitting scenarios deliberately run with the LAN cable still
# unplugged, so disconnected adapters must be selectable.
# ============================================================
$script:Nics = @()
try {
    $script:Nics = @(Get-NetAdapter -ErrorAction Stop | Sort-Object Name)
    Show-Info "Detected $($script:Nics.Count) network adapter(s)"
}
catch {
    Show-Warning "Failed to enumerate network adapters: $($_.Exception.Message)"
}

# ============================================================
# Default interfaceAlias for the NIC combo:
# pre-select the profile's source.interfaceAlias when both
# (a) a profile is loaded and (b) the alias is present on this PC.
# Otherwise the combo defaults to the first adapter row.
# ============================================================
$_defaultAlias = $null
if ($null -ne $script:MigrationProfile -and $null -ne $script:MigrationProfile.network) {
    if ($null -ne $script:MigrationProfile.network.source -and `
        -not [string]::IsNullOrWhiteSpace($script:MigrationProfile.network.source.interfaceAlias)) {
        $_defaultAlias = $script:MigrationProfile.network.source.interfaceAlias
    }
}

# ============================================================
# Show the menu (modal). Returns a pscustomobject:
#   .action          -> 'target' | 'source' | 'revert' | 'exit'
#   .oldPCName       -> selected hostlist OldPCName  (or $null)
#   .newPCName       -> selected hostlist NewPCName  (or $null)
#   .interfaceAlias  -> selected NIC name            (or $null)
# ============================================================
$result = Show-LanPrepMenu `
    -Version               $script:LanPrepVersion `
    -MigrationProfile      $script:MigrationProfile `
    -HostRows              $script:HostRows `
    -Nics                  $script:Nics `
    -DefaultInterfaceAlias $_defaultAlias

# Build the optional-parameter splat once so target/source paths share it.
$_childArgs = @{}
if (-not [string]::IsNullOrWhiteSpace($result.interfaceAlias)) {
    $_childArgs['InterfaceAlias'] = $result.interfaceAlias
}
if (-not [string]::IsNullOrWhiteSpace($result.oldPCName)) {
    $_childArgs['OldPCName'] = $result.oldPCName
}
if (-not [string]::IsNullOrWhiteSpace($result.newPCName)) {
    $_childArgs['NewPCName'] = $result.newPCName
}

switch ($result.action) {
    'target' {
        Show-Info "Running Prepare-LanMigration.ps1 -Role target ..."
        if ($result.oldPCName -or $result.newPCName) {
            Show-Info ("  host pair      : {0} -> {1}" -f $result.oldPCName, $result.newPCName)
        }
        if ($result.interfaceAlias) {
            Show-Info ("  interfaceAlias : {0}" -f $result.interfaceAlias)
        }
        # Reset $LASTEXITCODE so the finally block can rely on it to detect
        # success path (Prepare-LanMigration ends with explicit `exit 0`;
        # failure paths use `exit 1`). -Force suppresses the child's Y/N
        # prompt: the menu's role button (e.g. "(this PC = NEW-PC-01)") is
        # already the operator's last point of confirmation.
        $global:LASTEXITCODE = 0
        Write-Host ""
        & (Join-Path $script:LanPrepRoot 'Prepare-LanMigration.ps1') -Role target -Force @_childArgs
    }
    'source' {
        Show-Info "Running Prepare-LanMigration.ps1 -Role source ..."
        if ($result.oldPCName -or $result.newPCName) {
            Show-Info ("  host pair      : {0} -> {1}" -f $result.oldPCName, $result.newPCName)
        }
        if ($result.interfaceAlias) {
            Show-Info ("  interfaceAlias : {0}" -f $result.interfaceAlias)
        }
        $global:LASTEXITCODE = 0
        Write-Host ""
        & (Join-Path $script:LanPrepRoot 'Prepare-LanMigration.ps1') -Role source -Force @_childArgs
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
        Show-Warning "Unknown menu action: $($result.action)"
    }
}

}
finally {
    Write-Host ""
    if ($script:TranscriptStarted) {
        Write-Host "Log saved: $script:TranscriptPath" -ForegroundColor DarkGray
    }

    # Skip the trailing Read-Host on the target/source SUCCESS path only:
    #   - KeepAwake.bat is now running in a separate window (baton-passed),
    #     so closing this conhost immediately is the natural next step.
    # All other paths keep the Read-Host so the operator can read the
    # error / cancellation / completion message before the window closes:
    #   - $result is $null              -> early return before menu
    #     (fabriq main not found, dot-source failure, etc.)
    #   - $result.action = 'exit'       -> menu cancelled, give a beat
    #     so an accidental Esc/Quit doesn't slam the window shut
    #   - $result.action = 'revert'     -> operator explicitly asked to
    #     keep the Enter step per project decision (revert is rarer and
    #     less time-pressured than the prep path)
    #   - target/source + LASTEXITCODE != 0 -> Prepare-LanMigration
    #     failed; the child .ps1 already showed its own "Press Enter to
    #     exit" message, so this Read-Host is the parent's safety net
    #     (operator sees a second Enter prompt, but the parent transcript
    #     summary stays on screen).
    $skipReadHost = (
        $null -ne $result -and
        ($result.action -eq 'target' -or $result.action -eq 'source') -and
        $LASTEXITCODE -eq 0
    )
    if ($skipReadHost) {
        Write-Host "[ok] LAN-Prep finished; closing this window. (KeepAwake.bat continues in a separate window.)" -ForegroundColor Green
    }
    else {
        Read-Host "Press Enter to close this window"
    }

    if ($script:TranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch {}
    }
}
