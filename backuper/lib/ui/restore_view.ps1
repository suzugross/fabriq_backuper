# ============================================================
# FabriqBackUper - Restore View
# Phase 2.7.1: Compact layout for 780-tall form.
# Phase 2.7  : Target-user dropdown (resolves %USERPROFILE% etc.
#              on the restore side; cross-user migration).
# Form size assumption: 960x780 with 44-px header dock.
# ============================================================

$script:RestoreTimestampCombo  = $null
$script:RestoreSectionChecks   = @{}
$script:RestoreManifestLabel   = $null
$script:RestoreSectionContainer = $null
$script:RestorePrinterGrid     = $null
$script:RestoreCurrentManifest = $null
$script:RestoreExplicitDir     = $null
$script:RestoreBrowseLabel     = $null
$script:RestoreUserCombo       = $null
$script:RestoreUserList        = @()
# Phase 0.15.0: checkbox controlling whether outlook_pop restore should
# generate a "/cleanclientrules" launcher shortcut on the target user's
# Desktop. v0.17.0: default OFF (実機観察で「ルール手動実行 1 回で復活」が
# 判明、デフォルトで全削除する必要性が下がった)。
$script:RestoreOutlookShortcutCheck = $null
# v0.20.0: credentials section restore selection state.
# - RestoreCredentialsIncludeTargets: null = include all (default before
#   operator interaction). Array (possibly empty) = explicit selection.
# - RestoreCredentialsLastSource: source backup path that the current
#   selection was made against; cleared/re-evaluated on backup source change.
$script:RestoreCredentialsIncludeTargets = $null
$script:RestoreCredentialsLastSource     = $null
$script:RestoreCredentialsButton         = $null
$script:RestoreCredentialsStatusLabel    = $null
# v0.17.0: checkbox controlling whether outlook_pop restore should attempt
# Strategy B-light (registry auto-rebuild). Default OFF -- operator manual
# setup via Strategy A is the recommended path. Opt-in for advanced users
# who want to try registry import.
$script:RestoreOutlookAttemptStrategyBCheck = $null
# v0.25.0: checkbox controlling whether operator-facing artifacts
# (credentials payload + Outlook account info text) are consolidated into
# a single Desktop\<date>_<host>_BK\ folder instead of being scattered
# across Documents and PST folders. Default ON. When OFF, all sections
# behave exactly as in v0.24.5 (legacy emit locations).
$script:RestoreOperatorHandoffCheck = $null

function New-RestoreView {
    $panel = New-Object System.Windows.Forms.Panel
    $panel.BackColor = $script:bgForm

    # Phase 3C: same "close MainForm" semantics as backup_view.
    $btnBack = New-StyledButton -Text "< 戻る" -X 16 -Y 10 -Width 80 -Height 28
    $btnBack.Add_Click({ $script:MainForm.Close() })
    $panel.Controls.Add($btnBack)

    $title = New-StyledLabel -Text "リストア" -X 110 -Y 12 -Width 200 -Height 24 -Font $script:fontLarge
    $panel.Controls.Add($title)

    # ---- Source row ---------------------------------------
    $tsLbl = New-StyledLabel -Text "バックアップ日時 (hostlist 連携) または任意フォルダを参照" `
        -X 24 -Y 44 -Width 540 -Height 18 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($tsLbl)

    $combo = New-StyledComboBox -X 24 -Y 66 -Width 460 -Height 24
    $combo.Add_SelectedIndexChanged({
        $script:RestoreExplicitDir = $null
        if ($null -ne $script:RestoreBrowseLabel) { $script:RestoreBrowseLabel.Text = "" }
        # v0.20.0: credentials selection is per-source; reset on source change
        $script:RestoreCredentialsIncludeTargets = $null
        $script:RestoreCredentialsLastSource     = $null
        Update-RestoreCredentialsStatusLabel
        Update-RestoreSelection
    })
    $script:RestoreTimestampCombo = $combo
    $panel.Controls.Add($combo)

    $btnBrowse = New-StyledButton -Text "バックアップを参照..." -X 494 -Y 64 -Width 170 -Height 28
    $btnBrowse.Add_Click({ Invoke-RestoreBrowse })
    $panel.Controls.Add($btnBrowse)

    $btnUncConnect = New-StyledButton -Text "UNC 接続..." -X 670 -Y 64 -Width 130 -Height 28 -BgColor $script:bgAccent
    $btnUncConnect.Add_Click({
        # v0.23.0: pre-fill UNC path + username from the migration profile
        # when present. Restore reads from the same share that backup wrote
        # to, so backupRootUnc is the right preset for both modes.
        $initial = ''
        $initialUser = ''
        if ($null -ne $script:MigrationProfile) {
            if (-not [string]::IsNullOrWhiteSpace($script:MigrationProfile.backuper.backupRootUnc)) {
                $initial = $script:MigrationProfile.backuper.backupRootUnc
            }
            if (-not [string]::IsNullOrWhiteSpace($script:MigrationProfile.backuper.uncUsername)) {
                $initialUser = $script:MigrationProfile.backuper.uncUsername
            }
        }
        $unc = Show-UncConnectDialog -InitialPath $initial -InitialUsername $initialUser
        if (-not [string]::IsNullOrWhiteSpace($unc)) {
            [System.Windows.Forms.MessageBox]::Show(
                "接続成功:`n$unc`n`n続けて [バックアップを参照...] をクリックし、この共有内の実際のバックアップフォルダを選択してください。",
                "UNC 接続成功",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        }
    })
    $panel.Controls.Add($btnUncConnect)

    $script:RestoreBrowseLabel = New-StyledLabel -Text "" -X 24 -Y 96 -Width 880 -Height 16 -FgColor $script:fgDim
    $panel.Controls.Add($script:RestoreBrowseLabel)

    $script:RestoreManifestLabel = New-StyledLabel -Text "" -X 24 -Y 114 -Width 880 -Height 28 -FgColor $script:fgDim
    $panel.Controls.Add($script:RestoreManifestLabel)

    # ---- Sections row -------------------------------------
    $sectionLbl = New-StyledLabel -Text "セクション" `
        -X 24 -Y 150 -Width 240 -Height 18 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($sectionLbl)
    $script:RestoreSectionContainer = New-Object System.Windows.Forms.Panel
    $script:RestoreSectionContainer.Location = New-Object System.Drawing.Point(24, 172)
    $script:RestoreSectionContainer.Size = New-Object System.Drawing.Size(880, 26)
    $script:RestoreSectionContainer.BackColor = [System.Drawing.Color]::Transparent
    $panel.Controls.Add($script:RestoreSectionContainer)

    # ---- Target user row ----------------------------------
    $userLbl = New-StyledLabel -Text "対象ユーザ (リストア時の %USERPROFILE% 等を解決):" `
        -X 24 -Y 206 -Width 360 -Height 18 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($userLbl)
    $userCombo = New-StyledComboBox -X 386 -Y 202 -Width 260 -Height 24
    $script:RestoreUserCombo = $userCombo
    $panel.Controls.Add($userCombo)

    # ---- Credentials selection button (v0.20.0) -----------
    # Lives on the same Y as the target-user combo; lets operator open a
    # modal grid to (de)select which credentials to actually re-register
    # at restore time. Default ($script:RestoreCredentialsIncludeTargets
    # = $null) means "include all", same as v0.19.x behavior.
    $script:RestoreCredentialsButton = New-StyledButton `
        -Text "資格情報の選択..." -X 660 -Y 202 -Width 150 -Height 26
    $script:RestoreCredentialsButton.Add_Click({ Invoke-RestoreCredentialsSelect })
    $panel.Controls.Add($script:RestoreCredentialsButton)

    $script:RestoreCredentialsStatusLabel = New-StyledLabel `
        -Text "(未選択 = 全件)" -X 816 -Y 206 -Width 90 -Height 18 -FgColor $script:fgDim
    $panel.Controls.Add($script:RestoreCredentialsStatusLabel)

    # ---- Operator handoff row (v0.25.0) -------------------
    # Checkbox controlling whether credentials + outlook_pop emit their
    # operator-facing artifacts (登録.bat / register_credentials.ps1 /
    # RESTORE_INSTRUCTIONS.txt / _account_settings.txt) into a single
    # consolidated Desktop\<date>_<host>_BK\ folder instead of scattering
    # across Documents and PST folders. Default ON. OFF = full v0.24.5
    # legacy behaviour (no handoff folder ever created).
    $handoffCheck = New-StyledCheckBox `
        -Text "operator 用ファイル (資格情報 / Outlook 設定) をデスクトップに統合 (推奨)" `
        -X 24 -Y 232 -Width 700 -Height 22 -Checked $true
    $script:RestoreOperatorHandoffCheck = $handoffCheck
    $panel.Controls.Add($handoffCheck)

    # ---- Outlook extras row (Phase 0.15.0 + v0.17.0 + Y shift v0.25.0) ----
    # 2 つのチェックボックスを縦並びで配置:
    #   1. 初回起動用ショートカット (rule-clear) - default OFF (v0.17 変更)
    #   2. レジストリ自動再構築 (Strategy B-light) - default OFF (v0.17 新規)
    # どちらも opt-in 形式。デフォルトは "operator 手動セットアップが主軸" の運用。
    # v0.25.0: Y を +30 シフトして、上の operator handoff checkbox を新行で挿入。
    $outlookExtrasLbl = New-StyledLabel -Text "Outlook 追加オプション (どちらも opt-in、通常は OFF のまま)" `
        -X 24 -Y 264 -Width 600 -Height 18 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($outlookExtrasLbl)

    # v0.17.0: rule-clear shortcut, default OFF
    $shortcutCheck = New-StyledCheckBox `
        -Text "初回起動用ショートカットを生成 (壊れた仕分けルールをクリア)" `
        -X 24 -Y 284 -Width 500 -Height 22 -Checked $false
    $script:RestoreOutlookShortcutCheck = $shortcutCheck
    $panel.Controls.Add($shortcutCheck)

    $shortcutHint = New-StyledLabel `
        -Text "ルールが壊れている場合の対処用。通常は不要 (ルール 1 回手動実行で復活するため)" `
        -X 44 -Y 306 -Width 860 -Height 16 -FgColor $script:fgDim
    $panel.Controls.Add($shortcutHint)

    # v0.17.0: NEW - Strategy B-light opt-in, default OFF
    $strategyBCheck = New-StyledCheckBox `
        -Text "レジストリ自動再構築 (実験的、通常は使用しない)" `
        -X 24 -Y 326 -Width 500 -Height 22 -Checked $false
    $script:RestoreOutlookAttemptStrategyBCheck = $strategyBCheck
    $panel.Controls.Add($strategyBCheck)

    $strategyBHint = New-StyledLabel `
        -Text "MAPI registry transform 経由で自動再構築。不安定なため operator 手動セットアップを推奨" `
        -X 44 -Y 348 -Width 860 -Height 16 -FgColor $script:fgDim
    $panel.Controls.Add($strategyBHint)

    # ---- Printer list row (Y shifted +30 by v0.25.0 for handoff checkbox row) ----
    $pLbl = New-StyledLabel -Text "このバックアップ内のプリンタ (除外するチェックを外す)" `
        -X 24 -Y 374 -Width 540 -Height 18 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($pLbl)

    $btnSelAll = New-StyledButton -Text "全選択" -X 620 -Y 370 -Width 96 -Height 24
    $btnSelAll.Add_Click({ Set-AllRestorePrinterChecks $true })
    $panel.Controls.Add($btnSelAll)
    $btnNone = New-StyledButton -Text "クリア" -X 722 -Y 370 -Width 80 -Height 24
    $btnNone.Add_Click({ Set-AllRestorePrinterChecks $false })
    $panel.Controls.Add($btnNone)

    # Grid: Y shifted +30 to Y=400 by v0.25.0 (handoff row insertion).
    # Height kept at 244, so Y+H = 644 (was 614 in v0.24.5). Still fits
    # comfortably inside the ~736px panel height.
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(24, 400)
    $grid.Size = New-Object System.Drawing.Size(880, 244)
    Set-GridStyle -Grid $grid
    $grid.ReadOnly = $false

    $colCk = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colCk.HeaderText = ""; $colCk.Width = 36; $colCk.Name = "Check"
    [void]$grid.Columns.Add($colCk)
    $colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colName.HeaderText = "プリンタ名"; $colName.Width = 320; $colName.Name = "Name"; $colName.ReadOnly = $true
    [void]$grid.Columns.Add($colName)
    $colDriver = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colDriver.HeaderText = "ドライバ"; $colDriver.Width = 280; $colDriver.Name = "Driver"; $colDriver.ReadOnly = $true
    [void]$grid.Columns.Add($colDriver)
    $colPort = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colPort.HeaderText = "ポート"; $colPort.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    $colPort.Name = "Port"; $colPort.ReadOnly = $true
    [void]$grid.Columns.Add($colPort)
    $panel.Controls.Add($grid)
    $script:RestorePrinterGrid = $grid

    # ---- Start button (Y shifted +30 by v0.25.0) ----------
    $btnStart = New-StyledButton -Text "リストア開始" -X 700 -Y 654 -Width 204 -Height 44 -BgColor $script:bgAdd
    $btnStart.ForeColor = $script:fgWhite
    $btnStart.Font = $script:fontLarge
    $btnStart.Add_Click({ Invoke-RestoreStart })
    $panel.Controls.Add($btnStart)

    return $panel
}

function Set-AllRestorePrinterChecks {
    param([bool]$Checked)
    if ($null -eq $script:RestorePrinterGrid) { return }
    foreach ($row in $script:RestorePrinterGrid.Rows) {
        $row.Cells['Check'].Value = $Checked
    }
}

function Show-RestoreView {
    if ($null -eq $script:CurrentHost) {
        # Defensive: Phase 3C pre-selects host via session_form, so this
        # branch should not trigger in normal flow. If it does, close the
        # MainForm rather than navigating to the deleted ModeSelectView.
        [System.Windows.Forms.MessageBox]::Show("ホストが選択されていません。", "Fabriq BackUper",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        $script:MainForm.Close()
        return
    }

    $combo = $script:RestoreTimestampCombo
    $combo.Items.Clear()
    $timestamps = Get-BackupTimestamps -BackuperRoot $script:BackuperRoot -OldPcName $script:CurrentHost.OldPCname
    foreach ($ts in $timestamps) { [void]$combo.Items.Add($ts) }
    if ($timestamps.Count -gt 0) { $combo.SelectedIndex = 0 }
    else { $script:RestoreManifestLabel.Text = "($($script:CurrentHost.OldPCname) のローカルバックアップが見つかりません。別の場所にある場合は [バックアップを参照] を使用してください)" }

    $cont = $script:RestoreSectionContainer
    $cont.Controls.Clear()
    $script:RestoreSectionChecks = @{}
    # v0.22.0: width 168 + stride 178 fits 5 sections (msime_dict added).
    # See backup_view.ps1 for the layout history.
    $x = 0
    foreach ($s in $script:SectionList) {
        $cb = New-StyledCheckBox -Text $s.DisplayName -X $x -Y 4 -Width 168 -Height 22 -Checked ($s.Enabled -eq "1")
        $cb.Tag = $s.SectionName
        $cont.Controls.Add($cb)
        $script:RestoreSectionChecks[$s.SectionName] = $cb
        $x += 178
    }

    # Target user combo (default = logged-on interactive user)
    Update-RestoreUserComboItems
}

function Update-RestoreUserComboItems {
    $combo = $script:RestoreUserCombo
    if ($null -eq $combo) { return }
    $combo.Items.Clear()
    $script:RestoreUserList = @(Get-UserProfileList)
    foreach ($u in $script:RestoreUserList) { [void]$combo.Items.Add($u.Label) }
    $idx = Get-DefaultProfileIndex -List $script:RestoreUserList
    if ($idx -ge 0) { $combo.SelectedIndex = $idx }
}

function Get-SelectedRestoreUserProfilePath {
    $combo = $script:RestoreUserCombo
    if ($null -eq $combo -or $combo.SelectedIndex -lt 0) { return $null }
    if ($combo.SelectedIndex -ge $script:RestoreUserList.Count) { return $null }
    return $script:RestoreUserList[$combo.SelectedIndex].ProfilePath
}

function Invoke-RestoreBrowse {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "バックアップフォルダを選択 (manifest.json を含むこと)。UNC の場合は先に [UNC 接続...] で認証してください。"

    # v0.24.5: when a migration profile is loaded and a host is selected,
    # pre-seed SelectedPath so the operator lands directly in the target
    # PC's backup folder.
    #
    # Fallback chain (first existing path wins):
    #   1. <share.localPath>\<OldPCname>   (only if running on target host)
    #   2. <share.localPath>               (only if running on target host)
    #   3. <backuper.backupRootUnc>\<OldPCname>
    #   4. <backuper.backupRootUnc>
    #   5. (no preset)
    #
    # Target-host detection: a registered SMB share whose name matches
    # profile.share.shareName has Path == profile.share.localPath. If yes,
    # we're sitting ON the target host and should prefer local paths over
    # UNC (no auth needed, no network round-trip, more robust). Get-SmbShare
    # is read-only and doesn't require admin context to enumerate own shares.
    if ($null -ne $script:MigrationProfile -and `
        $null -ne $script:CurrentHost) {

        $hostName  = $script:CurrentHost.OldPCname
        $shareRoot = $script:MigrationProfile.backuper.backupRootUnc
        $shareLocal = $null
        $shareName  = $null
        if ($null -ne $script:MigrationProfile.share) {
            $shareLocal = $script:MigrationProfile.share.localPath
            $shareName  = $script:MigrationProfile.share.shareName
        }

        $isTargetHost = $false
        if (-not [string]::IsNullOrWhiteSpace($shareLocal) -and `
            -not [string]::IsNullOrWhiteSpace($shareName) -and `
            (Test-Path -LiteralPath $shareLocal)) {
            try {
                $smb = Get-SmbShare -Name $shareName -ErrorAction Stop
                if ($smb -and $smb.Path -ieq $shareLocal) {
                    $isTargetHost = $true
                }
            } catch {
                # Not a registered share on this PC -> not the target host.
            }
        }

        $candidates = @()
        if ($isTargetHost) {
            $candidates += (Join-Path $shareLocal $hostName)
            $candidates += $shareLocal
        }
        if (-not [string]::IsNullOrWhiteSpace($shareRoot)) {
            $candidates += (Join-Path $shareRoot $hostName)
            $candidates += $shareRoot
        }
        foreach ($c in $candidates) {
            if (-not [string]::IsNullOrWhiteSpace($c) -and (Test-Path -LiteralPath $c)) {
                $dlg.SelectedPath = $c
                break
            }
        }
    }

    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $chosen = $dlg.SelectedPath

    if (-not (Resolve-UncAccess -Path $chosen)) {
        [System.Windows.Forms.MessageBox]::Show(
            "フォルダに接続できません: $chosen`n`nUNC 共有の場合は先に [UNC 接続...] をクリックしてください。",
            "Fabriq BackUper", [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }

    $mfPath = Join-Path $chosen 'manifest.json'
    if (-not (Test-Path $mfPath)) {
        [System.Windows.Forms.MessageBox]::Show(
            "manifest.json が見つかりません:`n$chosen",
            "Fabriq BackUper", [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    $agg = $null
    try { $agg = Get-Content -Path $mfPath -Raw | ConvertFrom-Json }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "manifest.json の解析に失敗しました: $($_.Exception.Message)",
            "Fabriq BackUper", [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }
    if ($agg.manifestType -ne 'fabriq-backuper-snapshot') {
        [System.Windows.Forms.MessageBox]::Show(
            "想定外の manifestType: $($agg.manifestType)",
            "Fabriq BackUper", [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    # Phase 2.7.2: clear the combo FIRST so its SelectedIndexChanged side
    # effect (which resets RestoreExplicitDir / BrowseLabel / ManifestLabel
    # and clears the printer grid) runs before we install Browse-mode state.
    # The previous ordering put $script:RestoreExplicitDir = $chosen above
    # this line, which the event handler immediately wiped to $null when the
    # combo was previously at index 0 (local backups present).
    $script:RestoreTimestampCombo.SelectedIndex = -1

    $script:RestoreExplicitDir = $chosen
    $script:RestoreBrowseLabel.Text = "Browse mode: $chosen"
    # v0.20.0: source changed via Browse - reset credentials selection
    $script:RestoreCredentialsIncludeTargets = $null
    $script:RestoreCredentialsLastSource     = $null
    Update-RestoreCredentialsStatusLabel
    $sz = if ($agg.summary.totalBytes) { [math]::Round([long]$agg.summary.totalBytes / 1MB, 1) } else { 0 }
    $secCount = if ($agg.summary.sectionCount) { [int]$agg.summary.sectionCount } else { 0 }
    $script:RestoreManifestLabel.Text = "aggregate manifest  |  collectedAt=$($agg.collectedAt)  |  oldPcName=$($agg.oldPcName)  |  sections=$secCount  |  totalBytes=$sz MB"

    Show-RestorePrinterListFromAggregate -AggregateDir $chosen
}

function Show-RestorePrinterListFromAggregate {
    param([Parameter(Mandatory = $true)][string]$AggregateDir)

    # Phase 2.7.2: replaced the previous silent try/catch — failures were
    # invisible and made "grid empty" indistinguishable from "manifest missing
    # / malformed / property access failed". Now every branch reports state to
    # RestoreManifestLabel so the operator can diagnose without the console.
    if ($null -eq $script:RestorePrinterGrid) { return }
    $script:RestorePrinterGrid.Rows.Clear()

    $printerManifestPath = Join-Path $AggregateDir 'sections\printer\manifest.json'
    if (-not (Test-Path $printerManifestPath)) {
        $null = $script:RestorePrinterGrid.Rows.Add($false, "(no printer section manifest found)", "", "")
        if ($null -ne $script:RestoreManifestLabel) {
            $script:RestoreManifestLabel.Text += "  |  printer manifest: NOT FOUND ($printerManifestPath)"
        }
        return
    }

    $pm = $null
    try {
        $pm = Get-Content -Path $printerManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $null = $script:RestorePrinterGrid.Rows.Add($false, "(printer manifest read failed)", $_.Exception.Message, "")
        if ($null -ne $script:RestoreManifestLabel) {
            $script:RestoreManifestLabel.Text += "  |  printer manifest READ FAILED: $($_.Exception.Message)"
        }
        return
    }

    $printersNode = $null
    if ($null -ne $pm -and $null -ne $pm.items) { $printersNode = $pm.items.printers }
    $printersArr = @($printersNode)
    if ($printersArr.Count -eq 0 -or ($printersArr.Count -eq 1 -and $null -eq $printersArr[0])) {
        $null = $script:RestorePrinterGrid.Rows.Add($false, "(printer manifest has no printers)", "", "")
        if ($null -ne $script:RestoreManifestLabel) {
            $script:RestoreManifestLabel.Text += "  |  printers in manifest: 0"
        }
        return
    }

    $total = 0
    $hidden = 0
    foreach ($p in $printersArr) {
        if ($null -eq $p) { continue }
        $total++
        if ($p.driverName -eq 'Remote Desktop Easy Print') { $hidden++; continue }
        if ($p.portName -match '^TS\d+$') { $hidden++; continue }
        $isVirtual = $false
        $virtPats = @('Microsoft Print To PDF','Microsoft XPS Document Writer','OneNote','Microsoft Shared Fax','Microsoft OpenXPS')
        foreach ($vp in $virtPats) { if ($p.driverName -like "*$vp*") { $isVirtual = $true; break } }
        $virtPortPats = @('PORTPROMPT:','XPSPort:','FAX:','nul:','SHRFAX:')
        foreach ($vp in $virtPortPats) { if ($p.portName -like "*$vp*") { $isVirtual = $true; break } }
        if ($p.portName -like 'OneNote*') { $isVirtual = $true }
        $defaultChecked = -not $isVirtual
        $null = $script:RestorePrinterGrid.Rows.Add($defaultChecked, $p.name, $p.driverName, $p.portName)
    }

    $shown = $total - $hidden
    if ($null -ne $script:RestoreManifestLabel) {
        $script:RestoreManifestLabel.Text += "  |  printers: $shown shown, $hidden virtual/RDP hidden (of $total)"
    }
}

function Update-RestoreSelection {
    if ($script:RestorePrinterGrid) { $script:RestorePrinterGrid.Rows.Clear() }

    if ($null -eq $script:RestoreTimestampCombo -or $script:RestoreTimestampCombo.SelectedIndex -lt 0) {
        if ([string]::IsNullOrWhiteSpace($script:RestoreExplicitDir)) {
            $script:RestoreManifestLabel.Text = ""
        }
        return
    }
    $ts = $script:RestoreTimestampCombo.SelectedItem
    $aggregateDir = Join-Path (Join-Path (Join-Path $script:BackuperRoot 'Backup') $script:CurrentHost.OldPCname) $ts
    $aggregatePath = Join-Path $aggregateDir 'manifest.json'

    if (-not (Test-Path $aggregatePath)) {
        $script:RestoreManifestLabel.Text = "($ts に manifest.json が見つかりません)"
        return
    }
    try {
        $agg = Get-Content -Path $aggregatePath -Raw | ConvertFrom-Json
        $sz = if ($agg.summary.totalBytes) { [math]::Round([long]$agg.summary.totalBytes / 1MB, 1) } else { 0 }
        $secCount = if ($agg.summary.sectionCount) { [int]$agg.summary.sectionCount } else { 0 }
        $script:RestoreManifestLabel.Text = "aggregate manifest  |  collectedAt=$($agg.collectedAt)  |  sections=$secCount  |  totalBytes=$sz MB"
    }
    catch {
        $script:RestoreManifestLabel.Text = "aggregate manifest parse failed: $($_.Exception.Message)"
    }

    Show-RestorePrinterListFromAggregate -AggregateDir $aggregateDir
}

# v0.20.0: helpers for the credentials selection dialog ----------
function Get-RestoreCurrentAggregateDir {
    # Returns the aggregate backup directory currently selected by the
    # operator, or $null if none is selected. Mirrors the resolution
    # done in Invoke-RestoreStart so the dialog reads from the same
    # source the restore will use.
    if (-not [string]::IsNullOrWhiteSpace($script:RestoreExplicitDir)) {
        return $script:RestoreExplicitDir
    }
    if ($null -eq $script:CurrentHost) { return $null }
    if ($null -eq $script:RestoreTimestampCombo -or `
        $script:RestoreTimestampCombo.SelectedIndex -lt 0) {
        return $null
    }
    $ts = $script:RestoreTimestampCombo.SelectedItem
    return (Join-Path (Join-Path (Join-Path $script:BackuperRoot 'Backup') `
        $script:CurrentHost.OldPCname) $ts)
}

function Update-RestoreCredentialsStatusLabel {
    if ($null -eq $script:RestoreCredentialsStatusLabel) { return }
    if ($null -eq $script:RestoreCredentialsIncludeTargets) {
        $script:RestoreCredentialsStatusLabel.Text = '(未選択 = 全件)'
    } else {
        $script:RestoreCredentialsStatusLabel.Text = `
            ('{0} 件選択中' -f $script:RestoreCredentialsIncludeTargets.Count)
    }
}

function Invoke-RestoreCredentialsSelect {
    # Resolve the source backup dir; bail with a clear message if none
    # is selected yet so the operator knows what to do first.
    $aggregateDir = Get-RestoreCurrentAggregateDir
    if ([string]::IsNullOrWhiteSpace($aggregateDir) -or -not (Test-Path $aggregateDir)) {
        [System.Windows.Forms.MessageBox]::Show(
            "先にバックアップ (日時 または [バックアップを参照]) を選択してください。",
            "Fabriq BackUper",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    # Locate credentials section manifest
    $credsManifest = Join-Path $aggregateDir 'sections\credentials\manifest.json'
    if (-not (Test-Path $credsManifest)) {
        [System.Windows.Forms.MessageBox]::Show(
            "選択中のバックアップに credentials セクションの manifest がありません。`n($credsManifest)",
            "Fabriq BackUper",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    # Parse manifest
    $credsList = @()
    try {
        $manifestObj = Get-Content -Path $credsManifest -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $manifestObj.credentials) {
            $credsList = @($manifestObj.credentials)
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "credentials manifest の読み取りに失敗しました: $($_.Exception.Message)",
            "Fabriq BackUper",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }

    if ($credsList.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "選択中のバックアップに資格情報のエントリがありません (credentialCount=0)。",
            "Fabriq BackUper",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    # If the source has changed since the last selection, reset the
    # preselected list (avoid carrying stale Target strings forward).
    $preselect = $script:RestoreCredentialsIncludeTargets
    if ($script:RestoreCredentialsLastSource -ne $aggregateDir) {
        $preselect = $null
    }

    $selected = Show-CredentialsSelectDialog `
        -Credentials $credsList `
        -PreselectedTargets $preselect

    if ($null -eq $selected) { return }  # cancelled

    $script:RestoreCredentialsIncludeTargets = @($selected)
    $script:RestoreCredentialsLastSource     = $aggregateDir
    Update-RestoreCredentialsStatusLabel
}

function Invoke-RestoreStart {
    $useExplicit = -not [string]::IsNullOrWhiteSpace($script:RestoreExplicitDir)
    if (-not $useExplicit) {
        if ($null -eq $script:CurrentHost) { return }
        if ($null -eq $script:RestoreTimestampCombo -or $script:RestoreTimestampCombo.SelectedIndex -lt 0) {
            [System.Windows.Forms.MessageBox]::Show("バックアップ日時を選択するか [バックアップを参照...] を使用してください。", "Fabriq BackUper",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
    }

    $picked = @()
    foreach ($s in $script:SectionList) {
        $cb = $script:RestoreSectionChecks[$s.SectionName]
        if ($null -ne $cb -and $cb.Checked) { $picked += $s }
    }
    if ($picked.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("セクションが選択されていません。", "Fabriq BackUper",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    $selectedPrinters = @()
    if ($null -ne $script:RestorePrinterGrid) {
        foreach ($row in $script:RestorePrinterGrid.Rows) {
            if ($row.Cells['Check'].Value -eq $true) {
                $name = [string]$row.Cells['Name'].Value
                if (-not [string]::IsNullOrWhiteSpace($name) -and $name -notlike '(no *') {
                    $selectedPrinters += $name
                }
            }
        }
    }

    $targetUserProfilePath = Get-SelectedRestoreUserProfilePath
    $createShortcut = $false
    if ($null -ne $script:RestoreOutlookShortcutCheck) {
        $createShortcut = [bool]$script:RestoreOutlookShortcutCheck.Checked
    }
    # v0.17.0: Strategy B-light は opt-in。Checked=$false が新デフォルト動作
    # (= Strategy A operator manual setup)。Checked=$true で旧 v0.16.0 動作。
    $attemptStrategyB = $false
    if ($null -ne $script:RestoreOutlookAttemptStrategyBCheck) {
        $attemptStrategyB = [bool]$script:RestoreOutlookAttemptStrategyBCheck.Checked
    }
    # Phase 0.15.0: outlook_pop now receives both TargetUserProfilePath and
    # CreateRuleClearShortcut. Previously TargetUserProfilePath was not
    # forwarded; outlook_pop fell back to $env:USERPROFILE which under admin
    # elevation pointed at the admin profile instead of the operator-selected
    # logged-on user. Forwarding fixes that subtle path-resolution mismatch.
    $sectionParams = @{
        printer  = @{ IncludePrinters = $selectedPrinters }
        userdata = @{ TargetUserProfilePath = $targetUserProfilePath }
        outlook_pop = @{
            TargetUserProfilePath   = $targetUserProfilePath
            CreateRuleClearShortcut = $createShortcut
            AttemptStrategyB        = $attemptStrategyB
        }
        # v0.19.0: credentials section deploys the operator payload
        # (register_credentials.ps1 + 登録.bat + CSV + README.txt) into
        # the target user's Documents. TargetUserProfilePath drives that
        # deploy path; without it the deploy would fall back to the
        # admin profile (wrong user).
        # v0.20.0: IncludeTargets (optional) filters which credentials make
        # it into the deployed CSV. $null = include all (= v0.19.x behavior).
        credentials = @{
            TargetUserProfilePath = $targetUserProfilePath
            IncludeTargets        = $script:RestoreCredentialsIncludeTargets
        }
        # v0.22.0: msime_dict section. TargetUserProfilePath drives the
        # write destination (%APPDATA%\Microsoft\IME\15.0\IMEJP\UserDict\)
        # under the resolved user; the section stops the target user's
        # ctfmon to release the file lock before copying.
        msime_dict = @{
            TargetUserProfilePath = $targetUserProfilePath
        }
    }

    $hostForEngine = $script:CurrentHost
    $sourceLabel = ""
    if ($useExplicit) {
        $aggMfPath = Join-Path $script:RestoreExplicitDir 'manifest.json'
        try {
            $agg = Get-Content -Path $aggMfPath -Raw | ConvertFrom-Json
            $hostForEngine = [PSCustomObject]@{ OldPCname = $agg.oldPcName }
        } catch {
            $hostForEngine = [PSCustomObject]@{ OldPCname = '(unknown)' }
        }
        $sourceLabel = "Browse: $($script:RestoreExplicitDir)"
    } else {
        $ts = $script:RestoreTimestampCombo.SelectedItem
        $sourceLabel = "Hostlist: $($script:CurrentHost.OldPCname) / $ts"
    }

    # v0.25.0: Operator handoff folder path resolution (Phase A).
    # Only path math here -- mkdir + README writing happens after the
    # confirm dialog so cancelled restores don't leave empty folders.
    # Sections receive OperatorHandoffSubdir via SectionParams; Phase A
    # ships the UI/plumbing only and leaves credentials/outlook_pop emit
    # locations unchanged (Phase B/C will switch them based on this key).
    $script:RestoreHandoffEnabled = $false
    $script:RestoreHandoffRoot    = $null
    $script:RestoreHandoffOldPc   = $null
    if ($null -ne $script:RestoreOperatorHandoffCheck -and `
        $script:RestoreOperatorHandoffCheck.Checked -and `
        -not [string]::IsNullOrWhiteSpace($targetUserProfilePath)) {
        $oldPcForHandoff = if ($null -ne $hostForEngine) { $hostForEngine.OldPCname } else { 'unknown' }
        if ([string]::IsNullOrWhiteSpace($oldPcForHandoff)) { $oldPcForHandoff = 'unknown' }
        $script:RestoreHandoffRoot  = Resolve-OperatorHandoffRoot `
            -TargetUserProfilePath $targetUserProfilePath `
            -OldPcName             $oldPcForHandoff
        $script:RestoreHandoffOldPc = $oldPcForHandoff
        $script:RestoreHandoffEnabled = $true
        $credSubdir    = Resolve-OperatorHandoffSectionDir -HandoffRoot $script:RestoreHandoffRoot -SectionName 'credentials'
        $outlookSubdir = Resolve-OperatorHandoffSectionDir -HandoffRoot $script:RestoreHandoffRoot -SectionName 'outlook_pop'
        if (-not $sectionParams['credentials']) { $sectionParams['credentials'] = @{} }
        $sectionParams['credentials']['OperatorHandoffSubdir'] = $credSubdir
        if (-not $sectionParams['outlook_pop']) { $sectionParams['outlook_pop'] = @{} }
        $sectionParams['outlook_pop']['OperatorHandoffSubdir'] = $outlookSubdir
    }

    $userSummary = if ([string]::IsNullOrWhiteSpace($targetUserProfilePath)) {
        "対象ユーザ: (現在のプロセス)"
    } else {
        "対象ユーザ: $targetUserProfilePath"
    }
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "リストア元:`n  $sourceLabel`n`nセクション: $(@($picked | ForEach-Object { $_.SectionName }) -join ', ')`nプリンタ: $($selectedPrinters.Count) 件選択`n$userSummary",
        "Fabriq BackUper - 確認",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    # v0.25.0: Materialize the operator handoff folder + README (Phase A).
    # Done after confirm Yes so cancelled restores leave no trace on the
    # Desktop. On failure we clear OperatorHandoffSubdir from SectionParams
    # so credentials / outlook_pop fall back to legacy locations.
    if ($script:RestoreHandoffEnabled) {
        try {
            if (-not (Test-Path -LiteralPath $script:RestoreHandoffRoot)) {
                $null = New-Item -ItemType Directory -Path $script:RestoreHandoffRoot -Force -ErrorAction Stop
            }
            $readmePath = Join-Path $script:RestoreHandoffRoot 'README.txt'
            $readmeText = @"
============================================================
Fabriq BackUper - 移行後セットアップフォルダ
============================================================

このフォルダには、移行元 PC ($($script:RestoreHandoffOldPc)) からの
operator-facing な設定情報が番号順に集約されています。
番号順に作業してください。

01_資格情報\
  Windows 資格情報マネージャの再登録用ファイル。
  → 「登録.bat」をダブルクリックしてください。
     (※ 必ず復元対象ユーザでログインした状態で実行)

02_outlook_アカウント情報\
  Outlook プロファイルのアカウント設定情報 (POP / IMAP / SMTP)。
  → RESTORE_INSTRUCTIONS.txt または _account_settings.txt を参照し、
    Outlook を起動して各アカウントを手動追加してください。
  → PST ファイル本体は Documents\Outlook ファイル\ に展開されています
    (Outlook プロファイル設定が指す場所のため、ここには移していません)。

このフォルダは作業完了後に削除して構いません。

リストア実行日時 : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
リストア元 PC    : $($script:RestoreHandoffOldPc)
============================================================
"@
            $utf8Bom = New-Object System.Text.UTF8Encoding($true)
            [System.IO.File]::WriteAllText($readmePath, $readmeText, $utf8Bom)
            Show-Info "Operator handoff folder ready: $script:RestoreHandoffRoot"
        }
        catch {
            Show-Warning ("Failed to set up operator handoff folder; sections will fall back to legacy locations. Error: " + $_.Exception.Message)
            # Clear the subdir keys so sections see no handoff config
            if ($sectionParams.ContainsKey('credentials')) {
                $sectionParams['credentials'].Remove('OperatorHandoffSubdir') | Out-Null
            }
            if ($sectionParams.ContainsKey('outlook_pop')) {
                $sectionParams['outlook_pop'].Remove('OperatorHandoffSubdir') | Out-Null
            }
            $script:RestoreHandoffEnabled = $false
        }
    }

    Switch-View 'Progress'
    Initialize-ProgressView -Title "リストア実行中..."
    Add-ProgressLog "リストア元: $sourceLabel"
    Add-ProgressLog $userSummary
    if ($selectedPrinters.Count -gt 0) {
        Add-ProgressLog "選択プリンタ: $($selectedPrinters -join ', ')"
    }
    $script:MainForm.Refresh()

    # Phase 2.7.4: overall wall-clock for the run summary
    $overallSw = [System.Diagnostics.Stopwatch]::StartNew()

    $coreArgs = @{
        SelectedHost = $hostForEngine
        PickedSections = $picked
        BackuperRoot = $script:BackuperRoot
        FabriqRoot = $script:FabriqRoot
        SectionParamsBySection = $sectionParams
    }
    if ($useExplicit) {
        $coreArgs.ExplicitAggregateDir = $script:RestoreExplicitDir
    } else {
        $coreArgs.PickedTimestamp = $script:RestoreTimestampCombo.SelectedItem
    }
    $result = Invoke-BackuperRestoreCore @coreArgs

    $overallSw.Stop()

    Add-ProgressLog ""
    Add-ProgressLog "=========================================="
    Add-ProgressLog "リストア完了: $(Get-LocalizedStatusLabel $result.Status)"
    Add-ProgressLog "$($result.Message)"
    foreach ($key in $result.SectionResults.Keys) {
        $r = $result.SectionResults[$key]
        Add-ProgressLog ("  [{0,-10}] {1,-8} ({2} ms)" -f $key, (Get-LocalizedStatusLabel $r.Status), $r.ElapsedMs)
    }

    # ---- Run summary (Phase 2.7.4) --------------------------
    # Restore Summary fields differ from backup: userdata exposes
    # entrySuccess / entrySkip / entryFail; printer section may report
    # its own counts. Show elapsed + per-section entry counts when present.
    $aggSuccess = 0L
    $aggSkip    = 0L
    $aggFail    = 0L
    foreach ($key in $result.SectionResults.Keys) {
        $s = $result.SectionResults[$key].Summary
        if ($null -eq $s) { continue }
        if ($null -ne $s.entrySuccess) { $aggSuccess += [long]$s.entrySuccess }
        if ($null -ne $s.entrySkip)    { $aggSkip    += [long]$s.entrySkip }
        if ($null -ne $s.entryFail)    { $aggFail    += [long]$s.entryFail }
    }
    $elapsedStr = Format-Duration -Span $overallSw.Elapsed

    Add-ProgressLog ""
    Add-ProgressLog "実行サマリ:"
    Add-ProgressLog ("  経過時間 : {0}" -f $elapsedStr)
    if (($aggSuccess + $aggSkip + $aggFail) -gt 0) {
        Add-ProgressLog ("  項目     : 成功 {0} / スキップ {1} / 失敗 {2}" -f $aggSuccess, $aggSkip, $aggFail)
    }

    Set-ProgressFinished

    # Phase 2.7.5: completion popup (same pattern as Backup).
    $popupLines = @(
        "リストア $(Get-LocalizedStatusLabel $result.Status)"
        ""
        "経過時間 : $elapsedStr"
    )
    if (($aggSuccess + $aggSkip + $aggFail) -gt 0) {
        $popupLines += "項目 : 成功 $aggSuccess / スキップ $aggSkip / 失敗 $aggFail"
    }
    if (-not [string]::IsNullOrWhiteSpace($result.AggregateDir)) {
        $popupLines += ""
        $popupLines += "リストア元:"
        $popupLines += $result.AggregateDir
    }
    Show-CompletionPopup `
        -Title  "Fabriq BackUper - リストア完了 ($(Get-LocalizedStatusLabel $result.Status))" `
        -Body   ($popupLines -join "`n") `
        -Status $result.Status
}
