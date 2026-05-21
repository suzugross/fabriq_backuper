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

function New-RestoreView {
    $panel = New-Object System.Windows.Forms.Panel
    $panel.BackColor = $script:bgForm

    # Phase 3C: same "close MainForm" semantics as backup_view.
    $btnBack = New-StyledButton -Text "< Back" -X 16 -Y 10 -Width 80 -Height 28
    $btnBack.Add_Click({ $script:MainForm.Close() })
    $panel.Controls.Add($btnBack)

    $title = New-StyledLabel -Text "Restore" -X 110 -Y 12 -Width 200 -Height 24 -Font $script:fontLarge
    $panel.Controls.Add($title)

    # ---- Source row ---------------------------------------
    $tsLbl = New-StyledLabel -Text "Backup Timestamp (hostlist-driven) or Browse for arbitrary backup folder" `
        -X 24 -Y 44 -Width 540 -Height 18 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($tsLbl)

    $combo = New-StyledComboBox -X 24 -Y 66 -Width 460 -Height 24
    $combo.Add_SelectedIndexChanged({
        $script:RestoreExplicitDir = $null
        if ($null -ne $script:RestoreBrowseLabel) { $script:RestoreBrowseLabel.Text = "" }
        Update-RestoreSelection
    })
    $script:RestoreTimestampCombo = $combo
    $panel.Controls.Add($combo)

    $btnBrowse = New-StyledButton -Text "Browse for backup..." -X 494 -Y 64 -Width 170 -Height 28
    $btnBrowse.Add_Click({ Invoke-RestoreBrowse })
    $panel.Controls.Add($btnBrowse)

    $btnUncConnect = New-StyledButton -Text "Connect UNC..." -X 670 -Y 64 -Width 130 -Height 28 -BgColor $script:bgAccent
    $btnUncConnect.Add_Click({
        $unc = Show-UncConnectDialog
        if (-not [string]::IsNullOrWhiteSpace($unc)) {
            [System.Windows.Forms.MessageBox]::Show(
                "Connected to:`n$unc`n`nNow click [Browse for backup...] and navigate to the actual backup folder under this share.",
                "UNC Connected",
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
    $sectionLbl = New-StyledLabel -Text "Sections" `
        -X 24 -Y 150 -Width 240 -Height 18 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($sectionLbl)
    $script:RestoreSectionContainer = New-Object System.Windows.Forms.Panel
    $script:RestoreSectionContainer.Location = New-Object System.Drawing.Point(24, 172)
    $script:RestoreSectionContainer.Size = New-Object System.Drawing.Size(880, 26)
    $script:RestoreSectionContainer.BackColor = [System.Drawing.Color]::Transparent
    $panel.Controls.Add($script:RestoreSectionContainer)

    # ---- Target user row ----------------------------------
    $userLbl = New-StyledLabel -Text "Target user (resolves %USERPROFILE% etc. on restore):" `
        -X 24 -Y 206 -Width 360 -Height 18 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($userLbl)
    $userCombo = New-StyledComboBox -X 386 -Y 202 -Width 260 -Height 24
    $script:RestoreUserCombo = $userCombo
    $panel.Controls.Add($userCombo)

    # ---- Printer list row ---------------------------------
    $pLbl = New-StyledLabel -Text "Printers in this backup (uncheck to exclude)" `
        -X 24 -Y 238 -Width 540 -Height 18 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($pLbl)

    $btnSelAll = New-StyledButton -Text "Select All" -X 620 -Y 234 -Width 96 -Height 24
    $btnSelAll.Add_Click({ Set-AllRestorePrinterChecks $true })
    $panel.Controls.Add($btnSelAll)
    $btnNone = New-StyledButton -Text "None" -X 722 -Y 234 -Width 80 -Height 24
    $btnNone.Add_Click({ Set-AllRestorePrinterChecks $false })
    $panel.Controls.Add($btnNone)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(24, 264)
    $grid.Size = New-Object System.Drawing.Size(880, 350)
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
    $colPort.HeaderText = "Port"; $colPort.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    $colPort.Name = "Port"; $colPort.ReadOnly = $true
    [void]$grid.Columns.Add($colPort)
    $panel.Controls.Add($grid)
    $script:RestorePrinterGrid = $grid

    # ---- Start button -------------------------------------
    $btnStart = New-StyledButton -Text "Start Restore" -X 700 -Y 624 -Width 204 -Height 44 -BgColor $script:bgAdd
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
        [System.Windows.Forms.MessageBox]::Show("No host selected.", "Fabriq BackUper",
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
    else { $script:RestoreManifestLabel.Text = "(no local backups found for $($script:CurrentHost.OldPCname); use Browse for backup if your backup is elsewhere)" }

    $cont = $script:RestoreSectionContainer
    $cont.Controls.Clear()
    $script:RestoreSectionChecks = @{}
    $x = 0
    foreach ($s in $script:SectionList) {
        $cb = New-StyledCheckBox -Text $s.DisplayName -X $x -Y 4 -Width 300 -Height 22 -Checked ($s.Enabled -eq "1")
        $cb.Tag = $s.SectionName
        $cont.Controls.Add($cb)
        $script:RestoreSectionChecks[$s.SectionName] = $cb
        $x += 320
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
    $dlg.Description = "Select backup folder (must contain manifest.json). For UNC use [Connect UNC...] first to authenticate."
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $chosen = $dlg.SelectedPath

    if (-not (Resolve-UncAccess -Path $chosen)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Cannot reach folder: $chosen`n`nIf this is a UNC share, click [Connect UNC...] first.",
            "Fabriq BackUper", [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }

    $mfPath = Join-Path $chosen 'manifest.json'
    if (-not (Test-Path $mfPath)) {
        [System.Windows.Forms.MessageBox]::Show(
            "manifest.json not found in:`n$chosen",
            "Fabriq BackUper", [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    $agg = $null
    try { $agg = Get-Content -Path $mfPath -Raw | ConvertFrom-Json }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to parse manifest.json: $($_.Exception.Message)",
            "Fabriq BackUper", [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }
    if ($agg.manifestType -ne 'fabriq-backuper-snapshot') {
        [System.Windows.Forms.MessageBox]::Show(
            "Unexpected manifestType: $($agg.manifestType)",
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
        $script:RestoreManifestLabel.Text = "(manifest.json not found in $ts)"
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

function Invoke-RestoreStart {
    $useExplicit = -not [string]::IsNullOrWhiteSpace($script:RestoreExplicitDir)
    if (-not $useExplicit) {
        if ($null -eq $script:CurrentHost) { return }
        if ($null -eq $script:RestoreTimestampCombo -or $script:RestoreTimestampCombo.SelectedIndex -lt 0) {
            [System.Windows.Forms.MessageBox]::Show("Select a backup timestamp or use [Browse for backup...].", "Fabriq BackUper",
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
        [System.Windows.Forms.MessageBox]::Show("No sections selected.", "Fabriq BackUper",
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
    $sectionParams = @{
        printer  = @{ IncludePrinters = $selectedPrinters }
        userdata = @{ TargetUserProfilePath = $targetUserProfilePath }
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

    $userSummary = if ([string]::IsNullOrWhiteSpace($targetUserProfilePath)) {
        "Target user: (current process)"
    } else {
        "Target user: $targetUserProfilePath"
    }
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Restore from:`n  $sourceLabel`n`nSections: $(@($picked | ForEach-Object { $_.SectionName }) -join ', ')`nPrinters: $($selectedPrinters.Count) selected`n$userSummary",
        "Fabriq BackUper - Confirm",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    Switch-View 'Progress'
    Initialize-ProgressView -Title "Restore in progress..."
    Add-ProgressLog "Restoring from: $sourceLabel"
    Add-ProgressLog $userSummary
    if ($selectedPrinters.Count -gt 0) {
        Add-ProgressLog "Selected printers: $($selectedPrinters -join ', ')"
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
    Add-ProgressLog "Restore complete: $($result.Status)"
    Add-ProgressLog "$($result.Message)"
    foreach ($key in $result.SectionResults.Keys) {
        $r = $result.SectionResults[$key]
        Add-ProgressLog ("  [{0,-10}] {1,-8} ({2} ms)" -f $key, $r.Status, $r.ElapsedMs)
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
    Add-ProgressLog "Run summary:"
    Add-ProgressLog ("  Elapsed : {0}" -f $elapsedStr)
    if (($aggSuccess + $aggSkip + $aggFail) -gt 0) {
        Add-ProgressLog ("  Entries : {0} success / {1} skip / {2} fail" -f $aggSuccess, $aggSkip, $aggFail)
    }

    Set-ProgressFinished

    # Phase 2.7.5: completion popup (same pattern as Backup).
    $popupLines = @(
        "Restore $($result.Status)"
        ""
        "Elapsed : $elapsedStr"
    )
    if (($aggSuccess + $aggSkip + $aggFail) -gt 0) {
        $popupLines += "Entries : $aggSuccess success / $aggSkip skip / $aggFail fail"
    }
    if (-not [string]::IsNullOrWhiteSpace($result.AggregateDir)) {
        $popupLines += ""
        $popupLines += "Restored from:"
        $popupLines += $result.AggregateDir
    }
    Show-CompletionPopup `
        -Title  "Fabriq BackUper - Restore complete ($($result.Status))" `
        -Body   ($popupLines -join "`n") `
        -Status $result.Status
}
