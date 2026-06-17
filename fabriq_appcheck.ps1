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
# Build an index of LAUNCHABLE apps from the Windows "Applications" virtual
# folder (shell:AppsFolder) via Shell COM. Covers Win32 apps that have a
# Start-menu presence AND UWP apps, each with its AppUserModelID (.Path) --
# the SAME launch path Start search / Run uses. Returns @() on any failure
# (launching is best-effort; the check tool must keep working regardless).
# ------------------------------------------------------------
function Get-AppsFolderIndex {
    $index = New-Object System.Collections.Generic.List[object]
    $shell = $null
    try {
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.NameSpace('shell:AppsFolder')
        if ($null -ne $folder) {
            foreach ($item in $folder.Items()) {
                $nm = "$($item.Name)".Trim()
                $id = "$($item.Path)".Trim()
                if (-not [string]::IsNullOrWhiteSpace($nm) -and -not [string]::IsNullOrWhiteSpace($id)) {
                    $index.Add([PSCustomObject]@{ Name = $nm; Aumid = $id })
                }
            }
        }
    }
    catch {
        Show-Warning "appcheck: shell:AppsFolder enumeration failed; launch disabled: $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $shell) {
            try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch {}
        }
    }
    return @($index.ToArray())
}

# ------------------------------------------------------------
# Resolve an installed app's display name to a launchable AppUserModelID via
# the AppsFolder index. Exact (case-insensitive) match wins; otherwise a
# length-guarded substring match (>=4 chars) to avoid mis-launching on tiny
# tokens. Returns '' when there is no confident match -> that row is not
# launchable (no marker shown).
# ------------------------------------------------------------
function Resolve-AppLaunchId {
    param([string]$Name, [Parameter(Mandatory = $true)]$Index)
    $list = @($Index)
    $n = "$Name".Trim().ToLower()
    if ($n.Length -lt 2 -or $list.Count -eq 0) { return '' }
    # 1. exact display-name match.
    foreach ($e in $list) { if ("$($e.Name)".Trim().ToLower() -eq $n) { return "$($e.Aumid)" } }
    # 2. AppsFolder name is contained in the app name; longest entry wins.
    $best = ''; $bestLen = 0
    foreach ($e in $list) {
        $en = "$($e.Name)".Trim().ToLower()
        if ($en.Length -ge 4 -and $n.Contains($en) -and $en.Length -gt $bestLen) { $best = "$($e.Aumid)"; $bestLen = $en.Length }
    }
    if ($best -ne '') { return $best }
    # 3. app name is contained in an AppsFolder name; shortest entry = closest.
    $best2 = ''; $best2Len = [int]::MaxValue
    foreach ($e in $list) {
        $en = "$($e.Name)".Trim().ToLower()
        if ($n.Length -ge 4 -and $en.Contains($n) -and $en.Length -lt $best2Len) { $best2 = "$($e.Aumid)"; $best2Len = $en.Length }
    }
    return $best2
}

# ------------------------------------------------------------
# Run the cross-check: list rows x this PC's live apps.
# Returns a hashtable: @{ Cmp; ListPath; IsSample; ListCount; LiveCount; AppsIndex }.
# ------------------------------------------------------------
function Invoke-AppCheckScan {
    $listInfo = Get-AppCheckListPath
    $listRows = @()
    if ($null -ne $listInfo.Path) { $listRows = @(Import-AppMigrationList -Path $listInfo.Path) }
    $liveApps = @(Get-LiveInstalledApp)
    $cmp = Compare-AppMigrationList -ListRows $listRows -SourceApps $liveApps
    $appsIndex = @(Get-AppsFolderIndex)
    if ($script:VerboseScan) {
        Show-Info "appcheck: list=$($listRows.Count) live=$($liveApps.Count) entries=$(@($cmp.Entries).Count) unmatched=$(@($cmp.Unmatched).Count) appsfolder=$($appsIndex.Count)"
    }
    return @{
        Cmp       = $cmp
        ListPath  = $listInfo.Path
        IsSample  = $listInfo.IsSample
        ListCount = $listRows.Count
        LiveCount = $liveApps.Count
        AppsIndex = $appsIndex
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
    $appsIndex = @($Scan.AppsIndex)

    # 要移行 (present), required first, then optional. Sort by name within group.
    # Launch resolves against the ACTUAL installed app (Hits[0].Name), not the
    # list entry's curated name, for the most reliable AppsFolder match.
    $entries = @($cmp.Entries)
    $migReq = @($entries | Where-Object { $_.Matched -and $_.IsRequired } | Sort-Object Name)
    $migOpt = @($entries | Where-Object { $_.Matched -and -not $_.IsRequired } | Sort-Object Name)
    foreach ($e in @($migReq + $migOpt)) {
        $found = ''
        $launchName = ''
        $h = @($e.Hits)
        if ($h.Count -gt 0) {
            $first = $h[0]
            $launchName = "$($first.Name)".Trim()
            $ver = "$($first.Version)".Trim()
            $found = if ([string]::IsNullOrWhiteSpace($ver)) { "$($first.Name)" } else { "$($first.Name) ($ver)" }
            if ($h.Count -gt 1) { $found = "$found  他 $($h.Count - 1) 件" }
        }
        $aumid = if ([string]::IsNullOrWhiteSpace($launchName)) { '' } else { Resolve-AppLaunchId -Name $launchName -Index $appsIndex }
        $rows.Add([PSCustomObject]@{
            Kind = '要移行'; Required = $e.IsRequired; Name = $e.Name
            Found = $found; Category = $e.Category; Note = $e.Note
            LaunchName = $launchName; Aumid = $aumid
        })
    }

    # 未検出 (listed but not installed here) -- never launchable.
    foreach ($e in @($entries | Where-Object { -not $_.Matched } | Sort-Object Name)) {
        $rows.Add([PSCustomObject]@{
            Kind = '未検出'; Required = $e.IsRequired; Name = $e.Name
            Found = '(このPCに見当たりません)'; Category = $e.Category; Note = $e.Note
            LaunchName = ''; Aumid = ''
        })
    }

    # 参考 (installed but not on the list).
    foreach ($a in @($cmp.Unmatched | Sort-Object Name)) {
        $ver = "$($a.Version)".Trim()
        $nm  = "$($a.Name)".Trim()
        $disp = if ([string]::IsNullOrWhiteSpace($ver)) { $nm } else { "$nm ($ver)" }
        $aumid = if ([string]::IsNullOrWhiteSpace($nm)) { '' } else { Resolve-AppLaunchId -Name $nm -Index $appsIndex }
        $rows.Add([PSCustomObject]@{
            Kind = '参考'; Required = $false; Name = $disp
            Found = "$($a.Source)"; Category = ''; Note = ''
            LaunchName = $nm; Aumid = $aumid
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
        $canLaunch = -not [string]::IsNullOrWhiteSpace($r.Aumid)
        $launchMark = if ($canLaunch) { '▶' } else { '' }
        $idx = $Grid.Rows.Add($launchMark, $r.Kind, $reqMark, $r.Name, $r.Found, $r.Category, $r.Note)
        $row = $Grid.Rows[$idx]
        # Carry the launch target for the double-click handler.
        $row.Tag = [PSCustomObject]@{ Aumid = "$($r.Aumid)"; Name = "$($r.LaunchName)" }
        switch ($r.Kind) {
            '要移行' {
                if ($r.Required) {
                    $row.DefaultCellStyle.Font = $script:fontBold
                    $row.Cells[2].Style.ForeColor = $script:bgDelete   # red ● = 必須
                }
            }
            '未検出' { $row.DefaultCellStyle.ForeColor = $script:fgDim }
            '参考'   { $row.DefaultCellStyle.ForeColor = $script:fgDim }
        }
        # The ▶ stays lavender + bold even on dimmed rows so it reads as actionable.
        if ($canLaunch) {
            $row.Cells[0].Style.ForeColor = $script:bgAccent
            $row.Cells[0].Style.Font = $script:fontBold
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
    $grid.Size = New-Object System.Drawing.Size(880, 448)
    Set-GridStyle -Grid $grid
    $grid.AutoSizeColumnsMode = 'None'
    [void]$grid.Columns.Add('Launch', '起動')
    [void]$grid.Columns.Add('Kind', '区分')
    [void]$grid.Columns.Add('Req', '必須')
    [void]$grid.Columns.Add('Name', 'アプリ名（リスト/実体）')
    [void]$grid.Columns.Add('Found', '検出された実体')
    [void]$grid.Columns.Add('Cat', '分類')
    [void]$grid.Columns.Add('Note', '備考')
    $grid.Columns['Launch'].Width = 44
    $grid.Columns['Launch'].DefaultCellStyle.Alignment = 'MiddleCenter'
    $grid.Columns['Kind'].Width = 60
    $grid.Columns['Req'].Width = 40
    $grid.Columns['Req'].DefaultCellStyle.Alignment = 'MiddleCenter'
    $grid.Columns['Name'].Width = 220
    $grid.Columns['Found'].Width = 234
    $grid.Columns['Cat'].Width = 92
    $grid.Columns['Note'].Width = 160
    $form.Controls.Add($grid)

    # Launch hint + elevation note.
    $hint = New-StyledLabel `
        -Text "▶ の行はダブルクリックで起動できます（移行前に設定値をその場で確認する用）。起動先を特定できない行は ▶ なし。" `
        -X 16 -Y 536 -Width 880 -Height 18 -FgColor $script:bgAccent -Font $script:fontBold
    $form.Controls.Add($hint)
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

    # Double-click a ▶ row to launch the installed app (open it to check its
    # settings before migrating). Non-launchable rows have no Aumid -> no-op.
    $grid.Add_CellDoubleClick({
        param($gridSender, $ev)
        if ($null -eq $ev -or $ev.RowIndex -lt 0) { return }
        $row = $gridSender.Rows[$ev.RowIndex]
        $tag = $row.Tag
        if ($null -eq $tag -or [string]::IsNullOrWhiteSpace($tag.Aumid)) { return }
        try {
            # Quote the whole shell path: Win32 AppsFolder AUMIDs can contain spaces
            # (and '!'/'{}' for UWP); quoting keeps explorer.exe parsing them as one arg.
            Start-Process -FilePath 'explorer.exe' -ArgumentList "`"shell:AppsFolder\$($tag.Aumid)`""
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "起動に失敗しました:`n$($tag.Name)`n$($_.Exception.Message)", "アプリ移行チェック",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        }
    })

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
