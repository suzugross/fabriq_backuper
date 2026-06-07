# ============================================================
# Fabriq Handoff Viewer - Entry Script (v0.58.0)
# Called from Fabriq_HandoffViewer.exe (conhost + powershell, asInvoker).
# Standalone operator-handoff (集約) folder browser at the same layer as
# LAN-Prep / Cleanup: a dedicated GUI that finds the handoff folder for a
# hostlist-selected host and offers one-click shortcuts into the existing
# per-section info viewers (credentials / Outlook accounts) and the
# section folders / launcher batches.
#
# Split into its own tool (t-0006) so the Backuper operator UI stays focused.
# It owns NO discovery logic of its own: it dot-sources backuper/common.ps1
# and reuses Get-CleanupCandidate (Kind='handoff') for folder discovery and
# host attribution -- exactly the way Cleanup + LAN-Prep dot-source common.ps1
# (no vendoring, single source of truth).
#
# Hardening mirrors fabriq_cleanup.ps1: Start-Transcript, top-level trap,
# try/finally Read-Host so an EXE-launched conhost never closes on an
# error before the operator can read it.
# Comments / console output English; WinForms UI Japanese (CLAUDE.md rules).
# Read-only browser: the section launcher batches handle their own user
# context / UAC self-elevation; this app stays asInvoker.
# ============================================================

$ErrorActionPreference = 'Stop'

$script:RepoRoot          = $PSScriptRoot
$script:HandoffViewerRoot = Join-Path $PSScriptRoot 'tools\handoff_viewer'
$script:BackuperLib       = Join-Path $PSScriptRoot 'backuper'

# ---- transcript (first, so even dot-source failures are captured) ----
$logDir = $env:TEMP
if ([string]::IsNullOrWhiteSpace($logDir) -or -not (Test-Path -LiteralPath $logDir)) {
    $logDir = $script:RepoRoot
}
$script:TranscriptPath = Join-Path $logDir ("fabriq_handoffviewer_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
$script:TranscriptStarted = $false
try {
    Start-Transcript -Path $script:TranscriptPath -Force | Out-Null
    $script:TranscriptStarted = $true
    Write-Host "[transcript] $script:TranscriptPath" -ForegroundColor DarkGray
}
catch {
    Write-Host "[warn] Start-Transcript failed (continuing without log): $($_.Exception.Message)" -ForegroundColor Yellow
}

# ---- top-level trap (last-resort handler so conhost stays open) ----
trap {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Red
    Write-Host "[TRAP] Uncaught terminating error reached the top-level trap:" -ForegroundColor Red
    Write-Host "================================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    if ($_.InvocationInfo -and $_.InvocationInfo.ScriptName) {
        Write-Host ("  {0}:{1}" -f $_.InvocationInfo.ScriptName, $_.InvocationInfo.ScriptLineNumber) -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    Write-Host ""
    if ($script:TranscriptStarted) {
        Write-Host "Full log: $script:TranscriptPath" -ForegroundColor Cyan
    }
    Write-Host ""
    Read-Host "Press Enter to close this window"
    if ($script:TranscriptStarted) { try { Stop-Transcript | Out-Null } catch {} }
    break
}

# ---- compact passphrase prompt (viewer-local; verifies via common.ps1) ----
function global:Show-HandoffViewerPassphrasePrompt {
    param([Parameter(Mandatory = $true)][string]$VerifyTokenPath)
    $dlg = New-Object System.Windows.Forms.Form
    Set-FormStyle -Form $dlg -Title 'Fabriq 移行情報ビューア - マスターパスフレーズ' -Width 460 -Height 200
    $dlg.KeyPreview = $true
    $lbl = New-StyledLabel -Text "hostlist.csv が暗号化されています。マスターパスフレーズを入力してください。" `
        -X 20 -Y 16 -Width 410 -Height 40 -FgColor $script:fgHeader
    $dlg.Controls.Add($lbl)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point(20, 66)
    $box.Size = New-Object System.Drawing.Size(410, 24)
    $box.UseSystemPasswordChar = $true
    Set-TextBoxStyle -TextBox $box
    $dlg.Controls.Add($box)
    $result = @{ Value = $null }
    $btnCancel = New-StyledButton -Text 'キャンセル' -X 200 -Y 110 -Width 110 -Height 32
    $btnCancel.Add_Click({ $result.Value = $null; $dlg.Close() })
    $dlg.Controls.Add($btnCancel)
    $btnOk = New-StyledButton -Text 'OK' -X 320 -Y 110 -Width 110 -Height 32 -BgColor $script:bgAccent
    $btnOk.ForeColor = $script:fgWhite
    $btnOk.Add_Click({
        $pp = $box.Text
        if ([string]::IsNullOrWhiteSpace($pp)) { return }
        if (Test-MasterPassphrase -Passphrase $pp -VerifyTokenPath $VerifyTokenPath) {
            $result.Value = $pp; $dlg.Close()
        }
        else {
            [System.Windows.Forms.MessageBox]::Show("パスフレーズが一致しません。", "Fabriq 移行情報ビューア",
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            $box.SelectAll(); $box.Focus()
        }
    })
    $dlg.Controls.Add($btnOk)
    $dlg.Add_KeyDown({ if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $result.Value = $null; $dlg.Close() } })
    $dlg.Add_Shown({ $dlg.Activate(); $box.Focus() })
    [void]$dlg.ShowDialog()
    $dlg.Dispose()
    return $result.Value
}

# ============================================================
# Main body (try/finally so the Read-Host always runs).
# ============================================================
try {

$result = $null   # success sentinel for the finally block (Read-Host policy)

# Pre-load WinForms.
try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing       -ErrorAction Stop
}
catch {
    Write-Host "[FATAL] Failed to load WinForms / Drawing: $($_.Exception.Message)" -ForegroundColor Red
    return
}

# Dot-source backuper libraries (single source of truth) + the viewer view.
# common (Find-FabriqRoot, Test-MasterPassphrase, Show-*, Get-CleanupCandidate) ->
# migration_paths -> theme -> fabriq picker -> hostlist reader -> handoff viewer view.
try {
    . (Join-Path $script:BackuperLib 'common.ps1')
    . (Join-Path $script:BackuperLib 'lib\migration_paths.ps1')
    . (Join-Path $script:BackuperLib 'lib\ui\theme.ps1')
    . (Join-Path $script:BackuperLib 'lib\ui\fabriq_select_form.ps1')
    . (Join-Path $script:BackuperLib 'lib\hostlist_reader.ps1')
    . (Join-Path $script:HandoffViewerRoot 'lib\handoffviewer_view.ps1')
}
catch {
    Write-Host "[FATAL] Failed to dot-source libraries: $($_.Exception.Message)" -ForegroundColor Red
    return
}

# The discovery engine (Get-CleanupCandidate) reads $script:BackuperRoot.
$script:BackuperRoot = $script:BackuperLib

# Read VERSION (shared with the backuper - both live at the repo root).
$script:HandoffViewerVersion = '0.0.0'
$_verFile = Join-Path $script:RepoRoot 'VERSION'
if (Test-Path $_verFile) { $script:HandoffViewerVersion = (Get-Content -Path $_verFile -Raw).Trim() }

# Optional migration_profile (drives the candidate scan roots). Same load
# policy as the backuper / LAN-Prep / Cleanup.
$script:MigrationProfile = $null
$_profilePath = Join-Path $script:BackuperLib 'data\migration_profile.json'
if (Test-Path -LiteralPath $_profilePath) {
    try {
        $_jsonText = Get-Content -LiteralPath $_profilePath -Raw -Encoding UTF8
        if ($_jsonText -match '"\s*password\s*"') {
            Show-Error "Migration profile contains a 'password' key. Remove it before launching the viewer."
            return
        }
        $_profileObj = $_jsonText | ConvertFrom-Json
        if ($_profileObj.schemaVersion -eq 2) {
            $script:MigrationProfile = $_profileObj
            try { $null = Resolve-MigrationPaths -MigProfile $script:MigrationProfile -BackuperRoot $script:BackuperLib } catch {}
            Show-Info "Migration profile loaded: $($_profileObj.profileName)"
        }
        else { Show-Warning "Migration profile schemaVersion=$($_profileObj.schemaVersion) (expected 2). Ignored." }
    }
    catch { Show-Warning "Failed to parse migration profile (ignored): $($_.Exception.Message)" }
}

# Banner.
Write-Host ""
Show-Separator
Write-Host "  Fabriq Handoff Viewer  v$($script:HandoffViewerVersion)" -ForegroundColor Cyan
Write-Host "  Operator handoff-folder browser (per hostlist host)" -ForegroundColor DarkGray
Show-Separator
Write-Host ""

# ---- fabriq main discovery (REQUIRED: the host combo is driven by hostlist) ----
Set-Location -Path $script:RepoRoot
$_parentDir = Split-Path -Parent $script:RepoRoot
$_candidates = @(Find-FabriqRoot -ParentDir $_parentDir)
$script:FabriqRoot = $null
if ($_candidates.Count -eq 0) {
    Show-Error "Fabriq main directory not found under: $_parentDir"
    Show-Error "Expected a sibling directory containing kernel\csv\hostlist.csv (e.g. E:\fabriq\)."
    return
}
elseif ($_candidates.Count -eq 1) {
    $script:FabriqRoot = $_candidates[0].FullName
    Show-Info "Fabriq main detected: $($_candidates[0].Name)"
}
else {
    Show-Info "Multiple fabriq candidates found ($($_candidates.Count)). Opening picker."
    $_picked = Show-FabriqSelectForm -Candidates $_candidates
    if ([string]::IsNullOrWhiteSpace($_picked)) { Show-Error "No fabriq root selected. Exiting."; return }
    $script:FabriqRoot = $_picked
}

# ---- hostlist load (+ ENC: passphrase prompt) ----
# NOTE: always wrap Get-FabriqHostlist in @() so a single-row hostlist (which
# PowerShell unwraps to a scalar on return) still yields a reliable .Count
# (see ps51 list/array quirk).
$script:HostRows = @()
$_hostlistPath = Join-Path $script:FabriqRoot 'kernel\csv\hostlist.csv'
Show-Info "Hostlist source: $_hostlistPath"
$_hostsRaw = @(Get-FabriqHostlist -FabriqRoot $script:FabriqRoot)
Show-Info "Hostlist cold-load returned $($_hostsRaw.Count) row(s)."
if ($_hostsRaw.Count -gt 0) {
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
        $_pp = Show-HandoffViewerPassphrasePrompt -VerifyTokenPath $_verifyToken
        if ([string]::IsNullOrWhiteSpace($_pp)) {
            Show-Warning "Passphrase cancelled. Host combo will be empty."
        }
        else {
            $global:FabriqMasterPassphrase = $_pp
            $_hostsRaw = @(Get-FabriqHostlist -FabriqRoot $script:FabriqRoot)
            if ($_hostsRaw.Count -gt 0) { $script:HostRows = $_hostsRaw; Show-Success "Hostlist decrypted: $($script:HostRows.Count) row(s)" }
        }
    }
    else {
        $script:HostRows = $_hostsRaw; Show-Success "Hostlist loaded: $($script:HostRows.Count) row(s)"
    }
}
else {
    Show-Warning "Hostlist empty or unreadable: $_hostlistPath"
    Show-Warning "Confirm this file has data rows and an 'OldPCName' column. Host combo will be empty."
}

# ---- build the standalone viewer window ----
$script:CurrentHost = $null
$form = New-Object System.Windows.Forms.Form
Set-FormStyle -Form $form -Title "Fabriq 移行情報ビューア  v$($script:HandoffViewerVersion)" -Width 980 -Height 720
$script:MainForm = $form

$panel = New-HandoffViewerView
$panel.Dock = [System.Windows.Forms.DockStyle]::Fill
$form.Controls.Add($panel)

$form.Add_Shown({ $form.Activate(); Show-HandoffViewerView })
$result = 'shown'   # reached the GUI -> success path for the finally block
[System.Windows.Forms.Application]::Run($form)

}
finally {
    Write-Host ""
    if ($script:TranscriptStarted) { Write-Host "Log saved: $script:TranscriptPath" -ForegroundColor DarkGray }
    # On the success path (GUI shown + closed normally) close without an Enter;
    # on early-return / error paths keep the Read-Host so the operator can read it.
    if ($result -eq 'shown') {
        Write-Host "[ok] Handoff Viewer finished; closing this window." -ForegroundColor Green
    }
    else {
        Read-Host "Press Enter to close this window"
    }
    if ($script:TranscriptStarted) { try { Stop-Transcript | Out-Null } catch {} }
}
