# ============================================================
# Fabriq App Migration Check (source PC, pre-backup)  v0.74.0
#
# A standalone, disposable operator utility that runs ON THE SOURCE PC
# BEFORE a backup. It cross-checks the project's app_migration_list.csv
# against this PC's LIVE installed-app registry and shows, at a glance,
# which listed apps must be migrated.
#
# It reuses the SAME cross-check engine as the post-restore handoff tool
# (common.ps1: Import-AppMigrationList / Get-LiveInstalledApp /
# Compare-AppMigrationList), so the pre-backup view and the post-restore
# handoff view agree by construction.
#
# No fabriq main / hostlist / passphrase needed: this only reads the local
# registry (HKLM + the current user's HKCU) and the repo's CSV. Run it as
# the user being migrated (non-elevated) so per-user "Just me" installs are
# included.
#
# Entry: fabriq_appcheck.bat (ExecutionPolicy Bypass) -> this script.
# CLAUDE.md rule 5: this file carries Japanese UI strings, so UTF-8 with BOM.
# CLAUDE.md rule 6: console/English, WinForms UI/Japanese.
# ============================================================

param([switch]$VerboseScan)

# ------------------------------------------------------------
# Bootstrap
# ------------------------------------------------------------
$script:RepoRoot    = $PSScriptRoot
$script:BackuperLib = Join-Path $script:RepoRoot 'backuper'
$script:VerboseScan = [bool]$VerboseScan   # -VerboseScan: emit scan counts to the console

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Dot-source the single source of truth (common = engine + Show-*; theme = UI).
try {
    . (Join-Path $script:BackuperLib 'common.ps1')
    . (Join-Path $script:BackuperLib 'lib\ui\theme.ps1')
}
catch {
    [System.Windows.Forms.MessageBox]::Show(
        "ライブラリの読み込みに失敗しました:`n$($_.Exception.Message)",
        "アプリ移行チェック", [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    return
}

# VERSION (shared with the backuper at the repo root).
$script:AppCheckVersion = '0.0.0'
$_verFile = Join-Path $script:RepoRoot 'VERSION'
if (Test-Path -LiteralPath $_verFile) { $script:AppCheckVersion = (Get-Content -LiteralPath $_verFile -Raw).Trim() }

# ------------------------------------------------------------
# Resolve the migration list (real list preferred, sample fallback).
# ------------------------------------------------------------
function Get-AppCheckListPath {
    $real   = Join-Path $script:BackuperLib 'data\app_migration_list.csv'
    $sample = Join-Path $script:BackuperLib 'data\app_migration_list.sample.csv'
    if (Test-Path -LiteralPath $real)   { return [PSCustomObject]@{ Path = $real;   IsSample = $false } }
    if (Test-Path -LiteralPath $sample) { return [PSCustomObject]@{ Path = $sample; IsSample = $true } }
    return [PSCustomObject]@{ Path = $null; IsSample = $false }
}

# ------------------------------------------------------------
# Run the cross-check: list rows x this PC's live apps.
# Returns a hashtable: @{ Cmp; ListPath; IsSample; ListCount; LiveCount }.
# ------------------------------------------------------------
function Invoke-AppCheckScan {
    $listInfo = Get-AppCheckListPath
    $listRows = @()
    if ($null -ne $listInfo.Path) { $listRows = @(Import-AppMigrationList -Path $listInfo.Path) }
    $liveApps = @(Get-LiveInstalledApp)
    $cmp = Compare-AppMigrationList -ListRows $listRows -SourceApps $liveApps
    if ($script:VerboseScan) {
        Show-Info "appcheck: list=$($listRows.Count) live=$($liveApps.Count) entries=$(@($cmp.Entries).Count) unmatched=$(@($cmp.Unmatched).Count)"
    }
    return @{
        Cmp       = $cmp
        ListPath  = $listInfo.Path
        IsSample  = $listInfo.IsSample
        ListCount = $listRows.Count
        LiveCount = $liveApps.Count
    }
}

# ------------------------------------------------------------
# Flatten the compare result into display rows.
# Classification (source-PC semantics):
#   要移行 : listed app IS installed here (Entry.Matched) -> must be migrated
#   未検出 : listed app is NOT installed here (informational)
#   参考   : installed app NOT on the list (Unmatched)
# Each row: Kind / Required / Name / Found / Category / Note.
# ------------------------------------------------------------
function ConvertTo-AppCheckRows {
    param([Parameter(Mandatory = $true)]$Scan)
    $rows = New-Object System.Collections.Generic.List[object]
    $cmp = $Scan.Cmp

    # 要移行 (present), required first, then optional. Sort by name within group.
    $entries = @($cmp.Entries)
    $migReq = @($entries | Where-Object { $_.Matched -and $_.IsRequired } | Sort-Object Name)
    $migOpt = @($entries | Where-Object { $_.Matched -and -not $_.IsRequired } | Sort-Object Name)
    foreach ($e in @($migReq + $migOpt)) {
        $found = ''
        $h = @($e.Hits)
        if ($h.Count -gt 0) {
            $first = $h[0]
            $ver = "$($first.Version)".Trim()
            $found = if ([string]::IsNullOrWhiteSpace($ver)) { "$($first.Name)" } else { "$($first.Name) ($ver)" }
            if ($h.Count -gt 1) { $found = "$found  他 $($h.Count - 1) 件" }
        }
        $rows.Add([PSCustomObject]@{
            Kind = '要移行'; Required = $e.IsRequired; Name = $e.Name
            Found = $found; Category = $e.Category; Note = $e.Note
        })
    }

    # 未検出 (listed but not installed here).
    foreach ($e in @($entries | Where-Object { -not $_.Matched } | Sort-Object Name)) {
        $rows.Add([PSCustomObject]@{
            Kind = '未検出'; Required = $e.IsRequired; Name = $e.Name
            Found = '(このPCに見当たりません)'; Category = $e.Category; Note = $e.Note
        })
    }

    # 参考 (installed but not on the list).
    foreach ($a in @($cmp.Unmatched | Sort-Object Name)) {
        $ver = "$($a.Version)".Trim()
        $nm  = "$($a.Name)".Trim()
        $disp = if ([string]::IsNullOrWhiteSpace($ver)) { $nm } else { "$nm ($ver)" }
        $rows.Add([PSCustomObject]@{
            Kind = '参考'; Required = $false; Name = $disp
            Found = "$($a.Source)"; Category = ''; Note = ''
        })
    }
    return @($rows.ToArray())
}

# ------------------------------------------------------------
# Populate the grid + summary from a scan.
# ------------------------------------------------------------
function Update-AppCheckGrid {
    param(
        [Parameter(Mandatory = $true)]$Grid,
        [Parameter(Mandatory = $true)]$SummaryLabel,
        [Parameter(Mandatory = $true)]$Scan
    )
    $Grid.Rows.Clear()
    $rows = @(ConvertTo-AppCheckRows -Scan $Scan)

    $migReqCount = @($rows | Where-Object { $_.Kind -eq '要移行' -and $_.Required }).Count
    $migOptCount = @($rows | Where-Object { $_.Kind -eq '要移行' -and -not $_.Required }).Count
    $missCount   = @($rows | Where-Object { $_.Kind -eq '未検出' }).Count
    $refCount    = @($rows | Where-Object { $_.Kind -eq '参考' }).Count

    foreach ($r in $rows) {
        $reqMark = if ($r.Required) { '●' } else { '' }
        $idx = $Grid.Rows.Add($r.Kind, $reqMark, $r.Name, $r.Found, $r.Category, $r.Note)
        $row = $Grid.Rows[$idx]
        switch ($r.Kind) {
            '要移行' {
                if ($r.Required) {
                    $row.DefaultCellStyle.Font = $script:fontBold
                    $row.Cells[1].Style.ForeColor = $script:bgDelete   # red ● = 必須
                }
            }
            '未検出' { $row.DefaultCellStyle.ForeColor = $script:fgDim }
            '参考'   { $row.DefaultCellStyle.ForeColor = $script:fgDim }
        }
    }

    $listName = if ($null -eq $Scan.ListPath) { '(リスト未配置)' } else { Split-Path -Leaf $Scan.ListPath }
    $sampleNote = if ($Scan.IsSample) { '  ※サンプルリストで実行中（本リスト未配置）' } else { '' }
    $SummaryLabel.Text = "要移行 $($migReqCount + $migOptCount) 件（必須 $migReqCount / 任意 $migOptCount）  ｜  未検出 $missCount  ｜  リスト外 $refCount  ｜  使用リスト: $listName$sampleNote"
}

# ------------------------------------------------------------
# Export the current rows to a CSV via SaveFileDialog.
# ------------------------------------------------------------
function Export-AppCheckCsv {
    param([Parameter(Mandatory = $true)]$Scan)
    $rows = @(ConvertTo-AppCheckRows -Scan $Scan)
    $out = foreach ($r in $rows) {
        [PSCustomObject]@{
            区分   = $r.Kind
            必須   = $(if ($r.Required) { '1' } else { '' })
            アプリ名 = $r.Name
            検出   = $r.Found
            分類   = $r.Category
            備考   = $r.Note
        }
    }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'CSV (*.csv)|*.csv'
    $dlg.Title  = 'アプリ移行チェック結果の保存'
    $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $dlg.FileName = "app_migration_check_$($env:COMPUTERNAME)_$stamp.csv"
    try { $dlg.InitialDirectory = [Environment]::GetFolderPath('Desktop') } catch {}
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    try {
        $out | Export-Csv -LiteralPath $dlg.FileName -NoTypeInformation -Encoding UTF8
        [System.Windows.Forms.MessageBox]::Show(
            "保存しました:`n$($dlg.FileName)", "アプリ移行チェック",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "保存に失敗しました:`n$($_.Exception.Message)", "アプリ移行チェック",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
}

# ------------------------------------------------------------
# Build + show the form.
# ------------------------------------------------------------
function Show-AppCheckForm {
    $form = New-Object System.Windows.Forms.Form
    Set-FormStyle -Form $form -Title "Fabriq アプリ移行チェック（移行元PC）  v$($script:AppCheckVersion)" -Width 920 -Height 660

    # Header bar.
    $header = New-StyledPanel -X 0 -Y 0 -Width 904 -Height 44 -BgColor $script:bgPanel
    $title = New-StyledLabel -Text "移行すべきアプリ確認（バックアップ前）" -X 16 -Y 10 -Width 560 -Height 24 `
        -FgColor $script:fgWhite -Font $script:fontLarge
    $header.Controls.Add($title)
    $form.Controls.Add($header)

    # Summary line.
    $summary = New-StyledLabel -Text "" -X 16 -Y 54 -Width 880 -Height 20 -FgColor $script:fgHeader -Font $script:fontBold
    $form.Controls.Add($summary)

    # Grid.
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(16, 82)
    $grid.Size = New-Object System.Drawing.Size(880, 470)
    Set-GridStyle -Grid $grid
    $grid.AutoSizeColumnsMode = 'None'
    [void]$grid.Columns.Add('Kind', '区分')
    [void]$grid.Columns.Add('Req', '必須')
    [void]$grid.Columns.Add('Name', 'アプリ名（リスト/実体）')
    [void]$grid.Columns.Add('Found', '検出された実体')
    [void]$grid.Columns.Add('Cat', '分類')
    [void]$grid.Columns.Add('Note', '備考')
    $grid.Columns['Kind'].Width = 64
    $grid.Columns['Req'].Width = 44
    $grid.Columns['Req'].DefaultCellStyle.Alignment = 'MiddleCenter'
    $grid.Columns['Name'].Width = 230
    $grid.Columns['Found'].Width = 250
    $grid.Columns['Cat'].Width = 96
    $grid.Columns['Note'].Width = 168
    $form.Controls.Add($grid)

    # Elevation note.
    $note = New-StyledLabel `
        -Text "対象: 現在のユーザ（$($env:USERNAME)）のインストール済みアプリ（HKLM＋HKCU）。移行対象ユーザ本人で実行してください。" `
        -X 16 -Y 558 -Width 700 -Height 18 -FgColor $script:fgDim
    $form.Controls.Add($note)

    # Buttons.
    $btnRescan = New-StyledButton -Text "再スキャン" -X 16 -Y 582 -Width 120 -Height 32
    $btnCsv    = New-StyledButton -Text "CSV出力" -X 144 -Y 582 -Width 120 -Height 32
    $btnClose  = New-StyledButton -Text "閉じる" -X 776 -Y 582 -Width 120 -Height 32 -BgColor $script:bgAccent
    $form.Controls.Add($btnRescan)
    $form.Controls.Add($btnCsv)
    $form.Controls.Add($btnClose)

    # State + handlers.
    $script:AppCheckScan = $null
    $doScan = {
        $busy = Show-BusyOverlay -Message 'アプリを確認中...' -Owner $form
        try { $script:AppCheckScan = Invoke-AppCheckScan }
        finally { Close-BusyOverlay -Handle $busy }
        Update-AppCheckGrid -Grid $grid -SummaryLabel $summary -Scan $script:AppCheckScan
    }
    $btnRescan.Add_Click({ & $doScan })
    $btnCsv.Add_Click({
        if ($null -ne $script:AppCheckScan) { Export-AppCheckCsv -Scan $script:AppCheckScan }
    })
    $btnClose.Add_Click({ $form.Close() })

    $form.Add_Shown({
        $form.Activate()
        & $doScan
    })

    [void]$form.ShowDialog()
    $form.Dispose()
}

# ------------------------------------------------------------
# Main.
# ------------------------------------------------------------
Write-Host ""
Show-Separator
Write-Host "  Fabriq App Migration Check (source PC)  v$($script:AppCheckVersion)" -ForegroundColor Cyan
Write-Host "  Cross-checks app_migration_list.csv against this PC's live registry" -ForegroundColor DarkGray
Show-Separator
Write-Host ""

try {
    Show-AppCheckForm
}
catch {
    Write-Host "[FATAL] $($_.Exception.Message)" -ForegroundColor Red
    [System.Windows.Forms.MessageBox]::Show(
        "予期しないエラー:`n$($_.Exception.Message)", "アプリ移行チェック",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
}
