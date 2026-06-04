# ============================================================
# Fabriq BackUper - Show-Credentials.ps1
#
# Simple, dependency-free WinForms grid that lists the credentials that
# existed on the SOURCE PC's Windows Credential Manager, so the operator can
# see at a glance "what was on the old PC" and decide which (externally
# prepared) registration batch to run. Purely informational -- it registers
# nothing and contains NO passwords (the backup never captured them).
#
# Companion to the existing register_credentials.ps1 (the "register all"
# batch). Launched by 資格情報を表示.bat with -ExecutionPolicy Bypass.
#
# Data source (read-only):
#   credentials_list.csv  (same folder as this script, or -CsvPath)
#   columns: Store,Type,Target,UserName,Persist,Comment,LastWritten,BlobSize,RestoreHint
#
# A per-row "推奨アクション" is derived for glanceability:
#   - 証明書系 (DomainCertificate / GenericCertificate) -> スキップ (別途インポート)
#   - RestoreHint=manual (トークン/参照系, BlobSize 0 など)        -> 要確認 (再サインイン推奨)
#   - その他                                                       -> 登録対象
#
# Switches (diagnostics):
#   -CsvPath <path>  override the CSV to read (default: script dir)
#   -Dump            print parsed rows + summary as JSON and exit (no GUI)
#   -SelfTest        build the form headlessly (no ShowDialog) and exit
# ============================================================
[CmdletBinding()]
param(
    [string]$CsvPath,
    [switch]$Dump,
    [switch]$SelfTest,
    [string]$Shot
)

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------
# Resolve + load the CSV.
# ----------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($CsvPath)) {
    $root = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { (Get-Location).Path }
    $CsvPath = Join-Path $root 'credentials_list.csv'
}

function Get-CredAction {
    # Returns @{ Text; Kind }  Kind in register|warn|skip
    param($Type, $Hint)
    if ("$Type" -match '(?i)certificate') { return @{ Text = 'スキップ (証明書・別途インポート)'; Kind = 'skip' } }
    if ("$Hint" -eq 'manual')             { return @{ Text = '要確認 (トークン/参照系・再サインイン推奨)'; Kind = 'warn' } }
    return @{ Text = '登録対象'; Kind = 'register' }
}

$rows = @()
$loadError = $null
if (Test-Path -LiteralPath $CsvPath) {
    try { $rows = @(Import-Csv -LiteralPath $CsvPath -Encoding UTF8) }
    catch { $loadError = $_.Exception.Message }
} else {
    $loadError = "credentials_list.csv が見つかりません: $CsvPath"
}

# normalized records (display + derived action)
$records = New-Object System.Collections.Generic.List[object]
foreach ($r in $rows) {
    $act = Get-CredAction $r.Type $r.RestoreHint
    $records.Add([pscustomobject]@{
        Type     = "$($r.Type)"
        Target   = "$($r.Target)"
        UserName = "$($r.UserName)"
        Persist  = "$($r.Persist)"
        Action   = $act.Text
        Kind     = $act.Kind
    })
}
$cReg  = @($records | Where-Object { $_.Kind -eq 'register' }).Count
$cWarn = @($records | Where-Object { $_.Kind -eq 'warn' }).Count
$cSkip = @($records | Where-Object { $_.Kind -eq 'skip' }).Count

# ----------------------------------------------------------
# Headless dump.
# ----------------------------------------------------------
if ($Dump) {
    $out = [ordered]@{
        csvPath   = $CsvPath
        loadError = $loadError
        total     = $records.Count
        register  = $cReg
        warn      = $cWarn
        skip      = $cSkip
        rows      = $records.ToArray()
    }
    Write-Output ($out | ConvertTo-Json -Depth 5)
    return
}

# ============================================================
# GUI
# ============================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch {}
try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch {}

$Pal = @{
    Bg       = [System.Drawing.Color]::FromArgb(31, 31, 35)
    Banner   = [System.Drawing.Color]::FromArgb(78, 40, 40)
    Fg       = [System.Drawing.Color]::FromArgb(231, 231, 231)
    Dim      = [System.Drawing.Color]::FromArgb(120, 120, 126)
    Warn     = [System.Drawing.Color]::FromArgb(240, 196, 96)
    Header   = [System.Drawing.Color]::FromArgb(45, 45, 50)
    CellBg   = [System.Drawing.Color]::FromArgb(40, 40, 46)
    Sel      = [System.Drawing.Color]::FromArgb(60, 60, 90)
    Rule     = [System.Drawing.Color]::FromArgb(70, 70, 78)
}
function NF { param([single]$Size = 9, [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular)
    try { New-Object System.Drawing.Font('Yu Gothic UI', $Size, $Style) } catch { New-Object System.Drawing.Font('MS UI Gothic', $Size, $Style) } }

function New-CredForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = '旧PCの資格情報一覧 (参照用の疑似画面)'
    $form.ClientSize = New-Object System.Drawing.Size(820, 480)
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = $Pal.Bg
    $form.Font = (NF 9)
    $form.MinimumSize = New-Object System.Drawing.Size(560, 320)

    # banner
    $banner = New-Object System.Windows.Forms.Panel
    $banner.Dock = 'Top'; $banner.Height = 32; $banner.BackColor = $Pal.Banner
    $bl = New-Object System.Windows.Forms.Label
    $bl.AutoSize = $true; $bl.ForeColor = [System.Drawing.Color]::White
    $bl.Location = New-Object System.Drawing.Point(10, 8)
    $bl.Text = '■ 旧PCに登録されていた資格情報の一覧 (参照用・パスワードは含みません)'
    $banner.Controls.Add($bl)

    # summary
    $sum = New-Object System.Windows.Forms.Panel
    $sum.Dock = 'Top'; $sum.Height = 30; $sum.BackColor = $Pal.Bg
    $sl = New-Object System.Windows.Forms.Label
    $sl.AutoSize = $true; $sl.ForeColor = $Pal.Fg
    $sl.Location = New-Object System.Drawing.Point(10, 7)
    $sl.Text = "件数: $($records.Count)   ( 登録対象 $cReg / 要確認 $cWarn / 証明書スキップ $cSkip )"
    $sum.Controls.Add($sl)
    $form.Controls.Add($sum)
    # add the banner LAST among Top-docked controls so it sits at the very top.
    $form.Controls.Add($banner)

    # footer note
    $foot = New-Object System.Windows.Forms.Panel
    $foot.Dock = 'Bottom'; $foot.Height = 30; $foot.BackColor = $Pal.Bg
    $fl = New-Object System.Windows.Forms.Label
    $fl.AutoSize = $true; $fl.ForeColor = $Pal.Dim
    $fl.Location = New-Object System.Drawing.Point(10, 7)
    $fl.Text = '※ どの資格情報が有ったかの確認用です。登録は別途「登録.bat」または用意済みのバッチで行ってください。'
    $foot.Controls.Add($fl)
    $form.Controls.Add($foot)

    # grid
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = 'Fill'
    $grid.BackgroundColor = $Pal.Bg
    $grid.GridColor = $Pal.Rule
    $grid.BorderStyle = 'None'
    $grid.EnableHeadersVisualStyles = $false
    $grid.RowHeadersVisible = $false
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.ReadOnly = $true
    $grid.SelectionMode = 'FullRowSelect'
    $grid.MultiSelect = $false
    $grid.AutoSizeColumnsMode = 'Fill'
    $grid.ColumnHeadersHeightSizeMode = 'DisableResizing'
    $grid.ColumnHeadersDefaultCellStyle.BackColor = $Pal.Header
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = $Pal.Fg
    $grid.ColumnHeadersDefaultCellStyle.Font = (NF 9 ([System.Drawing.FontStyle]::Bold))
    $grid.DefaultCellStyle.BackColor = $Pal.CellBg
    $grid.DefaultCellStyle.ForeColor = $Pal.Fg
    $grid.DefaultCellStyle.SelectionBackColor = $Pal.Sel
    $grid.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
    $grid.RowTemplate.Height = 24

    [void]$grid.Columns.Add('Action', '推奨アクション')
    [void]$grid.Columns.Add('Type',   '種別')
    [void]$grid.Columns.Add('Target', 'ターゲット (URL/サーバ/アプリID)')
    [void]$grid.Columns.Add('User',   'ユーザー名')
    [void]$grid.Columns.Add('Persist','保持')
    $grid.Columns['Action'].FillWeight = 26
    $grid.Columns['Type'].FillWeight   = 16
    $grid.Columns['Target'].FillWeight = 34
    $grid.Columns['User'].FillWeight   = 16
    $grid.Columns['Persist'].FillWeight = 10

    foreach ($rec in $records) {
        $i = $grid.Rows.Add(@($rec.Action, $rec.Type, $rec.Target, $rec.UserName, $rec.Persist))
        $row = $grid.Rows[$i]
        switch ($rec.Kind) {
            'register' { $row.DefaultCellStyle.ForeColor = $Pal.Fg }
            'warn'     { $row.DefaultCellStyle.ForeColor = $Pal.Warn }
            'skip'     { $row.DefaultCellStyle.ForeColor = $Pal.Dim }
        }
    }
    if ($records.Count -eq 0) {
        $sl.Text = if ($loadError) { "読み込みエラー: $loadError" } else { '資格情報の一覧が空です。' }
        $sl.ForeColor = $Pal.Warn
    }
    $form.Controls.Add($grid)
    $grid.BringToFront()
    return $form
}

# ----------------------------------------------------------
# Headless form build / screenshot for verification.
# ----------------------------------------------------------
function Save-Shot {
    param($Form, [string]$Path)
    $Form.StartPosition = 'Manual'
    $Form.Location = New-Object System.Drawing.Point(-3000, -3000)
    $Form.ShowInTaskbar = $false
    $Form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 200
    [System.Windows.Forms.Application]::DoEvents()
    $w = $Form.ClientSize.Width; $h = $Form.ClientSize.Height
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $Form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $w, $h)))
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $Form.Hide()
}

if ($SelfTest) {
    $f = New-CredForm; $f.Dispose()
    Write-Output "SELFTEST OK ($($records.Count) row(s))"
    return
}
if (-not [string]::IsNullOrWhiteSpace($Shot)) {
    $null = New-Item -ItemType Directory -Path $Shot -Force
    $f = New-CredForm
    Save-Shot $f (Join-Path $Shot 'credentials.png')
    $f.Dispose()
    Write-Output "SHOT written to $Shot"
    return
}

$form = New-CredForm
[void]$form.ShowDialog()
$form.Dispose()
