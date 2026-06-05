# ============================================================
# Fabriq Cleanup - Cleanup View (standalone, v0.54.0)
# Post-migration bulk deletion of leftover artifacts for the
# selected host: backup trees, Desktop operator-handoff folders,
# and the LAN-Prep folder.
#
# Relocated from backuper/lib/ui/cleanup_view.ps1 (v0.34.0) into the
# standalone Fabriq Cleanup tool (t-0001). Adaptations vs the original
# in-app view:
#   - a 対象ホスト combo is added to the header (the standalone tool has
#     no session form to pre-select $script:CurrentHost); choosing a host
#     sets $script:CurrentHost from $script:HostRows and re-scans.
#   - the "< 戻る" button closes the tool's own form (no Switch-View).
#
# Discovery / recognition / path-safety / revert-gating + the safety
# guard Get-CleanupProtectedRoots all live in backuper/common.ps1, which
# fabriq_cleanup.ps1 dot-sources (single source of truth, also used by the
# Backuper's restore-side delete). This file owns only the WinForms surface.
# Japanese UI is allowed (CLAUDE.md rule 6); this file is UTF-8 with BOM (rule 5).
# ============================================================

$script:CleanupGrid        = $null
$script:CleanupHostCombo   = $null
$script:CleanupAckCheck    = $null
$script:CleanupStatusLabel = $null
$script:CleanupDeleteButton = $null
$script:CleanupCandidates  = @()

function global:New-CleanupView {
    $panel = New-Object System.Windows.Forms.Panel
    $panel.BackColor = $script:bgForm

    # ---- header row ----
    $btnBack = New-StyledButton -Text "< 戻る" -X 16 -Y 10 -Width 80 -Height 28
    $btnBack.Add_Click({ $script:MainForm.Close() })
    $panel.Controls.Add($btnBack)

    $title = New-StyledLabel -Text "クリーンアップ" -X 110 -Y 12 -Width 160 -Height 24 -Font $script:fontLarge
    $panel.Controls.Add($title)

    # ---- host selection (standalone: no session form pre-selects the host) ----
    $hostLbl = New-StyledLabel -Text "対象ホスト:" -X 286 -Y 16 -Width 84 -Height 20 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($hostLbl)

    $hostCombo = New-StyledComboBox -X 372 -Y 12 -Width 424 -Height 24
    foreach ($h in @($script:HostRows)) {
        if ($null -eq $h) { continue }
        $old = "$($h.OldPCname)"
        $new = "$($h.NewPCname)"
        $disp = if (-not [string]::IsNullOrWhiteSpace($new)) { "$old  ->  $new" } else { $old }
        [void]$hostCombo.Items.Add($disp)
    }
    $hostCombo.Add_SelectedIndexChanged({
        $idx = $script:CleanupHostCombo.SelectedIndex
        if ($idx -ge 0 -and $idx -lt @($script:HostRows).Count) {
            $script:CurrentHost = @($script:HostRows)[$idx]
        } else {
            $script:CurrentHost = $null
        }
        Update-CleanupGrid
    })
    $script:CleanupHostCombo = $hostCombo
    $panel.Controls.Add($hostCombo)

    $desc = New-StyledLabel `
        -Text "移行後に残ったバックアップ / 集約フォルダ / LAN-Prep フォルダを一括削除します。これらには平文の個人データが含まれます。" `
        -X 24 -Y 44 -Width 900 -Height 18 -FgColor $script:fgDim
    $panel.Controls.Add($desc)

    $desc2 = New-StyledLabel `
        -Text "削除は元に戻せません。チェックを確認し『選択を削除』を押すと、ホスト名の確認入力を求めます。" `
        -X 24 -Y 64 -Width 900 -Height 18 -FgColor $script:fgDim
    $panel.Controls.Add($desc2)

    # ---- candidate grid ----
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(24, 92)
    $grid.Size     = New-Object System.Drawing.Size(900, 470)
    Set-GridStyle -Grid $grid
    # Set-GridStyle forces $grid.ReadOnly = $true (display-only grids). We
    # need the checkbox column interactively editable, so re-enable cell
    # editing here; per-column ReadOnly (text cols ReadOnly, checkbox col
    # editable) and per-cell ReadOnly (disabled LAN-Prep rows) still apply.
    $grid.ReadOnly = $false
    $grid.AllowUserToAddRows = $false
    $grid.RowHeadersVisible  = $false
    $grid.SelectionMode      = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::None

    $colChk = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colChk.Name = 'sel'; $colChk.HeaderText = '選択'; $colChk.Width = 50; $colChk.ReadOnly = $false
    $grid.Columns.Add($colChk) | Out-Null

    $defs = @(
        @{ Name='kind';   Header='種別';     Width=110 },
        @{ Name='host';   Header='帰属ホスト'; Width=130 },
        @{ Name='loc';    Header='場所';     Width=130 },
        @{ Name='size';   Header='サイズ';   Width=90  },
        @{ Name='date';   Header='作成日時'; Width=140 },
        @{ Name='state';  Header='状態';     Width=130 },
        @{ Name='path';   Header='パス';     Width=600 }
    )
    foreach ($d in $defs) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.Name = $d.Name; $col.HeaderText = $d.Header; $col.Width = $d.Width; $col.ReadOnly = $true
        $grid.Columns.Add($col) | Out-Null
    }

    # commit checkbox edits immediately
    $grid.Add_CurrentCellDirtyStateChanged({
        if ($script:CleanupGrid.IsCurrentCellDirty) {
            $script:CleanupGrid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
        }
    })
    $script:CleanupGrid = $grid
    $panel.Controls.Add($grid)

    # ---- LAN-Prep acknowledgement ----
    $ack = New-Object System.Windows.Forms.CheckBox
    $ack.Text = "LAN-Prep フォルダも削除対象にする (LAN-Prep の『元に戻す』を実行済みであることを確認)"
    $ack.Location = New-Object System.Drawing.Point(24, 570)
    $ack.Size = New-Object System.Drawing.Size(900, 22)
    $ack.BackColor = $script:bgForm
    $ack.ForeColor = $script:fgHeader
    $ack.Add_CheckedChanged({ Update-CleanupLanPrepRows })
    $script:CleanupAckCheck = $ack
    $panel.Controls.Add($ack)

    # ---- action row ----
    $btnRescan = New-StyledButton -Text "再スキャン" -X 24 -Y 600 -Width 120 -Height 34
    $btnRescan.Add_Click({ Update-CleanupGrid })
    $panel.Controls.Add($btnRescan)

    $btnDelete = New-StyledButton -Text "選択を削除" -X 700 -Y 600 -Width 224 -Height 34 -BgColor $script:bgDelete
    $btnDelete.ForeColor = $script:fgWhite
    $btnDelete.Font = $script:fontBold
    $btnDelete.Add_Click({ Invoke-CleanupDelete })
    $script:CleanupDeleteButton = $btnDelete
    $panel.Controls.Add($btnDelete)

    $status = New-StyledLabel -Text "" -X 160 -Y 608 -Width 520 -Height 20 -FgColor $script:fgDim
    $script:CleanupStatusLabel = $status
    $panel.Controls.Add($status)

    return $panel
}

function global:Show-CleanupView {
    # on-show hook (called once after the form is built).
    # Auto-select this PC's host row: post-migration cleanup normally runs on the
    # NEW/target PC, so match NewPCName first, then OldPCname (Resolve-HostByComputerName
    # with PreferMode '' / 'Restore' tries NewPCName -> OldPCname). The operator can
    # still change the combo. Setting SelectedIndex fires SelectedIndexChanged, which
    # sets $script:CurrentHost and runs Update-CleanupGrid.
    if ($null -ne $script:CleanupHostCombo -and $script:CleanupHostCombo.Items.Count -gt 0 -and
        $script:CleanupHostCombo.SelectedIndex -lt 0 -and
        (Get-Command Resolve-HostByComputerName -ErrorAction SilentlyContinue)) {
        $rows = @($script:HostRows)
        $match = Resolve-HostByComputerName -HostList $rows -ComputerName $env:COMPUTERNAME -PreferMode 'Restore'
        if ($null -ne $match) {
            $idx = [array]::IndexOf($rows, $match)
            if ($idx -ge 0 -and $idx -lt $script:CleanupHostCombo.Items.Count) {
                Show-Info "Auto-selected host for this PC ('$env:COMPUTERNAME'): $($match.OldPCname) -> $($match.NewPCname)"
                $script:CleanupHostCombo.SelectedIndex = $idx   # fires SelectedIndexChanged -> Update-CleanupGrid
                return
            }
        }
        Show-Info "No hostlist row matches this PC ('$env:COMPUTERNAME'); select a host manually."
    }
    Update-CleanupGrid
}

function global:Update-CleanupGrid {
    if ($null -eq $script:CleanupGrid) { return }
    $oldPc = if ($null -ne $script:CurrentHost) { "$($script:CurrentHost.OldPCname)" } else { '' }

    $script:CleanupGrid.Rows.Clear()
    if ([string]::IsNullOrWhiteSpace($oldPc)) {
        $script:CleanupStatusLabel.Text = "上の『対象ホスト』を選択してください。"
        if ($null -ne $script:CleanupDeleteButton) { $script:CleanupDeleteButton.Enabled = $false }
        return
    }

    $script:CleanupStatusLabel.Text = "スキャン中..."
    [System.Windows.Forms.Application]::DoEvents()

    $cands = @()
    try {
        $cands = @(Get-CleanupCandidate -BackuperRoot $script:BackuperRoot `
            -MigrationProfile $script:MigrationProfile -OldPcName $oldPc)
    }
    catch {
        $script:CleanupStatusLabel.Text = "スキャン失敗: $($_.Exception.Message)"
        return
    }
    $script:CleanupCandidates = $cands
    $ackOn = ($null -ne $script:CleanupAckCheck -and $script:CleanupAckCheck.Checked)

    foreach ($c in $cands) {
        $kindLabel = switch ("$($c.Kind)") {
            'backup-tree' { 'バックアップ' }
            'handoff'     { '集約フォルダ' }
            'lanprep'     { 'LAN-Prep' }
            default       { "$($c.Kind)" }
        }
        $hostLabel = if ([string]::IsNullOrWhiteSpace($c.AttributedHost)) { '(不明)' } else { "$($c.AttributedHost)" }
        $sizeLabel = ''
        $b = [long]$c.SizeBytes
        if ($b -ge 1GB)      { $sizeLabel = ('{0:N2} GB' -f ($b / 1GB)) }
        elseif ($b -ge 1MB)  { $sizeLabel = ('{0:N1} MB' -f ($b / 1MB)) }
        elseif ($b -ge 1KB)  { $sizeLabel = ('{0:N0} KB' -f ($b / 1KB)) }
        else                 { $sizeLabel = ("$b B") }

        $selectable = $true
        $state = '削除可'
        if ($c.IsLanPrep -and -not $c.Reverted) {
            $state = '要「元に戻す」'
            if (-not $ackOn) { $selectable = $false }
        }
        elseif ($c.Unidentified) { $state = '識別不能（要確認）' }
        elseif ($c.ParentPath)   { $state = '親(LAN-Prep)に内包' }

        $precheck = $selectable -and (-not $c.IsLanPrep)

        $rowIdx = $script:CleanupGrid.Rows.Add($precheck, $kindLabel, $hostLabel, "$($c.Source)", $sizeLabel, "$($c.CreatedAt)", $state, "$($c.Path)")
        $row = $script:CleanupGrid.Rows[$rowIdx]
        $row.Tag = $c
        $row.Cells['sel'].ReadOnly = (-not $selectable)
        if (-not $selectable) {
            $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray
        }
    }

    if ($script:CleanupGrid.Rows.Count -eq 0) {
        $script:CleanupStatusLabel.Text = "ホスト『$oldPc』の削除対象は見つかりませんでした。"
        if ($null -ne $script:CleanupDeleteButton) { $script:CleanupDeleteButton.Enabled = $false }
    }
    else {
        $script:CleanupStatusLabel.Text = "$($script:CleanupGrid.Rows.Count) 件の候補。チェックして『選択を削除』。"
        if ($null -ne $script:CleanupDeleteButton) { $script:CleanupDeleteButton.Enabled = $true }
    }
}

function global:Update-CleanupLanPrepRows {
    # Re-evaluate LAN-Prep row selectability when the acknowledgement
    # checkbox is toggled (no disk re-scan, preserves other checks).
    if ($null -eq $script:CleanupGrid) { return }
    $ackOn = ($null -ne $script:CleanupAckCheck -and $script:CleanupAckCheck.Checked)
    foreach ($row in $script:CleanupGrid.Rows) {
        $c = $row.Tag
        if ($null -eq $c -or -not $c.IsLanPrep) { continue }
        $enabled = ($c.Reverted -or $ackOn)
        $row.Cells['sel'].ReadOnly = (-not $enabled)
        if (-not $enabled) {
            $row.Cells['sel'].Value = $false
            $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray
        }
        else {
            $row.DefaultCellStyle.ForeColor = $script:fgHeader
        }
    }
}

function global:Invoke-CleanupDelete {
    if ($null -eq $script:CleanupGrid) { return }

    # collect checked candidates
    $selected = New-Object System.Collections.Generic.List[object]
    foreach ($row in $script:CleanupGrid.Rows) {
        $c = $row.Tag
        if ($null -eq $c) { continue }
        if ($row.Cells['sel'].Value -eq $true) { $selected.Add($c) }
    }
    if ($selected.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("削除対象が選択されていません。", "Fabriq Cleanup",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    # containment: if a candidate's parent (LAN-Prep) is also selected, the
    # parent delete will remove it -- skip it from the explicit delete list.
    $selectedPaths = @{}
    foreach ($c in $selected) { $selectedPaths["$($c.Path.TrimEnd('\').ToLowerInvariant())"] = $true }
    $toDelete = New-Object System.Collections.Generic.List[object]
    foreach ($c in $selected) {
        $skip = $false
        if (-not [string]::IsNullOrWhiteSpace($c.ParentPath)) {
            $pk = "$($c.ParentPath.TrimEnd('\').ToLowerInvariant())"
            if ($selectedPaths.ContainsKey($pk)) { $skip = $true }
        }
        if (-not $skip) { $toDelete.Add($c) }
    }

    $totalBytes = ($selected | Measure-Object -Property SizeBytes -Sum).Sum
    $totalGb = if ($totalBytes) { '{0:N2} GB' -f ($totalBytes / 1GB) } else { '0 GB' }
    $oldPc = if ($null -ne $script:CurrentHost) { "$($script:CurrentHost.OldPCname)" } else { '' }

    $summary = "以下を完全に削除します（元に戻せません）:`n`n" +
               "  対象フォルダ数 : $($toDelete.Count)`n" +
               "  合計サイズ     : $totalGb`n`n" +
               "これらには平文の個人データが含まれます。`n" +
               "続行するには下の欄に対象ホスト名『$oldPc』を入力してください。"

    if (-not (Show-CleanupConfirmDialog -Summary $summary -Expected $oldPc)) {
        $script:CleanupStatusLabel.Text = "削除はキャンセルされました。"
        return
    }

    # protected roots for the safety guard (from common.ps1)
    $roots = Get-CleanupProtectedRoots

    $deleted = 0; $failed = 0; $skipped = 0
    $failLines = New-Object System.Collections.Generic.List[string]
    $logPath = $null
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    foreach ($c in $toDelete) {
        $r = Remove-CleanupArtifact -Path $c.Path -SubtreeDenyRoots $roots.Subtree -ProtectedRoots $roots.Protected
        switch ($r.Status) {
            'Deleted' { $deleted++ }
            'Skipped' { $skipped++ }
            default {
                $failed++
                $failLines.Add(("  ・{0}`n      {1}" -f $c.Path, $(if ($r.Error) { $r.Error } else { '(原因不明)' })))
            }
        }
        $line = "[{0}] {1} kind={2} host={3} -> {4}{5}" -f `
            $stamp, $c.Path, $c.Kind, $c.AttributedHost, $r.Status, `
            $(if ($r.Error) { " ($($r.Error))" } else { '' })
        $logPath = Write-CleanupHistory -BackuperRoot $script:BackuperRoot -Line $line
    }

    $msg = "削除結果`n`n  成功 : $deleted`n  失敗 : $failed`n  スキップ : $skipped"
    if ($failed -gt 0) {
        $shown = @($failLines | Select-Object -First 5)
        $msg += "`n`n【失敗の詳細】`n" + ($shown -join "`n")
        if ($failLines.Count -gt 5) { $msg += "`n  ... 他 $($failLines.Count - 5) 件" }
        if ($logPath) { $msg += "`n`n全ログ: $logPath" }
    }
    $icon = if ($failed -gt 0) { [System.Windows.Forms.MessageBoxIcon]::Warning } else { [System.Windows.Forms.MessageBoxIcon]::Information }
    [System.Windows.Forms.MessageBox]::Show($msg, "Fabriq Cleanup - クリーンアップ",
        [System.Windows.Forms.MessageBoxButtons]::OK, $icon) | Out-Null

    Update-CleanupGrid
}

function global:Show-CleanupConfirmDialog {
    # Strong confirmation: operator must type the exact host name.
    # Returns $true only when the typed text matches $Expected.
    param(
        [Parameter(Mandatory = $true)][string]$Summary,
        [Parameter(Mandatory = $true)][string]$Expected
    )
    $dlg = New-Object System.Windows.Forms.Form
    Set-FormStyle -Form $dlg -Title 'Fabriq Cleanup - 削除の確認' -Width 520 -Height 280
    $dlg.KeyPreview = $true

    $lbl = New-StyledLabel -Text $Summary -X 20 -Y 16 -Width 470 -Height 150 -FgColor $script:bgDelete
    $dlg.Controls.Add($lbl)

    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point(20, 176)
    $box.Size     = New-Object System.Drawing.Size(470, 24)
    Set-TextBoxStyle -TextBox $box
    $dlg.Controls.Add($box)

    $result = @{ Ok = $false }

    $btnCancel = New-StyledButton -Text 'キャンセル' -X 250 -Y 212 -Width 110 -Height 32
    $btnCancel.Add_Click({ $result.Ok = $false; $dlg.Close() })
    $dlg.Controls.Add($btnCancel)

    $btnOk = New-StyledButton -Text '削除する' -X 380 -Y 212 -Width 110 -Height 32 -BgColor $script:bgDelete
    $btnOk.ForeColor = $script:fgWhite
    $btnOk.Add_Click({
        if ($box.Text -ceq $Expected) {
            $result.Ok = $true; $dlg.Close()
        }
        else {
            [System.Windows.Forms.MessageBox]::Show("ホスト名が一致しません。", "Fabriq Cleanup",
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        }
    })
    $dlg.Controls.Add($btnOk)

    $dlg.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $result.Ok = $false; $dlg.Close() }
    })
    $dlg.Add_Shown({ $dlg.Activate(); $box.Focus() })
    [void]$dlg.ShowDialog()
    $dlg.Dispose()
    return [bool]$result.Ok
}
