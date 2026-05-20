# ============================================================
# FabriqBackUper - Userdata Edit Dialog (Phase 2.7)
# Modal dialog for Add / Edit of a userdata_list.csv entry.
# Returns a [PSCustomObject] mirroring the CSV row schema
# (Enabled, SourcePath, Recurse, ExcludePattern, OnConflict,
# IncludeAcl, Description) or $null on cancel.
#
# When the caller passes -Entry, the dialog is pre-populated
# with that row's values (Edit mode). When -Entry is omitted
# or $null, fields start blank with sensible defaults (Add mode).
# ============================================================

function Show-UserdataEditDialog {
    param(
        [object]$Entry = $null,
        [string]$DefaultUserProfilePath = $null
    )

    $script:_userdataEditResult = $null

    $isEdit = $null -ne $Entry
    $title  = if ($isEdit) { 'Edit userdata entry' } else { 'Add userdata entry' }

    # Dialog width 720 (Phase 2.7.1: previous 640 clipped the
    # IncludeAcl checkbox and the env-var hint text on the right).
    $dialog = New-Object System.Windows.Forms.Form
    Set-FormStyle -Form $dialog -Title $title -Width 720 -Height 360
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.StartPosition = 'CenterParent'
    if ($null -ne $script:MainForm) { $dialog.Owner = $script:MainForm }

    # --- SourcePath -------------------------------------------------
    $lblPath = New-StyledLabel -Text 'Source Path:' -X 20 -Y 22 -Width 110 -Height 20 -Font $script:fontBold
    $dialog.Controls.Add($lblPath)
    $txtPath = New-Object System.Windows.Forms.TextBox
    $txtPath.Location = New-Object System.Drawing.Point(140, 20)
    $txtPath.Size = New-Object System.Drawing.Size(400, 24)
    Set-TextBoxStyle -TextBox $txtPath
    $dialog.Controls.Add($txtPath)

    $btnBrowseDir = New-StyledButton -Text 'Folder...' -X 548 -Y 19 -Width 72 -Height 26
    $dialog.Controls.Add($btnBrowseDir)
    $btnBrowseFile = New-StyledButton -Text 'File...' -X 624 -Y 19 -Width 60 -Height 26
    $dialog.Controls.Add($btnBrowseFile)

    $hintLbl = New-StyledLabel `
        -Text 'Env vars: %USERPROFILE% / %APPDATA% / %LOCALAPPDATA% / %USERNAME%' `
        -X 140 -Y 48 -Width 544 -Height 16 -FgColor $script:fgDim
    $dialog.Controls.Add($hintLbl)

    # --- ExcludePattern --------------------------------------------
    $lblExcl = New-StyledLabel -Text 'Exclude Pattern:' -X 20 -Y 80 -Width 110 -Height 20 -Font $script:fontBold
    $dialog.Controls.Add($lblExcl)
    $txtExcl = New-Object System.Windows.Forms.TextBox
    $txtExcl.Location = New-Object System.Drawing.Point(140, 78)
    $txtExcl.Size = New-Object System.Drawing.Size(544, 24)
    Set-TextBoxStyle -TextBox $txtExcl
    $dialog.Controls.Add($txtExcl)

    $exclHint = New-StyledLabel `
        -Text 'Semicolon-separated globs (e.g. *.tmp;~$*;Cache/). Suffix `/` to match directories.' `
        -X 140 -Y 106 -Width 544 -Height 16 -FgColor $script:fgDim
    $dialog.Controls.Add($exclHint)

    # --- OnConflict + Recurse + IncludeAcl -------------------------
    $lblConflict = New-StyledLabel -Text 'On Conflict:' -X 20 -Y 138 -Width 110 -Height 20 -Font $script:fontBold
    $dialog.Controls.Add($lblConflict)
    $cmbConflict = New-StyledComboBox -X 140 -Y 136 -Width 160 -Height 24
    $cmbConflict.Items.AddRange(@('skip', 'overwrite', 'rename'))
    $dialog.Controls.Add($cmbConflict)

    $cbRecurse = New-StyledCheckBox -Text 'Recurse subdirectories' -X 320 -Y 138 -Width 170 -Height 22
    $dialog.Controls.Add($cbRecurse)

    $cbAcl = New-StyledCheckBox -Text 'Include ACL (/COPYALL)' -X 500 -Y 138 -Width 184 -Height 22
    $dialog.Controls.Add($cbAcl)

    # --- Description -----------------------------------------------
    $lblDesc = New-StyledLabel -Text 'Description:' -X 20 -Y 178 -Width 110 -Height 20 -Font $script:fontBold
    $dialog.Controls.Add($lblDesc)
    $txtDesc = New-Object System.Windows.Forms.TextBox
    $txtDesc.Location = New-Object System.Drawing.Point(140, 176)
    $txtDesc.Size = New-Object System.Drawing.Size(544, 24)
    Set-TextBoxStyle -TextBox $txtDesc
    $dialog.Controls.Add($txtDesc)

    # --- Enabled flag ----------------------------------------------
    $cbEnabled = New-StyledCheckBox -Text 'Enabled (selected for backup/restore)' -X 140 -Y 212 -Width 320 -Height 22
    $dialog.Controls.Add($cbEnabled)

    # --- Pre-populate ----------------------------------------------
    if ($isEdit) {
        $txtPath.Text   = "$($Entry.SourcePath)"
        $txtExcl.Text   = "$($Entry.ExcludePattern)"
        $txtDesc.Text   = "$($Entry.Description)"
        $onc = "$($Entry.OnConflict)".Trim().ToLowerInvariant()
        if ($cmbConflict.Items.Contains($onc)) { $cmbConflict.SelectedItem = $onc }
        else { $cmbConflict.SelectedItem = 'overwrite' }
        $cbRecurse.Checked = ("$($Entry.Recurse)" -match '^(1|true|yes)$')
        $cbAcl.Checked     = ("$($Entry.IncludeAcl)" -match '^(1|true|yes)$')
        $cbEnabled.Checked = ("$($Entry.Enabled)" -match '^(1|true|yes)$')
    }
    else {
        $cmbConflict.SelectedItem = 'overwrite'
        $cbRecurse.Checked = $true
        $cbAcl.Checked     = $false
        $cbEnabled.Checked = $true
    }

    # --- Buttons ---------------------------------------------------
    $btnOk = New-StyledButton -Text 'OK' -X 470 -Y 270 -Width 100 -Height 32 -BgColor $script:bgAccent
    $btnOk.Font = $script:fontBold
    $dialog.Controls.Add($btnOk)
    $btnCancel = New-StyledButton -Text 'Cancel' -X 580 -Y 270 -Width 104 -Height 32
    $dialog.Controls.Add($btnCancel)

    # --- Browse handlers -------------------------------------------
    $btnBrowseDir.Add_Click({
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = 'Select source folder'
        # Seed initial folder from the current text if it resolves locally.
        try {
            $seed = $txtPath.Text
            if (-not [string]::IsNullOrWhiteSpace($seed)) {
                $resolved = if (Get-Command Expand-PathWithUser -ErrorAction SilentlyContinue) {
                    Expand-PathWithUser -Path $seed -UserProfilePath $DefaultUserProfilePath
                } else {
                    [Environment]::ExpandEnvironmentVariables($seed)
                }
                if (Test-Path -LiteralPath $resolved) { $fbd.SelectedPath = $resolved }
            }
        } catch { }
        if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            # Phase 2.8.0: if the picked path sits under the selected user's
            # profile, rewrite the prefix back to %USERPROFILE% / %APPDATA% /
            # %LOCALAPPDATA% so the saved entry stays portable across users.
            $picked = $fbd.SelectedPath
            try {
                $picked = ConvertTo-EnvVarPath -AbsolutePath $picked -UserProfilePath $DefaultUserProfilePath
            } catch { }
            $txtPath.Text = $picked
        }
    })

    $btnBrowseFile.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Title = 'Select source file'
        $ofd.CheckFileExists = $true
        $ofd.Multiselect = $false
        try {
            $seed = $txtPath.Text
            if (-not [string]::IsNullOrWhiteSpace($seed)) {
                $resolved = if (Get-Command Expand-PathWithUser -ErrorAction SilentlyContinue) {
                    Expand-PathWithUser -Path $seed -UserProfilePath $DefaultUserProfilePath
                } else {
                    [Environment]::ExpandEnvironmentVariables($seed)
                }
                $dir = Split-Path $resolved -Parent
                if ((-not [string]::IsNullOrWhiteSpace($dir)) -and (Test-Path -LiteralPath $dir)) {
                    $ofd.InitialDirectory = $dir
                }
            }
        } catch { }
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $picked = $ofd.FileName
            try {
                $picked = ConvertTo-EnvVarPath -AbsolutePath $picked -UserProfilePath $DefaultUserProfilePath
            } catch { }
            $txtPath.Text = $picked
        }
    })

    # --- OK / Cancel handlers --------------------------------------
    $btnOk.Add_Click({
        $sp = $txtPath.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($sp)) {
            [System.Windows.Forms.MessageBox]::Show('Source Path is required.', 'Validation',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        $onc = "$($cmbConflict.SelectedItem)".Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($onc)) { $onc = 'overwrite' }

        $script:_userdataEditResult = [PSCustomObject][ordered]@{
            Enabled        = if ($cbEnabled.Checked) { '1' } else { '0' }
            SourcePath     = $sp
            Recurse        = if ($cbRecurse.Checked) { '1' } else { '0' }
            ExcludePattern = $txtExcl.Text
            OnConflict     = $onc
            IncludeAcl     = if ($cbAcl.Checked) { '1' } else { '0' }
            Description    = $txtDesc.Text
        }
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dialog.Close()
    })

    $btnCancel.Add_Click({
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dialog.Close()
    })

    [void]$dialog.ShowDialog()
    return $script:_userdataEditResult
}
