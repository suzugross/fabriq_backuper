# ============================================================
# Fabriq Extended Hostlist Editor - View (t-0011, v0.64.0)
#
# Standalone editor for backuper/data/extended_hostlist.csv. The grid is SEEDED
# FROM the Fabriq hostlist (absolute source of truth), so a row can only be
# authored against a real (OldPCname, NewPCname) pair -- reconciliation is
# enforced at WRITE time. The UNC password is encrypted with Protect-FabriqValue
# (portable ENC:, master-passphrase-gated) and round-trip verified before save;
# the plaintext never touches disk and is cleared from the field after save.
#
# Comments / console output English; WinForms UI Japanese (CLAUDE.md rules).
# ============================================================

$script:EhColumns = @('Enabled','OldPCname','NewPCname','UncUsername','UncPassword','VisualLabel','VisualColor','Note')
$script:EhFabriqRows = @()
$script:EhRows       = $null    # System.Collections.Generic.List[object] of raw extended rows
$script:EhGrid       = $null
$script:EhFields     = @{}
$script:EhSelectedPair = $null  # @{ Old=..; New=.. } of the selected fabriq host
$script:EhDataPath   = $null
$script:EhY          = 0
$script:EhBx         = 560
$script:EhLw         = 100
$script:EhFw         = 280
$script:EhFx         = 660

function Get-EhExtendedRowForPair {
    # Find the raw extended row whose normalized pair equals the given fabriq pair.
    param([string]$OldName, [string]$NewName)
    if ($null -eq $script:EhRows) { return $null }
    $key = (($OldName.Trim()) + '|' + ($NewName.Trim())).ToLowerInvariant()
    foreach ($r in $script:EhRows) {
        $ro = if ($r.PSObject.Properties.Name -contains 'OldPCname') { "$($r.OldPCname)".Trim() } else { '' }
        $rn = if ($r.PSObject.Properties.Name -contains 'NewPCname') { "$($r.NewPCname)".Trim() } else { '' }
        if ((($ro + '|' + $rn).ToLowerInvariant()) -eq $key) { return $r }
    }
    return $null
}

function Get-EhCredentialStatus {
    # Human-readable credential status for a raw extended row.
    param($Row)
    if ($null -eq $Row) { return '未登録' }
    $pw = if ($Row.PSObject.Properties.Name -contains 'UncPassword') { "$($Row.UncPassword)" } else { '' }
    if ([string]::IsNullOrWhiteSpace($pw)) { return '未登録' }
    if ($pw.StartsWith('ENC:')) { return '登録済(暗号化)' }
    return '平文(無効)'
}

function Read-EhExtendedRows {
    # (Re)load the raw extended hostlist rows (ALL rows incl. disabled) into the
    # mutable list, normalizing each to the canonical column set so save is stable.
    param([string]$Path)
    $list = New-Object System.Collections.Generic.List[object]
    if (-not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path -LiteralPath $Path)) {
        try {
            $raw = @(Import-Csv -Path $Path -Encoding UTF8)
            foreach ($r in $raw) {
                $o = [ordered]@{}
                foreach ($c in $script:EhColumns) {
                    $o[$c] = if ($r.PSObject.Properties.Name -contains $c) { "$($r.$c)" } else { '' }
                }
                [void]$list.Add([pscustomobject]$o)
            }
        } catch {
            Show-Warning "Extended hostlist read failed (starting empty): $($_.Exception.Message)"
        }
    }
    $script:EhRows = $list
}

function Save-EhRowsToDisk {
    # Persist the mutable list to extended_hostlist.csv as UTF-8 BOM + CRLF with
    # the canonical column order. Export-Csv -Encoding UTF8 (PS5.1) writes a BOM.
    param([string]$Path)
    $ordered = @()
    foreach ($r in $script:EhRows) {
        $o = [ordered]@{}
        foreach ($c in $script:EhColumns) {
            $o[$c] = if ($r.PSObject.Properties.Name -contains $c) { "$($r.$c)" } else { '' }
        }
        $ordered += [pscustomobject]$o
    }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $ordered | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
}

function Update-EhGrid {
    # Rebuild the grid from the Fabriq hostlist (source of truth) joined with any
    # extended row for each pair.
    if ($null -eq $script:EhGrid) { return }
    $script:EhGrid.Rows.Clear()
    foreach ($h in @($script:EhFabriqRows)) {
        $old = if ($h.PSObject.Properties.Name -contains 'OldPCname') { "$($h.OldPCname)".Trim() } else { '' }
        if ([string]::IsNullOrWhiteSpace($old)) { continue }
        $new = if ($h.PSObject.Properties.Name -contains 'NewPCname') { "$($h.NewPCname)".Trim() } else { '' }
        $ext = Get-EhExtendedRowForPair -OldName $old -NewName $new
        $status = Get-EhCredentialStatus -Row $ext
        $user = if ($null -ne $ext -and $ext.PSObject.Properties.Name -contains 'UncUsername') { "$($ext.UncUsername)" } else { '' }
        $label = if ($null -ne $ext -and $ext.PSObject.Properties.Name -contains 'VisualLabel') { "$($ext.VisualLabel)" } else { '' }
        $enabled = if ($null -eq $ext) { '-' } else {
            $ev = if ($ext.PSObject.Properties.Name -contains 'Enabled') { "$($ext.Enabled)".Trim() } else { '1' }
            if ($ev -eq '0' -or $ev -ieq 'false' -or $ev -ieq 'no') { '無効' } else { '有効' }
        }
        [void]$script:EhGrid.Rows.Add($old, $new, $status, $user, $label, $enabled)
    }
}

function Set-EhEditFieldsFromSelection {
    # Populate the edit fields from the selected fabriq row + its extended row.
    if ($null -eq $script:EhGrid -or $script:EhGrid.SelectedRows.Count -eq 0) { return }
    $row = $script:EhGrid.SelectedRows[0]
    $old = "$($row.Cells['OldPCname'].Value)"
    $new = "$($row.Cells['NewPCname'].Value)"
    $script:EhSelectedPair = @{ Old = $old; New = $new }
    $newDisp = if ([string]::IsNullOrWhiteSpace($new)) { '(NewPCname なし)' } else { $new }
    $script:EhFields['IdentityLabel'].Text = "対象: $old  ->  $newDisp"
    $ext = Get-EhExtendedRowForPair -OldName $old -NewName $new
    $get = { param($r, $c) if ($null -ne $r -and $r.PSObject.Properties.Name -contains $c) { "$($r.$c)" } else { '' } }
    $script:EhFields['UncUsername'].Text = (& $get $ext 'UncUsername')
    $script:EhFields['Password'].Text    = ''   # never show the stored secret
    $script:EhFields['VisualLabel'].Text = (& $get $ext 'VisualLabel')
    $script:EhFields['VisualColor'].Text = (& $get $ext 'VisualColor')
    $script:EhFields['Note'].Text        = (& $get $ext 'Note')
    $enabledVal = (& $get $ext 'Enabled')
    $script:EhFields['Enabled'].Checked  = -not ($enabledVal -eq '0' -or $enabledVal -ieq 'false' -or $enabledVal -ieq 'no')
    $pwHint = Get-EhCredentialStatus -Row $ext
    $script:EhFields['PasswordHint'].Text = "現在: $pwHint （新パスワード入力で更新／空欄で現状維持）"
}

function Add-EhField {
    # Add a labelled textbox to the edit panel at the running $script:EhY cursor.
    param([Parameter(Mandatory)]$Panel, [string]$Caption, [string]$Key, [bool]$Masked)
    $l = New-StyledLabel -Text $Caption -X $script:EhBx -Y ($script:EhY + 2) -Width $script:EhLw -Height 20 -FgColor $script:fgHeader
    $Panel.Controls.Add($l)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($script:EhFx, $script:EhY)
    $t.Size = New-Object System.Drawing.Size($script:EhFw, 24)
    Set-TextBoxStyle -TextBox $t
    if ($Masked) { $t.UseSystemPasswordChar = $true }
    $Panel.Controls.Add($t)
    $script:EhFields[$Key] = $t
    $script:EhY = $script:EhY + 32
}

function Invoke-EhSave {
    param([string]$Path)
    if ($null -eq $script:EhSelectedPair) {
        [System.Windows.Forms.MessageBox]::Show("先に左の一覧から対象ホストを選択してください。", "拡張HOSTLIST 編集",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    $old = $script:EhSelectedPair.Old
    $new = $script:EhSelectedPair.New
    $ext = Get-EhExtendedRowForPair -OldName $old -NewName $new

    # Resolve the password: typed -> encrypt + round-trip verify; blank -> keep existing.
    $typed = $script:EhFields['Password'].Text
    $encPw = if ($null -ne $ext -and $ext.PSObject.Properties.Name -contains 'UncPassword') { "$($ext.UncPassword)" } else { '' }
    if (-not [string]::IsNullOrEmpty($typed)) {
        if ([string]::IsNullOrWhiteSpace($global:FabriqMasterPassphrase)) {
            [System.Windows.Forms.MessageBox]::Show("マスターパスフレーズが未設定のため暗号化できません。", "拡張HOSTLIST 編集",
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            return
        }
        try {
            $candidate = Protect-FabriqValue -PlainValue $typed -Passphrase $global:FabriqMasterPassphrase
            $verify = Unprotect-FabriqValue -EncryptedValue $candidate -Passphrase $global:FabriqMasterPassphrase
            if ($verify -ne $typed) {
                [System.Windows.Forms.MessageBox]::Show("暗号化の自己検証に失敗しました（保存中止）。", "拡張HOSTLIST 編集",
                    [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                return
            }
            $encPw = $candidate
        } catch {
            [System.Windows.Forms.MessageBox]::Show("暗号化に失敗しました: $($_.Exception.Message)", "拡張HOSTLIST 編集",
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            return
        }
    }

    $enabledStr = if ($script:EhFields['Enabled'].Checked) { '1' } else { '0' }
    $vals = [ordered]@{
        Enabled     = $enabledStr
        OldPCname   = $old
        NewPCname   = $new
        UncUsername = $script:EhFields['UncUsername'].Text.Trim()
        UncPassword = $encPw
        VisualLabel = $script:EhFields['VisualLabel'].Text
        VisualColor = $script:EhFields['VisualColor'].Text.Trim()
        Note        = $script:EhFields['Note'].Text
    }
    if ($null -ne $ext) {
        foreach ($c in $script:EhColumns) { $ext.$c = $vals[$c] }
    } else {
        [void]$script:EhRows.Add([pscustomobject]$vals)
    }

    try {
        Save-EhRowsToDisk -Path $Path
    } catch {
        [System.Windows.Forms.MessageBox]::Show("保存に失敗しました: $($_.Exception.Message)", "拡張HOSTLIST 編集",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }
    $script:EhFields['Password'].Text = ''   # clear plaintext from the field
    Update-EhGrid
    [System.Windows.Forms.MessageBox]::Show("保存しました: $old", "拡張HOSTLIST 編集",
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}

function Invoke-EhDelete {
    param([string]$Path)
    if ($null -eq $script:EhSelectedPair) { return }
    $old = $script:EhSelectedPair.Old
    $new = $script:EhSelectedPair.New
    $ext = Get-EhExtendedRowForPair -OldName $old -NewName $new
    if ($null -eq $ext) {
        [System.Windows.Forms.MessageBox]::Show("このホストには拡張エントリがありません。", "拡張HOSTLIST 編集",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    $confirm = [System.Windows.Forms.MessageBox]::Show("$old の拡張エントリ（資格情報含む）を削除しますか？", "拡張HOSTLIST 編集",
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    [void]$script:EhRows.Remove($ext)
    try {
        Save-EhRowsToDisk -Path $Path
    } catch {
        [System.Windows.Forms.MessageBox]::Show("保存に失敗しました: $($_.Exception.Message)", "拡張HOSTLIST 編集",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }
    Update-EhGrid
    Set-EhEditFieldsFromSelection
}

function Get-EhPairKey {
    # Normalized reconciliation key from a name pair (trim + lowercase).
    param([string]$OldName, [string]$NewName)
    return (("$OldName".Trim()) + '|' + ("$NewName".Trim())).ToLowerInvariant()
}

function Resolve-EhImportField {
    # Field value for an imported row: prefer the staging column (even if blank,
    # when the column is present = explicit intent), else keep the existing row's
    # value (so partial staging CSVs do not wipe data), else ''.
    param($StagingRow, $ExistingRow, [string]$Col)
    if ($StagingRow.PSObject.Properties.Name -contains $Col) { return "$($StagingRow.$Col)" }
    if ($null -ne $ExistingRow -and $ExistingRow.PSObject.Properties.Name -contains $Col) { return "$($ExistingRow.$Col)" }
    return ''
}

function Invoke-EhBulkImport {
    # Bulk-import a staging CSV into extended_hostlist.csv. The staging CSV may
    # carry PLAINTEXT passwords in a 'Password' column (encrypted here via
    # Protect-FabriqValue + round-trip verify) OR a pre-encrypted 'UncPassword'
    # (ENC:) accepted verbatim. Every row is reconciled against the Fabriq
    # hostlist (absolute source of truth); rows whose (OldPCname,NewPCname) has
    # no exact Fabriq match are SKIPPED. Rows are UPSERTED (merged) by pair.
    # The plaintext staging file is the operator's to delete afterwards (warned).
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($global:FabriqMasterPassphrase)) {
        [System.Windows.Forms.MessageBox]::Show("マスターパスフレーズが未設定のため取込できません。", "拡張HOSTLIST 編集",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Title = "一括取込する CSV を選択 (Password 列=平文 / UncPassword 列=ENC: 既存暗号化)"
    $ofd.Filter = "CSV (*.csv)|*.csv|All files (*.*)|*.*"
    $dataDir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dataDir) -and (Test-Path -LiteralPath $dataDir)) { $ofd.InitialDirectory = $dataDir }
    if ($ofd.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $staging = $ofd.FileName

    $rows = $null
    try { $rows = @(Import-Csv -Path $staging -Encoding UTF8) }
    catch {
        [System.Windows.Forms.MessageBox]::Show("CSV 読込に失敗しました: $($_.Exception.Message)", "拡張HOSTLIST 編集",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }

    # Fabriq pair key set (absolute source of truth).
    $fabriqKeys = @{}
    foreach ($h in @($script:EhFabriqRows)) {
        $o = if ($h.PSObject.Properties.Name -contains 'OldPCname') { "$($h.OldPCname)".Trim() } else { '' }
        if ([string]::IsNullOrEmpty($o)) { continue }
        $n = if ($h.PSObject.Properties.Name -contains 'NewPCname') { "$($h.NewPCname)".Trim() } else { '' }
        $fabriqKeys[(Get-EhPairKey -OldName $o -NewName $n)] = $true
    }

    $imp = 0; $skip = 0; $errN = 0
    foreach ($r in $rows) {
        $o = if ($r.PSObject.Properties.Name -contains 'OldPCname') { "$($r.OldPCname)".Trim() } else { '' }
        if ([string]::IsNullOrWhiteSpace($o)) { $skip++; continue }
        $n = if ($r.PSObject.Properties.Name -contains 'NewPCname') { "$($r.NewPCname)".Trim() } else { '' }
        if (-not $fabriqKeys.ContainsKey((Get-EhPairKey -OldName $o -NewName $n))) { $skip++; continue }
        $existing = Get-EhExtendedRowForPair -OldName $o -NewName $n

        # Password resolution: plaintext 'Password' -> encrypt; else 'UncPassword'
        # must be ENC: (verbatim) or is rejected; else keep existing.
        $encPw = if ($null -ne $existing -and $existing.PSObject.Properties.Name -contains 'UncPassword') { "$($existing.UncPassword)" } else { '' }
        $plain = if ($r.PSObject.Properties.Name -contains 'Password') { "$($r.Password)" } else { '' }
        if (-not [string]::IsNullOrEmpty($plain)) {
            try {
                $cand = Protect-FabriqValue -PlainValue $plain -Passphrase $global:FabriqMasterPassphrase
                if ((Unprotect-FabriqValue -EncryptedValue $cand -Passphrase $global:FabriqMasterPassphrase) -ne $plain) { $errN++; continue }
                $encPw = $cand
            } catch { $errN++; continue }
        }
        elseif ($r.PSObject.Properties.Name -contains 'UncPassword') {
            $rawPw = "$($r.UncPassword)"
            if (-not [string]::IsNullOrWhiteSpace($rawPw)) {
                if ($rawPw.StartsWith('ENC:')) { $encPw = $rawPw } else { $errN++; continue }
            }
        }

        $enabled = Resolve-EhImportField -StagingRow $r -ExistingRow $existing -Col 'Enabled'
        if ([string]::IsNullOrWhiteSpace($enabled)) { $enabled = '1' }
        $vals = [ordered]@{
            Enabled     = $enabled
            OldPCname   = $o
            NewPCname   = $n
            UncUsername = (Resolve-EhImportField -StagingRow $r -ExistingRow $existing -Col 'UncUsername')
            UncPassword = $encPw
            VisualLabel = (Resolve-EhImportField -StagingRow $r -ExistingRow $existing -Col 'VisualLabel')
            VisualColor = (Resolve-EhImportField -StagingRow $r -ExistingRow $existing -Col 'VisualColor')
            Note        = (Resolve-EhImportField -StagingRow $r -ExistingRow $existing -Col 'Note')
        }
        if ($null -ne $existing) {
            foreach ($c in $script:EhColumns) { $existing.$c = $vals[$c] }
        } else {
            [void]$script:EhRows.Add([pscustomobject]$vals)
        }
        $imp++
    }

    try { Save-EhRowsToDisk -Path $Path }
    catch {
        [System.Windows.Forms.MessageBox]::Show("保存に失敗しました: $($_.Exception.Message)", "拡張HOSTLIST 編集",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }
    Update-EhGrid
    Set-EhEditFieldsFromSelection
    [System.Windows.Forms.MessageBox]::Show(
        ("取込 {0} 件 / スキップ(Fabriq不一致) {1} 件 / エラー {2} 件`n`n注意: 平文パスワードを含むステージング CSV は取込後に削除してください:`n{3}" -f $imp, $skip, $errN, $staging),
        "拡張HOSTLIST 編集", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}

function New-ExtHostlistEditorView {
    # Build the editor panel. $script:EhDataPath must be set by the launcher.
    param([Parameter(Mandatory = $true)][string]$DataPath)
    $script:EhDataPath = $DataPath

    $panel = New-Object System.Windows.Forms.Panel
    $panel.BackColor = $script:bgForm

    $title = New-StyledLabel -Text "拡張HOSTLIST 編集" -X 20 -Y 12 -Width 400 -Height 26 -Font $script:fontLarge
    $panel.Controls.Add($title)

    $info = New-StyledLabel -Text "ファイル: $DataPath" -X 20 -Y 42 -Width 900 -Height 18 -FgColor $script:fgDim
    $panel.Controls.Add($info)

    $hint = New-StyledLabel -Text "一覧は Fabriq hostlist（絶対正）から生成。行を選び右側で資格情報・視覚情報を編集して保存します。" `
        -X 20 -Y 62 -Width 720 -Height 18 -FgColor $script:fgDim
    $panel.Controls.Add($hint)

    $btnImport = New-StyledButton -Text "CSV一括取込" -X 760 -Y 10 -Width 200 -Height 30 -BgColor $script:bgAccent
    $btnImport.Add_Click({ Invoke-EhBulkImport -Path $script:EhDataPath })
    $panel.Controls.Add($btnImport)

    # ---- grid (left) ----
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(20, 90)
    $grid.Size = New-Object System.Drawing.Size(520, 520)
    Set-GridStyle -Grid $grid
    $grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::None
    $defs = @(
        @{ N = 'OldPCname';  H = '旧PC名';   W = 110 },
        @{ N = 'NewPCname';  H = '新PC名';   W = 110 },
        @{ N = 'Cred';       H = '資格情報'; W = 110 },
        @{ N = 'User';       H = 'ユーザ名'; W = 100 },
        @{ N = 'Label';      H = 'ラベル';   W = 60  },
        @{ N = 'Enabled';    H = '状態';     W = 50  }
    )
    foreach ($d in $defs) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.Name = $d.N; $col.HeaderText = $d.H; $col.Width = $d.W; $col.ReadOnly = $true
        $grid.Columns.Add($col) | Out-Null
    }
    $grid.Add_SelectionChanged({ Set-EhEditFieldsFromSelection })
    $panel.Controls.Add($grid)
    $script:EhGrid = $grid

    # ---- edit panel (right) ----
    $script:EhBx = 560; $script:EhLw = 100; $script:EhFw = 280; $script:EhFx = $script:EhBx + $script:EhLw
    $script:EhY = 90
    $idLbl = New-StyledLabel -Text "対象を選択してください" -X $script:EhBx -Y $script:EhY -Width 380 -Height 22 -Font $script:fontBold
    $panel.Controls.Add($idLbl)
    $script:EhFields = @{ IdentityLabel = $idLbl }
    $script:EhY += 34

    Add-EhField -Panel $panel -Caption "ユーザ名" -Key 'UncUsername' -Masked $false
    Add-EhField -Panel $panel -Caption "パスワード" -Key 'Password' -Masked $true
    $pwHint = New-StyledLabel -Text "" -X $script:EhFx -Y $script:EhY -Width $script:EhFw -Height 16 -FgColor $script:fgDim
    $panel.Controls.Add($pwHint)
    $script:EhFields['PasswordHint'] = $pwHint
    $script:EhY += 24
    Add-EhField -Panel $panel -Caption "ラベル(視覚)" -Key 'VisualLabel' -Masked $false
    Add-EhField -Panel $panel -Caption "色(#RRGGBB)" -Key 'VisualColor' -Masked $false
    Add-EhField -Panel $panel -Caption "メモ" -Key 'Note' -Masked $false

    $cb = New-StyledCheckBox -Text "有効 (Enabled)" -X $script:EhFx -Y $script:EhY -Width 200 -Height 22
    $cb.Checked = $true
    $panel.Controls.Add($cb)
    $script:EhFields['Enabled'] = $cb
    $script:EhY += 40

    $btnSave = New-StyledButton -Text "保存" -X $script:EhFx -Y $script:EhY -Width 140 -Height 34 -BgColor $script:bgAccent
    $btnSave.Add_Click({ Invoke-EhSave -Path $script:EhDataPath })
    $panel.Controls.Add($btnSave)
    $btnDel = New-StyledButton -Text "削除" -X ($script:EhFx + 150) -Y $script:EhY -Width 140 -Height 34
    $btnDel.Add_Click({ Invoke-EhDelete -Path $script:EhDataPath })
    $panel.Controls.Add($btnDel)

    return $panel
}

function Show-ExtHostlistEditorView {
    # Initial population (called after the form is shown).
    Read-EhExtendedRows -Path $script:EhDataPath
    Update-EhGrid
    if ($null -ne $script:EhGrid -and $script:EhGrid.Rows.Count -gt 0) {
        $script:EhGrid.ClearSelection()
        $script:EhGrid.Rows[0].Selected = $true
        Set-EhEditFieldsFromSelection
    }
}
