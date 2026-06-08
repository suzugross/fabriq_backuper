# ============================================================
# Fabriq Extended Hostlist Editor - Entry Script (t-0011, v0.64.0)
# Standalone editor for backuper/data/extended_hostlist.csv at the same layer as
# LAN-Prep / Cleanup / Handoff Viewer. Seeds its grid from the Fabriq hostlist
# (absolute source of truth) so only real (OldPCname, NewPCname) pairs can be
# authored, and encrypts UNC passwords with the portable master-passphrase ENC:
# model (Protect-FabriqValue). The live file holds ENCRYPTED passwords; it is
# gitignored.
#
# MANDATORY passphrase: this tool both decrypts (to show status) and encrypts
# (to store), so the master passphrase is required up front.
#
# Hardening mirrors fabriq_handoffviewer.ps1: Start-Transcript, top-level trap,
# try/finally Read-Host so an EXE/conhost-launched window never closes on an
# error before the operator can read it.
# Comments / console output English; WinForms UI Japanese (CLAUDE.md rules).
# ============================================================

$ErrorActionPreference = 'Stop'

$script:RepoRoot    = $PSScriptRoot
$script:EditorRoot  = Join-Path $PSScriptRoot 'tools\exthostlist_editor'
$script:BackuperLib = Join-Path $PSScriptRoot 'backuper'

# ---- transcript (first, so even dot-source failures are captured) ----
$logDir = $env:TEMP
if ([string]::IsNullOrWhiteSpace($logDir) -or -not (Test-Path -LiteralPath $logDir)) {
    $logDir = $script:RepoRoot
}
$script:TranscriptPath = Join-Path $logDir ("fabriq_exthostlist_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
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

# ---- master passphrase prompt (mandatory; verifies via common.ps1) ----
function global:Show-EhPassphrasePrompt {
    param([Parameter(Mandatory = $true)][string]$VerifyTokenPath)
    $dlg = New-Object System.Windows.Forms.Form
    Set-FormStyle -Form $dlg -Title 'Fabriq 拡張HOSTLIST 編集 - マスターパスフレーズ' -Width 460 -Height 200
    $dlg.KeyPreview = $true
    $lbl = New-StyledLabel -Text "資格情報の暗号化/復号にマスターパスフレーズが必要です。入力してください。" `
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
    $btnOk.Add_Click({
        $pp = $box.Text
        if ([string]::IsNullOrWhiteSpace($pp)) { return }
        if (Test-MasterPassphrase -Passphrase $pp -VerifyTokenPath $VerifyTokenPath) {
            $result.Value = $pp; $dlg.Close()
        }
        else {
            [System.Windows.Forms.MessageBox]::Show("パスフレーズが一致しません。", "拡張HOSTLIST 編集",
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

try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing       -ErrorAction Stop
}
catch {
    Write-Host "[FATAL] Failed to load WinForms / Drawing: $($_.Exception.Message)" -ForegroundColor Red
    return
}

# v0.66.1: route any WinForms event-handler exception to the transcript instead
# of the default JIT / ThreadException dialog. Belt-and-suspenders alongside the
# root fix in the editor (a PS5.1 dynamic-binder quirk surfaced that dialog).
try {
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
    [System.Windows.Forms.Application]::add_ThreadException({
        param($s, $e)
        Write-Host "[ThreadException] $($e.Exception.GetType().FullName): $($e.Exception.Message)" -ForegroundColor Red
        if ($e.Exception.StackTrace) { Write-Host $e.Exception.StackTrace -ForegroundColor DarkGray }
    })
}
catch {
    Write-Host "[warn] Could not install WinForms exception guard: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Dot-source backuper libraries (single source of truth) + the editor view.
try {
    . (Join-Path $script:BackuperLib 'common.ps1')
    . (Join-Path $script:BackuperLib 'lib\migration_paths.ps1')
    . (Join-Path $script:BackuperLib 'lib\ui\theme.ps1')
    . (Join-Path $script:BackuperLib 'lib\ui\fabriq_select_form.ps1')
    . (Join-Path $script:BackuperLib 'lib\hostlist_reader.ps1')
    . (Join-Path $script:BackuperLib 'lib\extended_hostlist.ps1')   # v0.66.0: reuse Test-ExtendedHostlistGate for the in-editor 突合 check
    . (Join-Path $script:EditorRoot 'lib\exthostlist_editor_view.ps1')
}
catch {
    Write-Host "[FATAL] Failed to dot-source libraries: $($_.Exception.Message)" -ForegroundColor Red
    return
}

$script:BackuperRoot = $script:BackuperLib
$script:EhDataPath   = Join-Path $script:BackuperLib 'data\extended_hostlist.csv'

# Read VERSION (shared with the backuper - both live at the repo root).
$script:EditorVersion = '0.0.0'
$_verFile = Join-Path $script:RepoRoot 'VERSION'
if (Test-Path $_verFile) { $script:EditorVersion = (Get-Content -Path $_verFile -Raw).Trim() }

Write-Host ""
Show-Separator
Write-Host "  Fabriq Extended Hostlist Editor  v$($script:EditorVersion)" -ForegroundColor Cyan
Write-Host "  Per-satellite extended hostlist (UNC creds + visual info)" -ForegroundColor DarkGray
Show-Separator
Write-Host ""

# ---- fabriq main discovery (REQUIRED: the grid is seeded from the hostlist) ----
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

# ---- mandatory master passphrase (needed to encrypt/decrypt UNC passwords) ----
$_verifyToken = Join-Path $script:FabriqRoot 'kernel\txt\passphrase_verify.txt'
if (-not (Test-Path -LiteralPath $_verifyToken)) {
    Show-Error "Passphrase verify token not found: $_verifyToken"
    return
}
$_pp = Show-EhPassphrasePrompt -VerifyTokenPath $_verifyToken
if ([string]::IsNullOrWhiteSpace($_pp)) {
    Show-Warning "Passphrase cancelled. The editor requires it to (de)crypt credentials. Exiting."
    return
}
$global:FabriqMasterPassphrase = $_pp
Show-Success "Master passphrase verified."

# ---- hostlist load (decrypted) ----
$_busy = Show-BusyOverlay   # v0.67.0 (t-0014): overlay during hostlist ENC: decrypt (console thread, pre-Run)
try { $script:EhFabriqRows = @(Get-FabriqHostlist -FabriqRoot $script:FabriqRoot) }
finally { Close-BusyOverlay $_busy }
Show-Info "Hostlist loaded: $($script:EhFabriqRows.Count) row(s)."
if ($script:EhFabriqRows.Count -eq 0) {
    Show-Warning "Hostlist empty or unreadable. The editor grid will be empty."
}

# ---- build the editor window ----
$form = New-Object System.Windows.Forms.Form
Set-FormStyle -Form $form -Title "Fabriq 拡張HOSTLIST 編集  v$($script:EditorVersion)" -Width 980 -Height 700
$script:MainForm = $form

$panel = New-ExtHostlistEditorView -DataPath $script:EhDataPath
$panel.Dock = [System.Windows.Forms.DockStyle]::Fill
$form.Controls.Add($panel)

$form.Add_Shown({ $form.Activate(); Show-ExtHostlistEditorView })
$result = 'shown'
[System.Windows.Forms.Application]::Run($form)

}
finally {
    Write-Host ""
    if ($script:TranscriptStarted) { Write-Host "Log saved: $script:TranscriptPath" -ForegroundColor DarkGray }
    if ($result -eq 'shown') {
        Write-Host "[ok] Extended Hostlist Editor finished; closing this window." -ForegroundColor Green
    }
    else {
        Read-Host "Press Enter to close this window"
    }
    if ($script:TranscriptStarted) { try { Stop-Transcript | Out-Null } catch {} }
}
