# ============================================================
# Fabriq BackUper - Show-OutlookAccounts.ps1
#
# Standalone, dependency-free WinForms viewer that re-creates the
# Outlook "Add Account (POP and IMAP)" wizard page and its
# "Internet E-mail Settings" sub-dialog (General / Outgoing Server /
# Advanced tabs) as a DARK pseudo-screen, so the operator can re-enter
# the migrated settings on the destination PC at a glance.
#
# Design intent (per operator request):
#   * Visual 1:1 replica of the real Outlook screens, INCLUDING the
#     transitions (the "Advanced (M)..." button opens the tabbed dialog).
#   * Deliberately DARK theme so it is obvious this is a reference mock,
#     not the real Outlook configuration UI.
#   * Fields/controls we have NO captured data for are greyed out so the
#     operator is not misled into thinking they must enter something.
#   * Transition controls that DO require setup (Advanced button, the
#     Outgoing-Server / Advanced tabs) are emphasised (red ring / red tab)
#     so the operator knows where the non-trivial settings live.
#
# Data sources (read-only, at runtime, relative to this script). Two modes,
# auto-detected in this priority order:
#
#   (1) accounts.json (self-authored)  --  a single, simple JSON file holding
#       both settings AND passwords. Use this to view hand-made settings that
#       did not come from a backup. Schema: see accounts.sample.json beside
#       this script. Picked up from -AccountsFile, or accounts.json in the
#       data folder.
#
#   (2) backup handoff (default)  --  _data\manifest.json (structured fields,
#       no passwords) + _account_settings.txt (recovered plaintext passwords,
#       parsed out of the "Password :" / "SMTP Password :" lines).
#
# Writes NOTHING to disk. Passwords live only in memory.
#
# Switches:
#   -DataDir <path>      folder to read from (default: script dir)
#   -AccountsFile <path> explicit self-authored JSON (overrides auto-detect)
#   -Dump                print parsed/normalized accounts as JSON and exit
#   -SelfTest            build the forms headlessly (no ShowDialog) and exit
# ============================================================
[CmdletBinding()]
param(
    [string]$DataDir,
    [string]$AccountsFile,
    [switch]$Dump,
    [switch]$SelfTest,
    [string]$Shot
)

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------
# Resolve the data root + the two input files.
# ----------------------------------------------------------
$root = if (-not [string]::IsNullOrWhiteSpace($DataDir)) { $DataDir } else { $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($root)) { $root = (Get-Location).Path }

$manifestPath = Join-Path $root '_data\manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    $alt = Join-Path $root 'manifest.json'
    if (Test-Path -LiteralPath $alt) { $manifestPath = $alt }
}
$settingsPath = Join-Path $root '_account_settings.txt'

# Self-authored JSON (mode 1): explicit -AccountsFile wins, else accounts.json
# in the data folder (or its _data\ subfolder).
$accountsJsonPath = $null
if (-not [string]::IsNullOrWhiteSpace($AccountsFile)) {
    $accountsJsonPath = $AccountsFile
} else {
    foreach ($cand in @((Join-Path $root 'accounts.json'), (Join-Path $root '_data\accounts.json'))) {
        if (Test-Path -LiteralPath $cand) { $accountsJsonPath = $cand; break }
    }
}

# ----------------------------------------------------------
# Value-formatting helpers (display only; never mutate source).
# ----------------------------------------------------------
function Format-Value {
    param($Value, $Fallback = '')
    if ($null -eq $Value -or "$Value" -eq '') { return $Fallback }
    return "$Value"
}

function Format-SecureConnection {
    param($Value)
    if ($null -eq $Value) { return $null }
    switch ([int]$Value) {
        0       { 'なし' }
        1       { 'SSL/TLS' }
        2       { 'STARTTLS' }
        3       { '自動' }
        default { "値=$Value" }
    }
}

function Format-IncomingEncryption {
    param($UseSsl, $SecureConnection)
    if ($UseSsl -eq 1) { return 'SSL/TLS' }
    elseif ($UseSsl -eq 0) { return 'なし' }
    else {
        $m = Format-SecureConnection $SecureConnection
        if ($m) { return $m } else { return 'なし' }
    }
}

function Format-SmtpEncryption {
    param($UseSsl, $SecureConnection)
    $m = Format-SecureConnection $SecureConnection
    if ($m) { return $m }
    if ($UseSsl -eq 1) { return 'SSL/TLS' }
    elseif ($UseSsl -eq 0) { return 'なし' }
    else { return '自動' }
}

function Format-Port {
    param($Port, $UseSsl, $SecureDefault, $PlainDefault)
    if ($null -ne $Port -and "$Port" -ne '') { return "$Port" }
    # Only assume the secure port when SSL is explicitly ON. When SSL is OFF
    # or UNKNOWN, fall back to the plain/standard port (operator preference:
    # "if unsure between 995 and 25, take the plain one").
    if ($UseSsl -eq 1) { return "$SecureDefault (推定)" }
    return "$PlainDefault (推定)"
}

# ----------------------------------------------------------
# Parse recovered plaintext passwords out of _account_settings.txt.
# Keyed by e-mail -> @{ inc; smtp }. Tolerant: a format change only loses
# the passwords, never the structured fields from the manifest.
# ----------------------------------------------------------
function Get-PasswordMap {
    param([string]$Path)
    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }
    $current = $null
    foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        $h = [regex]::Match($line, '^\s*アカウント\s+\d+\s*[:：]\s*(\S+)')
        if ($h.Success) {
            $current = $h.Groups[1].Value.Trim()
            if (-not $map.ContainsKey($current)) { $map[$current] = @{ inc = $null; smtp = $null } }
            continue
        }
        if ($null -eq $current) { continue }
        $ms = [regex]::Match($line, '^\s*SMTP\s*パスワード\s*[:：]\s*(.+?)\s*$')
        if ($ms.Success) { $map[$current].smtp = $ms.Groups[1].Value; continue }
        $mp = [regex]::Match($line, '^\s*パスワード\s*[:：]\s*(.+?)\s*$')
        if ($mp.Success) { $map[$current].inc = $mp.Groups[1].Value; continue }
    }
    return $map
}

# ----------------------------------------------------------
# Build a normalized account record from a manifest account node.
# ----------------------------------------------------------
function ConvertTo-AccountRecord {
    param($ProfileName, $Acct, $PwMap)
    $isImap = ("$($Acct.type)" -eq 'imap')
    $inc = if ($isImap) { $Acct.imap } else { $Acct.pop3 }

    $pwStored = $null
    if ($Acct.passwordStored) {
        if ($isImap -and $Acct.passwordStored.PSObject.Properties['imap']) {
            $pwStored = $Acct.passwordStored.imap
        } elseif ($Acct.passwordStored.PSObject.Properties['pop3']) {
            $pwStored = $Acct.passwordStored.pop3
        }
    }

    $incPw = $null; $smtpPw = $null
    $key = "$($Acct.email)"
    if ($PwMap.ContainsKey($key)) {
        $incPw  = $PwMap[$key].inc
        $smtpPw = $PwMap[$key].smtp
    }

    $pstFile = $null
    if ($Acct.pst -and $Acct.pst.PSObject.Properties['sourceFileName']) { $pstFile = $Acct.pst.sourceFileName }

    [pscustomobject]@{
        Profile       = $ProfileName
        SubKey        = $Acct.subKey
        IsImap        = $isImap
        Type          = if ($isImap) { 'IMAP' } else { 'POP3' }
        DisplayName   = $Acct.displayName
        Email         = $Acct.email
        AccountName   = $Acct.accountName
        ReplyEmail    = $Acct.replyEmail
        Organization  = $Acct.organization
        IncServer     = $inc.server
        IncUser       = $inc.userName
        IncPort       = $inc.port
        IncUseSsl     = $inc.useSSL
        IncSecCon     = $inc.secureConnection
        IncSpa        = if ($isImap) { $null } else { $Acct.pop3.useSPA }
        IncPassword   = $incPw
        SmtpServer    = $Acct.smtp.server
        SmtpUser      = $Acct.smtp.userName
        SmtpPort      = $Acct.smtp.port
        SmtpUseSsl    = $Acct.smtp.useSSL
        SmtpUseAuth   = $Acct.smtp.useAuth
        SmtpSecCon    = $Acct.smtp.secureConnection
        SmtpPassword  = $smtpPw
        PwStored      = $pwStored
        LeaveOnServer = if ($Acct.options) { $Acct.options.leaveOnServer } else { $null }
        PstFile       = $pstFile
    }
}

# ----------------------------------------------------------
# Self-authored JSON support: map a simple account object (see
# accounts.sample.json beside this script) to the SAME normalized record
# shape that ConvertTo-AccountRecord produces from a backup manifest.
# ----------------------------------------------------------
function ConvertTo-SecConValue {
    # Accept a number (0..3) or a name and return the modern Outlook
    # "encrypted connection type" enum value, or $null.
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ("$Value" -match '^\d+$') { return [int]$Value }
    $s = "$Value".ToLower()
    if ($s -match 'starttls')  { return 2 }
    if ($s -match 'ssl|tls')   { return 1 }
    if ($s -match 'none|なし')  { return 0 }
    if ($s -match 'auto|自動')  { return 3 }
    return $null
}

function ConvertFrom-SimpleAccount {
    param($A, [int]$Index = 0)
    $isImap = ("$($A.type)" -match '(?i)imap')
    $incSsl   = if ($null -ne $A.incomingSsl) { if ($A.incomingSsl) { 1 } else { 0 } } else { $null }
    $spa      = if ($null -ne $A.spa)         { if ($A.spa) { 1 } else { 0 } }         else { $null }
    $smtpAuth = if ($null -ne $A.smtpAuth)    { if ($A.smtpAuth) { 1 } else { 0 } }    else { $null }
    $smtpSec  = ConvertTo-SecConValue $A.smtpEncryption
    $incSec   = ConvertTo-SecConValue $A.incomingEncryption
    $leaveVal = $null
    if ($null -ne $A.leaveOnServer) {
        $on = [bool]$A.leaveOnServer
        $d = 0
        if ($null -ne $A.leaveDays) { $d = [int]$A.leaveDays }
        $leaveVal = ((($d -band 0xFFFF) -shl 16) -bor ([int]$on))
    }
    $incUser = if (-not [string]::IsNullOrWhiteSpace("$($A.incomingUser)")) { $A.incomingUser } else { $A.email }

    [pscustomobject]@{
        Profile       = if ($A.profile) { $A.profile } else { 'Manual' }
        SubKey        = ('{0:x8}' -f $Index)
        IsImap        = $isImap
        Type          = if ($isImap) { 'IMAP' } else { 'POP3' }
        DisplayName   = $A.displayName
        Email         = $A.email
        AccountName   = if ($A.accountName) { $A.accountName } else { $A.email }
        ReplyEmail    = $A.replyEmail
        Organization  = $A.organization
        IncServer     = $A.incomingServer
        IncUser       = $incUser
        IncPort       = $A.incomingPort
        IncUseSsl     = $incSsl
        IncSecCon     = $incSec
        IncSpa        = $spa
        IncPassword   = $A.password
        SmtpServer    = $A.smtpServer
        SmtpUser      = $A.smtpUser
        SmtpPort      = $A.smtpPort
        SmtpUseSsl    = $null
        SmtpUseAuth   = $smtpAuth
        SmtpSecCon    = $smtpSec
        SmtpPassword  = $A.smtpPassword
        PwStored      = if ($A.password) { $true } else { $null }
        LeaveOnServer = $leaveVal
        PstFile       = $A.pstFile
    }
}

# ----------------------------------------------------------
# Load accounts: self-authored JSON (mode 1) takes priority over the
# backup handoff (mode 2).
# ----------------------------------------------------------
$accounts = New-Object System.Collections.Generic.List[object]
$sourceLabel = $null

if ($null -ne $accountsJsonPath -and (Test-Path -LiteralPath $accountsJsonPath)) {
    $doc = Get-Content -LiteralPath $accountsJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $list = if ($doc -is [System.Array]) { $doc } elseif ($null -ne $doc.accounts) { $doc.accounts } else { @($doc) }
    $i = 0
    foreach ($a in @($list)) { $accounts.Add((ConvertFrom-SimpleAccount -A $a -Index $i)); $i++ }
    $meta = $doc.meta
    $srcPc   = if ($meta -and $meta.sourcePc)   { "$($meta.sourcePc)" }   else { '(自作 JSON)' }
    $srcUser = if ($meta -and $meta.sourceUser) { "$($meta.sourceUser)" } else { '-' }
    $olVer   = if ($meta -and $meta.outlookVer) { "$($meta.outlookVer)" } else { '' }
    $sourceLabel = "json:$accountsJsonPath"
} else {
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        $msg = "データソースが見つかりません:`r`n  backup : $manifestPath`r`n  JSON   : $accountsJsonPath"
        if ($Dump -or $SelfTest) { Write-Output $msg; return }
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show($msg, 'Outlook アカウント情報',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $pwMap = Get-PasswordMap -Path $settingsPath
    foreach ($prof in @($manifest.items.profiles)) {
        foreach ($a in @($prof.accounts)) {
            $accounts.Add((ConvertTo-AccountRecord -ProfileName $prof.name -Acct $a -PwMap $pwMap))
        }
    }
    $srcPc   = Format-Value $manifest.computerName '(不明)'
    $srcUser = if ($manifest.sourceUser) { Format-Value $manifest.sourceUser.userName '(不明)' } else { '(不明)' }
    $olVer   = Format-Value $manifest.outlookVersion ''
    $sourceLabel = "backup:$manifestPath"
}

# ----------------------------------------------------------
# Headless verification: dump normalized accounts and exit.
# ----------------------------------------------------------
if ($Dump) {
    $out = [ordered]@{
        source       = $sourceLabel
        sourcePc     = $srcPc
        sourceUser   = $srcUser
        outlookVer   = $olVer
        accountCount = $accounts.Count
        accounts     = $accounts.ToArray()
    }
    Write-Output ($out | ConvertTo-Json -Depth 6)
    return
}

if ($accounts.Count -eq 0 -and -not $SelfTest) {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show(
        'この移行データには POP / IMAP アカウントが見つかりませんでした。',
        'Outlook アカウント情報',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information)
    return
}

# ============================================================
# GUI
# ============================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch {}
try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch {}

# Dark pseudo-screen palette. NOTE: do NOT rename to $C -- PowerShell
# variable names are case-insensitive and helper locals use $c (CheckBox),
# which would silently shadow the palette and null out every colour.
$Pal = @{
    Bg       = [System.Drawing.Color]::FromArgb(31, 31, 35)
    Banner   = [System.Drawing.Color]::FromArgb(78, 40, 40)
    Fg       = [System.Drawing.Color]::FromArgb(231, 231, 231)
    Dim      = [System.Drawing.Color]::FromArgb(112, 112, 118)
    Accent   = [System.Drawing.Color]::FromArgb(200, 168, 240)
    FieldBg  = [System.Drawing.Color]::FromArgb(58, 58, 66)
    FieldDim = [System.Drawing.Color]::FromArgb(38, 38, 42)
    FieldFg  = [System.Drawing.Color]::White
    Red      = [System.Drawing.Color]::FromArgb(255, 74, 74)
    BtnBg    = [System.Drawing.Color]::FromArgb(66, 66, 74)
    Rule     = [System.Drawing.Color]::FromArgb(70, 70, 78)
}

function NF {
    param([single]$Size = 9, [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular)
    try { return New-Object System.Drawing.Font('Yu Gothic UI', $Size, $Style) }
    catch { return New-Object System.Drawing.Font('MS UI Gothic', $Size, $Style) }
}

# ---- control factory helpers --------------------------------------------
function New-Lbl {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [bool]$Dim = $false, $Font = $null, [int]$W = 0, [int]$H = 18)
    $l = New-Object System.Windows.Forms.Label
    if ($W -gt 0) { $l.AutoSize = $false; $l.SetBounds($X, $Y, $W, $H) }
    else { $l.AutoSize = $true; $l.Location = New-Object System.Drawing.Point($X, $Y) }
    $l.Text = $Text
    $l.ForeColor = if ($Dim) { $Pal.Dim } else { $Pal.Fg }
    if ($Font) { $l.Font = $Font }
    $Parent.Controls.Add($l)
    return $l
}

function New-Section {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [bool]$Dim = $false)
    $l = New-Object System.Windows.Forms.Label
    $l.AutoSize = $true
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Text = $Text
    $l.ForeColor = if ($Dim) { $Pal.Dim } else { $Pal.Accent }
    $l.Font = (NF 9 ([System.Drawing.FontStyle]::Bold))
    $Parent.Controls.Add($l)
    return $l
}

function New-Data {
    param($Parent, [int]$X, [int]$Y, [int]$W, [string]$Value = '', [bool]$HasData = $true)
    $t = New-Object System.Windows.Forms.TextBox
    $t.SetBounds($X, $Y, $W, 23)
    $t.ReadOnly = $true
    $t.BorderStyle = 'FixedSingle'
    $t.Text = $Value
    if ($HasData) { $t.BackColor = $Pal.FieldBg; $t.ForeColor = $Pal.FieldFg }
    else { $t.BackColor = $Pal.FieldDim; $t.ForeColor = $Pal.Dim }
    $Parent.Controls.Add($t)
    return $t
}

function New-Chk {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W, [bool]$Checked = $false, [bool]$Dim = $false)
    $c = New-Object System.Windows.Forms.CheckBox
    $c.AutoCheck = $false
    $c.SetBounds($X, $Y, $W, 20)
    $c.Text = $Text
    $c.Checked = $Checked
    $c.ForeColor = if ($Dim) { $Pal.Dim } else { $Pal.Fg }
    $Parent.Controls.Add($c)
    return $c
}

function New-Radio {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W, [bool]$Checked = $false, [bool]$Dim = $false)
    $r = New-Object System.Windows.Forms.RadioButton
    $r.AutoCheck = $false
    $r.SetBounds($X, $Y, $W, 20)
    $r.Text = $Text
    $r.Checked = $Checked
    $r.ForeColor = if ($Dim) { $Pal.Dim } else { $Pal.Fg }
    $Parent.Controls.Add($r)
    return $r
}

function New-MockBtn {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H = 26)
    # A greyed, non-functional button (replica only).
    $b = New-Object System.Windows.Forms.Button
    $b.SetBounds($X, $Y, $W, $H)
    $b.Text = $Text
    $b.FlatStyle = 'Flat'
    $b.Enabled = $false
    $b.ForeColor = $Pal.Dim
    $b.BackColor = $Pal.FieldDim
    $b.FlatAppearance.BorderColor = $Pal.Rule
    $Parent.Controls.Add($b)
    return $b
}

function New-ActiveBtn {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H = 28)
    $b = New-Object System.Windows.Forms.Button
    $b.SetBounds($X, $Y, $W, $H)
    $b.Text = $Text
    $b.FlatStyle = 'Flat'
    $b.ForeColor = $Pal.Fg
    $b.BackColor = $Pal.BtnBg
    $b.FlatAppearance.BorderColor = $Pal.Accent
    $Parent.Controls.Add($b)
    return $b
}

function Add-CopyButton {
    # A small clipboard button placed just right of a value box; copies that
    # box's current text. Not part of the Outlook replica (operator request).
    param($Parent, $TextBox)
    $b = New-Object System.Windows.Forms.Button
    $b.SetBounds(($TextBox.Right + 3), $TextBox.Top, 26, 22)
    try { $b.Text = [System.Char]::ConvertFromUtf32(0x1F4CB) } catch { $b.Text = 'C' }
    $b.FlatStyle = 'Flat'
    try { $b.Font = New-Object System.Drawing.Font('Segoe UI Emoji', 9) } catch {}
    $b.ForeColor = $Pal.Fg
    $b.BackColor = $Pal.BtnBg
    $b.FlatAppearance.BorderColor = $Pal.Rule
    $b.TabStop = $false
    $b.Tag = $TextBox
    $b.Add_Click({
        $src = $this.Tag
        if ($null -ne $src) {
            $val = "$($src.Text)"
            if (-not [string]::IsNullOrEmpty($val)) {
                try { [System.Windows.Forms.Clipboard]::SetText($val) } catch {}
            }
        }
    })
    if ($script:copyTip) { $script:copyTip.SetToolTip($b, 'この値をコピー') }
    $Parent.Controls.Add($b)
    return $b
}

# ---- "needs attention" computation --------------------------------------
function Get-Attention {
    param($A)
    $needSmtpAuth = ($A.SmtpUseAuth -eq 1)
    $incDefault = if ($A.IsImap) { 143 } else { 110 }
    $needInc = ($A.IncUseSsl -eq 1) -or
               ($null -ne $A.IncSecCon -and [int]$A.IncSecCon -ne 0) -or
               ($null -ne $A.IncPort -and "$($A.IncPort)" -ne '' -and [int]$A.IncPort -ne $incDefault)
    $needSmtp = ($A.SmtpUseSsl -eq 1) -or
                ($null -ne $A.SmtpSecCon -and [int]$A.SmtpSecCon -ne 0) -or
                ($null -ne $A.SmtpPort -and "$($A.SmtpPort)" -ne '' -and [int]$A.SmtpPort -ne 25)
    $needPorts = $needInc -or $needSmtp
    return @{ SmtpAuth = $needSmtpAuth; Ports = $needPorts; Advanced = ($needSmtpAuth -or $needPorts) }
}

# =========================================================================
# Advanced dialog: "Internet E-mail Settings" (General/Outgoing/Advanced)
# Built fresh per account. Tabs needing setup are coloured red.
# =========================================================================
function New-AdvancedForm {
    param($A)
    $att = Get-Attention $A

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'インターネット電子メール設定  [参照用の疑似画面]'
    $dlg.ClientSize = New-Object System.Drawing.Size(472, 528)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.BackColor = $Pal.Bg
    $dlg.Font = (NF 9)
    $script:copyTip = New-Object System.Windows.Forms.ToolTip

    # --- custom dark tab strip (3 buttons + 3 panels) ---
    $tabDefs = @(
        @{ Text = '全般';        Att = $false },
        @{ Text = '送信サーバー'; Att = $att.SmtpAuth },
        @{ Text = '詳細設定';     Att = $att.Ports }
    )
    $tabBtns = New-Object System.Collections.Generic.List[object]
    $panels  = New-Object System.Collections.Generic.List[object]
    $tx = 8
    for ($i = 0; $i -lt $tabDefs.Count; $i++) {
        $d = $tabDefs[$i]
        $label = if ($d.Att) { "● $($d.Text)" } else { $d.Text }
        $w = if ($d.Att) { 118 } else { 96 }
        $b = New-Object System.Windows.Forms.Button
        $b.SetBounds($tx, 8, $w, 28)
        $b.Text = $label
        $b.FlatStyle = 'Flat'
        $b.Tag = $i
        $b.BackColor = $Pal.Bg
        $b.ForeColor = if ($d.Att) { $Pal.Red } else { $Pal.Fg }
        $b.FlatAppearance.BorderColor = $Pal.Rule
        $dlg.Controls.Add($b)
        $tabBtns.Add($b)
        $tx += $w + 2

        $p = New-Object System.Windows.Forms.Panel
        $p.SetBounds(0, 44, 472, 446)
        $p.BackColor = $Pal.Bg
        $p.Visible = ($i -eq 0)
        $dlg.Controls.Add($p)
        $panels.Add($p)
    }

    $tabBtnArr = $tabBtns.ToArray()
    $panelArr  = $panels.ToArray()
    $tabAttArr = @($tabDefs | ForEach-Object { [bool]$_.Att })
    $onTab = {
        param($snd, $ev)
        $sel = [int]$snd.Tag
        for ($k = 0; $k -lt $panelArr.Count; $k++) {
            $panelArr[$k].Visible = ($k -eq $sel)
            $bb = $tabBtnArr[$k]
            if ($k -eq $sel) { $bb.BackColor = $Pal.BtnBg } else { $bb.BackColor = $Pal.Bg }
            if ($tabAttArr[$k]) { $bb.ForeColor = $Pal.Red } else { $bb.ForeColor = $Pal.Fg }
        }
    }.GetNewClosure()
    foreach ($b in $tabBtnArr) { $b.Add_Click($onTab) }
    $tabBtnArr[0].BackColor = $Pal.BtnBg

    # ============ Panel 0: General ============
    $p0 = $panelArr[0]
    New-Section $p0 'メール アカウント' 16 14 | Out-Null
    New-Lbl $p0 ('このアカウントを表す名前を入力してください ("仕事"、' + "`r`n" + '"Microsoft Mail サーバー" など)(N)') 16 36 $true $null 430 32 | Out-Null
    $tbAcct = New-Data $p0 28 74 360 (Format-Value $A.AccountName $A.Email) $true
    Add-CopyButton $p0 $tbAcct | Out-Null
    New-Section $p0 'その他のユーザー情報' 16 116 | Out-Null
    New-Lbl $p0 '組織(O):' 28 144 | Out-Null
    $hasOrg = (-not [string]::IsNullOrWhiteSpace("$($A.Organization)"))
    $tbOrg = New-Data $p0 150 141 250 (Format-Value $A.Organization) $hasOrg
    Add-CopyButton $p0 $tbOrg | Out-Null
    New-Lbl $p0 '返信電子メール(R):' 28 172 | Out-Null
    $hasReply = (-not [string]::IsNullOrWhiteSpace("$($A.ReplyEmail)"))
    $tbReply = New-Data $p0 150 169 250 (Format-Value $A.ReplyEmail) $hasReply
    Add-CopyButton $p0 $tbReply | Out-Null

    # ============ Panel 1: Outgoing Server ============
    $p1 = $panelArr[1]
    $needAuth = $att.SmtpAuth
    $authChk = New-Chk $p1 '送信サーバー (SMTP) は認証が必要(O)' 16 16 410 $needAuth (-not $needAuth)
    if ($needAuth) { $authChk.ForeColor = $Pal.Red }
    $sameAsIncoming = [string]::IsNullOrWhiteSpace("$($A.SmtpUser)")
    New-Radio $p1 '受信メール サーバーと同じ設定を使用する(U)' 36 46 410 ($needAuth -and $sameAsIncoming) (-not $needAuth) | Out-Null
    New-Radio $p1 '次のアカウントとパスワードでログオンする(L)' 36 72 410 ($needAuth -and -not $sameAsIncoming) (-not $needAuth) | Out-Null
    $dimOther = (-not $needAuth) -or $sameAsIncoming
    New-Lbl $p1 'アカウント名(N):' 56 102 $dimOther | Out-Null
    $tbSmtpUser = New-Data $p1 160 99 250 (Format-Value $A.SmtpUser) (-not $dimOther)
    Add-CopyButton $p1 $tbSmtpUser | Out-Null
    New-Lbl $p1 'パスワード(P):' 56 130 $dimOther | Out-Null
    $tbSmtpPw = New-Data $p1 160 127 250 (Format-Value $A.SmtpPassword '(未復元)') (-not $dimOther -and -not [string]::IsNullOrWhiteSpace("$($A.SmtpPassword)"))
    Add-CopyButton $p1 $tbSmtpPw | Out-Null
    New-Chk $p1 'パスワードを保存する(R)' 160 154 200 $false $true | Out-Null
    New-Chk $p1 'セキュリティで保護されたパスワード認証 (SPA) に対応(Q)' 56 178 360 $false $true | Out-Null
    New-Radio $p1 'メールを送信する前に受信メール サーバーにログオンする(I)' 36 208 410 $false $true | Out-Null

    # ============ Panel 2: Advanced ============
    $p2 = $panelArr[2]
    New-Section $p2 'サーバーのポート番号' 16 12 | Out-Null
    $incLbl = if ($A.IsImap) { '受信サーバー (IMAP)(I):' } else { '受信サーバー (POP3)(I):' }
    New-Lbl $p2 $incLbl 28 42 | Out-Null
    $secDefIn = if ($A.IsImap) { 993 } else { 995 }
    $plainDefIn = if ($A.IsImap) { 143 } else { 110 }
    New-Data $p2 240 39 60 (Format-Port $A.IncPort $A.IncUseSsl $secDefIn $plainDefIn) $true | Out-Null
    New-MockBtn $p2 '標準設定(D)' 308 39 90 24 | Out-Null
    New-Chk $p2 'このサーバーでは暗号化された接続 (SSL/TLS) が必要(E)' 28 70 410 ($A.IncUseSsl -eq 1) ($null -eq $A.IncUseSsl) | Out-Null
    New-Lbl $p2 '送信サーバー (SMTP)(O):' 28 100 | Out-Null
    New-Data $p2 240 97 60 (Format-Port $A.SmtpPort $A.SmtpUseSsl 587 25) $true | Out-Null
    New-Lbl $p2 '使用する暗号化接続の種類(C):' 28 130 | Out-Null
    $tbEnc = New-Data $p2 240 127 150 (Format-SmtpEncryption $A.SmtpUseSsl $A.SmtpSecCon) $true
    Add-CopyButton $p2 $tbEnc | Out-Null

    New-Section $p2 'サーバーのタイムアウト(T)' 16 166 $true | Out-Null
    New-Lbl $p2 '短い ───────┼─────── 長い     1 分' 28 190 $true | Out-Null

    New-Section $p2 '配信' 16 222 | Out-Null
    $leaveOn = $false; $days = $null
    if ($null -ne $A.LeaveOnServer) {
        $v = [int64]$A.LeaveOnServer
        $leaveOn = (($v -band 1) -ne 0)
        $days = (([int64]$v -shr 16) -band 0xFFFF)
    }
    $hasLeave = ($null -ne $A.LeaveOnServer)
    New-Chk $p2 'サーバーにメッセージのコピーを置く(L)' 28 248 360 $leaveOn (-not $hasLeave) | Out-Null
    $dimDel = (-not $hasLeave) -or (-not $leaveOn) -or ($null -eq $days -or $days -le 0)
    New-Chk $p2 'サーバーから削除する(R)' 48 274 150 ($leaveOn -and $days -gt 0) $dimDel | Out-Null
    New-Data $p2 200 272 50 ("$days") (-not $dimDel) | Out-Null
    New-Lbl $p2 '日後' 256 274 $dimDel | Out-Null
    New-Chk $p2 '[削除済みアイテム] から削除されたら、サーバーから削除(M)' 48 300 410 $false $true | Out-Null

    # OK / Cancel (close only; this is a reference mock)
    $btnOk = New-ActiveBtn $dlg 'OK' 300 492 78 26
    $btnCancel = New-ActiveBtn $dlg 'キャンセル' 384 492 78 26
    $btnOk.Add_Click({ $dlg.Close() })
    $btnCancel.Add_Click({ $dlg.Close() })
    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCancel

    # expose the content panels so -Shot can capture each tab headlessly
    $dlg.Tag = $panelArr
    return $dlg
}

# =========================================================================
# Main form: "Add Account - POP and IMAP Account Settings" replica
# =========================================================================
$script:accounts = $accounts
$script:mui = @{}

function Set-DataField {
    param($Tb, [string]$Text, [bool]$HasData)
    $Tb.Text = $Text
    if ($HasData) { $Tb.BackColor = $Pal.FieldBg; $Tb.ForeColor = $Pal.FieldFg }
    else { $Tb.BackColor = $Pal.FieldDim; $Tb.ForeColor = $Pal.Dim }
}

function Set-ChkField {
    param($Cb, [bool]$Checked, [bool]$HasData)
    $Cb.Checked = $Checked
    $Cb.ForeColor = if ($HasData) { $Pal.Fg } else { $Pal.Dim }
}

function Set-MainFields {
    param($A)
    $script:current = $A
    $m = $script:mui

    Set-DataField $m.Name      (Format-Value $A.DisplayName) (-not [string]::IsNullOrWhiteSpace("$($A.DisplayName)"))
    Set-DataField $m.Email     (Format-Value $A.Email)       (-not [string]::IsNullOrWhiteSpace("$($A.Email)"))
    Set-DataField $m.Type      $A.Type                       $true
    Set-DataField $m.IncServer (Format-Value $A.IncServer)   (-not [string]::IsNullOrWhiteSpace("$($A.IncServer)"))
    Set-DataField $m.SmtpServer (Format-Value $A.SmtpServer) (-not [string]::IsNullOrWhiteSpace("$($A.SmtpServer)"))
    Set-DataField $m.AcctName  (Format-Value $A.IncUser)     (-not [string]::IsNullOrWhiteSpace("$($A.IncUser)"))
    $hasPw = (-not [string]::IsNullOrWhiteSpace("$($A.IncPassword)"))
    Set-DataField $m.Password  (Format-Value $A.IncPassword '(未復元)') $hasPw
    Set-ChkField  $m.SavePw    ([bool]$A.PwStored) ($null -ne $A.PwStored)
    Set-ChkField  $m.Spa       ($A.IncSpa -eq 1)   ($null -ne $A.IncSpa)

    # data-file binding: reflect the real per-account PST association.
    $hasPst = (-not [string]::IsNullOrWhiteSpace("$($A.PstFile)"))
    Set-ChkField  $m.DfExisting $hasPst $hasPst
    Set-ChkField  $m.DfNew      $false  $false
    $pstText = if ($hasPst) { "$($A.PstFile)" } elseif ($A.IsImap) { '(IMAP: ローカルデータファイルなし)' } else { '(なし)' }
    Set-DataField $m.PstFile   $pstText $hasPst

    $att = Get-Attention $A
    $script:needAdvanced = $att.Advanced
    $script:detailHint.Visible = $att.Advanced

    $idx = $script:cmb.SelectedIndex + 1
    $script:lblCount.Text = "$idx / $($script:accounts.Count) 件"
    $script:mainForm.Invalidate()
}

function New-MainForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Outlook アカウント設定 (移行参照用の疑似画面)'
    $form.ClientSize = New-Object System.Drawing.Size(792, 584)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.BackColor = $Pal.Bg
    $form.Font = (NF 9)
    $script:mainForm = $form
    $script:copyTip = New-Object System.Windows.Forms.ToolTip

    # ----- mock banner (our addition; signals "not the real Outlook") -----
    $banner = New-Object System.Windows.Forms.Panel
    $banner.SetBounds(0, 0, 792, 34)
    $banner.BackColor = $Pal.Banner
    $form.Controls.Add($banner)
    $bl = New-Object System.Windows.Forms.Label
    $bl.AutoSize = $true
    $bl.Location = New-Object System.Drawing.Point(10, 9)
    $bl.ForeColor = [System.Drawing.Color]::White
    $bl.Text = '■ 参照用の疑似画面です（実際の Outlook 画面ではありません）'
    $banner.Controls.Add($bl)

    # account selector (our addition) -- wide so long e-mail addresses are
    # never truncated.
    $lblPick = New-Object System.Windows.Forms.Label
    $lblPick.AutoSize = $true
    $lblPick.ForeColor = [System.Drawing.Color]::White
    $lblPick.Location = New-Object System.Drawing.Point(406, 9)
    $lblPick.Text = 'アカウント:'
    $banner.Controls.Add($lblPick)

    $cmb = New-Object System.Windows.Forms.ComboBox
    $cmb.SetBounds(478, 5, 304, 24)
    $cmb.DropDownStyle = 'DropDownList'
    $cmb.DropDownWidth = 360
    $cmb.BackColor = $Pal.FieldBg
    $cmb.ForeColor = $Pal.FieldFg
    $banner.Controls.Add($cmb)
    $script:cmb = $cmb

    $lblCount = New-Object System.Windows.Forms.Label
    $lblCount.AutoSize = $true
    $lblCount.ForeColor = [System.Drawing.Color]::White
    # (count is shown in the wizard header to the right of the title)

    # ----- wizard header -----
    New-Lbl $form 'POP と IMAP のアカウント設定' 20 44 $false (NF 11 ([System.Drawing.FontStyle]::Bold)) | Out-Null
    New-Lbl $form 'お使いのアカウントのメール サーバーの設定を入力してください。' 20 70 $true | Out-Null
    $lblCount.Location = New-Object System.Drawing.Point(680, 50)
    $form.Controls.Add($lblCount)
    $script:lblCount = $lblCount

    # divider under header
    $rule = New-Object System.Windows.Forms.Panel
    $rule.SetBounds(0, 92, 792, 1); $rule.BackColor = $Pal.Rule
    $form.Controls.Add($rule)

    # ===== LEFT column =====
    # Start the value column past the widest label so long labels (e.g. the
    # SMTP server label) never overlap their value boxes. Measured at runtime
    # so it stays correct regardless of font / DPI.
    $leftLabelX = 34
    # leave ~32px of room past the value box for the per-field copy button.
    $leftValueEnd = 372
    $leftLabels = @(
        '名前(Y):', '電子メール アドレス(E):', 'アカウントの種類(A):',
        '受信メール サーバー(I):', '送信メール サーバー (SMTP)(O):',
        'アカウント名(U):', 'パスワード(P):'
    )
    $maxLblW = 0
    foreach ($t in $leftLabels) {
        $wpx = [System.Windows.Forms.TextRenderer]::MeasureText($t, $form.Font).Width
        if ($wpx -gt $maxLblW) { $maxLblW = $wpx }
    }
    $fX = $leftLabelX + $maxLblW + 12
    $fW = $leftValueEnd - $fX

    New-Section $form 'ユーザー情報' 20 104 | Out-Null
    New-Lbl $form '名前(Y):' $leftLabelX 130 | Out-Null
    $script:mui.Name = New-Data $form $fX 127 $fW
    Add-CopyButton $form $script:mui.Name | Out-Null
    New-Lbl $form '電子メール アドレス(E):' $leftLabelX 158 | Out-Null
    $script:mui.Email = New-Data $form $fX 155 $fW
    Add-CopyButton $form $script:mui.Email | Out-Null

    New-Section $form 'サーバー情報' 20 190 | Out-Null
    New-Lbl $form 'アカウントの種類(A):' $leftLabelX 216 | Out-Null
    $script:mui.Type = New-Data $form $fX 213 $fW
    New-Lbl $form '受信メール サーバー(I):' $leftLabelX 244 | Out-Null
    $script:mui.IncServer = New-Data $form $fX 241 $fW
    Add-CopyButton $form $script:mui.IncServer | Out-Null
    New-Lbl $form '送信メール サーバー (SMTP)(O):' $leftLabelX 272 | Out-Null
    $script:mui.SmtpServer = New-Data $form $fX 269 $fW
    Add-CopyButton $form $script:mui.SmtpServer | Out-Null

    New-Section $form 'メール サーバーへのログオン情報' 20 304 | Out-Null
    New-Lbl $form 'アカウント名(U):' $leftLabelX 330 | Out-Null
    $script:mui.AcctName = New-Data $form $fX 327 $fW
    Add-CopyButton $form $script:mui.AcctName | Out-Null
    New-Lbl $form 'パスワード(P):' $leftLabelX 358 | Out-Null
    $script:mui.Password = New-Data $form $fX 355 $fW
    Add-CopyButton $form $script:mui.Password | Out-Null
    $script:mui.SavePw = New-Chk $form 'パスワードを保存する(R)' $fX 380 220 $false $true
    $script:mui.Spa = New-Chk $form 'メール サーバーが SPA に対応している場合はオンにする(Q)' 20 406 360 $false $true

    # ===== RIGHT column =====
    # "Test account settings" stays greyed (we have no test data). The
    # "Deliver new messages to" block DOES reflect real data: the per-account
    # PST binding from the manifest (pst.sourceFileName).
    New-Section $form 'アカウント設定のテスト' 412 104 $true | Out-Null
    New-Lbl $form ('アカウントをテストして、入力内容が正しいかどうかを' + "`r`n" + '確認することをお勧めします。') 412 128 $true $null 360 34 | Out-Null
    New-MockBtn $form 'アカウント設定のテスト(T)' 430 168 180 24 | Out-Null
    New-Chk $form '[次へ] をクリックしたらアカウント設定を自動的にテストする(S)' 412 200 360 $true $true | Out-Null

    New-Section $form '新しいメッセージの配信先:' 412 234 | Out-Null
    $script:mui.DfNew = New-Radio $form '新しい Outlook データ ファイル(W)' 412 260 300 $false $true
    $script:mui.DfExisting = New-Radio $form '既存の Outlook データ ファイル(X)' 412 284 300 $false $false
    $script:mui.PstFile = New-Data $form 432 310 200 '' $false
    New-MockBtn $form '参照(S)' 640 310 70 24 | Out-Null

    # divider above the bottom row
    $rule2 = New-Object System.Windows.Forms.Panel
    $rule2.SetBounds(0, 500, 792, 1); $rule2.BackColor = $Pal.Rule
    $form.Controls.Add($rule2)

    # the key transition button (emphasised when setup is required)
    $detailHint = New-Object System.Windows.Forms.Label
    $detailHint.AutoSize = $false
    $detailHint.SetBounds(430, 432, 190, 20)
    $detailHint.TextAlign = 'MiddleRight'
    $detailHint.ForeColor = $Pal.Red
    $detailHint.Font = (NF 9 ([System.Drawing.FontStyle]::Bold))
    $detailHint.Text = '要設定 →'
    $form.Controls.Add($detailHint)
    $script:detailHint = $detailHint

    $btnDetail = New-ActiveBtn $form '詳細設定(M)...' 628 430 150 28
    $script:detailBtn = $btnDetail
    $btnDetail.Add_Click({
        $dlg = New-AdvancedForm $script:current
        [void]$dlg.ShowDialog($script:mainForm)
        $dlg.Dispose()
    })

    # bottom nav row (greyed replica)
    New-MockBtn $form '< 戻る(B)' 438 540 80 26 | Out-Null
    New-MockBtn $form '次へ(N) >' 524 540 80 26 | Out-Null
    $btnClose = New-ActiveBtn $form 'キャンセル' 610 540 80 26
    New-MockBtn $form 'ヘルプ' 696 540 80 26 | Out-Null
    $btnClose.Add_Click({ $script:mainForm.Close() })
    $form.CancelButton = $btnClose

    # red ring around the Advanced button when setup is required
    $form.Add_Paint({
        param($snd, $e)
        if ($script:needAdvanced -and $null -ne $script:detailBtn) {
            $r = $script:detailBtn.Bounds
            $r.Inflate(10, 8)
            $e.Graphics.SmoothingMode = 'AntiAlias'
            $pen = New-Object System.Drawing.Pen($Pal.Red, 2.5)
            $e.Graphics.DrawEllipse($pen, $r)
            $pen.Dispose()
        }
    })

    # populate selector
    foreach ($a in $script:accounts) {
        [void]$cmb.Items.Add("$($a.Email)  [$($a.Type)]")
    }
    $cmb.Add_SelectedIndexChanged({
        Set-MainFields $script:accounts[$script:cmb.SelectedIndex]
    })
    if ($script:accounts.Count -gt 0) { $cmb.SelectedIndex = 0 }

    return $form
}

# ----------------------------------------------------------
# Render a (possibly never-shown) form to a PNG for headless visual
# verification. Layout is absolute, so DrawToBitmap reproduces it.
# ----------------------------------------------------------
function Save-Shot {
    param($Form, [string]$Path)
    # Child controls only render in DrawToBitmap once their handles are
    # realized, which requires the form to be shown. Show it far off-screen,
    # pump the message queue, capture, then hide.
    $Form.StartPosition = 'Manual'
    $Form.Location = New-Object System.Drawing.Point(-3000, -3000)
    $Form.ShowInTaskbar = $false
    $Form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 150
    [System.Windows.Forms.Application]::DoEvents()
    $w = $Form.ClientSize.Width; $h = $Form.ClientSize.Height
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $Form.DrawToBitmap($bmp, $rect)
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $Form.Hide()
}

# ----------------------------------------------------------
# Entry: self-test (headless build), screenshot, or show.
# ----------------------------------------------------------
if ($SelfTest) {
    $f = New-MainForm
    foreach ($a in $script:accounts) { $d = New-AdvancedForm $a; $d.Dispose() }
    $f.Dispose()
    Write-Output "SELFTEST OK ($($script:accounts.Count) account(s))"
    return
}

if (-not [string]::IsNullOrWhiteSpace($Shot)) {
    $null = New-Item -ItemType Directory -Path $Shot -Force
    $f = New-MainForm
    Save-Shot $f (Join-Path $Shot 'main.png')
    $f.Dispose()
    $d = New-AdvancedForm $script:accounts[0]
    $panels = $d.Tag
    $names = @('general', 'outgoing', 'advanced')
    for ($i = 0; $i -lt $panels.Count; $i++) {
        for ($k = 0; $k -lt $panels.Count; $k++) { $panels[$k].Visible = ($k -eq $i) }
        Save-Shot $d (Join-Path $Shot ("adv_$($names[$i]).png"))
    }
    $d.Dispose()
    Write-Output "SHOTS written to $Shot"
    return
}

$form = New-MainForm
[void]$form.ShowDialog()
$form.Dispose()
