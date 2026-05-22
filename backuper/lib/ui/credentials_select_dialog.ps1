# ============================================================
# FabriqBackUper - Credentials Restore Select Dialog (v0.20.0)
#
# Modal dialog for selecting which credential entries to include
# in the deployed CSV at restore time. The backup itself always
# captures everything (no source-side filtering); this dialog lets
# operators carve down what actually gets re-registered on the
# target machine.
#
# Show-CredentialsSelectDialog
#   -Credentials [array]
#       Source manifest's `credentials` array
#       (each item has target / type / userName / persist /
#        comment / lastWritten / blobSize / restoreHint).
#   -PreselectedTargets [array]
#       Target strings to start checked. $null / empty array means
#       "all checked" on first open. After the user has interacted,
#       the caller passes back the previous selection so the dialog
#       restores prior state.
#
# Return value
#   Array of selected Target strings (possibly empty), OR
#   $null if the operator cancels.
#
# The dialog is sized 920 x 480 so the grid fits ~10 visible rows.
# Form parent is $script:MainForm when present (centre-parent dock).
# ============================================================

function Show-CredentialsSelectDialog {
    param(
        [Parameter(Mandatory = $true)][array]$Credentials,
        [array]$PreselectedTargets = $null
    )

    # First-time vs subsequent: $null preselected => all checked
    $usePreselect = $false
    $preselectSet = $null
    if ($null -ne $PreselectedTargets) {
        $usePreselect = $true
        $preselectSet = New-Object System.Collections.Generic.HashSet[string]
        foreach ($t in $PreselectedTargets) { [void]$preselectSet.Add([string]$t) }
    }

    $dialog = New-Object System.Windows.Forms.Form
    Set-FormStyle -Form $dialog -Title '資格情報の選択 (リストア対象)' -Width 920 -Height 480
    $dialog.MaximizeBox    = $false
    $dialog.MinimizeBox    = $false
    $dialog.StartPosition  = 'CenterParent'
    if ($null -ne $script:MainForm) { $dialog.Owner = $script:MainForm }

    # ----- Top hint label ------------------------------------
    $hintLbl = New-StyledLabel `
        -Text 'チェックを入れたエントリのみがリストア時に CSV へ書き出され、operator の 登録.bat で再登録の対象になります。' `
        -X 18 -Y 14 -Width 870 -Height 18 -FgColor $script:fgDim
    $dialog.Controls.Add($hintLbl)

    # ----- Bulk action buttons -------------------------------
    $btnAll = New-StyledButton -Text '全選択' -X 18 -Y 40 -Width 100 -Height 26
    $dialog.Controls.Add($btnAll)

    $btnNone = New-StyledButton -Text '全クリア' -X 124 -Y 40 -Width 100 -Height 26
    $dialog.Controls.Add($btnNone)

    $btnClearManual = New-StyledButton -Text 'manual を除外' -X 230 -Y 40 -Width 130 -Height 26
    $dialog.Controls.Add($btnClearManual)

    $countLbl = New-StyledLabel -Text '' -X 600 -Y 44 -Width 290 -Height 20 `
        -Font $script:fontBold -FgColor $script:fgHeader
    $dialog.Controls.Add($countLbl)

    # ----- Grid ----------------------------------------------
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(18, 76)
    $grid.Size = New-Object System.Drawing.Size(870, 322)
    Set-GridStyle -Grid $grid
    $grid.ReadOnly         = $false
    $grid.AllowUserToAddRows = $false
    $grid.RowHeadersVisible  = $false

    $colCk = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colCk.HeaderText = ''
    $colCk.Width      = 32
    $colCk.Name       = 'Check'
    [void]$grid.Columns.Add($colCk)

    $colTarget = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colTarget.HeaderText = 'Target'
    $colTarget.Width = 360
    $colTarget.Name = 'Target'
    $colTarget.ReadOnly = $true
    [void]$grid.Columns.Add($colTarget)

    $colType = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colType.HeaderText = 'Type'
    $colType.Width = 110
    $colType.Name = 'Type'
    $colType.ReadOnly = $true
    [void]$grid.Columns.Add($colType)

    $colUser = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colUser.HeaderText = 'UserName'
    $colUser.Width = 160
    $colUser.Name = 'UserName'
    $colUser.ReadOnly = $true
    [void]$grid.Columns.Add($colUser)

    $colPersist = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colPersist.HeaderText = 'Persist'
    $colPersist.Width = 100
    $colPersist.Name = 'Persist'
    $colPersist.ReadOnly = $true
    [void]$grid.Columns.Add($colPersist)

    $colHint = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colHint.HeaderText = 'Hint'
    $colHint.Name = 'Hint'
    $colHint.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    $colHint.ReadOnly = $true
    [void]$grid.Columns.Add($colHint)

    # Populate rows
    foreach ($c in $Credentials) {
        $checked = $true
        if ($usePreselect) {
            $checked = $preselectSet.Contains([string]$c.target)
        }
        $rowIdx = $grid.Rows.Add($checked, $c.target, $c.type, $c.userName, $c.persist, $c.restoreHint)
        # Tag the row with the canonical Target for retrieval later.
        $grid.Rows[$rowIdx].Tag = [string]$c.target
    }

    # ----- Counter update helper -----------------------------
    $script:_credSelectDialog_UpdateCount = {
        $sel = 0
        $total = $grid.Rows.Count
        foreach ($r in $grid.Rows) {
            if ([bool]$r.Cells['Check'].Value) { $sel++ }
        }
        $countLbl.Text = ('選択中: {0} / {1}' -f $sel, $total)
    }
    & $script:_credSelectDialog_UpdateCount

    # Hook CellValueChanged so the counter follows operator clicks.
    # We must commit the edit so the value is reflected immediately
    # (DataGridView defers checkbox commit until row leaves edit mode).
    $grid.Add_CurrentCellDirtyStateChanged({
        if ($grid.IsCurrentCellDirty -and $grid.CurrentCell -is [System.Windows.Forms.DataGridViewCheckBoxCell]) {
            $grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) | Out-Null
        }
    })
    $grid.Add_CellValueChanged({
        param($s, $e)
        if ($e.ColumnIndex -eq 0) {
            & $script:_credSelectDialog_UpdateCount
        }
    })

    # ----- Bulk button handlers ------------------------------
    $btnAll.Add_Click({
        foreach ($r in $grid.Rows) { $r.Cells['Check'].Value = $true }
        & $script:_credSelectDialog_UpdateCount
    })
    $btnNone.Add_Click({
        foreach ($r in $grid.Rows) { $r.Cells['Check'].Value = $false }
        & $script:_credSelectDialog_UpdateCount
    })
    $btnClearManual.Add_Click({
        foreach ($r in $grid.Rows) {
            if ([string]$r.Cells['Hint'].Value -eq 'manual') {
                $r.Cells['Check'].Value = $false
            }
        }
        & $script:_credSelectDialog_UpdateCount
    })

    $dialog.Controls.Add($grid)

    # ----- OK / Cancel ---------------------------------------
    $btnOk = New-StyledButton -Text 'OK' -X 692 -Y 410 -Width 96 -Height 30 -BgColor $script:bgAccent
    $btnOk.ForeColor = $script:fgWhite
    $btnOk.Font = $script:fontBold
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dialog.Controls.Add($btnOk)
    $dialog.AcceptButton = $btnOk

    $btnCancel = New-StyledButton -Text 'キャンセル' -X 792 -Y 410 -Width 96 -Height 30
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($btnCancel)
    $dialog.CancelButton = $btnCancel

    # ----- Run modal -----------------------------------------
    $result = $dialog.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }

    # Collect selected Targets
    $selected = New-Object System.Collections.Generic.List[string]
    foreach ($r in $grid.Rows) {
        if ([bool]$r.Cells['Check'].Value) {
            $selected.Add([string]$r.Tag) | Out-Null
        }
    }
    return ,@($selected.ToArray())
}
