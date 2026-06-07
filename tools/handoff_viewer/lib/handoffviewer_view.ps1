# ============================================================
# Fabriq Handoff Viewer - Viewer View (standalone, v0.58.0)
# Browse the operator-handoff (集約) folder for a hostlist-selected host
# and launch the existing per-section info viewers / launcher batches with
# one click.
#
# This file owns ONLY the WinForms surface. Discovery + host attribution
# come from backuper/common.ps1 (Get-CleanupCandidate, Kind='handoff';
# Resolve-OperatorHandoffSectionDir for the fixed 01-04 subdir names), which
# fabriq_handoffviewer.ps1 dot-sources (single source of truth, shared with
# Cleanup + the Backuper restore-side). No private scanner / no subdir-name
# duplication here.
#
# Read-only browser: the existing per-section viewers (Show-Credentials,
# Show-OutlookAccounts) are launched in a separate hidden-console powershell;
# the section launcher batches (登録.bat / Restore-Outlook.bat /
# Install-Printers.bat) are started in their own console and handle their own
# user context / UAC self-elevation. This app stays asInvoker.
# Japanese UI is allowed (CLAUDE.md rule 6); this file is UTF-8 with BOM (rule 5).
# ============================================================

$script:HvGrid          = $null
$script:HvHostCombo     = $null
$script:HvStatusLabel   = $null
$script:HvShortcutPanel = $null
$script:HvSelectedFolder = $null
$script:HvCandidates    = @()

function global:New-HandoffViewerView {
    $panel = New-Object System.Windows.Forms.Panel
    $panel.BackColor = $script:bgForm

    # ---- header row ----
    $btnBack = New-StyledButton -Text "< 戻る" -X 16 -Y 10 -Width 80 -Height 28
    $btnBack.Add_Click({ $script:MainForm.Close() })
    $panel.Controls.Add($btnBack)

    $title = New-StyledLabel -Text "移行情報ビューア" -X 110 -Y 12 -Width 200 -Height 24 -Font $script:fontLarge
    $panel.Controls.Add($title)

    # ---- host selection (standalone: no session form pre-selects the host) ----
    $hostLbl = New-StyledLabel -Text "対象ホスト:" -X 322 -Y 16 -Width 84 -Height 20 -Font $script:fontBold -FgColor $script:fgHeader
    $panel.Controls.Add($hostLbl)

    $hostCombo = New-StyledComboBox -X 408 -Y 12 -Width 538 -Height 24
    foreach ($h in @($script:HostRows)) {
        if ($null -eq $h) { continue }
        $old = "$($h.OldPCname)"
        $new = "$($h.NewPCname)"
        $disp = if (-not [string]::IsNullOrWhiteSpace($new)) { "$old  ->  $new" } else { $old }
        [void]$hostCombo.Items.Add($disp)
    }
    $hostCombo.Add_SelectedIndexChanged({
        $idx = $script:HvHostCombo.SelectedIndex
        if ($idx -ge 0 -and $idx -lt @($script:HostRows).Count) {
            $script:CurrentHost = @($script:HostRows)[$idx]
        } else {
            $script:CurrentHost = $null
        }
        Update-HandoffViewerGrid
    })
    $script:HvHostCombo = $hostCombo
    $panel.Controls.Add($hostCombo)

    $desc = New-StyledLabel `
        -Text "選択ホストの移行情報（集約）フォルダを一覧します。フォルダを選ぶと、右側に各種設定の表示・適用ショートカットが出ます。" `
        -X 24 -Y 44 -Width 920 -Height 18 -FgColor $script:fgDim
    $panel.Controls.Add($desc)

    # ---- handoff-folder grid (left) ----
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(24, 76)
    $grid.Size     = New-Object System.Drawing.Size(600, 540)
    Set-GridStyle -Grid $grid
    $grid.AllowUserToAddRows = $false
    $grid.RowHeadersVisible  = $false
    $grid.MultiSelect        = $false
    $grid.SelectionMode      = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::None

    $defs = @(
        @{ Name='folder'; Header='集約フォルダ'; Width=210 },
        @{ Name='host';   Header='帰属ホスト';   Width=120 },
        @{ Name='date';   Header='作成日時';     Width=140 },
        @{ Name='size';   Header='サイズ';       Width=100 }
    )
    foreach ($d in $defs) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.Name = $d.Name; $col.HeaderText = $d.Header; $col.Width = $d.Width; $col.ReadOnly = $true
        $grid.Columns.Add($col) | Out-Null
    }
    $grid.Add_SelectionChanged({
        $g = $script:HvGrid
        if ($null -eq $g -or $g.SelectedRows.Count -eq 0) {
            $script:HvSelectedFolder = $null
        } else {
            $c = $g.SelectedRows[0].Tag
            $script:HvSelectedFolder = if ($null -ne $c) { "$($c.Path)" } else { $null }
        }
        Update-HandoffViewerShortcuts
    })
    $script:HvGrid = $grid
    $panel.Controls.Add($grid)

    # ---- shortcut panel (right) ----
    $sp = New-Object System.Windows.Forms.Panel
    $sp.Location = New-Object System.Drawing.Point(640, 76)
    $sp.Size     = New-Object System.Drawing.Size(308, 540)
    $sp.BackColor = $script:bgForm
    $sp.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $sp.AutoScroll = $true   # many Outlook accounts -> let the shortcut list scroll
    $script:HvShortcutPanel = $sp
    $panel.Controls.Add($sp)

    # ---- action row ----
    $btnRescan = New-StyledButton -Text "再スキャン" -X 24 -Y 624 -Width 120 -Height 34
    $btnRescan.Add_Click({ Update-HandoffViewerGrid })
    $panel.Controls.Add($btnRescan)

    $status = New-StyledLabel -Text "" -X 160 -Y 632 -Width 480 -Height 20 -FgColor $script:fgDim
    $script:HvStatusLabel = $status
    $panel.Controls.Add($status)

    return $panel
}

function global:Show-HandoffViewerView {
    # on-show hook (called once after the form is built).
    # Auto-select this PC's host row: the viewer normally runs on the NEW/target
    # PC, so match NewPCName first, then OldPCname (Resolve-HostByComputerName
    # with PreferMode 'Restore'). The operator can still change the combo.
    if ($null -ne $script:HvHostCombo -and $script:HvHostCombo.Items.Count -gt 0 -and
        $script:HvHostCombo.SelectedIndex -lt 0 -and
        (Get-Command Resolve-HostByComputerName -ErrorAction SilentlyContinue)) {
        $rows = @($script:HostRows)
        $match = Resolve-HostByComputerName -HostList $rows -ComputerName $env:COMPUTERNAME -PreferMode 'Restore'
        if ($null -ne $match) {
            $idx = [array]::IndexOf($rows, $match)
            if ($idx -ge 0 -and $idx -lt $script:HvHostCombo.Items.Count) {
                Show-Info "Auto-selected host for this PC ('$env:COMPUTERNAME'): $($match.OldPCname) -> $($match.NewPCname)"
                $script:HvHostCombo.SelectedIndex = $idx   # fires SelectedIndexChanged -> Update-HandoffViewerGrid
                return
            }
        }
        Show-Info "No hostlist row matches this PC ('$env:COMPUTERNAME'); select a host manually."
    }
    Update-HandoffViewerGrid
}

function global:Update-HandoffViewerGrid {
    if ($null -eq $script:HvGrid) { return }
    $oldPc = if ($null -ne $script:CurrentHost) { "$($script:CurrentHost.OldPCname)" } else { '' }

    $script:HvGrid.Rows.Clear()
    $script:HvSelectedFolder = $null
    Update-HandoffViewerShortcuts

    if ([string]::IsNullOrWhiteSpace($oldPc)) {
        $script:HvStatusLabel.Text = "上の『対象ホスト』を選択してください。"
        return
    }

    $script:HvStatusLabel.Text = "スキャン中..."
    [System.Windows.Forms.Application]::DoEvents()

    $cands = @()
    try {
        $cands = @(Get-CleanupCandidate -BackuperRoot $script:BackuperRoot `
            -MigrationProfile $script:MigrationProfile -OldPcName $oldPc)
    }
    catch {
        $script:HvStatusLabel.Text = "スキャン失敗: $($_.Exception.Message)"
        return
    }
    # the viewer only cares about handoff (集約) folders, not backup trees / LAN-Prep
    $handoffs = @($cands | Where-Object { "$($_.Kind)" -eq 'handoff' })
    $script:HvCandidates = $handoffs

    foreach ($c in $handoffs) {
        $folderName = Split-Path -Leaf "$($c.Path)"
        $hostLabel  = if ([string]::IsNullOrWhiteSpace($c.AttributedHost)) { '(不明)' } else { "$($c.AttributedHost)" }
        $sizeLabel  = ''
        $b = [long]$c.SizeBytes
        if ($b -ge 1GB)      { $sizeLabel = ('{0:N2} GB' -f ($b / 1GB)) }
        elseif ($b -ge 1MB)  { $sizeLabel = ('{0:N1} MB' -f ($b / 1MB)) }
        elseif ($b -ge 1KB)  { $sizeLabel = ('{0:N0} KB' -f ($b / 1KB)) }
        else                 { $sizeLabel = ("$b B") }

        $rowIdx = $script:HvGrid.Rows.Add($folderName, $hostLabel, "$($c.CreatedAt)", $sizeLabel)
        $script:HvGrid.Rows[$rowIdx].Tag = $c
    }

    if ($script:HvGrid.Rows.Count -eq 0) {
        $script:HvStatusLabel.Text = "ホスト『$oldPc』の移行情報フォルダは見つかりませんでした。"
    }
    else {
        $script:HvGrid.ClearSelection()
        $script:HvStatusLabel.Text = "$($script:HvGrid.Rows.Count) 件。フォルダを選択してください。"
    }
}

function global:Update-HandoffViewerShortcuts {
    # Rebuild the right-hand shortcut panel for the currently selected handoff
    # folder. Each button is enabled only when its target (viewer data / subdir /
    # launcher batch) actually exists, so older handoff layouts gray out cleanly.
    $p = $script:HvShortcutPanel
    if ($null -eq $p) { return }
    $p.Controls.Clear()

    $folder = $script:HvSelectedFolder
    if ([string]::IsNullOrWhiteSpace($folder) -or -not (Test-Path -LiteralPath $folder)) {
        $hint = New-StyledLabel -Text "左の一覧から集約フォルダを選択してください。" `
            -X 12 -Y 16 -Width 268 -Height 40 -FgColor $script:fgDim
        $p.Controls.Add($hint)
        return
    }

    # section subdirs via the shared resolver (fixed 01-04 names live in common.ps1)
    $credDir = Resolve-OperatorHandoffSectionDir -HandoffRoot $folder -SectionName 'credentials'
    $olkDir  = Resolve-OperatorHandoffSectionDir -HandoffRoot $folder -SectionName 'outlook_pop'
    $sysDir  = Resolve-OperatorHandoffSectionDir -HandoffRoot $folder -SectionName 'system_evidence'
    $prnDir  = Resolve-OperatorHandoffSectionDir -HandoffRoot $folder -SectionName 'printer'

    # canonical viewer scripts (use the install copies so the app works even on a
    # handoff folder whose bundled _data lacks the viewer script).
    $credViewer = Join-Path $script:BackuperRoot 'lib\sections\credentials\operator_payload\Show-Credentials.ps1'
    $olkViewer  = Join-Path $script:BackuperRoot 'lib\sections\outlook_pop\assets\Show-OutlookAccounts.ps1'

    # viewer DATA + launcher batches (handoff layout: support files under _data\)
    $credCsv = Find-HvFirstPath @( (Join-Path $credDir '_data\credentials_list.csv'), (Join-Path $credDir 'credentials_list.csv') )
    $olkData = Find-HvFirstPath @( (Join-Path $olkDir '_data'), $olkDir )
    $credBat = Join-Path $credDir '登録.bat'
    $olkBat  = Join-Path $olkDir 'Restore-Outlook.bat'
    $prnBat  = Join-Path $prnDir 'Install-Printers.bat'
    $prnTxt  = Join-Path $prnDir '_printer_settings.txt'

    $y = 8
    $hdr = New-StyledLabel -Text (Split-Path -Leaf $folder) -X 12 -Y $y -Width 268 -Height 20 `
        -Font $script:fontBold -FgColor $script:fgHeader
    $p.Controls.Add($hdr); $y += 30

    $lbl1 = New-StyledLabel -Text "── 情報を表示 ──" -X 12 -Y $y -Width 268 -Height 16 -FgColor $script:fgDim
    $p.Controls.Add($lbl1); $y += 22

    Add-HvActionButton -Panel $p -Text "資格情報を表示" -Y $y -Enabled (-not [string]::IsNullOrWhiteSpace($credCsv)) `
        -Tag @{ Action='viewer'; Script=$credViewer; ArgName='-CsvPath'; ArgValue=$credCsv } ; $y += 36
    # Outlook: one view shortcut per account. The restore section drops one
    # per-account launcher .bat ("<num> <email> の設定を表示.bat") into 02_*, so
    # reflect ALL of them (multiple mailboxes => one shortcut each). Restore-Outlook.bat
    # is the apply action and lives in the .bat section below, not here. Fall back to a
    # single canonical viewer for older handoff layouts that have no per-account .bat.
    $olkViewBats = @()
    if (-not [string]::IsNullOrWhiteSpace($olkDir) -and (Test-Path -LiteralPath $olkDir)) {
        $olkViewBats = @(Get-ChildItem -LiteralPath $olkDir -Filter '*.bat' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '(?i)^Restore-Outlook\.bat$' } | Sort-Object Name)
    }
    if ($olkViewBats.Count -gt 0) {
        $lblO = New-StyledLabel -Text "Outlook 設定（アカウント別）" -X 12 -Y $y -Width 268 -Height 16 -FgColor $script:fgDim
        $p.Controls.Add($lblO); $y += 20
        foreach ($vb in $olkViewBats) {
            Add-HvActionButton -Panel $p -Text $vb.BaseName -Y $y -Enabled $true `
                -Tag @{ Action='batview'; Value="$($vb.FullName)" } ; $y += 36
        }
    }
    else {
        Add-HvActionButton -Panel $p -Text "Outlook 設定を表示" -Y $y -Enabled (-not [string]::IsNullOrWhiteSpace($olkData)) `
            -Tag @{ Action='viewer'; Script=$olkViewer; ArgName='-DataDir'; ArgValue=$olkData } ; $y += 36
    }
    Add-HvActionButton -Panel $p -Text "移行元PC情報フォルダを開く" -Y $y -Enabled ($null -ne $sysDir -and (Test-Path -LiteralPath $sysDir)) `
        -Tag @{ Action='open'; Value=$sysDir } ; $y += 36
    # Printer settings: show the .txt in the IN-APP text viewer (no notepad / no
    # default-app association) so the target PC environment stays untouched.
    # Fall back to opening the folder when the summary .txt is absent.
    if (-not [string]::IsNullOrWhiteSpace($prnTxt) -and (Test-Path -LiteralPath $prnTxt)) {
        Add-HvActionButton -Panel $p -Text "プリンタ設定を表示" -Y $y -Enabled $true `
            -Tag @{ Action='textview'; Value="$prnTxt"; Title='プリンタ設定' } ; $y += 36
    }
    else {
        Add-HvActionButton -Panel $p -Text "プリンタフォルダを開く" -Y $y -Enabled ($null -ne $prnDir -and (Test-Path -LiteralPath $prnDir)) `
            -Tag @{ Action='open'; Value="$prnDir" } ; $y += 36
    }
    $y += 8

    $lbl2 = New-StyledLabel -Text "── 設定を適用 (.bat) ──" -X 12 -Y $y -Width 268 -Height 16 -FgColor $script:fgDim
    $p.Controls.Add($lbl2); $y += 22

    Add-HvActionButton -Panel $p -Text "資格情報を登録 (登録.bat)" -Y $y -Enabled (Test-Path -LiteralPath $credBat) `
        -BgColor $script:bgAccent -Tag @{ Action='bat'; Value=$credBat } ; $y += 36
    Add-HvActionButton -Panel $p -Text "Outlook を自動復元 (Restore-Outlook.bat)" -Y $y -Enabled (Test-Path -LiteralPath $olkBat) `
        -BgColor $script:bgAccent -Tag @{ Action='bat'; Value=$olkBat } ; $y += 36
    Add-HvActionButton -Panel $p -Text "プリンタをインストール (Install-Printers.bat)" -Y $y -Enabled (Test-Path -LiteralPath $prnBat) `
        -BgColor $script:bgAccent -Tag @{ Action='bat'; Value=$prnBat } ; $y += 44

    Add-HvActionButton -Panel $p -Text "集約フォルダを開く" -Y $y -Enabled $true `
        -Tag @{ Action='open'; Value=$folder } ; $y += 36
}

function global:Add-HvActionButton {
    param(
        [Parameter(Mandatory = $true)]$Panel,
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][int]$Y,
        $Tag,
        [bool]$Enabled = $true,
        $BgColor = $null
    )
    if ($null -ne $BgColor) {
        $b = New-StyledButton -Text $Text -X 12 -Y $Y -Width 268 -Height 32 -BgColor $BgColor
        $b.ForeColor = $script:fgWhite
    }
    else {
        $b = New-StyledButton -Text $Text -X 12 -Y $Y -Width 268 -Height 32
    }
    $b.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $b.Tag = $Tag
    $b.Enabled = $Enabled
    $b.Add_Click({ param($s, $e) Invoke-HvDispatch -Tag $s.Tag })
    $Panel.Controls.Add($b)
    return $b
}

function global:Invoke-HvDispatch {
    param($Tag)
    if ($null -eq $Tag) { return }
    switch ("$($Tag.Action)") {
        'viewer'  { Invoke-HvViewer -ScriptPath $Tag.Script -ArgName $Tag.ArgName -ArgValue $Tag.ArgValue }
        'open'    { Invoke-HvOpenPath -Path $Tag.Value }
        'bat'      { Invoke-HvRunBat  -BatPath $Tag.Value }
        'batview'  { Invoke-HvRunBat  -BatPath $Tag.Value -NoConfirm }
        'textview' { Show-HvTextViewer -Path $Tag.Value -Title $Tag.Title }
    }
}

function global:Find-HvFirstPath {
    param([string[]]$Candidates)
    foreach ($c in $Candidates) {
        if (-not [string]::IsNullOrWhiteSpace($c) -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function global:Show-HvWarn {
    param([string]$Text, [string]$Caption = "Fabriq 移行情報ビューア")
    [System.Windows.Forms.MessageBox]::Show($Text, $Caption,
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
}

function global:Invoke-HvViewer {
    param([string]$ScriptPath, [string]$ArgName, [string]$ArgValue)
    if ([string]::IsNullOrWhiteSpace($ScriptPath) -or -not (Test-Path -LiteralPath $ScriptPath)) {
        Show-HvWarn "ビューアスクリプトが見つかりません: $ScriptPath"; return
    }
    if ([string]::IsNullOrWhiteSpace($ArgValue) -or -not (Test-Path -LiteralPath $ArgValue)) {
        Show-HvWarn "表示するデータが見つかりません: $ArgValue"; return
    }
    $a = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$ScriptPath`" $ArgName `"$ArgValue`""
    try { Start-Process -FilePath 'powershell.exe' -ArgumentList $a | Out-Null }
    catch { Show-HvWarn "起動に失敗しました: $($_.Exception.Message)" }
}

function global:Invoke-HvOpenPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        Show-HvWarn "見つかりません: $Path"; return
    }
    try {
        if (Test-Path -LiteralPath $Path -PathType Container) {
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $Path) | Out-Null
        }
        else {
            Start-Process -FilePath $Path | Out-Null
        }
    }
    catch { Show-HvWarn "開けませんでした: $($_.Exception.Message)" }
}

function global:Invoke-HvRunBat {
    # -NoConfirm: read-only view launchers (the per-account "設定を表示.bat") just
    # open a viewer window, so they skip the apply-confirmation dialog. The apply
    # batches (登録 / Restore-Outlook / Install-Printers) confirm before running.
    param([string]$BatPath, [switch]$NoConfirm)
    if ([string]::IsNullOrWhiteSpace($BatPath) -or -not (Test-Path -LiteralPath $BatPath)) {
        Show-HvWarn "バッチが見つかりません: $BatPath"; return
    }
    if (-not $NoConfirm) {
        $name = Split-Path -Leaf $BatPath
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "『$name』を実行します。`n`nこのバッチは移行先ユーザの設定（資格情報 / Outlook / プリンタ）を変更します。`n移行先ユーザでログイン中であることを確認してください。`n`n実行しますか？",
            "Fabriq 移行情報ビューア - 実行確認",
            [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    try { Start-Process -FilePath $BatPath -WorkingDirectory (Split-Path -Parent $BatPath) | Out-Null }
    catch { Show-HvWarn "起動に失敗しました: $($_.Exception.Message)" }
}

function global:Show-HvTextViewer {
    # In-app, read-only viewer for a .txt/.csv reference file. Used instead of
    # Start-Process (which would invoke notepad / the default app and leave traces
    # on the target PC). Monospace, scrollable, selectable (copy OK), no write.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Title = "テキストビューア"
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        Show-HvWarn "ファイルが見つかりません: $Path"; return
    }
    $text = ''
    try { $text = [System.IO.File]::ReadAllText($Path) }   # auto-detects BOM, UTF-8 default
    catch { Show-HvWarn "読み込みに失敗しました: $($_.Exception.Message)"; return }

    $dlg = New-Object System.Windows.Forms.Form
    Set-FormStyle -Form $dlg -Title "Fabriq 移行情報ビューア - $Title" -Width 760 -Height 600
    $dlg.KeyPreview = $true

    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline  = $true
    $box.ReadOnly   = $true
    $box.WordWrap   = $false
    $box.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
    $box.Font       = New-Object System.Drawing.Font('Consolas', 10)
    $box.BackColor  = [System.Drawing.Color]::White
    $box.Location   = New-Object System.Drawing.Point(12, 12)
    $box.Size       = New-Object System.Drawing.Size(720, 500)
    $box.Anchor     = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom `
        -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $box.Text       = $text
    $box.Select(0, 0)
    $dlg.Controls.Add($box)

    $btnClose = New-StyledButton -Text "閉じる" -X 620 -Y 522 -Width 110 -Height 32 -BgColor $script:bgAccent
    $btnClose.ForeColor = $script:fgWhite
    $btnClose.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $btnClose.Add_Click({ $dlg.Close() })
    $dlg.Controls.Add($btnClose)

    $dlg.Add_KeyDown({ if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $dlg.Close() } })
    $dlg.Add_Shown({ $dlg.Activate() })
    [void]$dlg.ShowDialog()
    $dlg.Dispose()
}
