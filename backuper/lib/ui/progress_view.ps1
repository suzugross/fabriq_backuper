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

    $script:ProgressTitle = New-StyledLabel -Text "In progress..." `
        -X 24 -Y 14 -Width 800 -Height 28 -Font $script:fontLarge
    $panel.Controls.Add($script:ProgressTitle)

    # Phase 2.7.8: per-entry status checklist. Sits above the streaming
    # log so an operator can see "Documents done, Chrome in progress,
    # Desktop pending" at a glance and start verifying restored apps
    # the moment their entry flips to Done.
    $entryLbl = New-StyledLabel -Text "Entry status" `
        -X 24 -Y 46 -Width 400 -Height 18 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($entryLbl)

    $entries = New-Object System.Windows.Forms.DataGridView
    $entries.Location = New-Object System.Drawing.Point(24, 68)
    $entries.Size = New-Object System.Drawing.Size(880, 150)
    Set-GridStyle -Grid $entries
    $entries.RowTemplate.Height = 22
    $entries.ColumnHeadersHeight = 24

    $colStatus = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colStatus.HeaderText = "Status"; $colStatus.Width = 130; $colStatus.Name = "Status"
    $colStatus.ReadOnly = $true
    $colStatus.DefaultCellStyle.Font = $script:fontSemiBold
    [void]$entries.Columns.Add($colStatus)

    $colLabel = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colLabel.HeaderText = "Entry"; $colLabel.Name = "Label"; $colLabel.ReadOnly = $true
    $colLabel.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    [void]$entries.Columns.Add($colLabel)

    $panel.Controls.Add($entries)
    $global:Fbp_ProgressEntriesGrid = $entries

    # Streaming log (Phase 2.7.4) — shrunk to make room for the checklist.
    $logLbl = New-StyledLabel -Text "Detail log" `
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
    $btnDone = New-StyledButton -Text "Done" `
        -X 700 -Y 624 -Width 204 -Height 44 -BgColor $script:bgAccent
    $btnDone.Font = $script:fontLarge
    $btnDone.Enabled = $false
    $btnDone.Add_Click({ $script:MainForm.Close() })
    $panel.Controls.Add($btnDone)
    $script:ProgressDoneBtn = $btnDone

    return $panel
}

function Initialize-ProgressView {
    param([string]$Title = "In progress...")
    if ($null -ne $script:ProgressTitle)        { $script:ProgressTitle.Text = $Title }
    if ($null -ne $global:Fbp_ProgressLogBox)   { $global:Fbp_ProgressLogBox.Text = "" }
    if ($null -ne $script:ProgressDoneBtn)      { $script:ProgressDoneBtn.Enabled = $false }
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
    $global:Fbp_ProgressEntriesGrid.Rows.Clear()
    if ($null -eq $Entries -or $Entries.Count -eq 0) { return }
    foreach ($e in $Entries) {
        if ($null -eq $e) { continue }
        $label = if ($e.Label) { "$($e.Label)" } else { '' }
        $idx = $global:Fbp_ProgressEntriesGrid.Rows.Add('[ ] Pending', $label)
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
        'Pending'    { '[ ] Pending' }
        'InProgress' { '[*] In progress...' }
        'Done'       { '[v] Done' }
        'Partial'    { '[!] Partial' }
        'Failed'     { '[x] Failed' }
        'Skipped'    { '[-] Skipped' }
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
    if ($null -ne $script:ProgressTitle)   { $script:ProgressTitle.Text = "Finished" }
    if ($null -ne $script:ProgressDoneBtn) { $script:ProgressDoneBtn.Enabled = $true }
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
