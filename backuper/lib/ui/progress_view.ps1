# ============================================================
# FabriqBackUper - Progress View
# Shows live (in Phase 2.1: completion-only) log + Done button.
# Note: Phase 2.1 runs ops synchronously on UI thread so the
# log only updates after completion. Phase 2.2 will move to a
# Runspace + timer for true live updates.
# ============================================================

$script:ProgressTitle       = $null
$script:ProgressDoneBtn     = $null

# Phase 2.7.10: UI controls that are accessed from inside the section
# script (which is invoked via `& $scriptPath` and therefore runs in a
# SEPARATE script scope) must live in $global: — PowerShell's $script:
# resolves to the CURRENT executing script's scope, not the defining
# script's scope, so $script:ProgressLogBox was null when Add-ProgressLog
# was called from userdata/backup.ps1 or userdata/restore.ps1. Popup
# worked because Show-CompletionPopup is called from Invoke-BackupStart
# which lives in fabriq's script scope. The two controls below escape
# that pattern via $global: with a Fbp_ prefix to avoid collisions.
$global:Fbp_ProgressLogBox      = $null
$global:Fbp_ProgressEntriesGrid = $null

function New-ProgressView {
    $panel = New-Object System.Windows.Forms.Panel
    $panel.BackColor = $script:bgForm

    $script:ProgressTitle = New-StyledLabel -Text "実行中..." `
        -X 24 -Y 14 -Width 800 -Height 28 -Font $script:fontLarge
    $panel.Controls.Add($script:ProgressTitle)

    # Phase 2.7.8: per-entry status checklist. Sits above the streaming
    # log so an operator can see "Documents done, Chrome in progress,
    # Desktop pending" at a glance and start verifying restored apps
    # the moment their entry flips to Done.
    $entryLbl = New-StyledLabel -Text "項目別の状態" `
        -X 24 -Y 46 -Width 400 -Height 18 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($entryLbl)

    $entries = New-Object System.Windows.Forms.DataGridView
    $entries.Location = New-Object System.Drawing.Point(24, 68)
    $entries.Size = New-Object System.Drawing.Size(880, 150)
    Set-GridStyle -Grid $entries
    $entries.RowTemplate.Height = 22
    $entries.ColumnHeadersHeight = 24

    $colStatus = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colStatus.HeaderText = "状態"; $colStatus.Width = 130; $colStatus.Name = "Status"
    $colStatus.ReadOnly = $true
    $colStatus.DefaultCellStyle.Font = $script:fontSemiBold
    [void]$entries.Columns.Add($colStatus)

    $colLabel = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colLabel.HeaderText = "項目"; $colLabel.Name = "Label"; $colLabel.ReadOnly = $true
    $colLabel.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    [void]$entries.Columns.Add($colLabel)

    $panel.Controls.Add($entries)
    $global:Fbp_ProgressEntriesGrid = $entries

    # Streaming log (Phase 2.7.4) — shrunk to make room for the checklist.
    $logLbl = New-StyledLabel -Text "詳細ログ" `
        -X 24 -Y 226 -Width 400 -Height 18 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($logLbl)

    $log = New-Object System.Windows.Forms.TextBox
    $log.Multiline = $true
    $log.ReadOnly  = $true
    $log.ScrollBars = "Vertical"
    $log.Location = New-Object System.Drawing.Point(24, 248)
    $log.Size = New-Object System.Drawing.Size(880, 362)
    Set-TextBoxStyle -TextBox $log
    $log.Font = $script:fontMono
    $panel.Controls.Add($log)
    $global:Fbp_ProgressLogBox = $log

    # Done button. Phase 3C: ModeSelectView is gone; pressing Done now
    # closes the MainForm (= ends the .exe session). The operator re-
    # launches Fabriq_BackUper.exe to start a new session with a fresh
    # passphrase / host / mode choice.
    $btnDone = New-StyledButton -Text "完了" `
        -X 700 -Y 624 -Width 204 -Height 44 -BgColor $script:bgAccent
    $btnDone.Font = $script:fontLarge
    $btnDone.Enabled = $false
    $btnDone.Add_Click({
        # v0.53.0 (A) / v0.69.0 (t-0015): pressing 完了 is the explicit "finish
        # migration" action -> attempt the post-run auto network revert (self-gated:
        # only fires on Success + matching role + local profile + snapshot present +
        # not already reverted) BEFORE closing.
        #   ReturnView='Restore' -> target reverts (Invoke-RestoreAutoRevert)
        #   ReturnView='Backup'  -> source reverts (Invoke-BackupAutoRevert)
        if ($script:ProgressReturnView -eq 'Restore' -and `
            (Get-Command Invoke-RestoreAutoRevert -ErrorAction SilentlyContinue)) {
            Invoke-RestoreAutoRevert -Status "$($script:RestoreLastStatus)"
        }
        elseif ($script:ProgressReturnView -eq 'Backup' -and `
            (Get-Command Invoke-BackupAutoRevert -ErrorAction SilentlyContinue)) {
            Invoke-BackupAutoRevert -Status "$($script:BackupLastStatus)"
        }
        $script:MainForm.Close()
    })
    $panel.Controls.Add($btnDone)
    $script:ProgressDoneBtn = $btnDone

    # v0.50.0 (D6): optional "return to previous view" button, shown only when
    # the run was launched with a ReturnView (currently restore). Lets the
    # operator iterate (re-restore not-yet-done items / delete data) instead of
    # ending the session. Hidden by default; Set-ProgressFinished reveals it.
    $btnReturn = New-StyledButton -Text "リストア画面へ戻る" `
        -X 472 -Y 624 -Width 212 -Height 44
    $btnReturn.Font = $script:fontLarge
    $btnReturn.Visible = $false
    $btnReturn.Enabled = $false
    $btnReturn.Add_Click({
        if (-not [string]::IsNullOrWhiteSpace($script:ProgressReturnView)) {
            Switch-View $script:ProgressReturnView
        }
    })
    $panel.Controls.Add($btnReturn)
    $script:ProgressReturnBtn = $btnReturn

    return $panel
}

function Initialize-ProgressView {
    param(
        [string]$Title = "実行中...",
        # v0.50.0 (D6): when set (e.g. 'Restore'), Set-ProgressFinished reveals
        # a "return to <view>" button so the operator can iterate instead of
        # ending the session. Null (default, e.g. backup) = only the 完了 button.
        [string]$ReturnView = $null
    )
    $script:ProgressReturnView = $ReturnView
    if ($null -ne $script:ProgressTitle)        { $script:ProgressTitle.Text = $Title }
    if ($null -ne $global:Fbp_ProgressLogBox)   { $global:Fbp_ProgressLogBox.Text = "" }
    if ($null -ne $script:ProgressDoneBtn)      { $script:ProgressDoneBtn.Enabled = $false }
    if ($null -ne $script:ProgressReturnBtn)    { $script:ProgressReturnBtn.Visible = $false; $script:ProgressReturnBtn.Enabled = $false }
    if ($null -ne $global:Fbp_ProgressEntriesGrid) { $global:Fbp_ProgressEntriesGrid.Rows.Clear() }
}

# ============================================================
# Phase 2.7.8: per-entry checklist helpers. Section scripts
# call Initialize-ProgressEntries once with the planned entries,
# then Set-EntryStatus -Id <id> -Status <state> as they progress.
# Each Set-EntryStatus pumps DoEvents so the change paints
# immediately on the synchronous UI thread.
# ============================================================

function Initialize-ProgressEntries {
    param([array]$Entries)
    # $Entries: array of @{ Id = 'XX'; Label = '...' } hashtables
    if ($null -eq $global:Fbp_ProgressEntriesGrid) { return }
    # v0.55.1 (t-0002): do NOT clear the grid here. Multiple restore sections
    # (userdata + outlook_pop) each call this once; clearing made the section that
    # ran last clobber the earlier one's rows, so only Outlook profiles survived in
    # the per-entry list. Accumulate instead so every section's entries are listed.
    # The per-run reset is done once at run start by Initialize-ProgressView
    # (Rows.Clear). Entry ids are section-unique (userdata '01' vs outlook
    # '<profile>/<subKey>'), so Set-EntryStatus still targets the correct row.
    if ($null -eq $Entries -or $Entries.Count -eq 0) { return }
    foreach ($e in $Entries) {
        if ($null -eq $e) { continue }
        $label = if ($e.Label) { "$($e.Label)" } else { '' }
        $idx = $global:Fbp_ProgressEntriesGrid.Rows.Add('[ ] 待機中', $label)
        $global:Fbp_ProgressEntriesGrid.Rows[$idx].Tag = "$($e.Id)"
    }
    if (([System.Windows.Forms.Application] -as [type])) {
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Set-EntryStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Pending','InProgress','Done','Partial','Failed','Skipped')]
        [string]$Status
    )
    if ($null -eq $global:Fbp_ProgressEntriesGrid) { return }
    $marker = switch ($Status) {
        'Pending'    { '[ ] 待機中' }
        'InProgress' { '[*] 実行中...' }
        'Done'       { '[v] 完了' }
        'Partial'    { '[!] 部分成功' }
        'Failed'     { '[x] 失敗' }
        'Skipped'    { '[-] スキップ' }
    }
    $color = switch ($Status) {
        'Done'       { [System.Drawing.Color]::FromArgb(28, 128, 28) }
        'Failed'     { [System.Drawing.Color]::FromArgb(198, 40, 40) }
        'Partial'    { [System.Drawing.Color]::FromArgb(196, 110, 0) }
        'Skipped'    { [System.Drawing.Color]::FromArgb(120, 120, 120) }
        'InProgress' { [System.Drawing.Color]::FromArgb(34, 84, 168) }
        default      { [System.Drawing.Color]::FromArgb(34, 34, 34) }
    }
    foreach ($row in $global:Fbp_ProgressEntriesGrid.Rows) {
        if ("$($row.Tag)" -eq $Id) {
            $row.Cells['Status'].Value = $marker
            $row.Cells['Status'].Style.ForeColor = $color
            # Auto-scroll the in-progress row into view
            if ($Status -eq 'InProgress') {
                try { $global:Fbp_ProgressEntriesGrid.FirstDisplayedScrollingRowIndex = $row.Index } catch { }
            }
            break
        }
    }
    if (([System.Windows.Forms.Application] -as [type])) {
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Add-ProgressLog {
    param([string]$Line)
    # Phase 2.7.10: read from $global: so this works when called from
    # inside section scripts (which run in a different script scope).
    if ($null -eq $global:Fbp_ProgressLogBox) { return }
    $global:Fbp_ProgressLogBox.AppendText($Line + [Environment]::NewLine)
}

function Set-ProgressFinished {
    if ($null -ne $script:ProgressTitle)   { $script:ProgressTitle.Text = "完了しました" }
    if ($null -ne $script:ProgressDoneBtn) { $script:ProgressDoneBtn.Enabled = $true }
    # v0.50.0 (D6): reveal the "return to previous view" button when this run
    # was launched with a ReturnView (restore -> iterate loop).
    if ($null -ne $script:ProgressReturnBtn -and -not [string]::IsNullOrWhiteSpace($script:ProgressReturnView)) {
        $label = switch ($script:ProgressReturnView) {
            'Restore' { "リストア画面へ戻る" }
            'Backup'  { "バックアップ画面へ戻る" }
            default   { "前の画面へ戻る" }
        }
        $script:ProgressReturnBtn.Text    = $label
        $script:ProgressReturnBtn.Visible = $true
        $script:ProgressReturnBtn.Enabled = $true
    }
}

# ============================================================
# Phase 2.7.4: summary formatting helpers used by Invoke-BackupStart
# and Invoke-RestoreStart to render the final-run summary block
# (elapsed time + aggregated data size).
# ============================================================

function Format-Bytes {
    param([Parameter(Mandatory = $true)][long]$Bytes)
    if ($Bytes -lt 0) { return "0 B" }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Format-Duration {
    param([Parameter(Mandatory = $true)][TimeSpan]$Span)
    if ($Span.TotalHours -ge 1) {
        return ('{0}h {1:00}m {2:00}s' -f [int]$Span.TotalHours, $Span.Minutes, $Span.Seconds)
    }
    if ($Span.TotalMinutes -ge 1) {
        return ('{0}m {1:00}s' -f [int]$Span.TotalMinutes, $Span.Seconds)
    }
    return ('{0:N1}s' -f $Span.TotalSeconds)
}

# Phase 2.7.5: end-of-run completion popup. Shows a modal MessageBox so
# the operator notices the run finished even if they stepped away from
# the Progress View. Activate() pulls the form forward, MessageBox itself
# plays the OS notification sound + flashes the taskbar entry.
function Show-CompletionPopup {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Body,
        [Parameter(Mandatory = $true)][string]$Status  # Success / Partial / Failed / Skipped
    )
    $icon = switch ($Status) {
        'Failed'  { [System.Windows.Forms.MessageBoxIcon]::Error }
        'Partial' { [System.Windows.Forms.MessageBoxIcon]::Warning }
        default   { [System.Windows.Forms.MessageBoxIcon]::Information }
    }
    if ($null -ne $script:MainForm) { $script:MainForm.Activate() }
    [void][System.Windows.Forms.MessageBox]::Show(
        $script:MainForm,
        $Body,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        $icon)
}

# Hook called by Switch-View when entering this view (no-op,
# caller is expected to initialize via Initialize-ProgressView).
function Show-ProgressView { }

# Map internal Status enum (kept in English for manifest schema
# compatibility / ValidateSet contracts) to a Japanese display label.
# Used by Set-EntryStatus markers, Show-CompletionPopup titles, and
# Add-ProgressLog wrappers in backup_view / restore_view.
function Get-LocalizedStatusLabel {
    param([Parameter(Mandatory)][string]$Status)
    switch ($Status) {
        'Success'    { '成功' }
        'Partial'    { '部分成功' }
        'Failed'     { '失敗' }
        'Skipped'    { 'スキップ' }
        'Done'       { '完了' }
        'Pending'    { '待機中' }
        'InProgress' { '実行中' }
        default      { $Status }
    }
}
