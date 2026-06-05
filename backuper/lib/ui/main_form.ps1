# ============================================================
# FabriqBackUper - Main Form
# Single Form with swappable Panel-based views (Mode Select /
# Backup / Restore / Progress). View modules expose
# New-<Name>View functions returning a Panel; this file owns
# the form, view switching, and shared state.
# ============================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ============================================================
# Shared state (script-scope, read/write by views)
# ============================================================
$script:MainForm     = $null
$script:Hostlist     = @()
$script:CurrentHost  = $null
$script:SectionList  = @()
$script:Views        = @{}   # name -> Panel
$script:ContentArea  = $null # parent Panel that holds the active view
$script:HostLabel    = $null # header host indicator

function Switch-View {
    param([string]$Name)
    foreach ($k in $script:Views.Keys) {
        $script:Views[$k].Visible = ($k -eq $Name)
    }
    # Per-view on-show hook
    $onShowName = "Show-${Name}View"
    if (Get-Command $onShowName -ErrorAction SilentlyContinue) {
        & $onShowName
    }
}

function Update-HostHeader {
    if ($null -ne $script:HostLabel) {
        if ($null -eq $script:CurrentHost) {
            $script:HostLabel.Text = "対象ホスト: (未選択)"
        } else {
            $newName = if ($script:CurrentHost.PSObject.Properties.Name -contains 'NewPCname') {
                $script:CurrentHost.NewPCname
            } else { '' }
            $suffix = if (-not [string]::IsNullOrWhiteSpace($newName)) { " -> $newName" } else { '' }
            $script:HostLabel.Text = "対象ホスト: $($script:CurrentHost.OldPCname)$suffix"
        }
    }
}

function Start-FabriqBackuperGui {
    param(
        [Parameter(Mandatory = $true)][string]$BackuperVersion,
        [Parameter(Mandatory = $true)][string]$BackuperRoot,
        [Parameter(Mandatory = $true)][string]$FabriqRoot,
        # Phase 3C: caller (main.ps1) pre-selects mode + host index via
        # Show-BackuperSessionForm. The unified session form replaces the
        # legacy ModeSelectView so these parameters are now required.
        [Parameter(Mandatory = $true)][ValidateSet('Backup','Restore')][string]$InitialMode,
        [Parameter(Mandatory = $true)][int]$InitialHostIndex
    )

    $script:BackuperVersion = $BackuperVersion
    $script:BackuperRoot    = $BackuperRoot
    $script:FabriqRoot      = $FabriqRoot

    # Load hostlist + section registry up-front. The caller must have set
    # $global:FabriqMasterPassphrase before invoking this function, so the
    # ENC: values will be transparently decrypted by Import-ModuleCsv.
    $script:Hostlist = @(Get-FabriqHostlist -FabriqRoot $FabriqRoot)
    if ($null -eq $script:Hostlist -or $script:Hostlist.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "hostlist の読み込みに失敗、または空です。$FabriqRoot\kernel\csv\hostlist.csv を確認してください。",
            "Fabriq BackUper - エラー",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return
    }
    if ($InitialHostIndex -lt 0 -or $InitialHostIndex -ge $script:Hostlist.Count) {
        [System.Windows.Forms.MessageBox]::Show(
            "InitialHostIndex が範囲外です: $InitialHostIndex (hostlist 件数: $($script:Hostlist.Count))",
            "Fabriq BackUper - エラー",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return
    }
    $script:CurrentHost = $script:Hostlist[$InitialHostIndex]
    $script:SectionList = @(Get-RegisteredSections -BackuperRoot $BackuperRoot)

    # Build main form (Phase 2.7.1: 900 -> 780, compact layout).
    # Inner content area = Height - title bar (~30) - borders (~16) - header dock (44).
    # v0.26.0: Height 780 -> 810 to accommodate the +30 Y shift on backup/restore
    # views caused by the new two-row section grid (system_evidence added). The
    # restore view's Start button (now Y=684 + H=44 = bottom 728) was being
    # clipped at the previous 780-tall window; 810 gives inner area ~720 with
    # an 8-12 px safety margin depending on OS chrome. Still well below a
    # laptop's ~800px visible area after taskbar.
    $form = New-Object System.Windows.Forms.Form
    Set-FormStyle -Form $form -Title "Fabriq BackUper v$BackuperVersion" -Width 960 -Height 810
    $script:MainForm = $form

    # Header bar (dark stripe with title + host indicator)
    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = "Top"
    $header.Height = 44
    $header.BackColor = $script:bgPanel
    $form.Controls.Add($header)

    $titleLbl = New-StyledLabel -Text "Fabriq BackUper" `
        -X 16 -Y 10 -Width 240 -Height 22 `
        -FgColor $script:fgWhite -Font $script:fontLarge
    $header.Controls.Add($titleLbl)

    $script:HostLabel = New-StyledLabel -Text "Host: (not selected)" `
        -X 270 -Y 14 -Width 420 -Height 18 `
        -FgColor $script:fgWhite -Font $script:fontNormal
    $header.Controls.Add($script:HostLabel)

    # Content area (fills below header)
    $content = New-Object System.Windows.Forms.Panel
    $content.Dock = "Fill"
    $content.BackColor = $script:bgForm
    $form.Controls.Add($content)
    $content.BringToFront()
    $script:ContentArea = $content

    # Build views (each returns a Panel). Phase 3C removes ModeSelectView:
    # the unified session_form.ps1 dialog already collected passphrase +
    # host + Backup/Restore choice before this function was invoked.
    $script:Views['Backup']   = New-BackupView
    $script:Views['Restore']  = New-RestoreView
    $script:Views['Progress'] = New-ProgressView

    foreach ($k in $script:Views.Keys) {
        $script:Views[$k].Dock = "Fill"
        $script:Views[$k].Visible = $false
        $content.Controls.Add($script:Views[$k])
    }

    # Reflect pre-selected host in the header label, then jump straight
    # to the requested view.
    Update-HostHeader
    Switch-View $InitialMode

    # v0.42.0 (P2): stop the restore-view poll timer on close (defensive; the
    # subprocess exits right after, but don't leave a timer armed).
    $form.Add_FormClosing({
        if ($null -ne $script:RestorePollTimer) { try { $script:RestorePollTimer.Stop() } catch {} }
    })

    [System.Windows.Forms.Application]::Run($form)
}
