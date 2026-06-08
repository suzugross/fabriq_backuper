# ============================================================
# FabriqBackUper - UNC Connect Dialog (Phase 2.6)
# Modal dialog: UNC path + Username + Password.
# On Connect, attempts New-PSDrive with credentials and probes
# reachability. Returns the connected UNC path on success,
# $null on cancel/failure.
# ============================================================

function Show-UncConnectDialog {
    param(
        [string]$InitialPath = "",
        # v0.23.0: optional preset for the Username field. When supplied
        # along with InitialPath, focus is moved to the password field on
        # dialog show so the operator only needs to type the password.
        [string]$InitialUsername = ""
    )

    $script:_uncConnectResult = $null

    $dialog = New-Object System.Windows.Forms.Form
    Set-FormStyle -Form $dialog -Title "UNC 共有へ接続" -Width 540 -Height 270
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.StartPosition = "CenterParent"
    if ($null -ne $script:MainForm) { $dialog.Owner = $script:MainForm }

    # UNC Path
    $lblPath = New-StyledLabel -Text "UNC パス:" -X 20 -Y 24 -Width 110 -Height 20 -Font $script:fontBold
    $dialog.Controls.Add($lblPath)
    $txtPath = New-Object System.Windows.Forms.TextBox
    $txtPath.Location = New-Object System.Drawing.Point(140, 22)
    $txtPath.Size = New-Object System.Drawing.Size(370, 24)
    Set-TextBoxStyle -TextBox $txtPath
    $txtPath.Text = $InitialPath
    $dialog.Controls.Add($txtPath)

    $hintLbl = New-StyledLabel -Text "例: \\nas01\migrate\backups" `
        -X 140 -Y 50 -Width 370 -Height 16 -FgColor $script:fgDim
    $dialog.Controls.Add($hintLbl)

    # Username
    $lblUser = New-StyledLabel -Text "ユーザ名:" -X 20 -Y 84 -Width 110 -Height 20 -Font $script:fontBold
    $dialog.Controls.Add($lblUser)
    $txtUser = New-Object System.Windows.Forms.TextBox
    $txtUser.Location = New-Object System.Drawing.Point(140, 82)
    $txtUser.Size = New-Object System.Drawing.Size(370, 24)
    Set-TextBoxStyle -TextBox $txtUser
    $txtUser.Text = $InitialUsername
    $dialog.Controls.Add($txtUser)

    $userHint = New-StyledLabel -Text "書式: DOMAIN\user  または  user@domain" `
        -X 140 -Y 110 -Width 370 -Height 16 -FgColor $script:fgDim
    $dialog.Controls.Add($userHint)

    # Password
    $lblPwd = New-StyledLabel -Text "パスワード:" -X 20 -Y 142 -Width 110 -Height 20 -Font $script:fontBold
    $dialog.Controls.Add($lblPwd)
    $txtPwd = New-Object System.Windows.Forms.TextBox
    $txtPwd.Location = New-Object System.Drawing.Point(140, 140)
    $txtPwd.Size = New-Object System.Drawing.Size(370, 24)
    Set-TextBoxStyle -TextBox $txtPwd
    $txtPwd.UseSystemPasswordChar = $true
    $dialog.Controls.Add($txtPwd)

    # Buttons
    $btnConnect = New-StyledButton -Text "接続" -X 280 -Y 190 -Width 110 -Height 32 -BgColor $script:bgAccent
    $btnConnect.Font = $script:fontBold
    $dialog.Controls.Add($btnConnect)

    $btnCancel = New-StyledButton -Text "キャンセル" -X 400 -Y 190 -Width 110 -Height 32
    $dialog.Controls.Add($btnCancel)

    $btnConnect.Add_Click({
        $uncPath = $txtPath.Text.Trim()
        $userName = $txtUser.Text.Trim()
        $pwdRaw = $txtPwd.Text

        if ([string]::IsNullOrWhiteSpace($uncPath)) {
            [System.Windows.Forms.MessageBox]::Show("UNC パスを入力してください。", "接続",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        if (-not $uncPath.StartsWith('\\')) {
            [System.Windows.Forms.MessageBox]::Show("UNC パスではありません (`\\` で始まる必要があります)。", "接続",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        if ([string]::IsNullOrWhiteSpace($userName) -or [string]::IsNullOrWhiteSpace($pwdRaw)) {
            [System.Windows.Forms.MessageBox]::Show("ユーザ名とパスワードを入力してください。", "接続",
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
        # v0.67.0 (t-0014): wait cursor during New-PSDrive + Test-Path (the network
        # connect can stall for seconds on a slow/unreachable share).
        $dialog.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
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
                    "認証は成功しましたがパスに接続できません:`n$uncPath",
                    "接続", [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "接続失敗:`n$($_.Exception.Message)",
                "接続", [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
        finally {
            $dialog.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })

    $btnCancel.Add_Click({
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dialog.Close()
    })

    # v0.23.0: when both path and username are pre-filled (typical when
    # a migration profile is loaded), jump focus straight to the password
    # field so the operator can immediately type credentials.
    if (-not [string]::IsNullOrWhiteSpace($InitialPath) -and `
        -not [string]::IsNullOrWhiteSpace($InitialUsername)) {
        $dialog.Add_Shown({ $txtPwd.Focus() })
    }

    [void]$dialog.ShowDialog()

    if ($script:_uncConnectResult) {
        return $script:_uncConnectResult
    }
    return $null
}
