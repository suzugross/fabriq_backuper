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
# v0.60.0 (t-0009 P1): app-migration compare modal state
$script:HvAppGrid       = $null
$script:HvAppInfoLabel  = $null
$script:HvAppShowExtra  = $null
$script:HvAppCmp        = $null
$script:HvAppFolder     = $null
$script:HvAppSrcCount   = 0

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

    # v0.60.0 (t-0009 P1): app-migration cross-check (旧PC × 突合リスト) — in-app GUI,
    # enabled when this handoff has the source app inventory CSV (05_ or legacy 03_).
    $appData = Get-HvAppData -HandoffFolder $folder
    $appEnabled = ($null -ne $appData.Desktop -or $null -ne $appData.Store)
    Add-HvActionButton -Panel $p -Text "アプリ移行を突合" -Y $y -Enabled $appEnabled `
        -BgColor $script:bgAccent -Tag @{ Action='appcompare'; Value=$folder } ; $y += 42

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
        'bat'        { Invoke-HvRunBat  -BatPath $Tag.Value }
        'batview'    { Invoke-HvRunBat  -BatPath $Tag.Value -NoConfirm }
        'textview'   { Show-HvTextViewer -Path $Tag.Value -Title $Tag.Title }
        'appcompare' { Show-AppCompareModal -HandoffFolder $Tag.Value }
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

function global:Get-HvAppData {
    # Resolve the app-compare inputs for a handoff folder. Dual-location: prefer the
    # new 05_アプリケーション情報 section, else the legacy system_evidence (03_移行元PC情報)
    # location -- so it works before AND after the t-0009 section move. The 突合リスト is
    # taken from the handoff copy first, else the repo data\ list, else the sample.
    param([Parameter(Mandatory = $true)][string]$HandoffFolder)
    $appDir = Join-Path $HandoffFolder '05_アプリケーション情報'
    $sysDir = Resolve-OperatorHandoffSectionDir -HandoffRoot $HandoffFolder -SectionName 'system_evidence'
    $bases = @()
    foreach ($b in @($appDir, $sysDir)) { if (-not [string]::IsNullOrWhiteSpace($b)) { $bases += $b } }
    $desktop = $null; $store = $null; $list = $null
    foreach ($b in $bases) {
        if ($null -eq $desktop) { $c = Join-Path $b '11_DesktopApps.csv'; if (Test-Path -LiteralPath $c) { $desktop = $c } }
        if ($null -eq $store)   { $c = Join-Path $b '11_StoreApps.csv';   if (Test-Path -LiteralPath $c) { $store   = $c } }
        if ($null -eq $list)    { $c = Join-Path $b 'app_migration_list.csv'; if (Test-Path -LiteralPath $c) { $list = $c } }
    }
    if ($null -eq $list) {
        $repoList   = Join-Path $script:BackuperRoot 'data\app_migration_list.csv'
        $repoSample = Join-Path $script:BackuperRoot 'data\app_migration_list.sample.csv'
        if (Test-Path -LiteralPath $repoList) { $list = $repoList }
        elseif (Test-Path -LiteralPath $repoSample) { $list = $repoSample }
    }
    return @{ Desktop = $desktop; Store = $store; List = $list }
}

function global:Get-HvStateColor {
    param([string]$State)
    switch ("$State") {
        '要移行' { return [System.Drawing.Color]::FromArgb(255, 249, 196) }  # light yellow
        '移行済' { return [System.Drawing.Color]::FromArgb(200, 230, 201) }  # light green (P3)
        '不要'   { return [System.Drawing.Color]::FromArgb(255, 224, 224) }  # light red (P3)
        default  { return [System.Drawing.Color]::FromArgb(238, 238, 238) }  # gray (未検出 / 対象外)
    }
}

function global:Show-AppCompareModal {
    # In-app app-migration cross-check GUI (t-0009 P1, 2-way: 旧PC × 突合リスト).
    # Reads the source-PC app CSVs from the selected handoff folder + the project
    # 突合リスト, runs the shared Compare-AppMigrationList, and shows a color-coded grid.
    param([Parameter(Mandatory = $true)][string]$HandoffFolder)
    $data = Get-HvAppData -HandoffFolder $HandoffFolder
    if ($null -eq $data.Desktop -and $null -eq $data.Store) {
        Show-HvWarn "このフォルダに移行元アプリ情報 (11_DesktopApps.csv / 11_StoreApps.csv) が見つかりません。"; return
    }
    if ([string]::IsNullOrWhiteSpace($data.List)) {
        Show-HvWarn "突合リスト (app_migration_list.csv) が見つかりません。`n案件用リストを backuper\data\ または集約フォルダに配置してください。"; return
    }
    $script:HvAppFolder = $HandoffFolder

    $dlg = New-Object System.Windows.Forms.Form
    Set-FormStyle -Form $dlg -Title "Fabriq 移行情報ビューア - アプリ移行突合" -Width 900 -Height 640
    $dlg.KeyPreview = $true

    $script:HvAppInfoLabel = New-StyledLabel -Text "" -X 12 -Y 12 -Width 640 -Height 18 -FgColor $script:fgDim
    $dlg.Controls.Add($script:HvAppInfoLabel)

    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Text = "リスト外アプリも表示"
    $chk.Location = New-Object System.Drawing.Point(660, 10)
    $chk.Size = New-Object System.Drawing.Size(214, 22)
    $chk.BackColor = $script:bgForm
    $chk.ForeColor = $script:fgHeader
    $chk.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $chk.Add_CheckedChanged({ Update-HvAppCompareGrid })
    $script:HvAppShowExtra = $chk
    $dlg.Controls.Add($chk)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(12, 38)
    $grid.Size = New-Object System.Drawing.Size(860, 508)
    Set-GridStyle -Grid $grid
    $grid.AllowUserToAddRows = $false
    $grid.RowHeadersVisible = $false
    $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::None
    $grid.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom `
        -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $defs = @(
        @{ N = 'name';   H = 'アプリ名';        W = 210 },
        @{ N = 'req';    H = '要否';            W = 56  },
        @{ N = 'cat';    H = '分類';            W = 100 },
        @{ N = 'old';    H = '旧PC';            W = 52  },
        @{ N = 'state';  H = '状態';            W = 84  },
        @{ N = 'detail'; H = '検出 / パターン'; W = 226 },
        @{ N = 'note';   H = '備考';            W = 120 }
    )
    foreach ($d in $defs) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.Name = $d.N; $col.HeaderText = $d.H; $col.Width = $d.W; $col.ReadOnly = $true
        $grid.Columns.Add($col) | Out-Null
    }
    $script:HvAppGrid = $grid
    $dlg.Controls.Add($grid)

    $btnRefresh = New-StyledButton -Text "更新" -X 12 -Y 556 -Width 100 -Height 32
    $btnRefresh.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    $btnRefresh.Add_Click({ Invoke-HvAppCompareRefresh })
    $dlg.Controls.Add($btnRefresh)

    $btnExport = New-StyledButton -Text "CSV エクスポート" -X 120 -Y 556 -Width 150 -Height 32
    $btnExport.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    $btnExport.Add_Click({ Export-HvAppCompareCsv })
    $dlg.Controls.Add($btnExport)

    $btnClose = New-StyledButton -Text "閉じる" -X 762 -Y 556 -Width 110 -Height 32 -BgColor $script:bgAccent
    $btnClose.ForeColor = $script:fgWhite
    $btnClose.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $btnClose.Add_Click({ $dlg.Close() })
    $dlg.Controls.Add($btnClose)

    $dlg.Add_KeyDown({ if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $dlg.Close() } })
    $dlg.Add_Shown({ $dlg.Activate(); Invoke-HvAppCompareRefresh })
    [void]$dlg.ShowDialog()
    $dlg.Dispose()
    $script:HvAppGrid = $null
}

function global:Invoke-HvAppCompareRefresh {
    # Re-read the CSVs + 突合リスト for the current folder, recompute, re-render.
    if ([string]::IsNullOrWhiteSpace($script:HvAppFolder)) { return }
    $data = Get-HvAppData -HandoffFolder $script:HvAppFolder
    $listRows = @(Import-AppMigrationList -Path $data.List)
    if ($listRows.Count -eq 0) {
        Show-HvWarn "突合リストが空、または読み込めませんでした: $($data.List)"
        $script:HvAppCmp = @{ Entries = @(); Unmatched = @(); Skipped = @() }
        $script:HvAppSrcCount = 0
    }
    else {
        $srcApps = @(Get-AppMigrationSourceApp -DesktopCsvPath $data.Desktop -StoreCsvPath $data.Store)
        $script:HvAppCmp = Compare-AppMigrationList -ListRows $listRows -SourceApps $srcApps
        $script:HvAppSrcCount = $srcApps.Count
    }
    Update-HvAppCompareGrid
}

function global:Update-HvAppCompareGrid {
    $grid = $script:HvAppGrid
    if ($null -eq $grid) { return }
    $cmp = $script:HvAppCmp
    $grid.Rows.Clear()
    if ($null -eq $cmp) { return }
    $need = 0; $nf = 0
    foreach ($e in @($cmp.Entries)) {
        $old   = if ($e.Matched) { '○' } else { '-' }
        $state = if ($e.Matched) { '要移行' } else { '未検出' }
        if ($e.Matched) { $need++ } else { $nf++ }
        $detail = if ($e.Matched) { (@($e.Hits | ForEach-Object { "$($_.Name)" }) -join ', ') } else { "パターン: $($e.MatchPatterns)" }
        $req = if ($e.IsRequired) { '必須' } else { '任意' }
        $idx = $grid.Rows.Add($e.Name, $req, $e.Category, $old, $state, $detail, $e.Note)
        $grid.Rows[$idx].DefaultCellStyle.BackColor = Get-HvStateColor -State $state
    }
    $extra = 0
    if ($null -ne $script:HvAppShowExtra -and $script:HvAppShowExtra.Checked) {
        foreach ($a in @($cmp.Unmatched)) {
            $extra++
            $idx = $grid.Rows.Add("$($a.Name)", '', "$($a.Source)", '○', '対象外', "v$($a.Version)", '')
            $grid.Rows[$idx].DefaultCellStyle.BackColor = Get-HvStateColor -State '対象外'
        }
    }
    if ($null -ne $script:HvAppInfoLabel) {
        $skip = if ($null -ne $cmp.Skipped) { @($cmp.Skipped).Count } else { 0 }
        $skipTxt  = if ($skip)  { " / 設定不備 $skip" } else { '' }
        $extraTxt = if ($extra) { " / リスト外 $extra" } else { '' }
        $script:HvAppInfoLabel.Text = ("突合リスト {0} 件 / 移行元アプリ {1} 件  ―  要移行 {2} / 未検出 {3}{4}{5}" -f @($cmp.Entries).Count, $script:HvAppSrcCount, $need, $nf, $skipTxt, $extraTxt)
    }
}

function global:Export-HvAppCompareCsv {
    $cmp = $script:HvAppCmp
    if ($null -eq $cmp -or @($cmp.Entries).Count -eq 0) { Show-HvWarn "エクスポートする突合結果がありません。"; return }
    if ([string]::IsNullOrWhiteSpace($script:HvAppFolder)) { return }
    $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $out = Join-Path $script:HvAppFolder ("_AppCompareReport_{0}.csv" -f $stamp)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($e in @($cmp.Entries)) {
        $rows.Add([PSCustomObject]@{
            アプリ名 = $e.Name
            要否     = if ($e.IsRequired) { '必須' } else { '任意' }
            分類     = $e.Category
            旧PC     = if ($e.Matched) { '○' } else { '-' }
            状態     = if ($e.Matched) { '要移行' } else { '未検出' }
            検出     = if ($e.Matched) { (@($e.Hits | ForEach-Object { "$($_.Name)" }) -join '; ') } else { '' }
            パターン = $e.MatchPatterns
            備考     = $e.Note
        })
    }
    try {
        $rows | Export-Csv -LiteralPath $out -NoTypeInformation -Encoding UTF8
        [System.Windows.Forms.MessageBox]::Show("エクスポートしました:`n$out", "Fabriq 移行情報ビューア",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
    catch { Show-HvWarn "エクスポートに失敗しました: $($_.Exception.Message)" }
}
