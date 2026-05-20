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

function New-BackupView {
    $panel = New-Object System.Windows.Forms.Panel
    $panel.BackColor = $script:bgForm

    # ---- Top row: Back + title ----------------------------
    $btnBack = New-StyledButton -Text "< Back" -X 16 -Y 10 -Width 80 -Height 28
    $btnBack.Add_Click({ Switch-View 'ModeSelect' })
    $panel.Controls.Add($btnBack)

    $title = New-StyledLabel -Text "Backup" -X 110 -Y 12 -Width 200 -Height 24 -Font $script:fontLarge
    $panel.Controls.Add($title)

    # ---- Destination row ----------------------------------
    $destLbl = New-StyledLabel -Text "Destination root (local path or UNC):" `
        -X 24 -Y 44 -Width 320 -Height 18 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($destLbl)

    $destBox = New-Object System.Windows.Forms.TextBox
    $destBox.Location = New-Object System.Drawing.Point(24, 66)
    $destBox.Size = New-Object System.Drawing.Size(620, 24)
    Set-TextBoxStyle -TextBox $destBox
    $destBox.Text = (Join-Path $script:BackuperRoot 'Backup')
    $panel.Controls.Add($destBox)
    $script:BackupDestinationBox = $destBox

    $btnDestBrowse = New-StyledButton -Text "Browse..." -X 654 -Y 64 -Width 100 -Height 28
    $btnDestBrowse.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "Select backup destination root (local folder)"
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

    $btnUncConnect = New-StyledButton -Text "Connect UNC..." -X 762 -Y 64 -Width 130 -Height 28 -BgColor $script:bgAccent
    $btnUncConnect.Add_Click({
        $initial = if ($script:BackupDestinationBox.Text -like '\\*') { $script:BackupDestinationBox.Text } else { '' }
        $unc = Show-UncConnectDialog -InitialPath $initial
        if (-not [string]::IsNullOrWhiteSpace($unc)) {
            $script:BackupDestinationBox.Text = $unc
        }
    })
    $panel.Controls.Add($btnUncConnect)

    # ---- Sections row -------------------------------------
    $sectionGroupLbl = New-StyledLabel -Text "Sections" `
        -X 24 -Y 100 -Width 200 -Height 18 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($sectionGroupLbl)
    $script:BackupSectionContainer = New-Object System.Windows.Forms.Panel
    $script:BackupSectionContainer.Location = New-Object System.Drawing.Point(24, 122)
    $script:BackupSectionContainer.Size = New-Object System.Drawing.Size(880, 26)
    $script:BackupSectionContainer.BackColor = [System.Drawing.Color]::Transparent
    $panel.Controls.Add($script:BackupSectionContainer)

    # ---- Printer list row ---------------------------------
    $pLbl = New-StyledLabel -Text "Printers on this PC (uncheck to exclude)" `
        -X 24 -Y 156 -Width 540 -Height 18 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($pLbl)

    $btnSelectAll = New-StyledButton -Text "Select All" -X 620 -Y 152 -Width 96 -Height 24
    $btnSelectAll.Add_Click({ Set-AllPrinterChecks $true })
    $panel.Controls.Add($btnSelectAll)

    $btnNone = New-StyledButton -Text "None" -X 722 -Y 152 -Width 80 -Height 24
    $btnNone.Add_Click({ Set-AllPrinterChecks $false })
    $panel.Controls.Add($btnNone)

    $btnRefresh = New-StyledButton -Text "Refresh" -X 808 -Y 152 -Width 96 -Height 24
    $btnRefresh.Add_Click({ Update-BackupPrinterGrid })
    $panel.Controls.Add($btnRefresh)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(24, 182)
    $grid.Size = New-Object System.Drawing.Size(880, 140)
    Set-GridStyle -Grid $grid
    $grid.ReadOnly = $false

    $colCk = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colCk.HeaderText = ""; $colCk.Width = 36; $colCk.Name = "Check"
    [void]$grid.Columns.Add($colCk)

    $colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colName.HeaderText = "Printer Name"; $colName.Width = 320; $colName.Name = "Name"; $colName.ReadOnly = $true
    [void]$grid.Columns.Add($colName)

    $colDriver = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colDriver.HeaderText = "Driver"; $colDriver.Width = 280; $colDriver.Name = "Driver"; $colDriver.ReadOnly = $true
    [void]$grid.Columns.Add($colDriver)

    $colPort = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colPort.HeaderText = "Port"
    $colPort.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    $colPort.Name = "Port"; $colPort.ReadOnly = $true
    [void]$grid.Columns.Add($colPort)

    $panel.Controls.Add($grid)
    $script:BackupPrinterGrid = $grid

    # ---- User Data row: title + source user combo ---------
    $entryLbl = New-StyledLabel -Text "User Data (toggle = per-session, Add/Edit/Delete/Save persist)" `
        -X 24 -Y 336 -Width 540 -Height 18 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($entryLbl)

    $userLbl = New-StyledLabel -Text "Source user:" `
        -X 568 -Y 336 -Width 80 -Height 18 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($userLbl)
    $userCombo = New-StyledComboBox -X 650 -Y 332 -Width 254 -Height 24
    $script:BackupUserCombo = $userCombo
    $panel.Controls.Add($userCombo)

    # ---- User Data row: editor buttons --------------------
    $btnEntryAdd = New-StyledButton -Text "Add" -X 24 -Y 362 -Width 80 -Height 26 -BgColor $script:bgAdd
    $btnEntryAdd.ForeColor = $script:fgWhite
    $btnEntryAdd.Add_Click({ Invoke-EntryAdd })
    $panel.Controls.Add($btnEntryAdd)

    $btnEntryEdit = New-StyledButton -Text "Edit" -X 108 -Y 362 -Width 80 -Height 26
    $btnEntryEdit.Add_Click({ Invoke-EntryEdit })
    $panel.Controls.Add($btnEntryEdit)

    $btnEntryDel = New-StyledButton -Text "Delete" -X 192 -Y 362 -Width 80 -Height 26 -BgColor $script:bgDelete
    $btnEntryDel.ForeColor = $script:fgWhite
    $btnEntryDel.Add_Click({ Invoke-EntryDelete })
    $panel.Controls.Add($btnEntryDel)

    # Phase 2.7.7: row reorder. Up/Down swap the selected row with its
    # neighbor and persist to CSV immediately (same .bak rotation as
    # Add/Edit/Delete). The new order propagates to future backups'
    # manifest.items.entries[] which determines restore execution order.
    $btnEntryUp = New-StyledButton -Text "Up" -X 280 -Y 362 -Width 50 -Height 26
    $btnEntryUp.Add_Click({ Invoke-EntryMoveUp })
    $panel.Controls.Add($btnEntryUp)

    $btnEntryDown = New-StyledButton -Text "Down" -X 336 -Y 362 -Width 50 -Height 26
    $btnEntryDown.Add_Click({ Invoke-EntryMoveDown })
    $panel.Controls.Add($btnEntryDown)

    $btnEntrySave = New-StyledButton -Text "Save changes" -X 400 -Y 362 -Width 124 -Height 26 -BgColor $script:bgAccent
    $btnEntrySave.Font = $script:fontBold
    $btnEntrySave.Add_Click({ Invoke-EntrySaveAll })
    $panel.Controls.Add($btnEntrySave)

    # ---- User Data grid -----------------------------------
    $eGrid = New-Object System.Windows.Forms.DataGridView
    $eGrid.Location = New-Object System.Drawing.Point(24, 396)
    $eGrid.Size = New-Object System.Drawing.Size(880, 218)
    Set-GridStyle -Grid $eGrid
    $eGrid.ReadOnly = $false

    $ec0 = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $ec0.HeaderText = "On"; $ec0.Width = 40; $ec0.Name = "Enabled"
    [void]$eGrid.Columns.Add($ec0)

    $ec2 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $ec2.HeaderText = "Description"; $ec2.Width = 220; $ec2.Name = "Description"; $ec2.ReadOnly = $true
    [void]$eGrid.Columns.Add($ec2)

    $ec3 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $ec3.HeaderText = "SourcePath"; $ec3.Width = 320; $ec3.Name = "SourcePath"; $ec3.ReadOnly = $true
    [void]$eGrid.Columns.Add($ec3)

    $ec4 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $ec4.HeaderText = "Conflict"; $ec4.Width = 80; $ec4.Name = "OnConflict"; $ec4.ReadOnly = $true
    [void]$eGrid.Columns.Add($ec4)

    $ec5 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $ec5.HeaderText = "Exclude"; $ec5.Name = "ExcludePattern"; $ec5.ReadOnly = $true
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

    # ---- Start button -------------------------------------
    $btnStart = New-StyledButton -Text "Start Backup" -X 700 -Y 624 -Width 204 -Height 44 -BgColor $script:bgAccent
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
    foreach ($p in $allPrinters) {
        $isVirtual = Test-BackupViewVirtualPrinter -P $p
        $defaultChecked = -not $isVirtual
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
        [System.Windows.Forms.MessageBox]::Show("Select a row first.", "Edit entry",
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
        [System.Windows.Forms.MessageBox]::Show("Select a row first.", "Delete entry",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    $idx = $grid.CurrentRow.Index
    if ($idx -lt 0 -or $idx -ge $script:BackupEntries.Count) { return }
    $target = $script:BackupEntries[$idx]
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Delete this entry?`n`n$($target.SourcePath)`n($($target.Description))",
        "Delete entry",
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
        "Saved $($script:BackupEntries.Count) entry(ies) to:`n$csvPath`n`nPrevious version preserved as .bak.",
        "Save changes",
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
        [System.Windows.Forms.MessageBox]::Show("Select a row first.", "Reorder entry",
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
    $x = 0
    foreach ($s in $script:SectionList) {
        $cb = New-StyledCheckBox -Text $s.DisplayName -X $x -Y 4 -Width 300 -Height 22 -Checked ($s.Enabled -eq "1")
        $cb.Tag = $s.SectionName
        $cont.Controls.Add($cb)
        $script:BackupSectionChecks[$s.SectionName] = $cb
        $x += 320
    }

    Update-BackupPrinterGrid
    Update-BackupUserComboItems

    # Load CSV into memory + render grid
    $csvPath = Join-Path $script:BackuperRoot 'data\userdata_list.csv'
    $script:BackupEntries = @(Read-UserdataCsv -Path $csvPath)
    Update-BackupEntryGridFromMemory
}

function Invoke-BackupStart {
    if ($null -eq $script:CurrentHost) {
        [System.Windows.Forms.MessageBox]::Show("No host selected.", "Fabriq BackUper",
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
        [System.Windows.Forms.MessageBox]::Show("No sections selected.", "Fabriq BackUper",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
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
        }
        # Phase 2.9.0a: outlook_pop reads HKCU under the selected user too
        outlook_pop = @{
            SourceUserProfilePath = $sourceUserProfilePath
        }
    }

    $destRoot = $script:BackupDestinationBox.Text
    if ([string]::IsNullOrWhiteSpace($destRoot)) {
        $destRoot = Join-Path $script:BackuperRoot 'Backup'
    }
    if (-not (Resolve-UncAccess -Path $destRoot)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Cannot reach destination: $destRoot`n`nUse [Connect UNC...] if credentials are needed.",
            "Fabriq BackUper", [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }

    $printerSummary = if ($selectedPrinters.Count -gt 0) {
        "Printers: $($selectedPrinters.Count) selected"
    } else {
        "Printers: 0 (printer section will be skipped)"
    }
    $userdataSummary = "User data: $($selectedEntries.Count) entry(ies) enabled"
    $userSummary = if ([string]::IsNullOrWhiteSpace($sourceUserProfilePath)) {
        "Source user: (current process)"
    } else {
        "Source user: $sourceUserProfilePath"
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Start backup for $($script:CurrentHost.OldPCname)?`n`nDestination: $destRoot`nSections: $(@($picked | ForEach-Object { $_.SectionName }) -join ', ')`n$printerSummary`n$userdataSummary`n$userSummary",
        "Fabriq BackUper - Confirm",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    Switch-View 'Progress'
    Initialize-ProgressView -Title "Backup in progress..."
    Add-ProgressLog "Starting backup for $($script:CurrentHost.OldPCname)"
    Add-ProgressLog "Destination: $destRoot"
    Add-ProgressLog $userSummary
    if ($selectedPrinters.Count -gt 0) {
        Add-ProgressLog "Selected printers: $($selectedPrinters -join ', ')"
    }
    if ($selectedEntries.Count -gt 0) {
        Add-ProgressLog "Selected user-data entries:"
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
        -DestinationRoot $destRoot

    $overallSw.Stop()

    Add-ProgressLog ""
    Add-ProgressLog "=========================================="
    Add-ProgressLog "Backup complete: $($result.Status)"
    Add-ProgressLog "$($result.Message)"
    foreach ($key in $result.SectionResults.Keys) {
        $r = $result.SectionResults[$key]
        Add-ProgressLog ("  [{0,-10}] {1,-8} ({2} ms)" -f $key, $r.Status, $r.ElapsedMs)
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
    Add-ProgressLog "Run summary:"
    Add-ProgressLog ("  Elapsed   : {0}" -f $elapsedStr)
    Add-ProgressLog ("  Data size : {0}" -f $bytesStr)
    if ($aggFiles -gt 0 -or $aggDirs -gt 0) {
        Add-ProgressLog ("  Files     : {0:N0} files, {1:N0} dirs" -f $aggFiles, $aggDirs)
    }
    if ($aggEntries -gt 0) {
        Add-ProgressLog ("  Entries   : {0}" -f $aggEntries)
    }

    Set-ProgressFinished

    # Phase 2.7.5: completion popup so the operator notices end-of-run
    # without staring at the Progress View. Modal MessageBox + form
    # Activate(); icon reflects Status (Success / Partial / Failed).
    $popupLines = @(
        "Backup $($result.Status)"
        ""
        "Elapsed   : $elapsedStr"
        "Data size : $bytesStr"
    )
    if ($aggFiles -gt 0 -or $aggDirs -gt 0) {
        $popupLines += "Files     : {0:N0} files, {1:N0} dirs" -f $aggFiles, $aggDirs
    }
    if ($aggEntries -gt 0) {
        $popupLines += "Entries   : $aggEntries"
    }
    if (-not [string]::IsNullOrWhiteSpace($result.AggregateDir)) {
        $popupLines += ""
        $popupLines += "Written to:"
        $popupLines += $result.AggregateDir
    }
    Show-CompletionPopup `
        -Title  "Fabriq BackUper - Backup complete ($($result.Status))" `
        -Body   ($popupLines -join "`n") `
        -Status $result.Status
}
