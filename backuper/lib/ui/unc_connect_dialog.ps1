# ============================================================
# FabriqBackUper - UNC Connect Dialog (Phase 2.6)
# Modal dialog: UNC path + Username + Password.
# On Connect, attempts New-PSDrive with credentials and probes
# reachability. Returns the connected UNC path on success,
# $null on cancel/failure.
# ============================================================

function Show-UncConnectDialog {
    param([string]$InitialPath = "")

    $script:_uncConnectResult = $null

    $dialog = New-Object System.Windows.Forms.Form
    Set-FormStyle -Form $dialog -Title "Connect to UNC share" -Width 540 -Height 270
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.StartPosition = "CenterParent"
    if ($null -ne $script:MainForm) { $dialog.Owner = $script:MainForm }

    # UNC Path
    $lblPath = New-StyledLabel -Text "UNC Path:" -X 20 -Y 24 -Width 110 -Height 20 -Font $script:fontBold
    $dialog.Controls.Add($lblPath)
    $txtPath = New-Object System.Windows.Forms.TextBox
    $txtPath.Location = New-Object System.Drawing.Point(140, 22)
    $txtPath.Size = New-Object System.Drawing.Size(370, 24)
    Set-TextBoxStyle -TextBox $txtPath
    $txtPath.Text = $InitialPath
    $dialog.Controls.Add($txtPath)

    $hintLbl = New-StyledLabel -Text "Example: \\nas01\migrate\backups" `
        -X 140 -Y 50 -Width 370 -Height 16 -FgColor $script:fgDim
    $dialog.Controls.Add($hintLbl)

    # Username
    $lblUser = New-StyledLabel -Text "Username:" -X 20 -Y 84 -Width 110 -Height 20 -Font $script:fontBold
    $dialog.Controls.Add($lblUser)
    $txtUser = New-Object System.Windows.Forms.TextBox
    $txtUser.Location = New-Object System.Drawing.Point(140, 82)
    $txtUser.Size = New-Object System.Drawing.Size(370, 24)
    Set-TextBoxStyle -TextBox $txtUser
    $dialog.Controls.Add($txtUser)

    $userHint = New-StyledLabel -Text "Format: DOMAIN\user  or  user@domain" `
        -X 140 -Y 110 -Width 370 -Height 16 -FgColor $script:fgDim
    $dialog.Controls.Add($userHint)

    # Password
    $lblPwd = New-StyledLabel -Text "Password:" -X 20 -Y 142 -Width 110 -Height 20 -Font $script:fontBold
    $dialog.Controls.Add($lblPwd)
    $txtPwd = New-Object System.Windows.Forms.TextBox
    $txtPwd.Location = New-Object System.Drawing.Point(140, 140)
    $txtPwd.Size = New-Object System.Drawing.Size(370, 24)
    Set-TextBoxStyle -TextBox $txtPwd
    $txtPwd.UseSystemPasswordChar = $true
    $dialog.Controls.Add($txtPwd)

    # Buttons
    $btnConnect = New-StyledButton -Text "Connect" -X 280 -Y 190 -Width 110 -Height 32 -BgColor $script:bgAccent
    $btnConnect.Font = $script:fontBold
    $dialog.Controls.Add($btnConnect)

    $btnCancel = New-StyledButton -Text "Cancel" -X 400 -Y 190 -Width 110 -Height 32
    $dialog.Controls.Add($btnCancel)

    $btnConnect.Add_Click({
        $uncPath = $txtPath.Text.Trim()
        $userName = $txtUser.Text.Trim()
        $pwdRaw = $txtPwd.Text

        if ([string]::IsNullOrWhiteSpace($uncPath)) {
            [System.Windows.Forms.MessageBox]::Show("Please enter a UNC path.", "Connect",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        if (-not $uncPath.StartsWith('\\')) {
            [System.Windows.Forms.MessageBox]::Show("Not a UNC path (must start with `\\`).", "Connect",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        if ([string]::IsNullOrWhiteSpace($userName) -or [string]::IsNullOrWhiteSpace($pwdRaw)) {
            [System.Windows.Forms.MessageBox]::Show("Please enter username and password.", "Connect",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        # Build credential
        $secPwd = ConvertTo-SecureString $pwdRaw -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential ($userName, $secPwd)

        # Map share root via New-PSDrive
        $shareRoot = if ($uncPath -match '^(\\\\[^\\]+\\[^\\]+)') { $Matches[1] } else { $uncPath }
        $driveName = "FabriqBU$([System.Diagnostics.Process]::GetCurrentProcess().Id)"
        try {
            if (Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue) {
                Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue
            }
            $null = New-PSDrive -Name $driveName -PSProvider FileSystem -Root $shareRoot `
                -Credential $cred -Scope Global -ErrorAction Stop

            # Probe
            if (Test-Path -LiteralPath $uncPath) {
                $script:_uncConnectResult = $uncPath
                $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
                $dialog.Close()
            }
            else {
                [System.Windows.Forms.MessageBox]::Show(
                    "Authenticated successfully but the path is not reachable:`n$uncPath",
                    "Connect", [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Connection failed:`n$($_.Exception.Message)",
                "Connect", [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    })

    $btnCancel.Add_Click({
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dialog.Close()
    })

    [void]$dialog.ShowDialog()

    if ($script:_uncConnectResult) {
        return $script:_uncConnectResult
    }
    return $null
}
