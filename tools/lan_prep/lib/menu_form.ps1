# ============================================================
# Fabriq LAN-Prep - Menu Form (v0.24.0)
# WinForms menu shown by fabriq_lanprep.ps1 after the EXE is
# launched. 4 action buttons; returns a string token to the
# caller which dispatches to the appropriate Prepare/Revert
# script.
#
# Theme: lavender accent (#9366BD) for the primary "Prepare"
# actions, neutral for Revert and Exit. Reuses backuper's
# theme.ps1 (Set-FormStyle / New-StyledLabel / New-StyledButton).
# ============================================================

function global:Show-LanPrepMenu {
    param(
        [Parameter(Mandatory)][string]$Version,
        # Optional. When provided, shows a banner with profile.profileName
        # under the title. Also enables the "Revert" button only when the
        # snapshot file resolved from profile actually exists.
        $MigrationProfile = $null
    )

    $script:_lanPrepMenuResult = 'exit'

    $hasProfile = ($null -ne $MigrationProfile)
    $formHeight = if ($hasProfile) { 380 } else { 360 }

    $form = New-Object System.Windows.Forms.Form
    Set-FormStyle -Form $form -Title 'Fabriq LAN-Prep - メニュー' -Width 520 -Height $formHeight
    $form.MaximizeBox  = $false
    $form.MinimizeBox  = $false
    $form.StartPosition = 'CenterScreen'
    $form.KeyPreview   = $true

    $yPos = 20

    # ---- Title row ----
    $titleLabel = New-StyledLabel -Text 'Fabriq LAN-Prep' `
        -X 20 -Y $yPos -Width 480 -Height 32 `
        -Font $script:fontTitle -FgColor $script:bgAccent
    $form.Controls.Add($titleLabel)
    $yPos += 32

    $versionLabel = New-StyledLabel -Text "v$Version  -  LAN 直結移行用 ネットワーク設定 + 共有作成" `
        -X 20 -Y $yPos -Width 480 -Height 16 -FgColor $script:fgDim
    $form.Controls.Add($versionLabel)
    $yPos += 22

    # ---- Optional profile banner ----
    if ($hasProfile) {
        $bannerText = "LAN 移行 profile: $($MigrationProfile.profileName)"
        $bannerLabel = New-StyledLabel -Text $bannerText `
            -X 20 -Y $yPos -Width 480 -Height 20 `
            -Font $script:fontBold -FgColor $script:bgAccent
        $form.Controls.Add($bannerLabel)
        $yPos += 26
    }
    else {
        $missingLabel = New-StyledLabel `
            -Text "(migration_profile.json が未配置です。先に backuper\data\migration_profile.json を作成してください)" `
            -X 20 -Y $yPos -Width 480 -Height 20 -FgColor $script:bgDelete
        $form.Controls.Add($missingLabel)
        $yPos += 26
    }

    # ---- Action buttons (2x2 grid feel, but stacked vertically for clarity) ----
    # Target (primary, lavender accent)
    $btnTarget = New-StyledButton `
        -Text '移行先として設定 (IP 変更 + 共有作成)' `
        -X 20 -Y $yPos -Width 480 -Height 44 -BgColor $script:bgAccent
    $btnTarget.Font = $script:fontBold
    $btnTarget.Enabled = $hasProfile
    $btnTarget.Add_Click({
        $script:_lanPrepMenuResult = 'target'
        $form.Close()
    })
    $form.Controls.Add($btnTarget)
    $yPos += 52

    # Source (primary, lavender accent)
    $btnSource = New-StyledButton `
        -Text '移行元として設定 (IP 変更のみ)' `
        -X 20 -Y $yPos -Width 480 -Height 44 -BgColor $script:bgAccent
    $btnSource.Font = $script:fontBold
    $btnSource.Enabled = $hasProfile
    $btnSource.Add_Click({
        $script:_lanPrepMenuResult = 'source'
        $form.Close()
    })
    $form.Controls.Add($btnSource)
    $yPos += 52

    # Revert (neutral)
    $btnRevert = New-StyledButton `
        -Text '元に戻す (ネットワーク復元 + 共有削除)' `
        -X 20 -Y $yPos -Width 480 -Height 36
    $btnRevert.Enabled = $hasProfile
    $btnRevert.Add_Click({
        $script:_lanPrepMenuResult = 'revert'
        $form.Close()
    })
    $form.Controls.Add($btnRevert)
    $yPos += 44

    # Exit (neutral)
    $btnExit = New-StyledButton `
        -Text '終了' `
        -X 20 -Y $yPos -Width 480 -Height 32
    $btnExit.Add_Click({
        $script:_lanPrepMenuResult = 'exit'
        $form.Close()
    })
    $form.Controls.Add($btnExit)

    # Form-level Esc = Exit
    $form.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            $script:_lanPrepMenuResult = 'exit'
            $form.Close()
        }
    })

    [void]$form.ShowDialog()
    $form.Dispose()

    return $script:_lanPrepMenuResult
}
