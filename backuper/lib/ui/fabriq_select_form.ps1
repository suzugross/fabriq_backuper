# ============================================================
# Fabriq BackUper - Fabriq Root Selection Dialog
# Shown only when Find-FabriqRoot returns multiple candidates.
# ============================================================
# Pattern reference: checksheet/lib/fabriq_select_form.ps1
# (DataGridView of candidates + OK/Cancel, lavender accent).
#
# Param  : -Candidates  array of System.IO.DirectoryInfo from Find-FabriqRoot
# Returns: [string] selected FullName on OK / Enter / double-click,
#          $null on Cancel / Esc / window close
# ============================================================

function global:Show-FabriqSelectForm {
    param(
        [Parameter(Mandatory)][array]$Candidates
    )

    $script:_fabriqSelectResult = $null

    $form = New-Object System.Windows.Forms.Form
    Set-FormStyle -Form $form -Title 'Fabriq BackUper - Fabriq ディレクトリ選択' -Width 520 -Height 360
    $form.KeyPreview = $true

    # Header band (lavender accent for backuper identity)
    $hdr = New-StyledPanel -X 0 -Y 0 -Width 520 -Height 44 -BgColor $script:bgAccent
    $hdr.Dock = [System.Windows.Forms.DockStyle]::Top
    $form.Controls.Add($hdr)

    $hdrLabel = New-StyledLabel -Text 'Fabriq ディレクトリ選択' `
                                -X 16 -Y 10 -Width 480 -Height 26 `
                                -Font $script:fontLarge -FgColor $script:fgWhite
    $hdr.Controls.Add($hdrLabel)

    # Instruction
    $instLabel = New-StyledLabel `
        -Text '使用する Fabriq 本体ディレクトリを選択してください。' `
        -X 20 -Y 60 -Width 480 -Height 20 -FgColor $script:fgText
    $form.Controls.Add($instLabel)

    $subLabel = New-StyledLabel `
        -Text '(hostlist / passphrase / kernel version の読み取り元になります)' `
        -X 20 -Y 80 -Width 480 -Height 18 -FgColor $script:fgDim
    $form.Controls.Add($subLabel)

    # DataGridView of candidates
    $dgv = New-Object System.Windows.Forms.DataGridView
    $dgv.Location = New-Object System.Drawing.Point(20, 108)
    $dgv.Size     = New-Object System.Drawing.Size(480, 172)
    Set-GridStyle -Grid $dgv

    $colIdx = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colIdx.Name = 'No'
    $colIdx.HeaderText = '#'
    $colIdx.Width = 35
    $colIdx.DefaultCellStyle.Alignment = 'MiddleCenter'
    $dgv.Columns.Add($colIdx) | Out-Null

    $colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colName.Name = 'Name'
    $colName.HeaderText = 'ディレクトリ名'
    $colName.Width = 140
    $dgv.Columns.Add($colName) | Out-Null

    $colPath = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colPath.Name = 'Path'
    $colPath.HeaderText = 'フルパス'
    $colPath.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    $dgv.Columns.Add($colPath) | Out-Null

    for ($i = 0; $i -lt $Candidates.Count; $i++) {
        $dgv.Rows.Add(($i + 1), $Candidates[$i].Name, $Candidates[$i].FullName) | Out-Null
    }
    if ($dgv.Rows.Count -gt 0) {
        $dgv.Rows[0].Selected = $true
    }
    $form.Controls.Add($dgv)

    # Buttons
    $btnOk = New-StyledButton -Text '選択' -X 380 -Y 294 -Width 120 -Height 32 -BgColor $script:bgAccent
    $btnOk.Font = $script:fontBold
    $form.Controls.Add($btnOk)

    $btnCancel = New-StyledButton -Text 'キャンセル' -X 248 -Y 294 -Width 120 -Height 32
    $form.Controls.Add($btnCancel)

    # Submit handler: take selected row's Path cell
    $submitHandler = {
        if ($dgv.SelectedRows.Count -gt 0) {
            $script:_fabriqSelectResult = $dgv.SelectedRows[0].Cells['Path'].Value
            $form.Close()
        }
    }
    $btnOk.Add_Click($submitHandler)

    # Double-click on a row also commits
    $dgv.Add_CellDoubleClick({
        if ($_.RowIndex -ge 0) {
            $script:_fabriqSelectResult = $dgv.Rows[$_.RowIndex].Cells['Path'].Value
            $form.Close()
        }
    })

    # Cancel handler
    $btnCancel.Add_Click({
        $script:_fabriqSelectResult = $null
        $form.Close()
    })

    # Enter submits, Esc cancels
    $form.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $_.SuppressKeyPress = $true
            & $submitHandler
        } elseif ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            $script:_fabriqSelectResult = $null
            $form.Close()
        }
    })

    $form.Add_Shown({ $form.Activate() })
    [void]$form.ShowDialog()
    $form.Dispose()

    return $script:_fabriqSelectResult
}
