# ========================================
# Fabriq BackUper - Theme & UI Helpers
# ========================================
# CentreCOM-inspired light gray base shared with fabriq main and
# fabriq_checksheet (family pattern: same structural design,
# different accent color per app for at-a-glance identification).
#
# Accent color identity:
#   fabriq main      : blue   #4A90D9
#   fabriq_checksheet: pink   #E16EC3 (on a deep-purple base)
#   fabriq_backuper  : lavender #9366BD  <-- this file
#
# Self-contained copy per satellite-app isolation principle: no
# cross-app dependencies on internal libs.
# ========================================

# Required assemblies for the color / font / button helpers below.
# Must be loaded before any [System.Drawing.*] / [System.Windows.Forms.*]
# reference. Loaded here (not in main_form.ps1) because theme.ps1 is the
# first UI file dot-sourced and immediately uses System.Drawing.Color.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ========================================
# Color Scheme (CentreCOM Light Theme)
# ========================================
$script:bgForm       = [System.Drawing.Color]::FromArgb(186, 190, 194)  # #BABEC2 window bg
$script:bgPanel      = [System.Drawing.Color]::FromArgb(74, 74, 74)     # #4A4A4A header bar
$script:bgGrid       = [System.Drawing.Color]::FromArgb(225, 228, 231)  # #E1E4E7 grid bg
$script:bgCellAlt    = [System.Drawing.Color]::FromArgb(237, 238, 239)  # #EDEEEF alt row
$script:bgCell       = [System.Drawing.Color]::FromArgb(225, 228, 231)  # #E1E4E7 normal row
$script:bgHeader     = [System.Drawing.Color]::FromArgb(160, 166, 171)  # #A0A6AB grid header
$script:bgButton     = [System.Drawing.Color]::FromArgb(152, 157, 161)  # #989DA1 button
$script:bgButtonHov  = [System.Drawing.Color]::FromArgb(170, 174, 179)  # #AAAEB3 hover
$script:bgAccent     = [System.Drawing.Color]::FromArgb(147, 102, 189)  # #9366BD accent lavender (backuper identity color)
$script:bgAccentHov  = [System.Drawing.Color]::FromArgb(127,  82, 166)  # #7F52A6 lavender hover (~12% darker)
$script:bgAdd        = [System.Drawing.Color]::FromArgb(76, 175, 80)    # #4CAF50 success green
$script:bgDelete     = [System.Drawing.Color]::FromArgb(198, 40, 40)    # #C62828 error red
$script:bgInput      = [System.Drawing.Color]::FromArgb(255, 255, 255)  # white text input
$script:bgSelection  = [System.Drawing.Color]::FromArgb(76, 175, 80)    # #4CAF50 selected row
$script:bgTabPage    = [System.Drawing.Color]::FromArgb(196, 200, 204)  # #C4C8CC tab bg
$script:bgPreview    = [System.Drawing.Color]::FromArgb(210, 214, 219)  # #D2D6DB preview area

$script:fgText       = [System.Drawing.Color]::FromArgb(34, 34, 34)     # #222222 main text
$script:fgDim        = [System.Drawing.Color]::FromArgb(100, 100, 100)  # #646464 dim text
$script:fgHeader     = [System.Drawing.Color]::FromArgb(44, 44, 44)     # #2C2C2C header labels
$script:fgBtnText    = [System.Drawing.Color]::FromArgb(34, 34, 34)     # #222222 button text
$script:fgWhite      = [System.Drawing.Color]::FromArgb(255, 255, 255)  # white (on accent)
$script:fgGridHeader = [System.Drawing.Color]::FromArgb(44, 44, 44)     # #2C2C2C grid header text

$script:gridLine     = [System.Drawing.Color]::FromArgb(164, 168, 173)  # #A4A8AD grid lines
$script:borderColor  = [System.Drawing.Color]::FromArgb(117, 123, 130)  # #757B82 borders

$script:stripeBlue   = [System.Drawing.Color]::FromArgb(74, 144, 217)   # #4A90D9
$script:stripeYellow = [System.Drawing.Color]::FromArgb(242, 201, 76)   # #F2C94C
$script:stripeRed    = [System.Drawing.Color]::FromArgb(235, 87, 87)    # #EB5757

# ========================================
# Fonts
# ========================================
$script:fontNormal   = New-Object System.Drawing.Font("Segoe UI", 9)
$script:fontBold     = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$script:fontSemiBold = New-Object System.Drawing.Font("Segoe UI Semibold", 9)
$script:fontLarge    = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$script:fontTitle    = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$script:fontMono     = New-Object System.Drawing.Font("Consolas", 8.5)

# ========================================
# Helpers
# ========================================
function New-StyledButton {
    param(
        [string]$Text,
        [int]$X = 0, [int]$Y = 0,
        [int]$Width = 120, [int]$Height = 30,
        $BgColor = $script:bgButton
    )
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    $btn.Location = New-Object System.Drawing.Point($X, $Y)
    $btn.Size = New-Object System.Drawing.Size($Width, $Height)
    $btn.FlatStyle = "Flat"
    $btn.FlatAppearance.BorderColor = $script:borderColor
    $btn.FlatAppearance.BorderSize = 1
    # Hover color: lavender-darker for accent buttons, gray for the rest.
    $btn.FlatAppearance.MouseOverBackColor =
        if ($BgColor -eq $script:bgAccent) { $script:bgAccentHov } else { $script:bgButtonHov }
    $btn.BackColor = $BgColor
    $btn.ForeColor = if ($BgColor -eq $script:bgAccent) { $script:fgWhite } else { $script:fgBtnText }
    $btn.Font = $script:fontNormal
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $btn
}

function Set-GridStyle {
    param($Grid)
    $Grid.BackgroundColor = $script:bgGrid
    $Grid.GridColor = $script:gridLine
    $Grid.BorderStyle = "FixedSingle"
    $Grid.CellBorderStyle = "SingleHorizontal"
    $Grid.RowHeadersVisible = $false
    $Grid.AllowUserToAddRows = $false
    $Grid.AllowUserToDeleteRows = $false
    $Grid.AllowUserToResizeRows = $false
    $Grid.ColumnHeadersHeightSizeMode = "DisableResizing"
    $Grid.ColumnHeadersHeight = 28
    $Grid.RowTemplate.Height = 26
    $Grid.DefaultCellStyle.BackColor = $script:bgCell
    $Grid.DefaultCellStyle.ForeColor = $script:fgText
    $Grid.DefaultCellStyle.SelectionBackColor = $script:bgSelection
    $Grid.DefaultCellStyle.SelectionForeColor = $script:fgWhite
    $Grid.DefaultCellStyle.Font = $script:fontNormal
    $Grid.AlternatingRowsDefaultCellStyle.BackColor = $script:bgCellAlt
    $Grid.EnableHeadersVisualStyles = $false
    $Grid.ColumnHeadersDefaultCellStyle.BackColor = $script:bgHeader
    $Grid.ColumnHeadersDefaultCellStyle.ForeColor = $script:fgGridHeader
    $Grid.ColumnHeadersDefaultCellStyle.Font = $script:fontSemiBold
    $Grid.SelectionMode = "FullRowSelect"
    $Grid.MultiSelect = $false
    $Grid.ReadOnly = $true

    $t = $Grid.GetType()
    $p = $t.GetProperty("DoubleBuffered", [System.Reflection.BindingFlags]"Instance,NonPublic")
    $p.SetValue($Grid, $true, $null)
}

function Set-TextBoxStyle {
    param($TextBox)
    $TextBox.BackColor = $script:bgInput
    $TextBox.ForeColor = $script:fgText
    $TextBox.Font = $script:fontNormal
    $TextBox.BorderStyle = "FixedSingle"
}

function New-StyledLabel {
    param(
        [string]$Text,
        [int]$X = 0, [int]$Y = 0,
        [int]$Width = 200, [int]$Height = 20,
        $FgColor = $script:fgText,
        $Font = $script:fontNormal
    )
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text
    $lbl.Location = New-Object System.Drawing.Point($X, $Y)
    $lbl.Size = New-Object System.Drawing.Size($Width, $Height)
    $lbl.ForeColor = $FgColor
    $lbl.Font = $Font
    $lbl.BackColor = [System.Drawing.Color]::Transparent
    return $lbl
}

function New-StyledPanel {
    param(
        [int]$X = 0, [int]$Y = 0,
        [int]$Width = 100, [int]$Height = 100,
        $BgColor = $script:bgPanel
    )
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point($X, $Y)
    $panel.Size = New-Object System.Drawing.Size($Width, $Height)
    $panel.BackColor = $BgColor
    return $panel
}

function New-StyledCheckBox {
    param(
        [string]$Text,
        [int]$X = 0, [int]$Y = 0,
        [int]$Width = 160, [int]$Height = 22,
        [bool]$Checked = $false
    )
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text = $Text
    $cb.Location = New-Object System.Drawing.Point($X, $Y)
    $cb.Size = New-Object System.Drawing.Size($Width, $Height)
    $cb.ForeColor = $script:fgText
    $cb.Font = $script:fontNormal
    $cb.BackColor = [System.Drawing.Color]::Transparent
    $cb.Checked = $Checked
    return $cb
}

function New-StyledComboBox {
    param(
        [int]$X = 0, [int]$Y = 0,
        [int]$Width = 200, [int]$Height = 24
    )
    $cb = New-Object System.Windows.Forms.ComboBox
    $cb.Location = New-Object System.Drawing.Point($X, $Y)
    $cb.Size = New-Object System.Drawing.Size($Width, $Height)
    $cb.BackColor = $script:bgInput
    $cb.ForeColor = $script:fgText
    $cb.Font = $script:fontNormal
    $cb.DropDownStyle = "DropDownList"
    return $cb
}

function Set-FormStyle {
    param($Form, [string]$Title = "Fabriq BackUper", [int]$Width = 720, [int]$Height = 540)
    $Form.Text = $Title
    $Form.Size = New-Object System.Drawing.Size($Width, $Height)
    $Form.StartPosition = "CenterScreen"
    $Form.BackColor = $script:bgForm
    $Form.ForeColor = $script:fgText
    $Form.Font = $script:fontNormal
    $Form.FormBorderStyle = "FixedSingle"
    $Form.MaximizeBox = $false
}
