# ============================================================
# FabriqBackUper - Restore View
# Phase 2.7.1: Compact layout for 780-tall form.
# Phase 2.7  : Target-user dropdown (resolves %USERPROFILE% etc.
#              on the restore side; cross-user migration).
# Form size assumption: 960x780 with 44-px header dock.
# ============================================================

$script:RestoreTimestampCombo  = $null
# v0.27.0: parallel array to RestoreTimestampCombo.Items. Index N in
# RestoreTimestampEntries holds the {Name, FullPath, Source} object for
# the item rendered as "<Name>  [<Source>]" at the same index. Browse-mode
# adds a synthetic "(参照: <leaf>)" item; in that mode the entry list is
# replaced with a single-element array carrying the chosen FullPath.
$script:RestoreTimestampEntries = @()
$script:RestoreSectionChecks   = @{}
$script:RestoreManifestLabel   = $null
$script:RestoreSectionContainer = $null
$script:RestorePrinterGrid     = $null
$script:RestoreCurrentManifest = $null
# v0.47.0 (B): colored label that warns when the selected backup itself had
# failures/partials (read from the aggregate manifest). Read-only, never blocks.
$script:RestoreBackupWarningLabel = $null
# v0.47.0 (B): count of userdata entries that could NOT be backed up (status
# Failed/Partial/Skipped = missing source). Cached at source change because a
# Success-status userdata section can still hide individual missing entries.
$script:RestoreUserdataProblemCount = 0
$script:RestoreExplicitDir     = $null
# v0.27.0: explicit Browse-mode flag (previously inferred from whether
# RestoreExplicitDir was set; now ExplicitDir is *always* set even in
# timestamp mode because the engine takes a single ExplicitAggregateDir
# parameter, so we need a separate signal to render "Browse:" vs
# "Hostlist:" in sourceLabel).
$script:RestoreBrowseMode      = $false
$script:RestoreBrowseLabel     = $null
$script:RestoreUserCombo       = $null
$script:RestoreUserList        = @()
# v0.48.0 (C): editable free-space margin (MB) for the pre-restore check;
# seeded from migration_profile restore.freeSpaceMarginBytes (default 1 GB).
$script:RestoreFreeSpaceMarginBox = $null
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
# v0.46.0 (D1): userdata entry selection state. null = all entries (default,
# = pre-D1 behaviour). Mirrors the credentials selection trio. Passed to
# userdata/restore.ps1 as IncludeEntries (matched by sourcePath, already
# honored at userdata/restore.ps1:28-33,94-96 -- selection was a pure UI gap).
$script:RestoreUserdataIncludeTargets = $null
$script:RestoreUserdataLastSource     = $null
$script:RestoreUserdataButton         = $null
$script:RestoreUserdataStatusLabel    = $null
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
# v0.42.0 (P2): backup-arrival poll. The restore view polls the local Backup
# root for the _backup_complete.json flag that the source writes over the
# share (local operation model) and auto-selects the named backup.
$script:RestorePollTimer    = $null
$script:RestoreWaitActive   = $false
$script:RestoreWaitBaseline = $null   # placedAt of any flag present at wait-start (stale guard)
$script:RestoreWaitButton   = $null

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
        # v0.27.0: resolve the picked entry's FullPath to RestoreExplicitDir
        # so the engine call site is uniform across timestamp / Browse
        # modes. RestoreBrowseMode is intentionally NOT touched here -- its
        # lifecycle is owned by exactly two places: Show-RestoreView (sets
        # it to $false when initialising/returning to timestamp mode) and
        # Invoke-RestoreBrowse's success path (sets it to $true). The combo
        # itself is Enabled=$false in Browse mode so this handler does not
        # fire from operator action there.
        $idx = $script:RestoreTimestampCombo.SelectedIndex
        if ($idx -ge 0 -and $idx -lt $script:RestoreTimestampEntries.Count) {
            $script:RestoreExplicitDir = $script:RestoreTimestampEntries[$idx].FullPath
        } else {
            $script:RestoreExplicitDir = $null
        }
        # v0.20.0: credentials selection is per-source; reset on source change
        $script:RestoreCredentialsIncludeTargets = $null
        $script:RestoreCredentialsLastSource     = $null
        Update-RestoreCredentialsStatusLabel
        # v0.46.0 (D1): userdata selection is also per-source; reset together.
        $script:RestoreUserdataIncludeTargets = $null
        $script:RestoreUserdataLastSource     = $null
        Update-RestoreUserdataStatusLabel
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

    # v0.42.0 (P2): backup-arrival wait toggle + poll timer. The manual toggle
    # is always available; Show-RestoreView also auto-starts the wait when the
    # host has 0 backups yet. The poll fires on a NEWER flag for this host and
    # auto-selects the named timestamp (operator still clicks リストア開始).
    $script:RestoreWaitButton = New-StyledButton -Text "到着を待つ" -X 806 -Y 64 -Width 98 -Height 28
    $script:RestoreWaitButton.Add_Click({ Invoke-RestoreWaitToggle })
    $panel.Controls.Add($script:RestoreWaitButton)

    $script:RestorePollTimer = New-Object System.Windows.Forms.Timer
    $script:RestorePollTimer.Interval = 2000
    $script:RestorePollTimer.Add_Tick({ Invoke-RestoreWaitTick })

    $script:RestoreBrowseLabel = New-StyledLabel -Text "" -X 24 -Y 96 -Width 880 -Height 16 -FgColor $script:fgDim
    $panel.Controls.Add($script:RestoreBrowseLabel)

    $script:RestoreManifestLabel = New-StyledLabel -Text "" -X 24 -Y 114 -Width 880 -Height 28 -FgColor $script:fgDim
    $panel.Controls.Add($script:RestoreManifestLabel)

    # ---- Sections row -------------------------------------
    $sectionLbl = New-StyledLabel -Text "セクション" `
        -X 24 -Y 150 -Width 240 -Height 18 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($sectionLbl)

    # v0.47.0 (B): backup-failure warning, on the section header row between
    # the "セクション" label and the userdata-select button. Red = failed,
    # amber = partial-only; empty when the backup is clean.
    $script:RestoreBackupWarningLabel = New-StyledLabel `
        -Text "" -X 270 -Y 150 -Width 372 -Height 18 -Font $script:fontBold -FgColor $script:bgDelete
    $panel.Controls.Add($script:RestoreBackupWarningLabel)

    # v0.46.0 (D1): user-data entry selection (mirrors the credentials trio).
    # Right-aligned on the section header row. Default (null) = all entries;
    # opening the dialog lets the operator restore a subset.
    $script:RestoreUserdataButton = New-StyledButton `
        -Text "ユーザデータ選択..." -X 648 -Y 146 -Width 160 -Height 24
    $script:RestoreUserdataButton.Add_Click({ Invoke-RestoreUserdataSelect })
    $panel.Controls.Add($script:RestoreUserdataButton)

    $script:RestoreUserdataStatusLabel = New-StyledLabel `
        -Text "(未選択 = 全件)" -X 812 -Y 150 -Width 92 -Height 18 -FgColor $script:fgDim
    $panel.Controls.Add($script:RestoreUserdataStatusLabel)
    $script:RestoreSectionContainer = New-Object System.Windows.Forms.Panel
    $script:RestoreSectionContainer.Location = New-Object System.Drawing.Point(24, 172)
    # v0.26.0: Height raised 26 -> 56 for two-row section grid (3 sections per
    # row x 2 rows = 6 slots). Widgets below this container were shifted Y +30.
    $script:RestoreSectionContainer.Size = New-Object System.Drawing.Size(880, 56)
    $script:RestoreSectionContainer.BackColor = [System.Drawing.Color]::Transparent
    $panel.Controls.Add($script:RestoreSectionContainer)

    # ---- Target user row (Y +30 by v0.26.0) ----------------
    $userLbl = New-StyledLabel -Text "対象ユーザ (リストア時の %USERPROFILE% 等を解決):" `
        -X 24 -Y 236 -Width 360 -Height 18 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($userLbl)
    $userCombo = New-StyledComboBox -X 386 -Y 232 -Width 260 -Height 24
    $script:RestoreUserCombo = $userCombo
    $panel.Controls.Add($userCombo)

    # ---- Credentials selection button (v0.20.0, Y +30 by v0.26.0) ----
    # Lives on the same Y as the target-user combo; lets operator open a
    # modal grid to (de)select which credentials to actually re-register
    # at restore time. Default ($script:RestoreCredentialsIncludeTargets
    # = $null) means "include all", same as v0.19.x behavior.
    $script:RestoreCredentialsButton = New-StyledButton `
        -Text "資格情報の選択..." -X 660 -Y 232 -Width 150 -Height 26
    $script:RestoreCredentialsButton.Add_Click({ Invoke-RestoreCredentialsSelect })
    $panel.Controls.Add($script:RestoreCredentialsButton)

    $script:RestoreCredentialsStatusLabel = New-StyledLabel `
        -Text "(未選択 = 全件)" -X 816 -Y 236 -Width 90 -Height 18 -FgColor $script:fgDim
    $panel.Controls.Add($script:RestoreCredentialsStatusLabel)

    # ---- Operator handoff row (v0.25.0, Y +30 by v0.26.0) ----
    # Checkbox controlling whether credentials + outlook_pop emit their
    # operator-facing artifacts (登録.bat / register_credentials.ps1 /
    # RESTORE_INSTRUCTIONS.txt / _account_settings.txt) into a single
    # consolidated Desktop\<date>_<host>_BK\ folder instead of scattering
    # across Documents and PST folders. Default ON. OFF = full v0.24.5
    # legacy behaviour (no handoff folder ever created).
    $handoffCheck = New-StyledCheckBox `
        -Text "operator 用ファイル (資格情報 / Outlook 設定 / 移行元PC情報 / プリンタ) をデスクトップに統合 (推奨)" `
        -X 24 -Y 262 -Width 760 -Height 22 -Checked $true
    $script:RestoreOperatorHandoffCheck = $handoffCheck
    $panel.Controls.Add($handoffCheck)

    # ---- Outlook extras row (Phase 0.15.0 + v0.17.0 + Y shift v0.25.0 + v0.26.0) ----
    # 2 つのチェックボックスを縦並びで配置:
    #   1. 初回起動用ショートカット (rule-clear) - default OFF (v0.17 変更)
    #   2. レジストリ自動再構築 (Strategy B-light) - default OFF (v0.17 新規)
    # どちらも opt-in 形式。デフォルトは "operator 手動セットアップが主軸" の運用。
    # v0.25.0: Y を +30 シフトして、上の operator handoff checkbox を新行で挿入。
    # v0.26.0: 更に Y を +30 シフトして、section 領域を 2 行 (system_evidence 追加分) に拡張。
    $outlookExtrasLbl = New-StyledLabel -Text "Outlook 追加オプション (どちらも opt-in、通常は OFF のまま)" `
        -X 24 -Y 294 -Width 600 -Height 18 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($outlookExtrasLbl)

    # v0.17.0: rule-clear shortcut, default OFF
    $shortcutCheck = New-StyledCheckBox `
        -Text "初回起動用ショートカットを生成 (壊れた仕分けルールをクリア)" `
        -X 24 -Y 314 -Width 500 -Height 22 -Checked $false
    $script:RestoreOutlookShortcutCheck = $shortcutCheck
    $panel.Controls.Add($shortcutCheck)

    $shortcutHint = New-StyledLabel `
        -Text "ルールが壊れている場合の対処用。通常は不要 (ルール 1 回手動実行で復活するため)" `
        -X 44 -Y 336 -Width 860 -Height 16 -FgColor $script:fgDim
    $panel.Controls.Add($shortcutHint)

    # v0.32.0: "auto-restore batch" generation, default ON. The reg.exe
    # import no longer runs during restore; instead a Restore-Outlook.bat
    # is placed in 02_outlook_アカウント情報\ for the operator to run AS
    # THE TARGET USER. OFF = Strategy A files only (no batch).
    $strategyBCheck = New-StyledCheckBox `
        -Text "Outlook 自動復元バッチを生成 (推奨)" `
        -X 24 -Y 356 -Width 500 -Height 22 -Checked $true
    $script:RestoreOutlookAttemptStrategyBCheck = $strategyBCheck
    $panel.Controls.Add($strategyBCheck)

    $strategyBHint = New-StyledLabel `
        -Text "POP プロファイルを再構築する Restore-Outlook.bat を集約フォルダに配置。移行先ユーザで実行 (IMAP は手動)" `
        -X 44 -Y 378 -Width 860 -Height 16 -FgColor $script:fgDim
    $panel.Controls.Add($strategyBHint)

    # ---- Printer list row (Y +30 by v0.26.0 again, total +60 from v0.24.5) ----
    $pLbl = New-StyledLabel -Text "このバックアップ内のプリンタ (除外するチェックを外す)" `
        -X 24 -Y 404 -Width 540 -Height 18 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($pLbl)

    $btnSelAll = New-StyledButton -Text "全選択" -X 620 -Y 400 -Width 96 -Height 24
    $btnSelAll.Add_Click({ Set-AllRestorePrinterChecks $true })
    $panel.Controls.Add($btnSelAll)
    $btnNone = New-StyledButton -Text "クリア" -X 722 -Y 400 -Width 80 -Height 24
    $btnNone.Add_Click({ Set-AllRestorePrinterChecks $false })
    $panel.Controls.Add($btnNone)

    # Grid: Y shifted further +30 to Y=430 by v0.26.0 (2-row sections).
    # Height kept at 244, so Y+H = 674. Still fits the panel.
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(24, 430)
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

    # ---- Free-space margin field (v0.48.0 C), left of the start button ----
    $marginLbl = New-StyledLabel -Text "空き容量しきい値(MB):" `
        -X 24 -Y 694 -Width 170 -Height 18 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($marginLbl)
    $marginBox = New-Object System.Windows.Forms.TextBox
    $marginBox.Location = New-Object System.Drawing.Point(198, 690)
    $marginBox.Size = New-Object System.Drawing.Size(90, 24)
    Set-TextBoxStyle -TextBox $marginBox
    # Seed from the migration profile (bytes -> MB), else 1024 MB (1 GB).
    $seedMb = 1024
    if ($null -ne $script:MigrationProfile -and $null -ne $script:MigrationProfile.restore `
        -and $script:MigrationProfile.restore.freeSpaceMarginBytes) {
        try { $seedMb = [int]([long]$script:MigrationProfile.restore.freeSpaceMarginBytes / 1MB) } catch {}
    }
    $marginBox.Text = "$seedMb"
    $panel.Controls.Add($marginBox)
    $script:RestoreFreeSpaceMarginBox = $marginBox

    # ---- Start button (Y shifted +30 by v0.25.0 + further +30 by v0.26.0) ----
    $btnStart = New-StyledButton -Text "リストア開始" -X 700 -Y 684 -Width 204 -Height 44 -BgColor $script:bgAdd
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

    # v0.27.0: multi-root timestamp discovery. The combo is now populated
    # from local Backup\ AND any roots declared in migration_profile.json
    # (share.localPath + backuper.backupRootUnc). Same-named timestamps
    # are de-duplicated by Get-BackupTimestamps (priority: Local >
    # ShareLocal > UNC). Each item is rendered as "<Name>  [<Source>]"
    # so operators see which storage the entry came from.
    #
    # Re-entering Show-RestoreView is also the canonical "return from
    # Browse mode to timestamp mode" path (operator: < 戻る -> session_form
    # -> restore). Reset BrowseMode and the BrowseLabel style here so the
    # form starts in a clean timestamp-mode state regardless of how the
    # previous session ended.
    Stop-RestoreWait   # v0.42.0: cancel any poll from a prior session / re-entry
    # v0.50.0 (D6): reset the userdata entry selection on every (re-)entry so a
    # return after a partial restore starts from the restored-aware defaults
    # (restored entries unchecked, Partial re-checked) rather than the stale
    # prior selection. The combo re-fire below also resets it (D1); this is the
    # robust guard for the no-change / no-backup edges.
    $script:RestoreUserdataIncludeTargets = $null
    Update-RestoreUserdataStatusLabel
    $combo = $script:RestoreTimestampCombo
    $combo.Enabled = $true
    $script:RestoreBrowseMode = $false
    if ($null -ne $script:RestoreBrowseLabel) {
        $script:RestoreBrowseLabel.Text      = ""
        $script:RestoreBrowseLabel.Font      = $script:fontNormal
        $script:RestoreBrowseLabel.ForeColor = $script:fgDim
    }

    $count = Update-RestoreTimestampCombo
    if ($count -gt 0) {
        $combo.SelectedIndex = 0
    } else {
        $script:RestoreManifestLabel.Text = "($($script:CurrentHost.OldPCname) のバックアップが見つかりません (local / share / UNC のいずれにも存在せず)。別の場所にある場合は [バックアップを参照] を使用してください)"
        # v0.42.0 (P2): nothing to restore yet -> auto-wait for arrival.
        Start-RestoreWait -Auto
    }

    $cont = $script:RestoreSectionContainer
    $cont.Controls.Clear()
    $script:RestoreSectionChecks = @{}
    # v0.26.0: Two-row grid (3 sections per row x 2 rows). system_evidence
    # is forced (grey-out + Checked fixed). See backup_view.ps1 for full
    # layout history.
    $i = 0
    foreach ($s in $script:SectionList) {
        $col = $i % 3
        $row = [Math]::Floor($i / 3)
        $cb = New-StyledCheckBox -Text $s.DisplayName `
            -X ($col * 300) -Y (4 + $row * 30) -Width 280 -Height 22 `
            -Checked ($s.Enabled -eq "1")
        $cb.Tag = $s.SectionName
        if ($s.SectionName -eq 'system_evidence') {
            $cb.Checked = $true
            $cb.Enabled = $false
            $_tt = New-Object System.Windows.Forms.ToolTip
            $_tt.SetToolTip($cb, "移行証跡として必須。選択不可。")
        }
        $cont.Controls.Add($cb)
        $script:RestoreSectionChecks[$s.SectionName] = $cb
        # v0.47.0 (B): re-render the backup-failure warning when the operator
        # toggles a section, so the checked-section-scoped warning tracks the
        # live selection that Invoke-RestoreStart actually uses.
        $cb.Add_CheckedChanged({ Show-RestoreBackupWarnings })
        $i++
    }
    # v0.47.0 (B): re-render the warning now that the section checkboxes exist
    # (the earlier combo-driven render used the default-checked fallback, so
    # default-unchecked sections would otherwise be mis-counted until a toggle).
    Show-RestoreBackupWarnings

    # Target user combo (default = logged-on interactive user)
    Update-RestoreUserComboItems
}

# ============================================================
# v0.42.0 (P2): backup-arrival poll (consumes the P1 _backup_complete.json)
# ============================================================

function Update-RestoreTimestampCombo {
    # (Re)discovers backups for the current host across local + profile roots
    # and repopulates the timestamp combo. Returns the entry count. Shared by
    # Show-RestoreView (initial) and the wait-poll tick (after a flag lands).
    if ($null -eq $script:CurrentHost) { return 0 }
    $combo = $script:RestoreTimestampCombo
    $combo.Items.Clear()
    $additionalRoots = @()
    if ($null -ne $script:MigrationProfile) {
        if ($null -ne $script:MigrationProfile.share -and `
            -not [string]::IsNullOrWhiteSpace($script:MigrationProfile.share.localPath)) {
            $additionalRoots += $script:MigrationProfile.share.localPath
        }
        if ($null -ne $script:MigrationProfile.backuper -and `
            -not [string]::IsNullOrWhiteSpace($script:MigrationProfile.backuper.backupRootUnc)) {
            $additionalRoots += $script:MigrationProfile.backuper.backupRootUnc
        }
    }
    $entries = @(Get-BackupTimestamps `
        -BackuperRoot $script:BackuperRoot `
        -OldPcName    $script:CurrentHost.OldPCname `
        -AdditionalRoots $additionalRoots)
    $script:RestoreTimestampEntries = $entries
    foreach ($e in $entries) {
        [void]$combo.Items.Add("$($e.Name)  [$($e.Source)]")
    }
    return $entries.Count
}

function Start-RestoreWait {
    param([switch]$Auto)
    if ($null -eq $script:CurrentHost -or $null -eq $script:RestorePollTimer) { return }
    if ($script:RestoreBrowseMode) { return }
    # Baseline = placedAt of any flag already present, so we fire only on a
    # NEWER flag (ignores a stale flag left by a previous migration).
    $script:RestoreWaitBaseline = $null
    $existing = Read-BackupCompleteFlag -RootDir (Join-Path $script:BackuperRoot 'Backup')
    if ($null -ne $existing -and -not [string]::IsNullOrWhiteSpace("$($existing.placedAt)")) {
        $script:RestoreWaitBaseline = "$($existing.placedAt)"
    }
    $script:RestoreWaitActive = $true
    $script:RestorePollTimer.Start()
    if ($null -ne $script:RestoreWaitButton) { $script:RestoreWaitButton.Text = "待機停止" }
    $autoNote = if ($Auto) { " (自動)" } else { "" }
    $script:RestoreManifestLabel.Text = "バックアップ到着を待機中$autoNote … 移行元のバックアップ完了で自動選択します。"
}

function Stop-RestoreWait {
    if ($null -ne $script:RestorePollTimer) { try { $script:RestorePollTimer.Stop() } catch {} }
    $script:RestoreWaitActive   = $false
    $script:RestoreWaitBaseline = $null
    if ($null -ne $script:RestoreWaitButton) { $script:RestoreWaitButton.Text = "到着を待つ" }
}

function Invoke-RestoreWaitToggle {
    if ($script:RestoreWaitActive) {
        Stop-RestoreWait
        $script:RestoreManifestLabel.Text = "待機を停止しました。"
    } else {
        Start-RestoreWait
    }
}

function Invoke-RestoreWaitTick {
    if (-not $script:RestoreWaitActive -or $script:RestoreBrowseMode -or $null -eq $script:CurrentHost) { return }
    $flag = Read-BackupCompleteFlag -RootDir (Join-Path $script:BackuperRoot 'Backup')
    if ($null -eq $flag) { return }
    # Must be for the host we are restoring.
    if ("$($flag.oldPcName)" -ne "$($script:CurrentHost.OldPCname)") { return }
    # Must be newer than the baseline captured at wait-start (stale guard).
    if (-not [string]::IsNullOrWhiteSpace($script:RestoreWaitBaseline)) {
        try {
            $rk  = [System.Globalization.DateTimeStyles]::RoundtripKind
            $inv = [System.Globalization.CultureInfo]::InvariantCulture
            $b = [datetime]::Parse($script:RestoreWaitBaseline, $inv, $rk)
            $p = [datetime]::Parse("$($flag.placedAt)", $inv, $rk)
            if ($p -le $b) { return }
        } catch { return }   # fail-closed: can't prove the flag is newer -> don't fire
    }
    # Re-discover; the new folder should now be visible. If not yet, keep polling.
    $count = Update-RestoreTimestampCombo
    if ($count -le 0) { return }
    $targetIdx = -1
    for ($i = 0; $i -lt $script:RestoreTimestampEntries.Count; $i++) {
        if ("$($script:RestoreTimestampEntries[$i].Name)" -eq "$($flag.timestamp)") { $targetIdx = $i; break }
    }
    if ($targetIdx -lt 0) { return }   # named timestamp not discoverable yet -> keep polling
    Stop-RestoreWait
    $script:RestoreTimestampCombo.SelectedIndex = $targetIdx   # fires handler -> sets RestoreExplicitDir
    $script:RestoreManifestLabel.Text = "バックアップ到着: $($flag.timestamp) を自動選択しました。内容を確認し [リストア開始] を押してください。"
    try {
        [System.Windows.Forms.MessageBox]::Show(
            "移行元のバックアップが到着しました。`n`nホスト: $($flag.oldPcName)`n日時: $($flag.timestamp)`n状態: $($flag.status)`n`n自動選択しました。内容を確認のうえ [リストア開始] を押してください。",
            "バックアップ到着",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    } catch {}
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
    # v0.42.0 (P2): manual Browse = the operator takes explicit control of the
    # source, so cancel any active backup-arrival wait FIRST. This also closes
    # the window where the poll timer could fire DURING the open
    # FolderBrowserDialog modal (RestoreBrowseMode only flips $true after the
    # dialog closes), which would otherwise mutate the combo + pop a dialog on
    # top of the open folder picker.
    Stop-RestoreWait
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
        # v0.27.0 Phase C: previously this loop called Test-Path -LiteralPath
        # on each candidate to pick the first existing one. For UNC candidates
        # without a pre-established SMB session, Test-Path triggers a credential
        # broker challenge that blocks for 3-5 seconds per candidate -- with up
        # to 4 candidates that turned button-click into a ~20-second wait
        # before the dialog even appeared (the "資格情報的な処理が走っている?"
        # symptom). We now pick the first non-empty candidate unconditionally.
        # If the path does not exist, FolderBrowserDialog gracefully drops to
        # its closest existing parent on open, so the UX is preserved while the
        # network round-trip is eliminated.
        foreach ($c in $candidates) {
            if (-not [string]::IsNullOrWhiteSpace($c)) {
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

    # v0.27.0 Phase B: install Browse mode atomically.
    #   Step 1: SelectedIndex=-1 so the existing handler runs once and
    #           clears RestoreExplicitDir (so it can't leak across modes).
    #   Step 2: replace RestoreTimestampEntries with a single synthetic
    #           entry pointing at $chosen, marked Source='Browse'.
    #   Step 3: clear combo Items + add a single "(参照: <leaf>)" entry.
    #   Step 4: SelectedIndex=0 -- handler runs and resolves
    #           RestoreExplicitDir to entries[0].FullPath = $chosen.
    #   Step 5: Combo.Enabled=$false locks the new state in. The handler
    #           cannot fire from operator action while Enabled=$false, so
    #           the synthetic entry stays put until the next
    #           Show-RestoreView (= return-to-timestamp-mode path).
    #   Step 6: BrowseMode = $true, BrowseLabel switches to bold+accent.
    $script:RestoreTimestampCombo.SelectedIndex = -1

    $leaf = Split-Path -Leaf $chosen
    if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = $chosen }
    $script:RestoreTimestampEntries = @(
        [PSCustomObject]@{
            Name     = $leaf
            FullPath = $chosen
            Source   = 'Browse'
        }
    )

    $script:RestoreTimestampCombo.Items.Clear()
    [void]$script:RestoreTimestampCombo.Items.Add("(参照: $leaf)")
    $script:RestoreTimestampCombo.SelectedIndex = 0
    # handler has now set RestoreExplicitDir = $chosen via entries[0].FullPath

    $script:RestoreTimestampCombo.Enabled = $false
    $script:RestoreBrowseMode = $true
    $script:RestoreBrowseLabel.Text      = "Browse mode: $chosen"
    $script:RestoreBrowseLabel.Font      = $script:fontBold
    $script:RestoreBrowseLabel.ForeColor = $script:bgAccent

    # v0.20.0: source changed via Browse - reset credentials selection
    $script:RestoreCredentialsIncludeTargets = $null
    $script:RestoreCredentialsLastSource     = $null
    Update-RestoreCredentialsStatusLabel
    # v0.46.0 (D1): reset userdata selection on Browse source change too.
    $script:RestoreUserdataIncludeTargets = $null
    $script:RestoreUserdataLastSource     = $null
    Update-RestoreUserdataStatusLabel

    $sz = if ($agg.summary.totalBytes) { [math]::Round([long]$agg.summary.totalBytes / 1MB, 1) } else { 0 }
    $secCount = if ($agg.summary.sectionCount) { [int]$agg.summary.sectionCount } else { 0 }
    $script:RestoreManifestLabel.Text = "aggregate manifest  |  collectedAt=$($agg.collectedAt)  |  oldPcName=$($agg.oldPcName)  |  sections=$secCount  |  totalBytes=$sz MB"
    $script:RestoreCurrentManifest = $agg   # v0.47.0 (B): cache for warnings
    $script:RestoreUserdataProblemCount = Get-RestoreUserdataProblemCount -AggregateDir $chosen

    Show-RestorePrinterListFromAggregate -AggregateDir $chosen
    Show-RestoreBackupWarnings   # v0.47.0 (B): render backup-failure warning
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
    # v0.47.0 (B): reset the cached manifest + warning each refresh. The
    # success path re-caches and the end-of-function call renders; early
    # returns leave the warning cleared.
    $script:RestoreCurrentManifest = $null
    $script:RestoreUserdataProblemCount = 0
    if ($null -ne $script:RestoreBackupWarningLabel) { $script:RestoreBackupWarningLabel.Text = "" }

    if ($null -eq $script:RestoreTimestampCombo -or $script:RestoreTimestampCombo.SelectedIndex -lt 0) {
        if ([string]::IsNullOrWhiteSpace($script:RestoreExplicitDir)) {
            $script:RestoreManifestLabel.Text = ""
        }
        return
    }
    # v0.27.0: resolve to FullPath via RestoreTimestampEntries (the combo
    # text now includes a [<Source>] suffix and is no longer a valid
    # timestamp string by itself).
    $idx = $script:RestoreTimestampCombo.SelectedIndex
    $entry = $script:RestoreTimestampEntries[$idx]
    if ($null -eq $entry) {
        $script:RestoreManifestLabel.Text = ""
        return
    }
    $aggregateDir  = $entry.FullPath
    $aggregatePath = Join-Path $aggregateDir 'manifest.json'

    if (-not (Test-Path $aggregatePath)) {
        $script:RestoreManifestLabel.Text = "($($entry.Name) [$($entry.Source)] に manifest.json が見つかりません)"
        return
    }
    try {
        $agg = Get-Content -Path $aggregatePath -Raw | ConvertFrom-Json
        $sz = if ($agg.summary.totalBytes) { [math]::Round([long]$agg.summary.totalBytes / 1MB, 1) } else { 0 }
        $secCount = if ($agg.summary.sectionCount) { [int]$agg.summary.sectionCount } else { 0 }
        $script:RestoreManifestLabel.Text = "aggregate manifest  |  collectedAt=$($agg.collectedAt)  |  sections=$secCount  |  totalBytes=$sz MB  |  source=$($entry.Source)"
        $script:RestoreCurrentManifest = $agg   # v0.47.0 (B): cache for warnings
        $script:RestoreUserdataProblemCount = Get-RestoreUserdataProblemCount -AggregateDir $aggregateDir
    }
    catch {
        $script:RestoreManifestLabel.Text = "aggregate manifest parse failed: $($_.Exception.Message)"
    }

    Show-RestorePrinterListFromAggregate -AggregateDir $aggregateDir
    Show-RestoreBackupWarnings   # v0.47.0 (B): render backup-failure warning
}

# v0.47.0 (B): backup-failure warning ----------------------------
function Get-RestoreUserdataProblemCount {
    # Counts userdata entries that could NOT be backed up (status
    # Failed/Partial/Skipped = missing source). Returns 0 on any error/absence.
    param([string]$AggregateDir)
    if ([string]::IsNullOrWhiteSpace($AggregateDir)) { return 0 }
    $mf = Join-Path $AggregateDir 'sections\userdata\manifest.json'
    if (-not (Test-Path $mf)) { return 0 }
    try {
        $udm = Get-Content -Path $mf -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $udm.items -or $null -eq $udm.items.entries) { return 0 }
        $n = 0
        foreach ($en in @($udm.items.entries)) {
            $st = "$($en.status)"
            if ($st -eq 'Failed' -or $st -eq 'Partial' -or $st -eq 'Skipped') { $n++ }
        }
        return $n
    } catch { return 0 }
}

function Show-RestoreBackupWarnings {
    # Reads the cached aggregate manifest + cached userdata problem count and
    # shows a colored warning if the selected backup could not capture some
    # data the operator intends to restore. Read-only; never blocks restore.
    # Empty when clean / no manifest. Headline counts AND the (...) detail are
    # both scoped to CHECKED sections, so the two halves always agree.
    if ($null -eq $script:RestoreBackupWarningLabel) { return }
    $m = $script:RestoreCurrentManifest
    if ($null -eq $m) { $script:RestoreBackupWarningLabel.Text = ""; return }

    # Is a section checked to restore? Default = checked when the checkbox map
    # isn't built yet (first auto-fire before the section grid is rebuilt).
    $isChecked = {
        param([string]$Name)
        if ($null -ne $script:RestoreSectionChecks -and $script:RestoreSectionChecks.ContainsKey($Name)) {
            $cb = $script:RestoreSectionChecks[$Name]
            if ($null -ne $cb) { return [bool]$cb.Checked }
        }
        return $true
    }

    # Section-level Failed/Partial among CHECKED sections (Skipped excluded: a
    # whole-section skip is normally expected). Headline + detail share this set.
    $secFailed = 0; $secPartial = 0; $problems = @()
    if ($null -ne $m.sections) {
        foreach ($prop in $m.sections.PSObject.Properties) {
            $name = $prop.Name
            $st   = "$($prop.Value.status)"
            if ($st -ne 'Failed' -and $st -ne 'Partial') { continue }
            if (-not (& $isChecked $name)) { continue }
            if ($st -eq 'Failed') { $secFailed++ } else { $secPartial++ }
            $problems += ("{0}={1}" -f $name, $st)
        }
    }

    # Userdata entry-level missing/failed entries (only when userdata is a
    # checked section). Catches per-file 取得不可 that a Success-status
    # userdata section would otherwise hide from the always-visible banner.
    $udProblem = 0
    if (& $isChecked 'userdata') { $udProblem = [int]$script:RestoreUserdataProblemCount }

    if ($secFailed -eq 0 -and $secPartial -eq 0 -and $udProblem -eq 0) {
        $script:RestoreBackupWarningLabel.Text = ""
        return
    }

    $parts = @()
    if ($secFailed  -gt 0) { $parts += "失敗 $secFailed" }
    if ($secPartial -gt 0) { $parts += "部分 $secPartial" }
    if ($udProblem  -gt 0) { $parts += "ユーザデータ取得不可 $udProblem" }
    $txt = "⚠ バックアップに問題: " + ($parts -join ' / ') + " 件"
    if ($problems.Count -gt 0) { $txt += "  (" + ($problems -join ', ') + ")" }

    $script:RestoreBackupWarningLabel.Text = $txt
    # Red when data was lost / not captured (failed sections or missing userdata
    # entries); amber when only partial sections.
    if ($secFailed -gt 0 -or $udProblem -gt 0) {
        $script:RestoreBackupWarningLabel.ForeColor = $script:bgDelete
    } else {
        $script:RestoreBackupWarningLabel.ForeColor = [System.Drawing.Color]::FromArgb(180, 95, 0)
    }
}

# v0.48.0 (C): pre-restore free-space sizing ----------------------
function Get-RestoreFreeSpaceMarginBytes {
    # UI MB field wins; else migration_profile restore.freeSpaceMarginBytes;
    # else 1 GB. Always returns a [long] byte count.
    $defaultBytes = [long](1GB)
    if ($null -ne $script:RestoreFreeSpaceMarginBox) {
        $txt = "$($script:RestoreFreeSpaceMarginBox.Text)".Trim()
        $mb = 0
        if ([int]::TryParse($txt, [ref]$mb) -and $mb -ge 0) { return ([long]$mb * 1MB) }
    }
    if ($null -ne $script:MigrationProfile -and $null -ne $script:MigrationProfile.restore `
        -and $script:MigrationProfile.restore.freeSpaceMarginBytes) {
        try { return [long]$script:MigrationProfile.restore.freeSpaceMarginBytes } catch {}
    }
    return $defaultBytes
}

function Get-RestoreUserdataSelectionSizeBytes {
    # Sum byteCount of the userdata entries that will actually be restored
    # (respecting the D1 IncludeTargets subset; Skipped entries excluded).
    param([string]$AggregateDir)
    if ([string]::IsNullOrWhiteSpace($AggregateDir)) { return 0 }
    $mf = Join-Path $AggregateDir 'sections\userdata\manifest.json'
    if (-not (Test-Path $mf)) { return 0 }
    try {
        $udm = Get-Content -Path $mf -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $udm.items -or $null -eq $udm.items.entries) { return 0 }
        $sel = $script:RestoreUserdataIncludeTargets   # null = all entries
        $sum = [long]0
        foreach ($en in @($udm.items.entries)) {
            if ("$($en.status)" -eq 'Skipped') { continue }
            if ($null -ne $sel -and ("$($en.sourcePath)" -notin $sel)) { continue }
            if ($en.byteCount) { try { $sum += [long]$en.byteCount } catch {} }
        }
        return $sum
    } catch { return 0 }
}

function Get-RestoreSelectionSizeBytes {
    # Estimate the restore data size (bytes) for the CHECKED sections, from the
    # cached aggregate manifest (no UNC re-scan). userdata is sized per selected
    # entry; other sections use their manifest summary.totalBytes.
    param([array]$Picked, [string]$AggregateDir)
    $m = $script:RestoreCurrentManifest
    if ($null -eq $m -or $null -eq $Picked) { return 0 }
    $total = [long]0
    foreach ($p in $Picked) {
        $name = "$($p.SectionName)"
        if ($name -eq 'userdata') {
            $total += Get-RestoreUserdataSelectionSizeBytes -AggregateDir $AggregateDir
            continue
        }
        if ($null -ne $m.sections -and ($m.sections.PSObject.Properties.Name -contains $name)) {
            $sec = $m.sections.$name
            if ($null -ne $sec.summary -and $sec.summary.totalBytes) {
                try { $total += [long]$sec.summary.totalBytes } catch {}
            }
        }
    }
    return $total
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
    # v0.27.0: resolve via RestoreTimestampEntries (multi-root aware)
    $idx = $script:RestoreTimestampCombo.SelectedIndex
    $entry = $script:RestoreTimestampEntries[$idx]
    if ($null -eq $entry) { return $null }
    return $entry.FullPath
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

# v0.46.0 (D1): userdata entry selection -------------------------
function Update-RestoreUserdataStatusLabel {
    if ($null -eq $script:RestoreUserdataStatusLabel) { return }
    if ($null -eq $script:RestoreUserdataIncludeTargets) {
        $script:RestoreUserdataStatusLabel.Text = '(未選択 = 全件)'
    } else {
        $script:RestoreUserdataStatusLabel.Text = `
            ('{0} 件選択中' -f $script:RestoreUserdataIncludeTargets.Count)
    }
}

function Invoke-RestoreUserdataSelect {
    # Read the selected backup's userdata manifest, show a modal grid, and
    # store the chosen sourcePaths. Mirrors Invoke-RestoreCredentialsSelect.
    $aggregateDir = Get-RestoreCurrentAggregateDir
    if ([string]::IsNullOrWhiteSpace($aggregateDir) -or -not (Test-Path $aggregateDir)) {
        [System.Windows.Forms.MessageBox]::Show(
            "先にバックアップ (日時 または [バックアップを参照]) を選択してください。",
            "Fabriq BackUper",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    $udManifest = Join-Path $aggregateDir 'sections\userdata\manifest.json'
    if (-not (Test-Path $udManifest)) {
        [System.Windows.Forms.MessageBox]::Show(
            "選択中のバックアップに userdata セクションの manifest がありません。`n($udManifest)",
            "Fabriq BackUper",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    $entries = @()
    try {
        $manifestObj = Get-Content -Path $udManifest -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $manifestObj.items -and $null -ne $manifestObj.items.entries) {
            $entries = @($manifestObj.items.entries)
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "userdata manifest の読み取りに失敗しました: $($_.Exception.Message)",
            "Fabriq BackUper",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }
    if ($entries.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "選択中のバックアップに userdata エントリがありません。",
            "Fabriq BackUper",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    # Reset preselect if the source changed (avoid carrying stale sourcePaths).
    $preselect = $script:RestoreUserdataIncludeTargets
    if ($script:RestoreUserdataLastSource -ne $aggregateDir) { $preselect = $null }

    $selected = Show-UserdataSelectDialog -Entries $entries -PreselectedSourcePaths $preselect -AggregateDir $aggregateDir
    if ($null -eq $selected) { return }  # cancelled

    $script:RestoreUserdataIncludeTargets = @($selected)
    $script:RestoreUserdataLastSource     = $aggregateDir
    Update-RestoreUserdataStatusLabel
}

function Show-UserdataSelectDialog {
    # Modal selection grid for userdata entries (mirrors
    # Show-CredentialsSelectDialog). Returns an array of selected sourcePath
    # strings (possibly empty), or $null if cancelled. Entries that were
    # 'Skipped' at backup (no backupSubpath) are shown disabled (info only).
    param(
        [Parameter(Mandatory = $true)][array]$Entries,
        [array]$PreselectedSourcePaths = $null,
        [string]$AggregateDir = $null
    )
    $usePreselect = $false
    $preselectSet = $null
    if ($null -ne $PreselectedSourcePaths) {
        $usePreselect = $true
        $preselectSet = New-Object System.Collections.Generic.HashSet[string]
        foreach ($t in $PreselectedSourcePaths) { [void]$preselectSet.Add([string]$t) }
    }
    # v0.49.0 (D3/D4): per-entry dir root for reading _restored.json + deleting.
    $udEntriesRoot = $null
    if (-not [string]::IsNullOrWhiteSpace($AggregateDir)) {
        $udEntriesRoot = Join-Path $AggregateDir 'sections\userdata\entries'
    }

    $dialog = New-Object System.Windows.Forms.Form
    Set-FormStyle -Form $dialog -Title 'ユーザデータの選択 (リストア対象)' -Width 920 -Height 480
    $dialog.MaximizeBox   = $false
    $dialog.MinimizeBox   = $false
    $dialog.StartPosition = 'CenterParent'
    if ($null -ne $script:MainForm) { $dialog.Owner = $script:MainForm }

    $hintLbl = New-StyledLabel `
        -Text 'チェックを入れたエントリのみリストア。復元済みは既定で未チェック (やりなおし支援)。「取得不可」行は選択不可。' `
        -X 18 -Y 14 -Width 870 -Height 18 -FgColor $script:fgDim
    $dialog.Controls.Add($hintLbl)

    $btnAll = New-StyledButton -Text '全選択' -X 18 -Y 40 -Width 100 -Height 26
    $dialog.Controls.Add($btnAll)
    $btnNone = New-StyledButton -Text '全クリア' -X 124 -Y 40 -Width 100 -Height 26
    $dialog.Controls.Add($btnNone)
    # v0.49.0 (D4): delete the selected restored entry's backup data.
    $btnDelete = New-StyledButton -Text '選択のバックアップ削除' -X 360 -Y 40 -Width 180 -Height 26
    $dialog.Controls.Add($btnDelete)
    $countLbl = New-StyledLabel -Text '' -X 600 -Y 44 -Width 290 -Height 20 `
        -Font $script:fontBold -FgColor $script:fgHeader
    $dialog.Controls.Add($countLbl)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(18, 76)
    $grid.Size = New-Object System.Drawing.Size(870, 322)
    Set-GridStyle -Grid $grid
    $grid.ReadOnly           = $false
    $grid.AllowUserToAddRows = $false
    $grid.RowHeadersVisible  = $false
    $grid.SelectionMode      = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect

    $colCk = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colCk.HeaderText = ''; $colCk.Width = 32; $colCk.Name = 'Check'
    [void]$grid.Columns.Add($colCk)
    $colSrc = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colSrc.HeaderText = '元パス (SourcePath)'; $colSrc.Name = 'Src'; $colSrc.ReadOnly = $true
    $colSrc.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    [void]$grid.Columns.Add($colSrc)
    $colSize = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colSize.HeaderText = 'サイズ'; $colSize.Width = 110; $colSize.Name = 'Size'; $colSize.ReadOnly = $true
    [void]$grid.Columns.Add($colSize)
    $colStatus = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colStatus.HeaderText = '状態'; $colStatus.Width = 90; $colStatus.Name = 'Status'; $colStatus.ReadOnly = $true
    [void]$grid.Columns.Add($colStatus)
    $colRestored = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colRestored.HeaderText = '復元'; $colRestored.Width = 130; $colRestored.Name = 'Restored'; $colRestored.ReadOnly = $true
    [void]$grid.Columns.Add($colRestored)

    foreach ($ent in $Entries) {
        $isSkipped = ("$($ent.status)" -eq 'Skipped') -or [string]::IsNullOrWhiteSpace("$($ent.backupSubpath)")
        $sizeStr = if ($ent.byteCount) { ('{0:N1} MB' -f ([long]$ent.byteCount / 1MB)) } else { '0 MB' }
        $statusStr = if ($isSkipped) { '取得不可' } else { "$($ent.status)" }

        # v0.49.0 (D3): restored status from the per-entry _restored.json marker.
        # Defense-in-depth for the D4 delete: only build entryDir for a CLEAN
        # leaf id (machine ids are digits). Reject any separator / drive / '..'
        # so a tampered-manifest id can never make the delete target escape the
        # entries root toward the aggregate / Backup root.
        $entryDir = $null; $restoredStr = ''; $isRestored = $false; $dataDeleted = $false; $isComplete = $false
        $entryIdStr = "$($ent.id)"
        $idIsSafeLeaf = (-not [string]::IsNullOrWhiteSpace($entryIdStr)) -and `
                        ($entryIdStr -notmatch '[\\/:]') -and ($entryIdStr -notmatch '\.\.')
        if ($null -ne $udEntriesRoot -and $idIsSafeLeaf) {
            $entryDir = Join-Path $udEntriesRoot $entryIdStr
            if (Test-Path -LiteralPath (Join-Path $entryDir '_restored.json')) {
                $isRestored = $true
                $restoredStr = '復元済'
                $markerStatus = ''
                try {
                    $mk = Get-Content -LiteralPath (Join-Path $entryDir '_restored.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                    $markerStatus = "$($mk.status)"
                    $whenStr = if ($mk.restoredAt) { ' ' + ([datetime]$mk.restoredAt).ToString('MM/dd HH:mm') } else { '' }
                    if ($markerStatus -eq 'Partial') { $restoredStr = '復元済(部分)' + $whenStr } else { $restoredStr = '復元済' + $whenStr }
                } catch { }
                # v0.50.0 (D6): only a fully-complete restore (Done / already
                # present) counts as done for the resume default; Partial is
                # incomplete and defaults to CHECKED (re-restore to finish).
                $isComplete = ($markerStatus -eq 'Done' -or $markerStatus -eq 'AlreadyPresent')
                if (-not (Test-Path -LiteralPath (Join-Path $entryDir 'data'))) { $dataDeleted = $true; $restoredStr = 'データ削除済' }
            }
        }

        # Default check: not skipped, not already-restored (resume support),
        # unless an explicit preselect is in effect.
        $checked = $false
        if (-not $isSkipped -and -not $dataDeleted) {
            if ($usePreselect) { $checked = $preselectSet.Contains([string]$ent.sourcePath) }
            else { $checked = (-not $isComplete) }   # v0.50.0 (D6): Partial stays checked
        }
        $rowIdx = $grid.Rows.Add($checked, $ent.sourcePath, $sizeStr, $statusStr, $restoredStr)
        $grid.Rows[$rowIdx].Tag = [pscustomobject]@{
            SourcePath = [string]$ent.sourcePath; EntryDir = $entryDir
            Restored = $isRestored; DataDeleted = $dataDeleted
        }
        if ($isSkipped -or $dataDeleted) {
            $grid.Rows[$rowIdx].ReadOnly = $true
            $grid.Rows[$rowIdx].DefaultCellStyle.ForeColor = $script:fgDim
        } elseif ($isRestored) {
            $grid.Rows[$rowIdx].Cells['Restored'].Style.ForeColor = [System.Drawing.Color]::FromArgb(46, 125, 50)
        }
    }

    $script:_udSelectDialog_UpdateCount = {
        $sel = 0; $total = $grid.Rows.Count
        foreach ($r in $grid.Rows) { if ([bool]$r.Cells['Check'].Value) { $sel++ } }
        $countLbl.Text = ('選択中: {0} / {1}' -f $sel, $total)
    }
    & $script:_udSelectDialog_UpdateCount

    $grid.Add_CurrentCellDirtyStateChanged({
        if ($grid.IsCurrentCellDirty -and $grid.CurrentCell -is [System.Windows.Forms.DataGridViewCheckBoxCell]) {
            $grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) | Out-Null
        }
    })
    $grid.Add_CellValueChanged({
        param($s, $e)
        if ($e.ColumnIndex -eq 0) { & $script:_udSelectDialog_UpdateCount }
    })

    $btnAll.Add_Click({
        foreach ($r in $grid.Rows) { if (-not $r.ReadOnly) { $r.Cells['Check'].Value = $true } }
        & $script:_udSelectDialog_UpdateCount
    })
    $btnNone.Add_Click({
        foreach ($r in $grid.Rows) { if (-not $r.ReadOnly) { $r.Cells['Check'].Value = $false } }
        & $script:_udSelectDialog_UpdateCount
    })

    # v0.49.0 (D4): delete the selected restored entry's backup data, reusing
    # the cleanup engine (Test-CleanupPathSafe + Remove-CleanupArtifactTree).
    $btnDelete.Add_Click({
        if ($grid.SelectedRows.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("削除するエントリの行を選択してください。", "Fabriq BackUper",
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            return
        }
        $row = $grid.SelectedRows[0]
        $tag = $row.Tag
        if ($null -eq $tag -or -not $tag.Restored -or $tag.DataDeleted) {
            [System.Windows.Forms.MessageBox]::Show("復元済み (かつ未削除) のエントリのみ削除できます。", "Fabriq BackUper",
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            return
        }
        if ([string]::IsNullOrWhiteSpace($tag.EntryDir) -or -not (Test-Path -LiteralPath $tag.EntryDir)) {
            [System.Windows.Forms.MessageBox]::Show("対象フォルダが見つかりません。", "Fabriq BackUper",
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "このエントリのバックアップデータを削除します (復元済み):`n  $($tag.SourcePath)`n`n  $($tag.EntryDir)`n`nよろしいですか?",
            "Fabriq BackUper - 削除確認",
            [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $roots = Get-CleanupProtectedRoots
        $res = Remove-CleanupArtifact -Path $tag.EntryDir -SubtreeDenyRoots $roots.Subtree -ProtectedRoots $roots.Protected
        if ($res.Status -eq 'Deleted') {
            $tag.DataDeleted = $true
            $row.Cells['Restored'].Value = 'データ削除済'
            $row.Cells['Check'].Value = $false
            $row.ReadOnly = $true
            $row.DefaultCellStyle.ForeColor = $script:fgDim
            & $script:_udSelectDialog_UpdateCount
        } else {
            [System.Windows.Forms.MessageBox]::Show("削除できませんでした: $($res.Error)", "Fabriq BackUper",
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    })

    $dialog.Controls.Add($grid)

    $btnOk = New-StyledButton -Text 'OK' -X 692 -Y 410 -Width 96 -Height 30 -BgColor $script:bgAccent
    $btnOk.ForeColor = $script:fgWhite; $btnOk.Font = $script:fontBold
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dialog.Controls.Add($btnOk); $dialog.AcceptButton = $btnOk
    $btnCancel = New-StyledButton -Text 'キャンセル' -X 792 -Y 410 -Width 96 -Height 30
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($btnCancel); $dialog.CancelButton = $btnCancel

    $result = $dialog.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }

    $selected = New-Object System.Collections.Generic.List[string]
    foreach ($r in $grid.Rows) {
        if ([bool]$r.Cells['Check'].Value) { $selected.Add([string]$r.Tag.SourcePath) | Out-Null }
    }
    return ,@($selected.ToArray())
}

function Invoke-RestoreStart {
    # v0.27.0: RestoreExplicitDir is the single source of truth for the
    # target aggregate dir (the combo handler resolves to FullPath in
    # timestamp mode, Invoke-RestoreBrowse sets it in Browse mode). The
    # RestoreBrowseMode flag tells us which mode we are in, for label /
    # host resolution purposes.
    if ([string]::IsNullOrWhiteSpace($script:RestoreExplicitDir)) {
        if ($null -eq $script:CurrentHost) { return }
        [System.Windows.Forms.MessageBox]::Show("バックアップ日時を選択するか [バックアップを参照...] を使用してください。", "Fabriq BackUper",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
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
    # v0.32.0: AttemptStrategyB = "generate the auto-restore batch into the
    # operator handoff folder", default ON. Checked=$false = Strategy A files
    # only (no batch). Falls back to $true if the checkbox is unavailable.
    $attemptStrategyB = $true
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
        userdata = @{
            TargetUserProfilePath = $targetUserProfilePath
            # v0.46.0 (D1): null = all entries; array = selected sourcePaths.
            IncludeEntries        = $script:RestoreUserdataIncludeTargets
        }
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
        # v0.26.0: system_evidence section. Restore-time copy of the
        # source-PC evidence into the handoff folder for operator
        # reference. OperatorHandoffSubdir is filled in below (after
        # handoff folder resolution); without it the section is a no-op.
        system_evidence = @{
            TargetUserProfilePath = $targetUserProfilePath
        }
    }

    $hostForEngine = $script:CurrentHost
    $sourceLabel = ""
    if ($script:RestoreBrowseMode) {
        # Browse mode: trust the chosen folder's manifest for OldPCname,
        # since session_form's host selection may not match the folder
        # the operator just picked.
        $aggMfPath = Join-Path $script:RestoreExplicitDir 'manifest.json'
        try {
            $agg = Get-Content -Path $aggMfPath -Raw | ConvertFrom-Json
            $hostForEngine = [PSCustomObject]@{ OldPCname = $agg.oldPcName }
        } catch {
            $hostForEngine = [PSCustomObject]@{ OldPCname = '(unknown)' }
        }
        $sourceLabel = "Browse: $($script:RestoreExplicitDir)"
    } else {
        # Timestamp mode: use the session_form host and the picked entry's
        # display info (Name + Source) for the label.
        $idx = $script:RestoreTimestampCombo.SelectedIndex
        $entry = if ($idx -ge 0 -and $idx -lt $script:RestoreTimestampEntries.Count) {
            $script:RestoreTimestampEntries[$idx]
        } else { $null }
        if ($null -ne $entry) {
            $sourceLabel = "Hostlist: $($script:CurrentHost.OldPCname) / $($entry.Name) [$($entry.Source)]"
        } else {
            $sourceLabel = "Hostlist: $($script:CurrentHost.OldPCname)"
        }
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
        $credSubdir        = Resolve-OperatorHandoffSectionDir -HandoffRoot $script:RestoreHandoffRoot -SectionName 'credentials'
        $outlookSubdir     = Resolve-OperatorHandoffSectionDir -HandoffRoot $script:RestoreHandoffRoot -SectionName 'outlook_pop'
        $sysEvidenceSubdir = Resolve-OperatorHandoffSectionDir -HandoffRoot $script:RestoreHandoffRoot -SectionName 'system_evidence'
        $printerSubdir     = Resolve-OperatorHandoffSectionDir -HandoffRoot $script:RestoreHandoffRoot -SectionName 'printer'
        if (-not $sectionParams['credentials']) { $sectionParams['credentials'] = @{} }
        $sectionParams['credentials']['OperatorHandoffSubdir'] = $credSubdir
        if (-not $sectionParams['outlook_pop']) { $sectionParams['outlook_pop'] = @{} }
        $sectionParams['outlook_pop']['OperatorHandoffSubdir'] = $outlookSubdir
        # v0.26.0
        if (-not $sectionParams['system_evidence']) { $sectionParams['system_evidence'] = @{} }
        $sectionParams['system_evidence']['OperatorHandoffSubdir'] = $sysEvidenceSubdir
        # v0.29.0 (Phase 1)
        if (-not $sectionParams['printer']) { $sectionParams['printer'] = @{} }
        $sectionParams['printer']['OperatorHandoffSubdir'] = $printerSubdir
    }

    $userSummary = if ([string]::IsNullOrWhiteSpace($targetUserProfilePath)) {
        "対象ユーザ: (現在のプロセス)"
    } else {
        "対象ユーザ: $targetUserProfilePath"
    }

    # v0.48.0 (C): pre-restore free-space check (warn-only; folded into the
    # confirm dialog). Fail-open on any error / UNC source / unknown drive --
    # never blocks restore.
    $freeWarn = ""
    try {
        $aggDirC   = Get-RestoreCurrentAggregateDir
        $needBytes = Get-RestoreSelectionSizeBytes -Picked $picked -AggregateDir $aggDirC
        if ($needBytes -gt 0) {
            $probe = if (-not [string]::IsNullOrWhiteSpace($targetUserProfilePath)) { $targetUserProfilePath } else { $env:USERPROFILE }
            $qual = $null
            if (-not [string]::IsNullOrWhiteSpace($probe)) { $qual = Split-Path -Qualifier $probe -ErrorAction SilentlyContinue }
            if (-not [string]::IsNullOrWhiteSpace($qual)) {
                $free   = ([System.IO.DriveInfo]::new($qual + '\')).AvailableFreeSpace
                $margin = Get-RestoreFreeSpaceMarginBytes
                if (($free - $needBytes) -lt $margin) {
                    $needMb   = [math]::Round($needBytes / 1MB, 1)
                    $freeMb   = [math]::Round($free / 1MB, 1)
                    $slackMb  = [math]::Round(($free - $needBytes) / 1MB, 1)
                    $marginMb = [math]::Round($margin / 1MB, 1)
                    $freeWarn = "`n`n⚠ 空き容量不足の恐れ ($qual): 必要 $needMb MB / 空き $freeMb MB / 余裕 $slackMb MB (しきい値 $marginMb MB)"
                }
            }
        }
    } catch { }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "リストア元:`n  $sourceLabel`n`nセクション: $(@($picked | ForEach-Object { $_.SectionName }) -join ', ')`nプリンタ: $($selectedPrinters.Count) 件選択`n$userSummary$freeWarn",
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
  Outlook プロファイルのアカウント設定 (POP / IMAP / SMTP)。
  → POP アカウントは「Restore-Outlook.bat」をダブルクリックすると
    自動で再構築されます (必ず復元対象ユーザでログインした状態で実行。
    管理者としての実行は不可)。詳しい手順は同フォルダの README.txt を参照。
  → IMAP アカウントや、自動復元しない場合は、RESTORE_INSTRUCTIONS.txt /
    _account_settings.txt を参照し Outlook で手動追加してください。
  → PST ファイル本体は Documents\Outlook ファイル\ に展開されています
    (Outlook プロファイル設定が指す場所のため、ここには移していません)。

03_移行元PC情報\
  移行元 PC の構成情報スナップショット (ネットワーク / プリンタ / シリアル /
  インストール済アプリ / Wi-Fi プロファイル / 環境変数 など)。
  → 移行先 PC で各設定を手動再現する際の参照資料としてご利用ください。
  → 採取時の本来のネットワーク設定は _OriginalNetworkConfig.txt をご覧ください
    (LAN 直結移行で一時 IP に変更している場合、06_NetworkConfig.csv は
     一時 IP を記録しています)。
  → アプリ移行チェック: Check-AppMigration.bat をダブルクリックすると、
    案件で移行対象としているアプリ (app_migration_list.csv に定義) と
    移行元 PC の実インストール状況を突き合わせて表示します。
    定義 CSV が未配置の場合は同梱の .sample.csv をコピーして編集してから
    再実行してください。詳細結果は _AppMigrationReport.txt に保存されます。

04_プリンタ\
  移行元 PC のプリンタ環境を移行先 PC に再現するための一式
  (driver / port / 印刷設定 / インストールバッチ)。
  → 操作者が触るファイルは 3 つ:
     - Install-Printers.bat ... ダブルクリックでインストール開始
     - README.txt ............ 詳細手順 (このファイルの 04_プリンタ 抜粋)
     - _printer_settings.txt . 移行元プリンタの設定サマリ
  → _data\ サブフォルダにはインストーラ本体 (Install-Printers.ps1) と
     driver / printsettings / manifest 等の内部ファイルが入っています。
     こちらは操作者が直接開く必要はありません (Install-Printers.bat が
     自動で参照します)。
  → Install-Printers.bat は必ず復元対象ユーザでログインした状態で
     実行してください (UAC で同ユーザの管理者権限に昇格)。

このフォルダは作業完了後に削除して構いません。

リストア実行日時 : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
リストア元 PC    : $($script:RestoreHandoffOldPc)
============================================================
"@
            $utf8Bom = New-Object System.Text.UTF8Encoding($true)
            [System.IO.File]::WriteAllText($readmePath, $readmeText, $utf8Bom)
            # v0.34.0: best-effort cleanup marker at the handoff root, written
            # together with the README so the folder is recognised by the
            # Cleanup view even when every section is skipped (no 0N_ subdir).
            $null = New-CleanupMarker -Dir $script:RestoreHandoffRoot -ArtifactKind 'handoff' `
                -OldPcName $script:RestoreHandoffOldPc -BackuperVersion $script:BackuperVersion
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
            if ($sectionParams.ContainsKey('system_evidence')) {
                $sectionParams['system_evidence'].Remove('OperatorHandoffSubdir') | Out-Null
            }
            if ($sectionParams.ContainsKey('printer')) {
                $sectionParams['printer'].Remove('OperatorHandoffSubdir') | Out-Null
            }
            $script:RestoreHandoffEnabled = $false
        }
    }

    Switch-View 'Progress'
    Initialize-ProgressView -Title "リストア実行中..." -ReturnView 'Restore'
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
    # v0.27.0: always pass ExplicitAggregateDir (engine no longer accepts
    # PickedTimestamp; the combo handler / Browse handler has already
    # resolved any timestamp selection to a FullPath).
    $coreArgs.ExplicitAggregateDir = $script:RestoreExplicitDir
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
