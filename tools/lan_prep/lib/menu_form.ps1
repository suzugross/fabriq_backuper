# ============================================================
# Fabriq LAN-Prep - Menu Form (v0.30.0)
# WinForms menu shown by fabriq_lanprep.ps1 after the EXE is
# launched. Returns a pscustomobject describing the chosen
# action plus the resolved host pair and interfaceAlias.
#
# Theme: lavender accent (#9366BD) for the primary "Prepare"
# actions, neutral for Revert and Exit. Reuses backuper's
# theme.ps1 (Set-FormStyle / New-StyledLabel / New-StyledButton).
#
# v0.30.0 changes:
#   - Hostlist combo: lets operator pick a "OldPCname -> NewPCname"
#     row from fabriq's hostlist.csv. Empty / no selection keeps
#     the form usable in back-compat mode (= old behaviour, profile
#     drives everything).
#   - NIC combo: enumerates Get-NetAdapter so the interfaceAlias
#     used by Prepare-LanMigration is selected on the form rather
#     than hardcoded in profile.json.
#   - Role button labels are updated dynamically to show
#     "(this PC = NEW-PC-01)" / "(this PC = OLD-PC-01)" when a
#     hostlist row is selected, or "(profile)" when not.
#   - Return value changes from string token to pscustomobject so
#     caller can forward host pair + alias to the child script.
#   - Show-LanPrepPassphrasePrompt helper added (lives here to
#     avoid creating a new .ps1; new files made by the Write tool
#     would lose the UTF-8 BOM and mojibake Japanese labels under
#     PS5.1).
# ============================================================

function global:Show-LanPrepMenu {
    param(
        [Parameter(Mandatory)][string]$Version,
        # Optional. When provided, shows a banner with profile.profileName
        # under the title. When $null, role buttons are disabled because the
        # downstream Prepare-LanMigration requires a profile to run.
        $MigrationProfile = $null,
        # v0.30.0: fabriq hostlist rows (each row has at least OldPCname /
        # NewPCname). Pass @() to disable the host combo (back-compat mode).
        [array]$HostRows = @(),
        # v0.30.0: Get-NetAdapter results (Name / Status / MediaConnectState).
        # Used to populate the NIC combo.
        [array]$Nics = @(),
        # v0.30.0: optional initial selection for the NIC combo. Typically
        # the operator passes $MigrationProfile.network.source.interfaceAlias.
        [string]$DefaultInterfaceAlias = $null,
        # v0.31.0: hostlist combo is now hidden by default. Caller
        # (fabriq_lanprep.ps1) sets this only when env var
        # FABRIQ_LANPREP_HOSTLIST=1 is present. When $false (default), the
        # host combo block + dynamic role-button label updater are skipped
        # entirely, the form gets ~80px shorter, and role buttons keep a
        # static "(profile)" label. The slated removal path is described in
        # CHANGELOG v0.31.0 LAN-Prep entry; this switch is the seam.
        [switch]$ShowHostCombo
    )

    $hasProfile = ($null -ne $MigrationProfile)
    $hasHosts   = ($HostRows -and $HostRows.Count -gt 0)

    # v0.31.0: form height is dynamic on $ShowHostCombo. The host combo
    # block (label + combo + back-compat note) consumes ~80px of vertical
    # space; collapsing it shrinks the form to a tighter 3-button layout.
    $formHeight = if ($ShowHostCombo) { 520 } else { 440 }

    $form = New-Object System.Windows.Forms.Form
    Set-FormStyle -Form $form -Title 'Fabriq LAN-Prep - メニュー' -Width 560 -Height $formHeight
    $form.MaximizeBox  = $false
    $form.MinimizeBox  = $false
    $form.StartPosition = 'CenterScreen'
    $form.KeyPreview   = $true

    $yPos = 16

    # ---- Title row ----
    $titleLabel = New-StyledLabel -Text 'Fabriq LAN-Prep' `
        -X 20 -Y $yPos -Width 520 -Height 32 `
        -Font $script:fontTitle -FgColor $script:bgAccent
    $form.Controls.Add($titleLabel)
    $yPos += 32

    $versionLabel = New-StyledLabel -Text "v$Version  -  LAN 直結移行用 ネットワーク設定 + 共有作成" `
        -X 20 -Y $yPos -Width 520 -Height 16 -FgColor $script:fgDim
    $form.Controls.Add($versionLabel)
    $yPos += 24

    # ---- Profile banner ----
    if ($hasProfile) {
        $bannerText = "LAN 移行 profile: $($MigrationProfile.profileName)"
        $bannerLabel = New-StyledLabel -Text $bannerText `
            -X 20 -Y $yPos -Width 520 -Height 20 `
            -Font $script:fontBold -FgColor $script:bgAccent
        $form.Controls.Add($bannerLabel)
        $yPos += 24
    }
    else {
        $missingLabel = New-StyledLabel `
            -Text "(migration_profile.json が未配置です。先に backuper\data\migration_profile.json を作成してください)" `
            -X 20 -Y $yPos -Width 520 -Height 20 -FgColor $script:bgDelete
        $form.Controls.Add($missingLabel)
        $yPos += 24
    }

    # ---- Hostlist combo (v0.31.0: hidden unless -ShowHostCombo) ----
    # When -ShowHostCombo is not set, $hostCombo stays $null and the
    # closures below ($updateRoleLabels / $resolveHost) honour that.
    $hostCombo = $null
    if ($ShowHostCombo) {
        $hostLabel = New-StyledLabel -Text '対象 PC ペア (hostlist):' `
            -X 20 -Y $yPos -Width 200 -Height 18 `
            -Font $script:fontBold -FgColor $script:fgHeader
        $form.Controls.Add($hostLabel)
        $yPos += 22

        $hostCombo = New-StyledComboBox -X 20 -Y $yPos -Width 520 -Height 26
        # First entry is a sentinel "no selection -> back-compat" choice.
        [void]$hostCombo.Items.Add('(未選択 — profile 値で実行)')
        if ($hasHosts) {
            foreach ($h in $HostRows) {
                $oldName = "$($h.OldPCName)"
                $newName = if ($h.PSObject.Properties.Name -contains 'NewPCName') { "$($h.NewPCName)" } else { '' }
                if ([string]::IsNullOrWhiteSpace($newName)) {
                    [void]$hostCombo.Items.Add($oldName)
                }
                else {
                    [void]$hostCombo.Items.Add("$oldName  ->  $newName")
                }
            }
        }
        $hostCombo.SelectedIndex = 0
        $hostCombo.Enabled = $hasHosts
        $form.Controls.Add($hostCombo)
        $yPos += 30

        if (-not $hasHosts) {
            $noHostLabel = New-StyledLabel `
                -Text "(hostlist が読み込めなかったため後方互換モード。profile.json の値で実行されます)" `
                -X 20 -Y $yPos -Width 520 -Height 16 -FgColor $script:fgDim
            $form.Controls.Add($noHostLabel)
            $yPos += 20
        }
        else {
            $yPos += 4
        }
    }

    # ---- NIC combo ----
    $nicLabel = New-StyledLabel -Text '使用する NIC:' `
        -X 20 -Y $yPos -Width 200 -Height 18 `
        -Font $script:fontBold -FgColor $script:fgHeader
    $form.Controls.Add($nicLabel)
    $yPos += 22

    $nicCombo = New-StyledComboBox -X 20 -Y $yPos -Width 520 -Height 26
    if ($Nics -and $Nics.Count -gt 0) {
        foreach ($n in $Nics) {
            $label = "{0}  ({1}, {2})" -f $n.Name, $n.Status, $n.MediaConnectState
            [void]$nicCombo.Items.Add($label)
        }
        # Initial selection: profile-supplied alias if it matches any name,
        # otherwise the first row.
        $sel = 0
        if (-not [string]::IsNullOrWhiteSpace($DefaultInterfaceAlias)) {
            for ($i = 0; $i -lt $Nics.Count; $i++) {
                if ($Nics[$i].Name -eq $DefaultInterfaceAlias) { $sel = $i; break }
            }
        }
        $nicCombo.SelectedIndex = $sel
    }
    else {
        [void]$nicCombo.Items.Add('(NIC を取得できませんでした)')
        $nicCombo.SelectedIndex = 0
        $nicCombo.Enabled = $false
    }
    $form.Controls.Add($nicCombo)
    $yPos += 32

    # ---- Action buttons ----
    # Two role buttons (Target / Source), side by side.
    # v0.31.0 cosmetic update: labels condensed to "移行先（新PC）" /
    # "移行元（旧PC）" so operators don't have to read the role from
    # context. The source button uses $script:stripeYellow so the two
    # PCs are colour-distinguished at a glance (target = lavender accent,
    # source = warm yellow). Click handlers / return value / child-script
    # arguments are unchanged.
    $btnTarget = New-StyledButton `
        -Text '移行先（新PC）' `
        -X 20 -Y $yPos -Width 254 -Height 50 -BgColor $script:bgAccent
    $btnTarget.Font = $script:fontBold
    $btnTarget.Enabled = $hasProfile
    $form.Controls.Add($btnTarget)

    $btnSource = New-StyledButton `
        -Text '移行元（旧PC）' `
        -X 286 -Y $yPos -Width 254 -Height 50 -BgColor $script:stripeYellow
    $btnSource.Font = $script:fontBold
    $btnSource.Enabled = $hasProfile
    $form.Controls.Add($btnSource)
    $yPos += 58

    # Revert (neutral, full width)
    $btnRevert = New-StyledButton `
        -Text '元に戻す (ネットワーク復元 + 共有削除)' `
        -X 20 -Y $yPos -Width 520 -Height 36
    $btnRevert.Enabled = $hasProfile
    $form.Controls.Add($btnRevert)
    $yPos += 44

    # Exit
    $btnExit = New-StyledButton `
        -Text '終了' `
        -X 20 -Y $yPos -Width 520 -Height 32
    $form.Controls.Add($btnExit)

    # ---- Dynamic role-button label updater ----
    # v0.31.0: only wired when -ShowHostCombo is on. In default mode the
    # role buttons keep their static "移行先として設定" / "移行元として設定"
    # labels from New-StyledButton above.
    if ($ShowHostCombo -and $null -ne $hostCombo) {
        $updateRoleLabels = {
            $idx = $hostCombo.SelectedIndex
            if ($idx -le 0 -or -not $hasHosts) {
                $btnTarget.Text = '移行先（新PC）  (profile 値)'
                $btnSource.Text = '移行元（旧PC）  (profile 値)'
                return
            }
            $row = $HostRows[$idx - 1]
            $oldName = "$($row.OldPCName)"
            $newName = if ($row.PSObject.Properties.Name -contains 'NewPCName') { "$($row.NewPCName)" } else { '' }
            if ([string]::IsNullOrWhiteSpace($newName)) { $newName = '(未設定)' }
            if ([string]::IsNullOrWhiteSpace($oldName)) { $oldName = '(未設定)' }
            $btnTarget.Text = "移行先（新PC）`r`n(この PC = $newName)"
            $btnSource.Text = "移行元（旧PC）`r`n(この PC = $oldName)"
        }
        & $updateRoleLabels
        $hostCombo.Add_SelectedIndexChanged({ & $updateRoleLabels })
    }

    # ---- Result object ----
    # Initial = exit, overwritten by button handlers.
    $script:_lanPrepMenuResult = [pscustomobject]@{
        action         = 'exit'
        oldPCName      = $null
        newPCName      = $null
        interfaceAlias = $null
    }

    # Resolve currently-selected host row to (oldPCName, newPCName), or
    # ($null, $null) if the sentinel row is selected / no hosts loaded /
    # the host combo is hidden (v0.31.0 default).
    $resolveHost = {
        if (-not $ShowHostCombo -or $null -eq $hostCombo) { return @($null, $null) }
        $idx = $hostCombo.SelectedIndex
        if ($idx -le 0 -or -not $hasHosts) {
            return @($null, $null)
        }
        $row = $HostRows[$idx - 1]
        $oldName = "$($row.OldPCName)"
        $newName = if ($row.PSObject.Properties.Name -contains 'NewPCName') { "$($row.NewPCName)" } else { '' }
        if ([string]::IsNullOrWhiteSpace($oldName)) { $oldName = $null }
        if ([string]::IsNullOrWhiteSpace($newName)) { $newName = $null }
        return @($oldName, $newName)
    }

    # Resolve selected NIC alias (the part before the first 2 spaces, since
    # combo entries are formatted "Name  (Status, Media)").
    $resolveNic = {
        if (-not $nicCombo.Enabled -or $Nics.Count -eq 0) { return $null }
        $idx = $nicCombo.SelectedIndex
        if ($idx -lt 0 -or $idx -ge $Nics.Count) { return $null }
        return $Nics[$idx].Name
    }

    $btnTarget.Add_Click({
        $names = & $resolveHost
        $script:_lanPrepMenuResult = [pscustomobject]@{
            action         = 'target'
            oldPCName      = $names[0]
            newPCName      = $names[1]
            interfaceAlias = (& $resolveNic)
        }
        $form.Close()
    })
    $btnSource.Add_Click({
        $names = & $resolveHost
        $script:_lanPrepMenuResult = [pscustomobject]@{
            action         = 'source'
            oldPCName      = $names[0]
            newPCName      = $names[1]
            interfaceAlias = (& $resolveNic)
        }
        $form.Close()
    })
    $btnRevert.Add_Click({
        # Revert ignores host / NIC selection; the snapshot file carries
        # its own role + interfaceAlias.
        $script:_lanPrepMenuResult = [pscustomobject]@{
            action         = 'revert'
            oldPCName      = $null
            newPCName      = $null
            interfaceAlias = $null
        }
        $form.Close()
    })
    $btnExit.Add_Click({
        $script:_lanPrepMenuResult = [pscustomobject]@{
            action         = 'exit'
            oldPCName      = $null
            newPCName      = $null
            interfaceAlias = $null
        }
        $form.Close()
    })

    # Form-level Esc = Exit
    $form.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            $script:_lanPrepMenuResult = [pscustomobject]@{
                action         = 'exit'
                oldPCName      = $null
                newPCName      = $null
                interfaceAlias = $null
            }
            $form.Close()
        }
    })

    [void]$form.ShowDialog()
    $form.Dispose()

    return $script:_lanPrepMenuResult
}

# ============================================================
# Show-LanPrepPassphrasePrompt
# Modal WinForms dialog for entering the fabriq master passphrase.
# Verifies via Test-MasterPassphrase against $VerifyTokenPath.
# Returns the verified plaintext passphrase, or $null if cancelled.
# Lives in menu_form.ps1 (not a new file) so the BOM-tagged source
# can keep its Japanese labels intact under PS5.1.
# ============================================================
function global:Show-LanPrepPassphrasePrompt {
    param(
        [Parameter(Mandatory)][string]$VerifyTokenPath
    )

    $result = @{ Passphrase = $null }

    $form = New-Object System.Windows.Forms.Form
    Set-FormStyle -Form $form -Title 'Fabriq LAN-Prep - マスターパスフレーズ' -Width 480 -Height 220
    $form.MaximizeBox  = $false
    $form.MinimizeBox  = $false
    $form.StartPosition = 'CenterScreen'
    $form.KeyPreview   = $true

    $titleLabel = New-StyledLabel -Text 'マスターパスフレーズ入力' `
        -X 20 -Y 16 -Width 440 -Height 22 `
        -Font $script:fontBold -FgColor $script:bgAccent
    $form.Controls.Add($titleLabel)

    $hintLabel = New-StyledLabel `
        -Text 'hostlist の暗号化フィールドを復号するため、fabriq マスターパスフレーズを入力してください。' `
        -X 20 -Y 42 -Width 440 -Height 32 -FgColor $script:fgDim
    $form.Controls.Add($hintLabel)

    $ppBox = New-Object System.Windows.Forms.TextBox
    $ppBox.Location = New-Object System.Drawing.Point(20, 82)
    $ppBox.Size     = New-Object System.Drawing.Size(440, 24)
    $ppBox.UseSystemPasswordChar = $true
    Set-TextBoxStyle -TextBox $ppBox
    $form.Controls.Add($ppBox)

    $msgLabel = New-StyledLabel -Text '' `
        -X 20 -Y 112 -Width 440 -Height 20 -FgColor $script:bgDelete
    $form.Controls.Add($msgLabel)

    $btnCancel = New-StyledButton -Text 'キャンセル' `
        -X 240 -Y 140 -Width 100 -Height 32
    $form.Controls.Add($btnCancel)

    $btnOk = New-StyledButton -Text 'OK' `
        -X 350 -Y 140 -Width 110 -Height 32 -BgColor $script:bgAccent
    $btnOk.Font = $script:fontBold
    $form.Controls.Add($btnOk)

    $doSubmit = {
        $pp = $ppBox.Text
        if ([string]::IsNullOrWhiteSpace($pp)) {
            $msgLabel.Text = 'パスフレーズを入力してください。'
            return
        }
        if (-not (Test-Path -LiteralPath $VerifyTokenPath)) {
            $msgLabel.Text = ('verify token が見つかりません: {0}' -f $VerifyTokenPath)
            return
        }
        if (-not (Test-MasterPassphrase -Passphrase $pp -VerifyTokenPath $VerifyTokenPath)) {
            $msgLabel.Text = 'パスフレーズが正しくありません。再入力してください。'
            $ppBox.SelectAll()
            $ppBox.Focus()
            return
        }
        $result.Passphrase = $pp
        $form.Close()
    }

    $btnOk.Add_Click({ & $doSubmit })
    $btnCancel.Add_Click({
        $result.Passphrase = $null
        $form.Close()
    })
    $ppBox.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Return) {
            $btnOk.PerformClick()
            $_.Handled = $true
            $_.SuppressKeyPress = $true
        }
    })
    $form.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            $btnCancel.PerformClick()
        }
    })

    $form.Add_Shown({
        $form.Activate()
        $ppBox.Focus()
    })
    [void]$form.ShowDialog()
    $form.Dispose()

    return $result.Passphrase
}
