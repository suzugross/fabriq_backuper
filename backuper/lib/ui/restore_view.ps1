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
$script:RestoreDiskLabel       = $null   # v0.69.1 (t-0013): disk-space line
$script:RestoreSectionContainer = $null
# v0.51.0: consolidated restore-entry grid (replaces the section-checkbox grid,
# the printer grid, and the userdata/credentials selection modals).
$script:RestoreEntryGrid       = $null
$script:RestoreEntryDeleteBtn  = $null
$script:RestoreCurrentManifest = $null
# v0.47.0 (B): colored label that warns when the selected backup itself had
# failures/partials (read from the aggregate manifest). Read-only, never blocks.
$script:RestoreBackupWarningLabel = $null
# v0.47.0 (B): count of userdata entries that are GENUINE backup errors (status
# Failed/Partial). v0.72.0 (t-0019): Skipped = source-absent is benign ("該当なし")
# and excluded. Cached at source change because a Success-status userdata section
# can still hide individual failed entries.
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
# v0.53.0 (A): last restore status (Success/Partial/Failed), set by
# Invoke-RestoreStart; read by the Progress view's 完了 button to decide whether
# to fire the post-restore auto network revert.
$script:RestoreLastStatus      = $null
# Phase 0.15.0: checkbox controlling whether outlook_pop restore should
# generate a "/cleanclientrules" launcher shortcut on the target user's
# Desktop. v0.17.0: default OFF (実機観察で「ルール手動実行 1 回で復活」が
# 判明、デフォルトで全削除する必要性が下がった)。
$script:RestoreOutlookShortcutCheck = $null
# Restore entry-selection state. null = include all (default); array = the
# operator-checked subset, harvested from the consolidated grid in
# Invoke-RestoreStart. Passed to the engine as credentials IncludeTargets /
# userdata IncludeEntries (matched by target / sourcePath). v0.51.0 removed the
# selection modals; the per-source button / label / LastSource state went too.
$script:RestoreCredentialsIncludeTargets = $null
$script:RestoreUserdataIncludeTargets    = $null
# v0.17.0: checkbox controlling whether outlook_pop restore should attempt
# Strategy B-light (registry auto-rebuild). Default OFF -- operator manual
# setup via Strategy A is the recommended path. Opt-in for advanced users
# who want to try registry import.
$script:RestoreOutlookAttemptStrategyBCheck = $null
# v0.25.0 (relocated v0.59.0): checkbox controlling whether operator-facing
# artifacts (credentials / Outlook account info / source-PC evidence / printer)
# are consolidated into a single <BackuperRoot>\Handoff\<date>_<OldPC>_BK\ folder
# (was the target user's Desktop in v0.25-0.58.x) instead of being scattered
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
        # v0.51.0: entry selection is per-source; reset so the rebuilt grid
        # re-defaults (selection now lives in the consolidated grid rows).
        $script:RestoreCredentialsIncludeTargets = $null
        $script:RestoreUserdataIncludeTargets    = $null
        Update-RestoreSelection
    })
    $script:RestoreTimestampCombo = $combo
    $panel.Controls.Add($combo)

    $btnBrowse = New-StyledButton -Text "バックアップを参照..." -X 494 -Y 64 -Width 170 -Height 28
    $btnBrowse.Add_Click({ Invoke-RestoreBrowse })
    $panel.Controls.Add($btnBrowse)

    # v0.63.0: the standalone "UNC 接続" button was removed. UNC credential
    # entry is unified into the flow -- Invoke-RestoreBrowse authenticates the
    # preset share before/after the folder picker, and Invoke-RestoreStart
    # authenticates the resolved source (timestamp OR Browse) before the engine
    # runs (all via Resolve-UncAccess -> prefilled Show-UncConnectDialog).

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

    # H28 = two-line capacity: the "not found" / parse-failure messages are long
    # and wrap to a 2nd line; keep H28 so they are not clipped.
    # (The disk-space line is NOT placed here: a WinForms Transparent label does not
    #  show sibling controls behind it -- it paints the parent background -- and the
    #  manifest label sits in front by z-order, so an overlapping disk label was
    #  hidden. The disk line now lives next to the リストア開始 button, see below.)
    $script:RestoreManifestLabel = New-StyledLabel -Text "" -X 24 -Y 114 -Width 880 -Height 28 -FgColor $script:fgDim
    $panel.Controls.Add($script:RestoreManifestLabel)

    # ---- Target user row (v0.51.0: moved up; the section-checkbox grid and the
    # per-section selection modals are replaced by the consolidated entry list
    # below) ----
    $userLbl = New-StyledLabel -Text "対象ユーザ (リストア時の %USERPROFILE% 等を解決):" `
        -X 24 -Y 146 -Width 360 -Height 18 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($userLbl)
    $userCombo = New-StyledComboBox -X 386 -Y 142 -Width 260 -Height 24
    $script:RestoreUserCombo = $userCombo
    # v0.69.1 (t-0013): target user determines the restore drive -> refresh the disk line.
    $userCombo.Add_SelectedIndexChanged({ Update-RestoreDiskInfo })
    $panel.Controls.Add($userCombo)

    # ---- Operator handoff (v0.51.0: moved up) ----
    $handoffCheck = New-StyledCheckBox `
        -Text "operator 用ファイル (資格情報 / Outlook 設定 / 移行元PC情報 / プリンタ) を集約フォルダ (Backuper\Handoff) に統合 (推奨)" `
        -X 24 -Y 172 -Width 820 -Height 22 -Checked $true
    $script:RestoreOperatorHandoffCheck = $handoffCheck
    $panel.Controls.Add($handoffCheck)

    # ---- Outlook extras (v0.51.0: moved up; both opt-in, usually OFF) ----
    $outlookExtrasLbl = New-StyledLabel -Text "Outlook 追加オプション (どちらも opt-in、通常は OFF)" `
        -X 24 -Y 198 -Width 600 -Height 18 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($outlookExtrasLbl)

    $shortcutCheck = New-StyledCheckBox `
        -Text "初回起動用ショートカットを生成 (壊れた仕分けルールをクリア)" `
        -X 24 -Y 218 -Width 520 -Height 20 -Checked $false
    $script:RestoreOutlookShortcutCheck = $shortcutCheck
    $panel.Controls.Add($shortcutCheck)
    $shortcutHint = New-StyledLabel `
        -Text "ルールが壊れている場合の対処用。通常は不要 (ルール 1 回手動実行で復活)" `
        -X 44 -Y 238 -Width 860 -Height 14 -FgColor $script:fgDim
    $panel.Controls.Add($shortcutHint)

    $strategyBCheck = New-StyledCheckBox `
        -Text "Outlook 自動復元バッチを生成 (推奨)" `
        -X 24 -Y 258 -Width 520 -Height 20 -Checked $true
    $script:RestoreOutlookAttemptStrategyBCheck = $strategyBCheck
    $panel.Controls.Add($strategyBCheck)
    $strategyBHint = New-StyledLabel `
        -Text "POP プロファイル再構築 batch を集約フォルダに配置。移行先ユーザで実行 (IMAP は手動)" `
        -X 44 -Y 278 -Width 860 -Height 14 -FgColor $script:fgDim
    $panel.Controls.Add($strategyBHint)

    # ---- Consolidated restore-entry list (v0.51.0) ------------------
    # One grouped list replacing the section-checkbox grid, the printer grid,
    # and the userdata/credentials selection modals. Section header rows toggle
    # the (hidden) RestoreSectionChecks; entry rows are the per-entry selection
    # (userdata/credentials/printer) or info rows (outlook/msime/system_evidence).
    $listLbl = New-StyledLabel -Text "リストア項目 (セクション見出し + エントリ)" `
        -X 24 -Y 304 -Width 420 -Height 18 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($listLbl)

    $btnSelAll = New-StyledButton -Text "全選択" -X 470 -Y 300 -Width 80 -Height 24
    $btnSelAll.Add_Click({ Set-AllRestoreEntryChecks $true })
    $panel.Controls.Add($btnSelAll)
    $btnSelNone = New-StyledButton -Text "クリア" -X 556 -Y 300 -Width 80 -Height 24
    $btnSelNone.Add_Click({ Set-AllRestoreEntryChecks $false })
    $panel.Controls.Add($btnSelNone)
    # D4 (re-homed inline): delete the selected restored userdata entry's data.
    $script:RestoreEntryDeleteBtn = New-StyledButton -Text "選択のバックアップ削除" -X 642 -Y 300 -Width 170 -Height 24
    $script:RestoreEntryDeleteBtn.Add_Click({ Invoke-RestoreEntryDelete })
    $panel.Controls.Add($script:RestoreEntryDeleteBtn)

    # v0.57.0 (t-0008): reload the currently-selected backup. Re-reads its manifest
    # fresh from disk (Update-RestoreSelection) and rebuilds the entry list +
    # warnings, so a backup updated externally AFTER this screen opened (e.g. the
    # source augmented/completed it via the v0.56.0 backup session-merge) can be
    # picked up without reopening the restore session.
    $btnReload = New-StyledButton -Text "更新" -X 818 -Y 300 -Width 86 -Height 24
    $btnReload.Add_Click({ Update-RestoreSelection })
    $_reloadTt = New-Object System.Windows.Forms.ToolTip
    $_reloadTt.SetToolTip($btnReload, "選択中バックアップを再読込（移行元で追記/穴埋めした内容を反映）")
    $panel.Controls.Add($btnReload)

    # B warning (v0.47.0): own full-width line just above the list.
    $script:RestoreBackupWarningLabel = New-StyledLabel `
        -Text "" -X 24 -Y 326 -Width 880 -Height 18 -Font $script:fontBold -FgColor $script:bgDelete
    $panel.Controls.Add($script:RestoreBackupWarningLabel)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(24, 348)
    $grid.Size = New-Object System.Drawing.Size(880, 288)   # v0.69.3: -24 so the start button gets a bottom margin like Backup
    Set-GridStyle -Grid $grid
    $grid.ReadOnly = $false
    $grid.AllowUserToAddRows = $false
    $grid.RowHeadersVisible = $false
    $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect

    $colCk = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colCk.HeaderText = ""; $colCk.Width = 40; $colCk.Name = "Check"
    [void]$grid.Columns.Add($colCk)
    $colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colName.HeaderText = "対象"; $colName.Name = "Name"; $colName.ReadOnly = $true
    $colName.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    [void]$grid.Columns.Add($colName)
    $colKind = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colKind.HeaderText = "種別 / 状態"; $colKind.Width = 150; $colKind.Name = "Kind"; $colKind.ReadOnly = $true
    [void]$grid.Columns.Add($colKind)
    $colSize = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colSize.HeaderText = "サイズ / 補足"; $colSize.Width = 110; $colSize.Name = "Size"; $colSize.ReadOnly = $true
    [void]$grid.Columns.Add($colSize)
    $colRestored = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colRestored.HeaderText = "復元"; $colRestored.Width = 120; $colRestored.Name = "Restored"; $colRestored.ReadOnly = $true
    [void]$grid.Columns.Add($colRestored)

    $grid.Add_CurrentCellDirtyStateChanged({
        if ($grid.IsCurrentCellDirty -and $grid.CurrentCell -is [System.Windows.Forms.DataGridViewCheckBoxCell]) {
            $grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) | Out-Null
        }
    })
    $grid.Add_CellValueChanged({
        param($s, $e)
        if ($e.RowIndex -lt 0 -or $e.ColumnIndex -ne 0) { return }
        Invoke-RestoreEntryCheckChanged -RowIndex $e.RowIndex
    })
    $panel.Controls.Add($grid)
    $script:RestoreEntryGrid = $grid

    # Hidden host for the section on/off checkboxes. These remain the section
    # model that B (Show-RestoreBackupWarnings) and Invoke-RestoreStart read via
    # $script:RestoreSectionChecks[name].Checked / .Add_CheckedChanged; the grid
    # header rows mirror/drive them. Kept off-screen so that contract is unchanged.
    $script:RestoreSectionContainer = New-Object System.Windows.Forms.Panel
    $script:RestoreSectionContainer.Location = New-Object System.Drawing.Point(0, 0)
    $script:RestoreSectionContainer.Size = New-Object System.Drawing.Size(10, 10)
    $script:RestoreSectionContainer.Visible = $false
    $panel.Controls.Add($script:RestoreSectionContainer)

    # ---- Start button (Y shifted +30 by v0.25.0 + further +30 by v0.26.0) ----
    $btnStart = New-StyledButton -Text "リストア開始" -X 700 -Y 654 -Width 204 -Height 44 -BgColor $script:bgAdd
    $btnStart.ForeColor = $script:fgWhite
    $btnStart.Font = $script:fontLarge
    $btnStart.Add_Click({ Invoke-RestoreStart })
    $panel.Controls.Add($btnStart)

    # v0.69.2 (t-0013): disk-space estimate placed right next to the リストア開始 button
    # (in the free area to its left) so the operator sees it at the action point and it
    # is never hidden by other rows. Shows: target drive free / selected-backup size /
    # estimated free after restore (red when low). Filled by Update-RestoreDiskInfo.
    $script:RestoreDiskLabel = New-StyledLabel -Text "" -X 24 -Y 666 -Width 660 -Height 24 -FgColor $script:fgDim
    $panel.Controls.Add($script:RestoreDiskLabel)

    return $panel
}

function Set-AllRestoreEntryChecks {
    # v0.51.0: bulk (un)check the SELECTABLE entry rows of the consolidated grid
    # (skips section header rows, info rows, and greyed/ReadOnly rows).
    param([bool]$Checked)
    if ($null -eq $script:RestoreEntryGrid) { return }
    foreach ($row in $script:RestoreEntryGrid.Rows) {
        $tag = $row.Tag
        if ($null -eq $tag -or "$($tag.Kind)" -ne 'entry') { continue }
        if ($row.ReadOnly) { continue }
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
    # v0.50.0 (D6) / v0.51.0: reset the entry selection on every (re-)entry so a
    # return after a partial restore starts from the restored-aware defaults
    # (restored entries unchecked, Partial re-checked), not a stale selection.
    $script:RestoreUserdataIncludeTargets    = $null
    $script:RestoreCredentialsIncludeTargets = $null
    $combo = $script:RestoreTimestampCombo
    $combo.Enabled = $true
    $script:RestoreBrowseMode = $false
    if ($null -ne $script:RestoreBrowseLabel) {
        $script:RestoreBrowseLabel.Text      = ""
        $script:RestoreBrowseLabel.Font      = $script:fontNormal
        $script:RestoreBrowseLabel.ForeColor = $script:fgDim
    }

    # v0.51.0: build the hidden section on/off checkboxes BEFORE selecting a
    # timestamp, so the consolidated grid (built by Update-RestoreSelection on
    # SelectedIndex=0) can mirror them into section header rows. These remain the
    # section model B + Invoke-RestoreStart read via $script:RestoreSectionChecks.
    $cont = $script:RestoreSectionContainer
    $cont.Controls.Clear()
    $script:RestoreSectionChecks = @{}
    $i = 0
    foreach ($s in $script:SectionList) {
        $cb = New-StyledCheckBox -Text $s.DisplayName `
            -X 0 -Y ($i * 24) -Width 260 -Height 22 `
            -Checked ($s.Enabled -eq "1")
        $cb.Tag = $s.SectionName
        if ($s.SectionName -eq 'system_evidence') {
            $cb.Checked = $true
            $cb.Enabled = $false
        }
        $cont.Controls.Add($cb)
        $script:RestoreSectionChecks[$s.SectionName] = $cb
        # v0.47.0 (B): re-render the failure warning when a section toggles.
        $cb.Add_CheckedChanged({ Show-RestoreBackupWarnings })
        $i++
    }

    $count = Update-RestoreTimestampCombo
    if ($count -gt 0) {
        $combo.SelectedIndex = 0   # fires the handler -> Update-RestoreSelection -> builds the grid
    } else {
        $script:RestoreManifestLabel.Text = "($($script:CurrentHost.OldPCname) のバックアップが見つかりません (local / share / UNC のいずれにも存在せず)。別の場所にある場合は [バックアップを参照] を使用してください)"
        if ($null -ne $script:RestoreEntryGrid) { $script:RestoreEntryGrid.Rows.Clear() }
        # v0.42.0 (P2): nothing to restore yet -> auto-wait for arrival.
        Start-RestoreWait -Auto
    }

    # v0.47.0 (B): re-render now that the section checkboxes + grid exist.
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
    # v0.73.0 (t-0018): auto-start when enabled (default ON) AND the backup is CLEAN
    # (no genuine error; benign 該当なし skips OK). 60s cancellable countdown; on
    # proceed -> Invoke-RestoreStart -SkipConfirm (free-space etc. still checked).
    # Flag off / not clean / cancelled -> fall back to the manual prompt below.
    if ((Get-RestoreAutoStartOnArrival) -and (Test-RestoreBackupClean -AggregateDir $script:RestoreExplicitDir)) {
        $script:RestoreManifestLabel.Text = "バックアップ到着: $($flag.timestamp) — 問題なし。自動リストアを開始します (キャンセル可)。"
        if (Show-RestoreAutoStartCountdown -Seconds 60) {
            Invoke-RestoreStart -SkipConfirm
            # If the restore actually started it switched to the Progress view -> done.
            # If it aborted early (e.g. the free-space block showed its own dialog),
            # fall through to the manual prompt so we don't leave a stale label.
            if ($null -ne $script:Views -and $null -ne $script:Views['Progress'] -and $script:Views['Progress'].Visible) { return }
        }
        # cancelled / aborted -> manual fallback
    }
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
    $dlg.Description = "バックアップフォルダを選択 (manifest.json を含むこと)。UNC 共有の場合は認証情報の入力を求められます。"

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

    # v0.63.0: with the explicit "UNC 接続" button gone, authenticate the preset
    # UNC share (if SelectedPath was seeded to one) BEFORE opening the picker so
    # the operator can navigate into it. Cancelling just leaves the picker to
    # open at its default (they may still choose a local path).
    if ($dlg.SelectedPath -like '\\*' -and -not (Test-UncPath -Path $dlg.SelectedPath)) {
        $browsePresetUser = ''
        if ($null -ne $script:MigrationProfile -and `
            -not [string]::IsNullOrWhiteSpace($script:MigrationProfile.backuper.uncUsername)) {
            $browsePresetUser = $script:MigrationProfile.backuper.uncUsername
        }
        $browsePresetUser = Get-PresetUncUsername -ProfileUsername $browsePresetUser
        [void](Resolve-UncAccess -Path $dlg.SelectedPath -PresetUsername $browsePresetUser)
    }

    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $chosen = $dlg.SelectedPath

    # v0.63.0: confirm access to the chosen folder before reading its manifest
    # (post-selection prompt; prefilled with the profile username when present).
    $chosenPresetUser = ''
    if ($null -ne $script:MigrationProfile -and `
        -not [string]::IsNullOrWhiteSpace($script:MigrationProfile.backuper.uncUsername)) {
        $chosenPresetUser = $script:MigrationProfile.backuper.uncUsername
    }
    $chosenPresetUser = Get-PresetUncUsername -ProfileUsername $chosenPresetUser
    if (-not (Resolve-UncAccess -Path $chosen -PresetUsername $chosenPresetUser)) {
        [System.Windows.Forms.MessageBox]::Show(
            "フォルダに接続できませんでした: $chosen`n`n認証情報の入力をキャンセルしたか、接続に失敗しました。資格情報を確認して再度お試しください。",
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

    # v0.51.0: source changed via Browse - reset entry selection (rebuilt grid
    # re-defaults).
    $script:RestoreCredentialsIncludeTargets = $null
    $script:RestoreUserdataIncludeTargets    = $null

    $sz = if ($agg.summary.totalBytes) { [math]::Round([long]$agg.summary.totalBytes / 1MB, 1) } else { 0 }
    $secCount = if ($agg.summary.sectionCount) { [int]$agg.summary.sectionCount } else { 0 }
    $script:RestoreManifestLabel.Text = "aggregate manifest  |  collectedAt=$($agg.collectedAt)  |  oldPcName=$($agg.oldPcName)  |  sections=$secCount  |  totalBytes=$sz MB"
    $script:RestoreCurrentManifest = $agg   # v0.47.0 (B): cache for warnings
    $script:RestoreUserdataProblemCount = Get-RestoreUserdataProblemCount -AggregateDir $chosen

    Update-RestoreEntryGrid -AggregateDir $chosen
    Show-RestoreBackupWarnings   # v0.47.0 (B): render backup-failure warning
}

# v0.51.0: consolidated restore-entry grid -----------------------
function Set-RestoreSectionRowsEnabled {
    # Grey/un-grey the entry rows of one section (called when its header toggles).
    # Intrinsically-disabled rows (Selectable=$false: userdata Skipped/deleted,
    # info rows) stay disabled even when the section is enabled.
    param([string]$Section, [bool]$Enabled)
    if ($null -eq $script:RestoreEntryGrid) { return }
    foreach ($row in $script:RestoreEntryGrid.Rows) {
        $t = $row.Tag
        if ($null -eq $t -or "$($t.Kind)" -ne 'entry' -or "$($t.Section)" -ne $Section) { continue }
        $selectable = [bool]$t.Selectable
        if ($Enabled -and $selectable) {
            $row.ReadOnly = $false
            $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Empty
        } else {
            $row.ReadOnly = $true
            $row.DefaultCellStyle.ForeColor = $script:fgDim
        }
    }
}

function Invoke-RestoreEntryCheckChanged {
    # Grid Check toggled. Section header row -> mirror to the hidden section
    # checkbox (fires its CheckedChanged -> Show-RestoreBackupWarnings) and
    # grey/un-grey the section's entry rows. Entry rows: harvested at start.
    param([int]$RowIndex)
    $grid = $script:RestoreEntryGrid
    if ($null -eq $grid -or $RowIndex -lt 0 -or $RowIndex -ge $grid.Rows.Count) { return }
    $row = $grid.Rows[$RowIndex]
    $t = $row.Tag
    if ($null -eq $t -or "$($t.Kind)" -ne 'section') { return }
    $checked = [bool]$row.Cells['Check'].Value
    $cb = $script:RestoreSectionChecks["$($t.Section)"]
    if ($null -ne $cb) { $cb.Checked = $checked }   # mirror -> CheckedChanged -> B
    Set-RestoreSectionRowsEnabled -Section "$($t.Section)" -Enabled $checked
}

function Invoke-RestoreEntryDelete {
    # D4 (re-homed inline): delete the selected restored userdata entry's backup
    # data, reusing the cleanup engine (Test-CleanupPathSafe + protected roots).
    $grid = $script:RestoreEntryGrid
    if ($null -eq $grid -or $grid.SelectedRows.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("削除する行 (復元済みのユーザデータ) を選択してください。", "Fabriq BackUper",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    $row = $grid.SelectedRows[0]
    $t = $row.Tag
    if ($null -eq $t -or "$($t.Kind)" -ne 'entry' -or "$($t.Section)" -ne 'userdata' -or -not $t.Restored -or $t.DataDeleted) {
        [System.Windows.Forms.MessageBox]::Show("復元済み (かつ未削除) のユーザデータ行のみ削除できます。", "Fabriq BackUper",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    if ([string]::IsNullOrWhiteSpace($t.EntryDir) -or -not (Test-Path -LiteralPath $t.EntryDir)) {
        [System.Windows.Forms.MessageBox]::Show("対象フォルダが見つかりません。", "Fabriq BackUper",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "このエントリのバックアップデータを削除します (復元済み):`n  $($t.Key)`n`n  $($t.EntryDir)`n`nよろしいですか?",
        "Fabriq BackUper - 削除確認",
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $roots = Get-CleanupProtectedRoots
    $res = Remove-CleanupArtifact -Path $t.EntryDir -SubtreeDenyRoots $roots.Subtree -ProtectedRoots $roots.Protected
    if ($res.Status -eq 'Deleted') {
        $t.DataDeleted = $true
        $row.Cells['Restored'].Value = 'データ削除済'
        $row.Cells['Check'].Value    = $false
        $row.ReadOnly = $true
        $row.DefaultCellStyle.ForeColor = $script:fgDim
    } else {
        [System.Windows.Forms.MessageBox]::Show("削除できませんでした: $($res.Error)", "Fabriq BackUper",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
}

function Update-RestoreEntryGrid {
    # Rebuild the consolidated grid from the selected backup's manifests: one
    # section-header row per registered section (mirrors the hidden
    # RestoreSectionChecks), then per-entry rows. userdata/credentials/printer
    # entries are selectable; outlook_pop/msime_dict/system_evidence are info
    # rows. userdata rows carry D3 restored status + D4 delete target.
    param([Parameter(Mandatory = $true)][string]$AggregateDir)
    $grid = $script:RestoreEntryGrid
    if ($null -eq $grid) { return }
    $grid.Rows.Clear()
    $agg = $script:RestoreCurrentManifest
    $udEntriesRoot = Join-Path $AggregateDir 'sections\userdata\entries'

    foreach ($s in $script:SectionList) {
        $sectionName = "$($s.SectionName)"
        $display     = "$($s.DisplayName)"
        $cb = $script:RestoreSectionChecks[$sectionName]
        $sectionChecked = $true
        if ($null -ne $cb) { $sectionChecked = [bool]$cb.Checked }

        $secStatus = ''
        if ($null -ne $agg -and $null -ne $agg.sections -and `
            ($agg.sections.PSObject.Properties.Name -contains $sectionName)) {
            $secStatus = "$($agg.sections.$sectionName.status)"
        }

        $hdrIdx = $grid.Rows.Add($sectionChecked, ("── {0} ──" -f $display), $secStatus, "", "")
        $hrow = $grid.Rows[$hdrIdx]
        $hrow.Tag = [pscustomobject]@{ Kind = 'section'; Section = $sectionName }
        $hrow.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(226, 226, 232)
        $hrow.DefaultCellStyle.Font = $script:fontBold
        if ($sectionName -eq 'system_evidence') { $hrow.ReadOnly = $true }   # forced section

        $hadEntries = $false
        switch ($sectionName) {
            'userdata' {
                $udm = $null
                $mf = Join-Path $AggregateDir 'sections\userdata\manifest.json'
                if (Test-Path -LiteralPath $mf) { try { $udm = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
                if ($null -ne $udm -and $null -ne $udm.items -and $null -ne $udm.items.entries) {
                    foreach ($en in @($udm.items.entries)) {
                        if ($null -eq $en) { continue }
                        $hadEntries = $true
                        $isSkipped = ("$($en.status)" -eq 'Skipped') -or [string]::IsNullOrWhiteSpace("$($en.backupSubpath)")
                        $sizeStr = if ($en.byteCount) { ('{0:N1} MB' -f ([long]$en.byteCount / 1MB)) } else { '0 MB' }
                        $entryDir = $null; $restoredStr = ''; $isRestored = $false; $dataDeleted = $false; $isComplete = $false
                        $idStr = "$($en.id)"
                        $safeLeaf = (-not [string]::IsNullOrWhiteSpace($idStr)) -and ($idStr -notmatch '[\\/:]') -and ($idStr -notmatch '\.\.')
                        if ($safeLeaf) {
                            $entryDir = Join-Path $udEntriesRoot $idStr
                            if (Test-Path -LiteralPath (Join-Path $entryDir '_restored.json')) {
                                $isRestored = $true; $restoredStr = '復元済'; $mkStatus = ''
                                try {
                                    $mk = Get-Content -LiteralPath (Join-Path $entryDir '_restored.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                                    $mkStatus = "$($mk.status)"
                                    $whenStr = if ($mk.restoredAt) { ' ' + ([datetime]$mk.restoredAt).ToString('MM/dd HH:mm') } else { '' }
                                    if ($mkStatus -eq 'Partial') { $restoredStr = '復元済(部分)' + $whenStr } else { $restoredStr = '復元済' + $whenStr }
                                } catch {}
                                $isComplete = ($mkStatus -eq 'Done' -or $mkStatus -eq 'AlreadyPresent')
                                if (-not (Test-Path -LiteralPath (Join-Path $entryDir 'data'))) { $dataDeleted = $true; $restoredStr = 'データ削除済' }
                            }
                        }
                        $chk = (-not $isSkipped) -and (-not $dataDeleted) -and (-not $isComplete)
                        # v0.72.0 (t-0019): Skipped = source path absent on the source PC
                        # (device individual difference) -> benign "該当なし", NOT an error.
                        # Genuine copy errors stay Failed/Partial; empty-subpath non-Skipped
                        # (couldn't retrieve) keeps 取得不可.
                        $st  = if ("$($en.status)" -eq 'Skipped') { '該当なし' } elseif ($isSkipped) { '取得不可' } else { "$($en.status)" }
                        $ri = $grid.Rows.Add($chk, "    $($en.sourcePath)", $st, $sizeStr, $restoredStr)
                        $erow = $grid.Rows[$ri]
                        $selectable = (-not $isSkipped) -and (-not $dataDeleted)
                        $erow.Tag = [pscustomobject]@{ Kind='entry'; Section='userdata'; Key=[string]$en.sourcePath; EntryDir=$entryDir; Restored=$isRestored; DataDeleted=$dataDeleted; Selectable=$selectable }
                        if (-not $selectable) { $erow.ReadOnly = $true; $erow.DefaultCellStyle.ForeColor = $script:fgDim }
                        elseif ($isRestored) { $erow.Cells['Restored'].Style.ForeColor = [System.Drawing.Color]::FromArgb(46,125,50) }
                    }
                }
            }
            'credentials' {
                $cm = $null
                $mf = Join-Path $AggregateDir 'sections\credentials\manifest.json'
                if (Test-Path -LiteralPath $mf) { try { $cm = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
                if ($null -ne $cm -and $null -ne $cm.credentials) {
                    foreach ($c in @($cm.credentials)) {
                        if ($null -eq $c) { continue }
                        $hadEntries = $true
                        $ri = $grid.Rows.Add($true, "    $($c.target)", "$($c.type)", "$($c.userName)", "")
                        $grid.Rows[$ri].Tag = [pscustomobject]@{ Kind='entry'; Section='credentials'; Key=[string]$c.target; Selectable=$true }
                    }
                }
            }
            'printer' {
                $pm = $null
                $mf = Join-Path $AggregateDir 'sections\printer\manifest.json'
                if (Test-Path -LiteralPath $mf) { try { $pm = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
                $printersArr = @()
                if ($null -ne $pm -and $null -ne $pm.items) { $printersArr = @($pm.items.printers) }
                foreach ($p in $printersArr) {
                    if ($null -eq $p) { continue }
                    if ($p.driverName -eq 'Remote Desktop Easy Print') { continue }
                    if ($p.portName -match '^TS\d+$') { continue }
                    $isVirtual = $false
                    foreach ($vp in @('Microsoft Print To PDF','Microsoft XPS Document Writer','OneNote','Microsoft Shared Fax','Microsoft OpenXPS')) { if ($p.driverName -like "*$vp*") { $isVirtual = $true; break } }
                    foreach ($vp in @('PORTPROMPT:','XPSPort:','FAX:','nul:','SHRFAX:')) { if ($p.portName -like "*$vp*") { $isVirtual = $true; break } }
                    if ($p.portName -like 'OneNote*') { $isVirtual = $true }
                    $hadEntries = $true
                    $ri = $grid.Rows.Add((-not $isVirtual), "    $($p.name)", "$($p.driverName)", "$($p.portName)", "")
                    $grid.Rows[$ri].Tag = [pscustomobject]@{ Kind='entry'; Section='printer'; Key=[string]$p.name; Selectable=$true }
                }
            }
            'outlook_pop' {
                $om = $null
                $mf = Join-Path $AggregateDir 'sections\outlook_pop\manifest.json'
                if (Test-Path -LiteralPath $mf) { try { $om = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
                $profs = @()
                if ($null -ne $om -and $null -ne $om.items) { $profs = @($om.items.profiles) }
                foreach ($pf in $profs) {
                    if ($null -eq $pf) { continue }
                    $hadEntries = $true
                    $acc = 0; if ($null -ne $pf.accounts) { $acc = @($pf.accounts).Count }
                    $ri = $grid.Rows.Add($false, "    $($pf.name)", 'profile', ("{0} アカウント" -f $acc), "")
                    $rr = $grid.Rows[$ri]
                    $rr.Tag = [pscustomobject]@{ Kind='info'; Section='outlook_pop' }
                    $rr.ReadOnly = $true; $rr.DefaultCellStyle.ForeColor = $script:fgDim
                }
            }
            'msime_dict' {
                $mm = $null
                $mf = Join-Path $AggregateDir 'sections\msime_dict\manifest.json'
                if (Test-Path -LiteralPath $mf) { try { $mm = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
                $files = @(); if ($null -ne $mm -and $null -ne $mm.files) { $files = @($mm.files) }
                foreach ($f in $files) {
                    if ($null -eq $f) { continue }
                    $hadEntries = $true
                    $ri = $grid.Rows.Add($false, "    $($f.fileName)", 'IME辞書', "", "")
                    $rr = $grid.Rows[$ri]
                    $rr.Tag = [pscustomobject]@{ Kind='info'; Section='msime_dict' }
                    $rr.ReadOnly = $true; $rr.DefaultCellStyle.ForeColor = $script:fgDim
                }
            }
            default { }   # system_evidence + others: header only (info row added below)
        }

        if (-not $hadEntries) {
            $ri = $grid.Rows.Add($false, "    (項目選択なし)", '', "", "")
            $rr = $grid.Rows[$ri]
            $rr.Tag = [pscustomobject]@{ Kind='info'; Section=$sectionName }
            $rr.ReadOnly = $true; $rr.DefaultCellStyle.ForeColor = $script:fgDim
        }

        if (-not $sectionChecked) { Set-RestoreSectionRowsEnabled -Section $sectionName -Enabled $false }
    }
}

# v0.73.2: mirror the hidden section on/off checkboxes to what the SELECTED
# backup actually contains, so sections that were de-selected at backup time
# (absent from the aggregate manifest) default to OFF and are not restored /
# reported as "failed". Section present AND status != 'Skipped' -> ON, else OFF.
# system_evidence stays forced-ON (its checkbox is disabled). Must run BEFORE
# Update-RestoreEntryGrid, which reads these checks into the header rows (811).
function Update-RestoreSectionChecksFromManifest {
    param([Parameter(Mandatory = $true)]$Aggregate)
    if ($null -eq $script:RestoreSectionChecks) { return }
    foreach ($s in $script:SectionList) {
        $name = "$($s.SectionName)"
        if ($name -eq 'system_evidence') { continue }   # forced section, leave as-is
        $cb = $script:RestoreSectionChecks[$name]
        if ($null -eq $cb) { continue }
        $present = $false
        if ($null -ne $Aggregate -and $null -ne $Aggregate.sections -and `
            ($Aggregate.sections.PSObject.Properties.Name -contains $name)) {
            if ("$($Aggregate.sections.$name.status)" -ne 'Skipped') { $present = $true }
        }
        $cb.Checked = $present
    }
}

function Update-RestoreSelection {
    if ($null -ne $script:RestoreEntryGrid) { $script:RestoreEntryGrid.Rows.Clear() }
    # v0.47.0 (B): reset the cached manifest + warning each refresh. The
    # success path re-caches and the end-of-function call renders; early
    # returns leave the warning cleared.
    $script:RestoreCurrentManifest = $null
    $script:RestoreUserdataProblemCount = 0
    if ($null -ne $script:RestoreBackupWarningLabel) { $script:RestoreBackupWarningLabel.Text = "" }
    if ($null -ne $script:RestoreDiskLabel) { $script:RestoreDiskLabel.Text = "" }

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
        # v0.73.2: align section selection with what this backup contains (must run
        # before Update-RestoreEntryGrid below, which reads the hidden checks).
        Update-RestoreSectionChecksFromManifest -Aggregate $agg
    }
    catch {
        $script:RestoreManifestLabel.Text = "aggregate manifest parse failed: $($_.Exception.Message)"
    }

    Update-RestoreEntryGrid -AggregateDir $aggregateDir
    Show-RestoreBackupWarnings   # v0.47.0 (B): render backup-failure warning
    Update-RestoreDiskInfo       # v0.69.1 (t-0013): refresh the disk-space line
}

# v0.69.1 (t-0013): compact byte formatter (GB/MB/KB) for the restore disk line.
function Format-DiskSize {
    param([double]$Bytes)
    $neg = ''
    if ($Bytes -lt 0) { $neg = '-'; $Bytes = - $Bytes }
    if ($Bytes -ge 1073741824) { return ($neg + ('{0:N1} GB' -f ($Bytes / 1073741824))) }
    if ($Bytes -ge 1048576)    { return ($neg + ('{0:N1} MB' -f ($Bytes / 1048576))) }
    if ($Bytes -ge 1024)       { return ($neg + ('{0:N0} KB' -f ($Bytes / 1024))) }
    return ($neg + ('{0:N0} B' -f $Bytes))
}

# v0.69.1 (t-0013): refresh the restore-screen disk line -- target-drive free /
# selected-backup size / estimated free after restore. Display-only, never blocks;
# self-clears when no backup is selected; turns red when the estimate is tight.
function Update-RestoreDiskInfo {
    if ($null -eq $script:RestoreDiskLabel) { return }
    $agg = $script:RestoreCurrentManifest
    if ($null -eq $agg) { $script:RestoreDiskLabel.Text = ''; return }

    # selected-backup total size. Prefer the rolled-up summary.totalBytes, but
    # manifests written before v0.69.4 recorded 0 there (aggregator guard bug), so
    # fall back to summing the per-section summaries -- which are correct on disk.
    # ($agg is from ConvertFrom-Json => PSCustomObject, so property access is fine.)
    $backupBytes = 0
    if ($null -ne $agg.summary -and $null -ne $agg.summary.totalBytes) {
        try { $backupBytes = [long]$agg.summary.totalBytes } catch { $backupBytes = 0 }
    }
    if ($backupBytes -le 0 -and $null -ne $agg.sections) {
        $secSum = 0
        foreach ($sp in $agg.sections.PSObject.Properties) {
            $secSummary = $sp.Value.summary
            if ($null -ne $secSummary -and $null -ne $secSummary.totalBytes) {
                try { $secSum += [long]$secSummary.totalBytes } catch { }
            }
        }
        $backupBytes = $secSum
    }

    # target drive = root of the selected restore user profile (fallback: system drive)
    $profilePath = ''
    try { $profilePath = Get-SelectedRestoreUserProfilePath } catch { $profilePath = '' }
    $driveRoot = ''
    if (-not [string]::IsNullOrWhiteSpace($profilePath)) {
        try { $driveRoot = [System.IO.Path]::GetPathRoot($profilePath) } catch { $driveRoot = '' }
    }
    if ([string]::IsNullOrWhiteSpace($driveRoot)) { $driveRoot = "$env:SystemDrive\" }

    $free = -1
    try { $free = [long]((New-Object System.IO.DriveInfo -ArgumentList $driveRoot).AvailableFreeSpace) }
    catch { $free = -1 }
    if ($free -lt 0) {
        $script:RestoreDiskLabel.ForeColor = $script:fgDim
        $script:RestoreDiskLabel.Text = "ディスク空き容量を取得できませんでした ($driveRoot)"
        return
    }

    $after = $free - $backupBytes
    $driveDisp = $driveRoot.TrimEnd('\')
    $script:RestoreDiskLabel.Text = ("ディスク {0}   空き {1}   /   バックアップ {2}   /   リストア後の空き(目安) {3}" -f `
        $driveDisp, (Format-DiskSize $free), (Format-DiskSize $backupBytes), (Format-DiskSize $after))

    # red when the estimate is negative or within a small (1 GB) safety margin
    if ($after -lt 1073741824) {
        $script:RestoreDiskLabel.ForeColor = [System.Drawing.Color]::FromArgb(210, 60, 60)
    } else {
        $script:RestoreDiskLabel.ForeColor = $script:fgDim
    }
}

# v0.47.0 (B): backup-failure warning ----------------------------
function Get-RestoreUserdataProblemCount {
    # Counts userdata entries that are GENUINE backup errors (status Failed/Partial).
    # v0.72.0 (t-0019): Skipped = source-absent (device individual difference) is a
    # benign "該当なし" and is NOT counted. Returns 0 on any error/absence.
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
            # v0.72.0 (t-0019): count GENUINE errors only. Skipped = source-absent
            # (benign 該当なし) is NOT a problem.
            if ($st -eq 'Failed' -or $st -eq 'Partial') { $n++ }
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
    if ($udProblem  -gt 0) { $parts += "ユーザデータ取得失敗 $udProblem" }   # v0.72.0 (t-0019): genuine errors only (該当なしスキップは除外)
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

# v0.52.0 (C rework): pre-restore free-space sizing --------------
function Get-RestoreFreeSpaceHeadroomBytes {
    # Disk breathing-room to keep FREE after the restore. profile override
    # restore.freeSpaceHeadroomBytes wins; else 10 GB. No operator UI (the old
    # editable threshold was dropped as meaningless). Always returns [long].
    $defaultBytes = [long](10GB)
    if ($null -ne $script:MigrationProfile -and $null -ne $script:MigrationProfile.restore `
        -and $script:MigrationProfile.restore.freeSpaceHeadroomBytes) {
        try { return [long]$script:MigrationProfile.restore.freeSpaceHeadroomBytes } catch {}
    }
    return $defaultBytes
}

# v0.73.0 (t-0018): auto-start-on-arrival opt-in. profile restore.autoStartOnArrival
# wins; DEFAULT TRUE (absent -> true). Returns [bool].
function Get-RestoreAutoStartOnArrival {
    if ($null -ne $script:MigrationProfile -and $null -ne $script:MigrationProfile.restore -and `
        $null -ne $script:MigrationProfile.restore.PSObject.Properties['autoStartOnArrival']) {
        try { return [bool]$script:MigrationProfile.restore.autoStartOnArrival } catch { return $true }
    }
    return $true
}

# v0.73.0 (t-0018): is the selected backup CLEAN enough to auto-start? TRUE only when
# there is NO genuine error -- no Failed/Partial section AND no Failed/Partial userdata
# entry. benign Skipped (該当なし / source-absent) is allowed. Fail-closed on any error.
function Test-RestoreBackupClean {
    param([string]$AggregateDir)
    if ([string]::IsNullOrWhiteSpace($AggregateDir)) { return $false }
    $mfPath = Join-Path $AggregateDir 'manifest.json'
    if (-not (Test-Path -LiteralPath $mfPath)) { return $false }
    try { $agg = Get-Content -LiteralPath $mfPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $false }
    if ($null -ne $agg.sections) {
        foreach ($p in $agg.sections.PSObject.Properties) {
            $st = "$($p.Value.status)"
            if ([string]::IsNullOrWhiteSpace($st)) { return $false }   # unknown status -> fail-closed (manual, never auto-start)
            if ($st -eq 'Failed' -or $st -eq 'Partial') { return $false }
        }
    }
    if ((Get-RestoreUserdataProblemCount -AggregateDir $AggregateDir) -gt 0) { return $false }
    return $true
}

# v0.73.0 (t-0018): cancellable countdown before auto-starting a restore. Returns
# $true to proceed (timeout or 今すぐ開始), $false if cancelled / window closed.
function Show-RestoreAutoStartCountdown {
    param([int]$Seconds = 60)
    $script:_rdAutoStartProceed   = $false
    $script:_rdCountdownRemaining = [int]$Seconds

    $dlg = New-Object System.Windows.Forms.Form
    Set-FormStyle -Form $dlg -Title "リストア自動開始" -Width 460 -Height 210
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.StartPosition = "CenterParent"
    if ($null -ne $script:MainForm) { $dlg.Owner = $script:MainForm }

    $lbl = New-StyledLabel -Text "" -X 20 -Y 22 -Width 420 -Height 70
    $dlg.Controls.Add($lbl)
    $lbl.Text = "移行元のバックアップが到着しました (問題なし)。`n`nあと $($script:_rdCountdownRemaining) 秒で自動的にリストアを開始します。`n中止する場合は [キャンセル] を押してください。"

    $btnNow = New-StyledButton -Text "今すぐ開始" -X 110 -Y 128 -Width 130 -Height 36 -BgColor $script:bgAdd
    $btnNow.ForeColor = $script:fgWhite
    $btnNow.Font = $script:fontBold
    $dlg.Controls.Add($btnNow)
    $btnCancel = New-StyledButton -Text "キャンセル" -X 260 -Y 128 -Width 130 -Height 36
    $dlg.Controls.Add($btnCancel)

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({
        $script:_rdCountdownRemaining--
        if ($script:_rdCountdownRemaining -le 0) {
            try { $timer.Stop() } catch {}
            $script:_rdAutoStartProceed = $true
            $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dlg.Close()
        } else {
            $lbl.Text = "移行元のバックアップが到着しました (問題なし)。`n`nあと $($script:_rdCountdownRemaining) 秒で自動的にリストアを開始します。`n中止する場合は [キャンセル] を押してください。"
        }
    })
    $btnNow.Add_Click({ try { $timer.Stop() } catch {}; $script:_rdAutoStartProceed = $true;  $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK;     $dlg.Close() })
    $btnCancel.Add_Click({ try { $timer.Stop() } catch {}; $script:_rdAutoStartProceed = $false; $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $dlg.Close() })
    $dlg.Add_FormClosing({ try { $timer.Stop() } catch {} })   # [X] close = cancel (proceed stays false)

    $timer.Start()
    [void]$dlg.ShowDialog()
    return [bool]$script:_rdAutoStartProceed
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

function Invoke-RestoreStart {
    param([switch]$SkipConfirm)   # v0.73.0 (t-0018): auto-start skips the YesNo confirm (the countdown is the confirmation)
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

    # v0.63.0: unify UNC credential entry into the flow (the explicit "UNC 接続"
    # button was removed). If the resolved source is a UNC share that is not
    # reachable yet, prompt for credentials here -- this covers BOTH timestamp
    # (hostlist) and Browse modes before the engine runs. Idempotent: once the
    # share is mapped, Test-UncPath short-circuits so there is no duplicate prompt.
    if ($script:RestoreExplicitDir -like '\\*' -and -not (Test-UncPath -Path $script:RestoreExplicitDir)) {
        $startPresetUser = ''
        if ($null -ne $script:MigrationProfile -and `
            -not [string]::IsNullOrWhiteSpace($script:MigrationProfile.backuper.uncUsername)) {
            $startPresetUser = $script:MigrationProfile.backuper.uncUsername
        }
        $startPresetUser = Get-PresetUncUsername -ProfileUsername $startPresetUser
        if (-not (Resolve-UncAccess -Path $script:RestoreExplicitDir -PresetUsername $startPresetUser)) {
            [System.Windows.Forms.MessageBox]::Show(
                "バックアップ元の共有に接続できませんでした:`n$($script:RestoreExplicitDir)`n`n認証情報の入力をキャンセルしたか、接続に失敗しました。",
                "Fabriq BackUper", [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
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

    # v0.51.0: harvest the per-entry selection from the consolidated grid.
    # printer -> array of checked names (existing contract). userdata/credentials
    # -> $null when ALL selectable entries are checked (= "all", the default
    # invariant B/C rely on), else the checked subset array. This reproduces the
    # exact SectionParams the removed modals + printer grid produced.
    $selectedPrinters = @()
    $udChecked = New-Object System.Collections.Generic.List[string]
    $udTotal = 0
    $credChecked = New-Object System.Collections.Generic.List[string]
    $credTotal = 0
    if ($null -ne $script:RestoreEntryGrid) {
        foreach ($row in $script:RestoreEntryGrid.Rows) {
            $t = $row.Tag
            if ($null -eq $t -or "$($t.Kind)" -ne 'entry') { continue }
            $isChk = [bool]$row.Cells['Check'].Value
            switch ("$($t.Section)") {
                'printer'     { if ($isChk) { $selectedPrinters += [string]$t.Key } }
                'userdata'    { if ([bool]$t.Selectable) { $udTotal++;   if ($isChk) { $udChecked.Add([string]$t.Key)   | Out-Null } } }
                'credentials' { if ([bool]$t.Selectable) { $credTotal++; if ($isChk) { $credChecked.Add([string]$t.Key) | Out-Null } } }
            }
        }
    }
    $script:RestoreUserdataIncludeTargets    = if ($udTotal   -gt 0 -and $udChecked.Count   -eq $udTotal)   { $null } else { @($udChecked.ToArray()) }
    $script:RestoreCredentialsIncludeTargets = if ($credTotal -gt 0 -and $credChecked.Count -eq $credTotal) { $null } else { @($credChecked.ToArray()) }

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
        # v0.59.0 (t-0006 stage 2): emit the handoff (集約) folder INTO the Backuper
        # install (<BackuperRoot>\Handoff\<date>_<OldPC>_BK) instead of the target
        # user's Desktop, so it is browsable via Fabriq Handoff Viewer and found by
        # Get-CleanupCandidate (Root 3b). $targetUserProfilePath is still required by
        # the gate above (sections register run-as-target-user) but no longer feeds
        # the handoff LOCATION.
        $script:RestoreHandoffRoot  = Resolve-OperatorHandoffRootLocal `
            -BackuperRoot $script:BackuperRoot `
            -OldPcName    $oldPcForHandoff
        $script:RestoreHandoffOldPc = $oldPcForHandoff
        $script:RestoreHandoffEnabled = $true
        $credSubdir        = Resolve-OperatorHandoffSectionDir -HandoffRoot $script:RestoreHandoffRoot -SectionName 'credentials'
        $outlookSubdir     = Resolve-OperatorHandoffSectionDir -HandoffRoot $script:RestoreHandoffRoot -SectionName 'outlook_pop'
        $sysEvidenceSubdir = Resolve-OperatorHandoffSectionDir -HandoffRoot $script:RestoreHandoffRoot -SectionName 'system_evidence'
        $printerSubdir     = Resolve-OperatorHandoffSectionDir -HandoffRoot $script:RestoreHandoffRoot -SectionName 'printer'
        $appSubdir         = Resolve-OperatorHandoffSectionDir -HandoffRoot $script:RestoreHandoffRoot -SectionName 'application'
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
        # v0.61.0 (t-0009 P2): application section -> 05_アプリケーション情報
        if (-not $sectionParams['application']) { $sectionParams['application'] = @{} }
        $sectionParams['application']['OperatorHandoffSubdir'] = $appSubdir
    }

    $userSummary = if ([string]::IsNullOrWhiteSpace($targetUserProfilePath)) {
        "対象ユーザ: (現在のプロセス)"
    } else {
        "対象ユーザ: $targetUserProfilePath"
    }

    # v0.52.0 (C rework): pre-restore free-space check. In local operation the
    # backup data already occupies disk, so the restore adds ~1x (the restored
    # copy) to the TARGET profile drive. Require free - selectedData >= headroom
    # (default 10 GB) else BLOCK (abort). Fail-open when undeterminable (UNC
    # source / unknown drive / size 0) so a broken check never blocks a
    # legitimate restore; the DriveInfo probe targets the user-profile drive,
    # never RestoreExplicitDir (which may be UNC).
    try {
        $aggDirC   = Get-RestoreCurrentAggregateDir
        $needBytes = Get-RestoreSelectionSizeBytes -Picked $picked -AggregateDir $aggDirC
        if ($needBytes -gt 0) {
            $probe = if (-not [string]::IsNullOrWhiteSpace($targetUserProfilePath)) { $targetUserProfilePath } else { $env:USERPROFILE }
            $qual = $null
            if (-not [string]::IsNullOrWhiteSpace($probe)) { $qual = Split-Path -Qualifier $probe -ErrorAction SilentlyContinue }
            if (-not [string]::IsNullOrWhiteSpace($qual)) {
                $free     = ([System.IO.DriveInfo]::new($qual + '\')).AvailableFreeSpace
                $headroom = Get-RestoreFreeSpaceHeadroomBytes
                if (($free - $needBytes) -lt $headroom) {
                    $needGb  = [math]::Round($needBytes / 1GB, 2)
                    $freeGb  = [math]::Round($free / 1GB, 2)
                    $shortGb = [math]::Round(($headroom - ($free - $needBytes)) / 1GB, 2)
                    $headGb  = [math]::Round($headroom / 1GB, 1)
                    [System.Windows.Forms.MessageBox]::Show(
                        ("空き容量不足のためリストアできません (ドライブ $qual)。`n`n" +
                         "リストアデータ: $needGb GB`n空き容量: $freeGb GB`n必要な空き: データ + $headGb GB の余裕`n不足: 約 $shortGb GB`n`n" +
                         "不要なデータの削除、または項目を分割してのリストアで対応してください。"),
                        "Fabriq BackUper - 空き容量不足",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                    return
                }
            }
        }
    } catch { }   # fail-open: never block restore on a check error

    # v0.73.0 (t-0018): auto-start (-SkipConfirm) bypasses this YesNo -- the 60s
    # cancellable countdown already served as the confirmation. All other guards
    # above (free-space etc.) still ran.
    if (-not $SkipConfirm) {
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "リストア元:`n  $sourceLabel`n`nセクション: $(@($picked | ForEach-Object { $_.SectionName }) -join ', ')`nプリンタ: $($selectedPrinters.Count) 件選択`n$userSummary",
            "Fabriq BackUper - 確認",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }

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
(このフォルダは Backuper の Handoff フォルダ配下にあり、「Fabriq 移行情報ビューア」からも開けます。)

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
  Wi-Fi プロファイル / 環境変数 など)。
  → 移行先 PC で各設定を手動再現する際の参照資料としてご利用ください。
  → 採取時の本来のネットワーク設定は _OriginalNetworkConfig.txt をご覧ください
    (LAN 直結移行で一時 IP に変更している場合、06_NetworkConfig.csv は
     一時 IP を記録しています)。
  → インストール済アプリの一覧とアプリ移行チェックは「05_アプリケーション情報」
    に移動しました (古いバックアップではこのフォルダにも 11_*.csv が残る場合があります)。

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

05_アプリケーション情報\
  移行元 PC のインストール済みアプリ一覧 (11_DesktopApps.csv / 11_StoreApps.csv) と
  案件のアプリ移行突合リスト (app_migration_list.csv) 一式。
  → アプリ移行チェック: Check-AppMigration.bat をダブルクリックすると、案件で移行対象と
    しているアプリ (app_migration_list.csv に定義) と移行元 PC の実インストール状況を
    突き合わせて表示します。定義 CSV が未配置の場合は同梱の .sample.csv をコピーして
    編集してから再実行してください。詳細結果は _AppMigrationReport.txt に保存されます。
  → 「Fabriq 移行情報ビューア」の「アプリ移行を突合」からも、同じ突合を画面上で
    確認できます。

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
            if ($sectionParams.ContainsKey('application')) {
                $sectionParams['application'].Remove('OperatorHandoffSubdir') | Out-Null
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

    # v0.53.0 (A): record the status so the Progress view's 完了 button can fire
    # the post-restore auto network revert (only on Success). Partial/Failed ->
    # the operator uses the D6 'return to restore' button instead (no revert).
    $script:RestoreLastStatus = "$($result.Status)"

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
    # v0.53.0 (A): the auto network revert fires when the operator presses the
    # Progress view's 完了 button (see progress_view.ps1) -- not here -- so the
    # migration LAN stays up until the operator explicitly finishes.
}

# v0.53.0 (A) / v0.69.0 (t-0015): post-run auto network revert (auto IP restore).
# Shared, ROLE-AWARE core. Both restore (target) and backup (source) finish their
# migration by reverting THIS PC's network to the pre-lanprep snapshot. The gate /
# confirm popup / Revert-LanMigration invocation are identical; only the expected
# role and the wording ("リストア" vs "バックアップ") differ.
function Invoke-AutoNetworkRevert {
    param(
        [string]$Status,
        [string]$ExpectedRole,    # 'target' (restore) | 'source' (backup)
        [string]$CompletedLabel   # 'リストア' | 'バックアップ'
    )
    # Gate: matching role + local profile (schema 2) + Success + rollback snapshot
    # present + not already reverted + profile allows. Destructive (the migration
    # LAN drops), so it runs only after the run + handoff are done.
    try {
        if ($Status -ne 'Success') { return }
        $prof = $script:MigrationProfile
        if ($null -eq $prof -or "$($prof.schemaVersion)" -ne '2') { return }

        $role = "$env:FABRIQ_BACKUPER_ROLE".Trim().ToLower()
        $hostRole = ''
        if ($null -ne $prof.share) { $hostRole = "$($prof.share.hostRole)".Trim().ToLower() }
        $want = "$ExpectedRole".Trim().ToLower()
        if ($role -ne $want -and $hostRole -ne $want) { return }

        if ($null -ne $prof.rollback) {
            if ($prof.rollback.revertNetwork -eq $false) { return }
            if ($prof.rollback.autoRevert   -eq $false) { return }
        }

        # Snapshot path: main.ps1 resolved <AUTO>; fall back to the derived path.
        $snapPath = ''
        if ($null -ne $prof.rollback -and `
            -not [string]::IsNullOrWhiteSpace("$($prof.rollback.snapshotPath)") -and `
            "$($prof.rollback.snapshotPath)" -ne '<AUTO>') {
            $snapPath = "$($prof.rollback.snapshotPath)"
        } else {
            $snapPath = Join-Path (Join-Path $script:BackuperRoot '_lanprep') '_rollback_snapshot.json'
        }
        if (-not (Test-Path -LiteralPath $snapPath)) { return }     # nothing to revert

        $doneMarker = Join-Path (Split-Path -Parent $snapPath) '_revert_done.json'
        if (Test-Path -LiteralPath $doneMarker) { return }          # idempotent: already reverted

        $repoRoot  = Split-Path -Parent $script:BackuperRoot
        $revertPs1 = Join-Path $repoRoot 'tools\lan_prep\Revert-LanMigration.ps1'
        $profPath  = Join-Path $script:BackuperRoot 'data\migration_profile.json'
        if (-not (Test-Path -LiteralPath $revertPs1)) { return }

        # --- gate passed: notify (GUI, not a batch prompt), then run revert ---
        [System.Windows.Forms.MessageBox]::Show(
            ("$CompletedLabel が完了しました。`n`nこれからネットワーク設定を移行前 (元の IP) に自動で戻します。`n" +
             "完了後、この PC は元の IP に復帰し、移行用 LAN / 共有は切断されます。`n`n[OK] で開始します。"),
            "Fabriq BackUper - ネットワーク自動復元",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null

        $revertArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $revertPs1,
                        '-SnapshotPath', $snapPath, '-ProfilePath', $profPath, '-Force', '-Unattended')
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $revertArgs -Wait -PassThru -WindowStyle Hidden

        if ($null -ne $proc -and $proc.ExitCode -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "ネットワーク設定を元に戻しました (元の IP に復帰)。移行作業は完了です。",
                "Fabriq BackUper - ネットワーク復元完了",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        } else {
            $code = if ($null -ne $proc) { "$($proc.ExitCode)" } else { '?' }
            [System.Windows.Forms.MessageBox]::Show(
                ("ネットワークの自動復元に失敗しました (exit $code)。`n`n" +
                 "管理者権限の PowerShell で tools\lan_prep\Revert-LanMigration.ps1 を実行するか、" +
                 "LAN-Prep メニューの Revert で手動復元してください。`n`n※ $CompletedLabel 自体は完了しています。"),
                "Fabriq BackUper - ネットワーク復元失敗",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        }
    } catch {
        # Never let an auto-revert error disrupt the already-completed run.
        try {
            [System.Windows.Forms.MessageBox]::Show(
                ("ネットワーク自動復元の起動に失敗しました: $($_.Exception.Message)`n`n" +
                 "手動で Revert してください。$CompletedLabel は完了しています。"),
                "Fabriq BackUper",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        } catch {}
    }
}

# v0.53.0 (A): post-restore auto network revert (target role).
function Invoke-RestoreAutoRevert {
    param([string]$Status)
    Invoke-AutoNetworkRevert -Status $Status -ExpectedRole 'target' -CompletedLabel 'リストア'
}

# v0.69.0 (t-0015): post-backup auto network revert (source role). Same flow as
# restore -- after backup Success the data is already on the target's share and the
# target restores from its LOCAL copy, so the source no longer needs the migration
# LAN and can revert its IP. Fires from the Progress 完了 button (ReturnView='Backup').
function Invoke-BackupAutoRevert {
    param([string]$Status)
    Invoke-AutoNetworkRevert -Status $Status -ExpectedRole 'source' -CompletedLabel 'バックアップ'
}
