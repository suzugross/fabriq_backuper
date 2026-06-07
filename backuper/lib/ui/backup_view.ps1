# ============================================================
# FabriqBackUper - Backup View
# Phase 2.7.1: Compact layout to fit 780-tall form (smaller
#              printer grid, tighter Y positions). Start button
#              now ends at Y=676 within the ~690-px content area.
# Phase 2.7  : Source-user dropdown + editable User Data grid
#              (Add / Edit / Delete / Save). Toggling the per-row
#              checkbox is ephemeral (filters the current run);
#              Save changes writes the Enabled column back to
#              userdata_list.csv (1-gen .bak rotation).
# Form size assumption: 960x780 with 44-px header dock.
# ============================================================

$script:BackupSectionChecks    = @{}
$script:BackupPrinterGrid      = $null
$script:BackupPrinterRows      = @()
$script:BackupEntryGrid        = $null
$script:BackupEntries          = @()   # Live in-memory CSV rows (PSCustomObjects)
$script:BackupSectionContainer = $null
$script:BackupDestinationBox   = $null
$script:BackupUserCombo        = $null
$script:BackupUserList         = @()

$script:VirtualDriverPatterns = @(
    'Microsoft Print To PDF',
    'Microsoft XPS Document Writer',
    'Microsoft Shared Fax Driver',
    'Microsoft OpenXPS Class Driver',
    'OneNote',
    'Remote Desktop Easy Print'
)
$script:VirtualPortPatterns = @(
    'PORTPROMPT:', 'XPSPort:', 'FAX:', 'nul:', 'SHRFAX:'
)

function Test-BackupViewVirtualPrinter {
    param($P)
    foreach ($pat in $script:VirtualDriverPatterns) { if ($P.DriverName -like "*$pat*") { return $true } }
    foreach ($pat in $script:VirtualPortPatterns)   { if ($P.PortName   -like "*$pat*") { return $true } }
    if ($P.PortName -like 'OneNote*') { return $true }
    if ($P.PortName -match '^TS\d+$') { return $true }
    return $false
}

# v0.39.0: A port is "restorable" (and therefore default-checked in the
# backup grid) only if the printer restore pipeline can recreate it
# programmatically: TCP/IP and LPR ports directly, and WSD ports whose
# Location yields an IPv4 (WSD -> TCP/IP 9100 rescue). USB / WSD-without-IP
# / Local / Bonjour / Other cannot be recreated on the target (they end up
# skipped + manual re-add) so they are left UNCHECKED by default. Operators
# can still tick them individually or via 全選択. Get-PortType and
# Get-IPv4FromLocation are the shared classifiers in backuper/common.ps1 --
# the same ones the printer backup section uses -- so the default selection
# matches exactly what restore can handle.
function Test-BackupViewRestorablePort {
    param($Printer, [hashtable]$PortMap)
    if ($null -eq $PortMap) { return $false }
    $port = $PortMap[$Printer.PortName]
    if ($null -eq $port) { return $false }
    switch (Get-PortType -Port $port) {
        'TCPIP' { return $true }
        'LPR'   { return $true }
        'WSD'   { return (-not [string]::IsNullOrWhiteSpace((Get-IPv4FromLocation -Location $Printer.Location))) }
        default { return $false }
    }
}

function New-BackupView {
    $panel = New-Object System.Windows.Forms.Panel
    $panel.BackColor = $script:bgForm

    # ---- Top row: Back + title ----------------------------
    # Phase 3C: "Back" now closes the MainForm (= ends the .exe session).
    # ModeSelectView was removed; to choose a different mode/host, the
    # operator re-launches Fabriq_BackUper.exe and uses the session form.
    $btnBack = New-StyledButton -Text "< 戻る" -X 16 -Y 10 -Width 80 -Height 28
    $btnBack.Add_Click({ $script:MainForm.Close() })
    $panel.Controls.Add($btnBack)

    $title = New-StyledLabel -Text "バックアップ" -X 110 -Y 12 -Width 200 -Height 24 -Font $script:fontLarge
    $panel.Controls.Add($title)

    # ---- Destination row ----------------------------------
    $destLbl = New-StyledLabel -Text "保存先ルート (ローカルパスまたは UNC):" `
        -X 24 -Y 44 -Width 320 -Height 18 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($destLbl)

    $destBox = New-Object System.Windows.Forms.TextBox
    $destBox.Location = New-Object System.Drawing.Point(24, 66)
    $destBox.Size = New-Object System.Drawing.Size(620, 24)
    Set-TextBoxStyle -TextBox $destBox
    # v0.23.0: when a LAN migration profile is loaded, default the backup
    # destination to backupRootUnc; otherwise fall back to the local
    # Backup\ subfolder under BackuperRoot (v0.22.x behaviour).
    if ($null -ne $script:MigrationProfile -and `
        -not [string]::IsNullOrWhiteSpace($script:MigrationProfile.backuper.backupRootUnc)) {
        $destBox.Text = $script:MigrationProfile.backuper.backupRootUnc
    }
    else {
        $destBox.Text = (Join-Path $script:BackuperRoot 'Backup')
    }
    $panel.Controls.Add($destBox)
    $script:BackupDestinationBox = $destBox

    $btnDestBrowse = New-StyledButton -Text "参照..." -X 654 -Y 64 -Width 100 -Height 28
    $btnDestBrowse.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "バックアップ保存先ルートを選択 (ローカルフォルダ)"
        $dlg.ShowNewFolderButton = $true
        if (-not [string]::IsNullOrWhiteSpace($script:BackupDestinationBox.Text) -and `
            (Test-Path $script:BackupDestinationBox.Text)) {
            $dlg.SelectedPath = $script:BackupDestinationBox.Text
        }
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:BackupDestinationBox.Text = $dlg.SelectedPath
        }
    })
    $panel.Controls.Add($btnDestBrowse)

    $btnUncConnect = New-StyledButton -Text "UNC 接続..." -X 762 -Y 64 -Width 130 -Height 28 -BgColor $script:bgAccent
    $btnUncConnect.Add_Click({
        $initial = if ($script:BackupDestinationBox.Text -like '\\*') { $script:BackupDestinationBox.Text } else { '' }
        # v0.23.0: if a migration profile is loaded, forward uncUsername as a
        # preset so the operator only needs to type the password.
        $initialUser = ''
        if ($null -ne $script:MigrationProfile -and `
            -not [string]::IsNullOrWhiteSpace($script:MigrationProfile.backuper.uncUsername)) {
            $initialUser = $script:MigrationProfile.backuper.uncUsername
        }
        $unc = Show-UncConnectDialog -InitialPath $initial -InitialUsername $initialUser
        if (-not [string]::IsNullOrWhiteSpace($unc)) {
            $script:BackupDestinationBox.Text = $unc
        }
    })
    $panel.Controls.Add($btnUncConnect)

    # ---- Sections row -------------------------------------
    $sectionGroupLbl = New-StyledLabel -Text "セクション" `
        -X 24 -Y 100 -Width 200 -Height 18 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($sectionGroupLbl)
    $script:BackupSectionContainer = New-Object System.Windows.Forms.Panel
    $script:BackupSectionContainer.Location = New-Object System.Drawing.Point(24, 122)
    # v0.26.0: Height raised 26 -> 56 for two-row section grid (3 sections per
    # row x 2 rows = 6 slots). Widgets below this container were shifted Y +30.
    $script:BackupSectionContainer.Size = New-Object System.Drawing.Size(880, 56)
    $script:BackupSectionContainer.BackColor = [System.Drawing.Color]::Transparent
    $panel.Controls.Add($script:BackupSectionContainer)

    # ---- Printer list row (Y +30 shifted by v0.26.0 for 2-row sections) ----
    $pLbl = New-StyledLabel -Text "この PC のプリンタ (除外するチェックを外す)" `
        -X 24 -Y 186 -Width 540 -Height 18 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($pLbl)

    $btnSelectAll = New-StyledButton -Text "全選択" -X 620 -Y 182 -Width 96 -Height 24
    $btnSelectAll.Add_Click({ Set-AllPrinterChecks $true })
    $panel.Controls.Add($btnSelectAll)

    $btnNone = New-StyledButton -Text "クリア" -X 722 -Y 182 -Width 80 -Height 24
    $btnNone.Add_Click({ Set-AllPrinterChecks $false })
    $panel.Controls.Add($btnNone)

    $btnRefresh = New-StyledButton -Text "更新" -X 808 -Y 182 -Width 96 -Height 24
    $btnRefresh.Add_Click({ Update-BackupPrinterGrid })
    $panel.Controls.Add($btnRefresh)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(24, 212)
    $grid.Size = New-Object System.Drawing.Size(880, 140)
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
    $colPort.HeaderText = "ポート"
    $colPort.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    $colPort.Name = "Port"; $colPort.ReadOnly = $true
    [void]$grid.Columns.Add($colPort)

    $panel.Controls.Add($grid)
    $script:BackupPrinterGrid = $grid

    # ---- User Data row: title + source user combo (Y +30 by v0.26.0) ----
    $entryLbl = New-StyledLabel -Text "ユーザデータ (チェック切替=今回のみ、追加/編集/削除/保存で永続化)" `
        -X 24 -Y 366 -Width 540 -Height 18 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($entryLbl)

    $userLbl = New-StyledLabel -Text "取得元ユーザ:" `
        -X 568 -Y 366 -Width 80 -Height 18 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($userLbl)
    $userCombo = New-StyledComboBox -X 650 -Y 362 -Width 254 -Height 24
    $script:BackupUserCombo = $userCombo
    $panel.Controls.Add($userCombo)

    # ---- User Data row: editor buttons (Y +30 by v0.26.0) ----
    $btnEntryAdd = New-StyledButton -Text "追加" -X 24 -Y 392 -Width 80 -Height 26 -BgColor $script:bgAdd
    $btnEntryAdd.ForeColor = $script:fgWhite
    $btnEntryAdd.Add_Click({ Invoke-EntryAdd })
    $panel.Controls.Add($btnEntryAdd)

    $btnEntryEdit = New-StyledButton -Text "編集" -X 108 -Y 392 -Width 80 -Height 26
    $btnEntryEdit.Add_Click({ Invoke-EntryEdit })
    $panel.Controls.Add($btnEntryEdit)

    $btnEntryDel = New-StyledButton -Text "削除" -X 192 -Y 392 -Width 80 -Height 26 -BgColor $script:bgDelete
    $btnEntryDel.ForeColor = $script:fgWhite
    $btnEntryDel.Add_Click({ Invoke-EntryDelete })
    $panel.Controls.Add($btnEntryDel)

    # Phase 2.7.7: row reorder. Up/Down swap the selected row with its
    # neighbor and persist to CSV immediately (same .bak rotation as
    # Add/Edit/Delete). The new order propagates to future backups'
    # manifest.items.entries[] which determines restore execution order.
    $btnEntryUp = New-StyledButton -Text "上へ" -X 280 -Y 392 -Width 50 -Height 26
    $btnEntryUp.Add_Click({ Invoke-EntryMoveUp })
    $panel.Controls.Add($btnEntryUp)

    $btnEntryDown = New-StyledButton -Text "下へ" -X 336 -Y 392 -Width 50 -Height 26
    $btnEntryDown.Add_Click({ Invoke-EntryMoveDown })
    $panel.Controls.Add($btnEntryDown)

    $btnEntrySave = New-StyledButton -Text "変更を保存" -X 400 -Y 392 -Width 124 -Height 26 -BgColor $script:bgAccent
    $btnEntrySave.Font = $script:fontBold
    $btnEntrySave.Add_Click({ Invoke-EntrySaveAll })
    $panel.Controls.Add($btnEntrySave)

    # ---- User Data grid (Y +30 by v0.26.0) -----------------------------
    $eGrid = New-Object System.Windows.Forms.DataGridView
    $eGrid.Location = New-Object System.Drawing.Point(24, 426)
    $eGrid.Size = New-Object System.Drawing.Size(880, 218)
    Set-GridStyle -Grid $eGrid
    $eGrid.ReadOnly = $false

    $ec0 = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $ec0.HeaderText = "有効"; $ec0.Width = 40; $ec0.Name = "Enabled"
    [void]$eGrid.Columns.Add($ec0)

    $ec2 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $ec2.HeaderText = "説明"; $ec2.Width = 220; $ec2.Name = "Description"; $ec2.ReadOnly = $true
    [void]$eGrid.Columns.Add($ec2)

    $ec3 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $ec3.HeaderText = "取得元パス"; $ec3.Width = 320; $ec3.Name = "SourcePath"; $ec3.ReadOnly = $true
    [void]$eGrid.Columns.Add($ec3)

    $ec4 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $ec4.HeaderText = "競合時"; $ec4.Width = 80; $ec4.Name = "OnConflict"; $ec4.ReadOnly = $true
    [void]$eGrid.Columns.Add($ec4)

    $ec5 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $ec5.HeaderText = "除外"; $ec5.Name = "ExcludePattern"; $ec5.ReadOnly = $true
    $ec5.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    [void]$eGrid.Columns.Add($ec5)

    # Double-click row to edit (renamed $sender -> $src to avoid the
    # PowerShell automatic variable; the param itself is unused).
    $eGrid.Add_CellDoubleClick({
        param($src, $ev)
        if ($ev.RowIndex -ge 0) { Invoke-EntryEdit }
    })

    $panel.Controls.Add($eGrid)
    $script:BackupEntryGrid = $eGrid

    # ---- Start button (Y +30 by v0.26.0) ----------------
    # v0.56.0 (t-0003): backup redo loop. Within one app session, every backup run
    # for the (fixed) host MERGES into the first run's aggregate dir = one growing
    # backup; relaunching the app starts a fresh session/backup. This label shows
    # the session-continuation state (set by Update-BackupRetryState). The merge is
    # automatic -- no toggle.
    $retryLbl = New-StyledLabel -Text "" -X 24 -Y 660 -Width 668 -Height 18 -FgColor $script:fgDim
    $panel.Controls.Add($retryLbl)
    $script:BackupRetryStatusLabel = $retryLbl

    $btnStart = New-StyledButton -Text "バックアップ開始" -X 700 -Y 654 -Width 204 -Height 44 -BgColor $script:bgAccent
    $btnStart.Font = $script:fontLarge
    $btnStart.Add_Click({ Invoke-BackupStart })
    $panel.Controls.Add($btnStart)

    return $panel
}

function Set-AllPrinterChecks {
    param([bool]$Checked)
    if ($null -eq $script:BackupPrinterGrid) { return }
    foreach ($row in $script:BackupPrinterGrid.Rows) {
        $row.Cells['Check'].Value = $Checked
    }
}

function Update-BackupPrinterGrid {
    if ($null -eq $script:BackupPrinterGrid) { return }
    $grid = $script:BackupPrinterGrid
    $grid.Rows.Clear()
    $script:BackupPrinterRows = @()
    $allPrinters = @()
    try { $allPrinters = @(Get-Printer -ErrorAction Stop) } catch { return }

    # v0.39.0: build a port-name -> port object map once so each printer's
    # port type can be classified (Get-PortType in common.ps1). Default
    # check = not-virtual AND restorable port (TCP/IP / LPR / WSD-with-IP);
    # USB and other non-recreatable ports start unchecked.
    $portMap = @{}
    try { foreach ($pt in @(Get-PrinterPort -ErrorAction Stop)) { $portMap[$pt.Name] = $pt } } catch { }

    foreach ($p in $allPrinters) {
        $isVirtual      = Test-BackupViewVirtualPrinter -P $p
        $isRestorable   = Test-BackupViewRestorablePort -Printer $p -PortMap $portMap
        $defaultChecked = (-not $isVirtual) -and $isRestorable
        $null = $grid.Rows.Add($defaultChecked, $p.Name, $p.DriverName, $p.PortName)
        $script:BackupPrinterRows += $p
    }
}

# ============================================================
# User-data editor: in-memory model
# ============================================================

function Update-BackupUserComboItems {
    $combo = $script:BackupUserCombo
    if ($null -eq $combo) { return }
    $combo.Items.Clear()
    $script:BackupUserList = @(Get-UserProfileList)
    foreach ($u in $script:BackupUserList) { [void]$combo.Items.Add($u.Label) }
    $idx = Get-DefaultProfileIndex -List $script:BackupUserList
    if ($idx -ge 0) { $combo.SelectedIndex = $idx }
}

function Get-SelectedBackupUserProfilePath {
    $combo = $script:BackupUserCombo
    if ($null -eq $combo -or $combo.SelectedIndex -lt 0) { return $null }
    if ($combo.SelectedIndex -ge $script:BackupUserList.Count) { return $null }
    return $script:BackupUserList[$combo.SelectedIndex].ProfilePath
}

function Update-BackupEntryGridFromMemory {
    $grid = $script:BackupEntryGrid
    if ($null -eq $grid) { return }
    $grid.Rows.Clear()
    foreach ($e in $script:BackupEntries) {
        $enabled = ("$($e.Enabled)" -match '^(1|true|yes)$')
        $idx = $grid.Rows.Add($enabled, $e.Description, $e.SourcePath, $e.OnConflict, $e.ExcludePattern)
        $grid.Rows[$idx].Tag = $e
    }
}

function Read-BackupEntryGridIntoMemory {
    # Sync the grid's Enabled checkbox column back into $script:BackupEntries
    # (other columns are read-only in the grid; editing is via the dialog).
    $grid = $script:BackupEntryGrid
    if ($null -eq $grid) { return }
    for ($i = 0; $i -lt $grid.Rows.Count; $i++) {
        $row = $grid.Rows[$i]
        if ($i -ge $script:BackupEntries.Count) { continue }
        $checked = ($row.Cells['Enabled'].Value -eq $true)
        $script:BackupEntries[$i].Enabled = if ($checked) { '1' } else { '0' }
    }
}

function Update-BackupRetryState {
    # v0.56.0 (t-0003): session-consistent backup. Once a backup has run THIS
    # session for the (fixed) host, every subsequent run merges into that backup
    # (engine -RetryIntoAggregateDir, gated in Invoke-BackupStart). This hook shows
    # the continuation status and pre-sets the selection to "keep ONLY the
    # previously failed/partial parts checked" (successful parts unchecked):
    #   - after Partial/Failed: failed sections + failed userdata entries pre-checked (穴埋め);
    #   - after Success: nothing pre-checked, so the operator checks/adds what to include.
    # The userdata SECTION checkbox is intentionally left checked so a newly-added
    # entry can still be captured. No prior run -> normal CSV defaults (untouched).
    $hasPrior = ($null -ne $script:BackupLastResult) -and `
                (-not [string]::IsNullOrWhiteSpace("$($script:BackupLastAggregateDir)")) -and `
                (Test-Path -LiteralPath "$($script:BackupLastAggregateDir)") -and `
                ($null -ne $script:CurrentHost) -and `
                ("$($script:BackupLastHostName)" -eq "$($script:CurrentHost.OldPCname)")

    if ($null -ne $script:BackupRetryStatusLabel) {
        if (-not $hasPrior) {
            $script:BackupRetryStatusLabel.Text = ''
        }
        else {
            $priorStatus = "$($script:BackupLastResult.Status)"
            $failParts = @()
            foreach ($key in $script:BackupLastResult.SectionResults.Keys) {
                $st = "$($script:BackupLastResult.SectionResults[$key].Status)"
                if ($st -eq 'Failed' -or $st -eq 'Partial') { $failParts += ("{0}({1})" -f $key, (Get-LocalizedStatusLabel $st)) }
            }
            $tail = if ($failParts.Count -gt 0) { " — 要再試行: $($failParts -join ', ')（失敗分をチェック済み）" } else { "" }
            $script:BackupRetryStatusLabel.Text =
                ("セッション継続中：このバックアップは {0} に統合されます（前回: {1}）{2}" -f `
                    (Split-Path -Leaf "$($script:BackupLastAggregateDir)"), (Get-LocalizedStatusLabel $priorStatus), $tail)
        }
    }

    if (-not $hasPrior) { return }

    # Keep ONLY previously failed/partial SECTIONS checked. Skip system_evidence
    # (always-on) and userdata (its SECTION stays checked so added/redone entries
    # can be captured; its ENTRIES are pre-selected just below).
    foreach ($name in @($script:BackupSectionChecks.Keys)) {
        if ($name -eq 'system_evidence' -or $name -eq 'userdata') { continue }
        $cb = $script:BackupSectionChecks[$name]
        if ($null -eq $cb) { continue }
        $sr = $script:BackupLastResult.SectionResults[$name]
        $st = if ($null -ne $sr) { "$($sr.Status)" } else { '' }
        $cb.Checked = ($st -eq 'Failed' -or $st -eq 'Partial')
    }

    # userdata ENTRIES: check ONLY the previously failed/partial ones (from the
    # last run's section manifest). After a full success this unchecks every entry,
    # so only entries the operator (re-)checks or newly adds are captured.
    $failedSources = @{}
    $udManifest = Join-Path "$($script:BackupLastAggregateDir)" 'sections\userdata\manifest.json'
    if (Test-Path -LiteralPath $udManifest) {
        try {
            $um = (Get-Content -LiteralPath $udManifest -Raw -Encoding UTF8) | ConvertFrom-Json
            foreach ($e in @($um.items.entries)) {
                $est = "$($e.status)"
                if ($est -eq 'Failed' -or $est -eq 'Partial') { $failedSources["$($e.sourcePath)"] = $true }
            }
        } catch { }
    }
    foreach ($e in $script:BackupEntries) {
        $e.Enabled = if ($failedSources.ContainsKey("$($e.SourcePath)")) { '1' } else { '0' }
    }
    Update-BackupEntryGridFromMemory
}

function Invoke-EntryAdd {
    $new = Show-UserdataEditDialog -DefaultUserProfilePath (Get-SelectedBackupUserProfilePath)
    if ($null -eq $new) { return }
    Read-BackupEntryGridIntoMemory
    $script:BackupEntries = @($script:BackupEntries) + @($new)
    $csvPath = Join-Path $script:BackuperRoot 'data\userdata_list.csv'
    Save-UserdataCsv -Path $csvPath -Entries $script:BackupEntries
    Update-BackupEntryGridFromMemory
}

function Invoke-EntryEdit {
    $grid = $script:BackupEntryGrid
    if ($null -eq $grid -or $null -eq $grid.CurrentRow) {
        [System.Windows.Forms.MessageBox]::Show("先に行を選択してください。", "項目の編集",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    $idx = $grid.CurrentRow.Index
    if ($idx -lt 0 -or $idx -ge $script:BackupEntries.Count) { return }
    $existing = $script:BackupEntries[$idx]
    $updated = Show-UserdataEditDialog -Entry $existing -DefaultUserProfilePath (Get-SelectedBackupUserProfilePath)
    if ($null -eq $updated) { return }
    Read-BackupEntryGridIntoMemory
    $script:BackupEntries[$idx] = $updated
    $csvPath = Join-Path $script:BackuperRoot 'data\userdata_list.csv'
    Save-UserdataCsv -Path $csvPath -Entries $script:BackupEntries
    Update-BackupEntryGridFromMemory
}

function Invoke-EntryDelete {
    $grid = $script:BackupEntryGrid
    if ($null -eq $grid -or $null -eq $grid.CurrentRow) {
        [System.Windows.Forms.MessageBox]::Show("先に行を選択してください。", "項目の削除",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    $idx = $grid.CurrentRow.Index
    if ($idx -lt 0 -or $idx -ge $script:BackupEntries.Count) { return }
    $target = $script:BackupEntries[$idx]
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "この項目を削除しますか?`n`n$($target.SourcePath)`n($($target.Description))",
        "項目の削除",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    Read-BackupEntryGridIntoMemory
    $kept = @()
    for ($i = 0; $i -lt $script:BackupEntries.Count; $i++) {
        if ($i -ne $idx) { $kept += $script:BackupEntries[$i] }
    }
    $script:BackupEntries = @($kept)
    $csvPath = Join-Path $script:BackuperRoot 'data\userdata_list.csv'
    Save-UserdataCsv -Path $csvPath -Entries $script:BackupEntries
    Update-BackupEntryGridFromMemory
}

function Invoke-EntrySaveAll {
    Read-BackupEntryGridIntoMemory
    $csvPath = Join-Path $script:BackuperRoot 'data\userdata_list.csv'
    Save-UserdataCsv -Path $csvPath -Entries $script:BackupEntries
    [System.Windows.Forms.MessageBox]::Show(
        "$($script:BackupEntries.Count) 件を保存しました:`n$csvPath`n`n直前のバージョンは .bak として保持されています。",
        "変更を保存",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}

function Move-BackupEntry {
    # Shared helper for Up/Down. Delta = -1 (up) or +1 (down).
    # Reads grid Enabled state back first, swaps the in-memory array,
    # persists to CSV (.bak rotation), re-renders, and restores the
    # selection on the moved row.
    param([Parameter(Mandatory = $true)][int]$Delta)
    $grid = $script:BackupEntryGrid
    if ($null -eq $grid -or $null -eq $grid.CurrentRow) {
        [System.Windows.Forms.MessageBox]::Show("先に行を選択してください。", "項目の並び替え",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    $idx = $grid.CurrentRow.Index
    $newIdx = $idx + $Delta
    if ($newIdx -lt 0 -or $newIdx -ge $script:BackupEntries.Count) { return }
    Read-BackupEntryGridIntoMemory
    $entries = @($script:BackupEntries)
    $tmp = $entries[$newIdx]
    $entries[$newIdx] = $entries[$idx]
    $entries[$idx] = $tmp
    $script:BackupEntries = $entries
    $csvPath = Join-Path $script:BackuperRoot 'data\userdata_list.csv'
    Save-UserdataCsv -Path $csvPath -Entries $script:BackupEntries
    Update-BackupEntryGridFromMemory
    if ($newIdx -lt $grid.Rows.Count) {
        $grid.ClearSelection()
        $grid.Rows[$newIdx].Selected = $true
        $grid.CurrentCell = $grid.Rows[$newIdx].Cells[0]
    }
}

function Invoke-EntryMoveUp   { Move-BackupEntry -Delta -1 }
function Invoke-EntryMoveDown { Move-BackupEntry -Delta  1 }

function Show-BackupView {
    $cont = $script:BackupSectionContainer
    $cont.Controls.Clear()
    $script:BackupSectionChecks = @{}
    # Layout history:
    #   v0.19.0: width 300 + stride 320 -> only 3 sections fit; 4th
    #            (credentials) rendered at X>=960, outside the 880px
    #            container.
    #   v0.19.1: width 200 + stride 215 -> 4 sections fit (max X=845).
    #   v0.22.0: width 168 + stride 178 -> 5 sections fit (max X=880
    #            exactly) so msime_dict joins the row.
    #   v0.26.0: 6th section (system_evidence) added. Single-row width-
    #            compression would crowd "Printer Environment" (19 chars),
    #            so the layout switched to TWO ROWS x 3 columns. The
    #            container Height was raised 26 -> 56 and widgets below
    #            were shifted Y +30 to clear the new row.
    #   Slot math (v0.26.0): width=280 / stride_x=300 / stride_y=30
    #     row 0 (Y=4 ):  printer        / userdata    / outlook_pop
    #     row 1 (Y=34):  credentials    / msime_dict  / system_evidence
    # system_evidence is forced (CheckBox is grey-out + Checked fixed) so
    # operator cannot uncheck it - migration evidence is always captured.
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
        $script:BackupSectionChecks[$s.SectionName] = $cb
        $i++
    }

    Update-BackupPrinterGrid
    Update-BackupUserComboItems

    # Load CSV into memory + render grid
    $csvPath = Join-Path $script:BackuperRoot 'data\userdata_list.csv'
    $script:BackupEntries = @(Read-UserdataCsv -Path $csvPath)
    Update-BackupEntryGridFromMemory

    # v0.56.0 (t-0003): after a Partial/Failed run of this host, surface the
    # status + pre-select only the failed parts and reveal the retry-merge toggle.
    Update-BackupRetryState
}

function Invoke-BackupStart {
    if ($null -eq $script:CurrentHost) {
        [System.Windows.Forms.MessageBox]::Show("ホストが選択されていません。", "Fabriq BackUper",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    $picked = @()
    foreach ($s in $script:SectionList) {
        $cb = $script:BackupSectionChecks[$s.SectionName]
        if ($null -ne $cb -and $cb.Checked) { $picked += $s }
    }
    if ($picked.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("セクションが選択されていません。", "Fabriq BackUper",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    # v0.56.0 (t-0003): retry-merge detection. When the redo-loop toggle is on and
    # a prior Partial/Failed run of THIS host exists, this run re-executes the
    # (failed) selection INTO that run's aggregate dir and merges, producing one
    # complete backup. Build the sourcePath->originalId map from the prior run's
    # userdata manifest so retried entries overwrite their ORIGINAL entry dirs.
    # v0.56.0: session-consistent -- ANY run after the first (same session, same
    # fixed host, prior aggregate dir still present) merges into that first dir. No
    # toggle; relaunching the app starts a fresh session/backup.
    $retryAggDir   = $null
    $retryEntryIds = @{}
    $isBackupRetry = $false
    if (-not [string]::IsNullOrWhiteSpace("$($script:BackupLastAggregateDir)") -and `
        (Test-Path -LiteralPath "$($script:BackupLastAggregateDir)") -and `
        ("$($script:BackupLastHostName)" -eq "$($script:CurrentHost.OldPCname)")) {
        $isBackupRetry = $true
        $retryAggDir   = "$($script:BackupLastAggregateDir)"
        $udManifest    = Join-Path $retryAggDir 'sections\userdata\manifest.json'
        if (Test-Path -LiteralPath $udManifest) {
            try {
                $um = (Get-Content -LiteralPath $udManifest -Raw -Encoding UTF8) | ConvertFrom-Json
                foreach ($e in @($um.items.entries)) {
                    $sp = "$($e.sourcePath)"
                    if (-not [string]::IsNullOrWhiteSpace($sp)) { $retryEntryIds[$sp] = "$($e.id)" }
                }
            } catch { }
        }
    }

    $selectedPrinters = @()
    if ($null -ne $script:BackupPrinterGrid) {
        foreach ($row in $script:BackupPrinterGrid.Rows) {
            if ($row.Cells['Check'].Value -eq $true) {
                $selectedPrinters += [string]$row.Cells['Name'].Value
            }
        }
    }

    # Ephemeral userdata selection: sync grid -> memory, then derive the
    # currently-checked SourcePath list for this run only (CSV file is
    # NOT touched here; persistence is via Save changes / Add / Edit / Delete).
    Read-BackupEntryGridIntoMemory
    $selectedEntries = @($script:BackupEntries |
        Where-Object { "$($_.Enabled)" -match '^(1|true|yes)$' } |
        ForEach-Object { $_.SourcePath })

    $sourceUserProfilePath = Get-SelectedBackupUserProfilePath

    $sectionParams = @{
        printer = @{
            IncludePrinters       = $selectedPrinters
            IncludeDriverBinaries = $true
            IncludePrintSettings  = $true
        }
        userdata = @{
            IncludeEntries        = $selectedEntries
            SourceUserProfilePath = $sourceUserProfilePath
            # v0.56.0 (t-0003): retry-merge -- fold the (failed) entries into the
            # previous run's manifest using their original ids.
            RetryMerge            = $isBackupRetry
            RetryEntryIds         = $retryEntryIds
        }
        # Phase 2.9.0a: outlook_pop reads HKCU under the selected user too
        outlook_pop = @{
            SourceUserProfilePath = $sourceUserProfilePath
        }
        # v0.19.0: credentials section. SourceUserProfilePath is metadata
        # only - actual target user is auto-resolved via Resolve-HkcuRoot
        # (logged-on user when admin context differs from interactive user).
        credentials = @{
            SourceUserProfilePath = $sourceUserProfilePath
        }
        # v0.22.0: msime_dict section. The MSIME user dictionary lives at
        # a fixed path (%APPDATA%\Microsoft\IME\15.0\IMEJP\UserDict\)
        # regardless of OS or IME generation, so SourceUserProfilePath is
        # the only knob needed.
        msime_dict = @{
            SourceUserProfilePath = $sourceUserProfilePath
        }
        # v0.26.0: system_evidence section. Captures PC configuration
        # evidence (§01/06/07/10/11/16/27 from fabriq evidence_config) for
        # operator reference at restore time. MigrationProfile is forwarded
        # so Phase 2's Step 0 can harvest rollback.snapshotPath (records
        # the pre-lanprep IP/Gateway/DNS, since §06 captures the temporary
        # lanprep IP instead).
        system_evidence = @{
            SourceUserProfilePath = $sourceUserProfilePath
            MigrationProfile      = $script:MigrationProfile
        }
    }

    $destRoot = $script:BackupDestinationBox.Text
    if ([string]::IsNullOrWhiteSpace($destRoot)) {
        $destRoot = Join-Path $script:BackuperRoot 'Backup'
    }
    if (-not (Resolve-UncAccess -Path $destRoot)) {
        [System.Windows.Forms.MessageBox]::Show(
            "保存先に接続できません: $destRoot`n`n認証情報が必要な場合は [UNC 接続...] を使用してください。",
            "Fabriq BackUper", [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }

    $printerSummary = if ($selectedPrinters.Count -gt 0) {
        "プリンタ: $($selectedPrinters.Count) 件選択"
    } else {
        "プリンタ: 0 件 (printer セクションはスキップ)"
    }
    $userdataSummary = "ユーザデータ: $($selectedEntries.Count) 件が有効"
    $userSummary = if ([string]::IsNullOrWhiteSpace($sourceUserProfilePath)) {
        "取得元ユーザ: (現在のプロセス)"
    } else {
        "取得元ユーザ: $sourceUserProfilePath"
    }

    $retryNote = if ($isBackupRetry) {
        "【セッション継続】このバックアップは前回のバックアップ ($(Split-Path -Leaf $retryAggDir)) に統合されます。`n`n"
    } else { "" }
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "$retryNote$($script:CurrentHost.OldPCname) のバックアップを開始しますか?`n`n保存先: $destRoot`nセクション: $(@($picked | ForEach-Object { $_.SectionName }) -join ', ')`n$printerSummary`n$userdataSummary`n$userSummary",
        "Fabriq BackUper - 確認",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    # v0.23.0: Outlook running pre-check (only when outlook_pop is selected).
    # PST files and HKCU Outlook profile keys are written / locked by an
    # active OUTLOOK.EXE process, so a backup taken mid-flight risks an
    # inconsistent .reg export and a partial PST capture. The pre-check
    # is scoped to the source user's SID so that an admin-elevated
    # backup running under a different identity does not enumerate (and
    # later kill) the admin's own unrelated Outlook session.
    $outlookCloseSummary = $null
    $outlookPopSelected = @($picked | Where-Object { $_.SectionName -eq 'outlook_pop' }).Count -gt 0
    if ($outlookPopSelected) {
        $runningOutlook = @(Test-OutlookRunningForSource)
        if ($runningOutlook.Count -gt 0) {
            $pidLabel = (@($runningOutlook | ForEach-Object { $_.ProcessId }) -join ', ')
            $outlookConfirm = [System.Windows.Forms.MessageBox]::Show(
                "取得元ユーザのセッションで OUTLOOK.EXE が起動中です (PID: $pidLabel)。`n`n" +
                "Outlook が起動したままバックアップすると、PST ファイルとレジストリ`n" +
                "プロファイルの整合性が崩れる可能性があります。Outlook を閉じてから`n" +
                "バックアップを続行しますか?`n`n" +
                "[はい] Outlook を閉じて続行`n" +
                "       (草稿の保存ダイアログが出たら画面で対応してください。`n" +
                "        5 秒たっても閉じない場合は強制終了します)`n" +
                "[いいえ] バックアップを中止 (手動で閉じてからやり直し)",
                "Fabriq BackUper - Outlook 起動中",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($outlookConfirm -ne [System.Windows.Forms.DialogResult]::Yes) {
                return
            }
            $stopResult = Stop-OutlookForSource
            $outlookCloseSummary = switch ($stopResult.Result) {
                'KilledGraceful' {
                    "Outlook を閉じました (graceful、対象 $($stopResult.AttemptedIds.Count) 件)"
                }
                'KilledForce' {
                    "Outlook を強制終了しました (graceful + force kill、対象 " +
                    "$($stopResult.AttemptedIds.Count) 件 / うち force=" +
                    "$($stopResult.ForceKilledIds.Count) 件)"
                }
                default {
                    "Outlook close result: $($stopResult.Result)"
                }
            }
        }
    }

    Switch-View 'Progress'
    # v0.56.0 (t-0003): pass -ReturnView 'Backup' so the progress view reveals a
    # "バックアップ画面へ戻る" button on finish, enabling the backup redo loop
    # (return -> retry failed parts merged into the same backup). Restore-only
    # auto-revert in the 完了 handler is gated on ReturnView='Restore', so backup
    # just closes on 完了.
    Initialize-ProgressView -Title "バックアップ実行中..." -ReturnView 'Backup'
    Add-ProgressLog "$($script:CurrentHost.OldPCname) のバックアップを開始します"
    Add-ProgressLog "保存先: $destRoot"
    Add-ProgressLog $userSummary
    if (-not [string]::IsNullOrWhiteSpace($outlookCloseSummary)) {
        Add-ProgressLog $outlookCloseSummary
    }
    if ($selectedPrinters.Count -gt 0) {
        Add-ProgressLog "選択プリンタ: $($selectedPrinters -join ', ')"
    }
    if ($selectedEntries.Count -gt 0) {
        Add-ProgressLog "選択されたユーザデータ項目:"
        foreach ($sp in $selectedEntries) { Add-ProgressLog "  - $sp" }
    }
    $script:MainForm.Refresh()

    # Phase 2.7.4: overall wall-clock for the run summary
    $overallSw = [System.Diagnostics.Stopwatch]::StartNew()

    $result = Invoke-BackuperBackupCore `
        -SelectedHost $script:CurrentHost `
        -PickedSections $picked `
        -BackuperRoot $script:BackuperRoot `
        -FabriqRoot $script:FabriqRoot `
        -BackuperVersion $script:BackuperVersion `
        -SectionParamsBySection $sectionParams `
        -DestinationRoot $destRoot `
        -RetryIntoAggregateDir $retryAggDir

    $overallSw.Stop()

    # v0.56.0 (t-0003): retain the run result so the redo loop (return -> retry)
    # can show status, pre-select failures, and merge a retry into THIS dir.
    $script:BackupLastResult       = $result
    $script:BackupLastAggregateDir = $result.AggregateDir
    $script:BackupLastHostName     = "$($script:CurrentHost.OldPCname)"

    Add-ProgressLog ""
    Add-ProgressLog "=========================================="
    Add-ProgressLog "バックアップ完了: $(Get-LocalizedStatusLabel $result.Status)"
    Add-ProgressLog "$($result.Message)"
    foreach ($key in $result.SectionResults.Keys) {
        $r = $result.SectionResults[$key]
        # Per-section status uses the same Get-LocalizedStatusLabel so the
        # overall and per-section labels stay consistent in the UI log.
        Add-ProgressLog ("  [{0,-10}] {1,-8} ({2} ms)" -f $key, (Get-LocalizedStatusLabel $r.Status), $r.ElapsedMs)
        if ($r.InternalSectionDir) {
            Add-ProgressLog "             -> $($r.InternalSectionDir)"
        } elseif ($r.ExternalOutputDir) {
            Add-ProgressLog "             -> $($r.ExternalOutputDir)  (external)"
        }
    }

    # ---- Run summary (Phase 2.7.4) --------------------------
    # Aggregate totalBytes / fileCount / dirCount across sections that
    # report them in Summary. Both printer and userdata expose totalBytes;
    # userdata also exposes fileCount / dirCount / entryCount.
    $aggBytes = 0L
    $aggFiles = 0L
    $aggDirs  = 0L
    $aggEntries = 0L
    foreach ($key in $result.SectionResults.Keys) {
        $s = $result.SectionResults[$key].Summary
        if ($null -eq $s) { continue }
        if ($null -ne $s.totalBytes) { $aggBytes += [long]$s.totalBytes }
        if ($null -ne $s.fileCount)  { $aggFiles += [long]$s.fileCount }
        if ($null -ne $s.dirCount)   { $aggDirs  += [long]$s.dirCount }
        if ($null -ne $s.entryCount) { $aggEntries += [long]$s.entryCount }
    }
    $elapsedStr = Format-Duration -Span $overallSw.Elapsed
    $bytesStr   = Format-Bytes    -Bytes $aggBytes

    Add-ProgressLog ""
    Add-ProgressLog "実行サマリ:"
    Add-ProgressLog ("  経過時間 : {0}" -f $elapsedStr)
    Add-ProgressLog ("  データ量 : {0}" -f $bytesStr)
    if ($aggFiles -gt 0 -or $aggDirs -gt 0) {
        Add-ProgressLog ("  ファイル : {0:N0} 件, ディレクトリ {1:N0} 件" -f $aggFiles, $aggDirs)
    }
    if ($aggEntries -gt 0) {
        Add-ProgressLog ("  項目数   : {0}" -f $aggEntries)
    }

    Set-ProgressFinished

    # Phase 2.7.5: completion popup so the operator notices end-of-run
    # without staring at the Progress View. Modal MessageBox + form
    # Activate(); icon reflects Status (Success / Partial / Failed).
    $popupLines = @(
        "バックアップ $(Get-LocalizedStatusLabel $result.Status)"
        ""
        "経過時間 : $elapsedStr"
        "データ量 : $bytesStr"
    )
    if ($aggFiles -gt 0 -or $aggDirs -gt 0) {
        $popupLines += "ファイル : {0:N0} 件, ディレクトリ {1:N0} 件" -f $aggFiles, $aggDirs
    }
    if ($aggEntries -gt 0) {
        $popupLines += "項目数   : $aggEntries"
    }
    if (-not [string]::IsNullOrWhiteSpace($result.AggregateDir)) {
        $popupLines += ""
        $popupLines += "保存先:"
        $popupLines += $result.AggregateDir
    }
    Show-CompletionPopup `
        -Title  "Fabriq BackUper - バックアップ完了 ($(Get-LocalizedStatusLabel $result.Status))" `
        -Body   ($popupLines -join "`n") `
        -Status $result.Status
}
