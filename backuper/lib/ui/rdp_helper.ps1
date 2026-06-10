# ============================================================
# Fabriq BackUper - Remote Desktop helper (t-0004, Phase 1)
# Launches Windows mstsc.exe to the migration PEER (source <-> target),
# reusing the share credentials. Credentials are HYBRID:
#   - extended hostlist ENC: password -> decrypted on demand (warm session) and
#     injected via cmdkey for a prompt-free connect;
#   - otherwise the operator types the password (mstsc's own prompt).
# cmdkey-injected creds are read by mstsc ONLY at connect time, so they are
# deleted AFTER the connect: polled on the mstsc process exiting (Timer) and
# swept on app close. Plaintext passwords are never cached.
# ============================================================

# Tracking of injected TERMSRV creds awaiting cleanup: list of @{ Target; Proc }.
$script:RdpTracked = @()

function Get-RdpPeerAddress {
    # The migration PEER's address from the loaded profile + this PC's role:
    #   source -> network.target.ipAddress ; target -> network.source.ipAddress ;
    #   else host of backupRootUnc ; else '' (operator types it in the dialog).
    if ($null -eq $script:MigrationProfile) { return '' }
    $prof = $script:MigrationProfile
    $role = "$env:FABRIQ_BACKUPER_ROLE".Trim().ToLower()
    if ([string]::IsNullOrWhiteSpace($role) -and $null -ne $prof.share) {
        $role = "$($prof.share.hostRole)".Trim().ToLower()
    }
    if ($null -ne $prof.network) {
        if ($role -eq 'source' -and $null -ne $prof.network.target) { return "$($prof.network.target.ipAddress)".Trim() }
        if ($role -eq 'target' -and $null -ne $prof.network.source) { return "$($prof.network.source.ipAddress)".Trim() }
    }
    if ($null -ne $prof.backuper) {
        $unc = "$($prof.backuper.backupRootUnc)"
        if ($unc -match '^\\\\([^\\]+)\\') { return $Matches[1] }
    }
    return ''
}

function Get-RdpSelfAddress {
    # This PC's own migration-LAN IP (for the self-connect guard). '' if unknown.
    if ($null -eq $script:MigrationProfile) { return '' }
    $prof = $script:MigrationProfile
    $role = "$env:FABRIQ_BACKUPER_ROLE".Trim().ToLower()
    if ([string]::IsNullOrWhiteSpace($role) -and $null -ne $prof.share) {
        $role = "$($prof.share.hostRole)".Trim().ToLower()
    }
    if ($null -ne $prof.network) {
        if ($role -eq 'source' -and $null -ne $prof.network.source) { return "$($prof.network.source.ipAddress)".Trim() }
        if ($role -eq 'target' -and $null -ne $prof.network.target) { return "$($prof.network.target.ipAddress)".Trim() }
    }
    return ''
}

function Get-RdpPresetUsername {
    # Best-guess username: extended hostlist UncUsername, else profile uncUsername.
    $u = ''
    if (Get-Command -Name Get-PresetUncUsername -ErrorAction SilentlyContinue) {
        try { $u = "$(Get-PresetUncUsername)".Trim() } catch { $u = '' }
    }
    if ([string]::IsNullOrWhiteSpace($u) -and $null -ne $script:MigrationProfile -and $null -ne $script:MigrationProfile.backuper) {
        $u = "$($script:MigrationProfile.backuper.uncUsername)".Trim()
    }
    return $u
}

function Get-RdpPresetPassword {
    # On-demand decrypt of the extended-hostlist ENC: password for the current host
    # (mirrors Connect-UncFromExtendedHostlist). Returns '' when unavailable so the
    # operator types it. Never caches plaintext; subject to the same strict gate.
    try {
        if ([string]::IsNullOrWhiteSpace($global:FabriqMasterPassphrase)) { return '' }
        if ($null -eq $script:CurrentHost) { return '' }
        if (-not (Get-Command -Name Get-ExtendedHostEntry -ErrorAction SilentlyContinue)) { return '' }
        $entry = Get-ExtendedHostEntry -FabriqHost $script:CurrentHost
        if ($null -eq $entry) { return '' }
        $encPw = if ($entry.PSObject.Properties.Name -contains 'UncPassword') { "$($entry.UncPassword)" } else { '' }
        if ([string]::IsNullOrWhiteSpace($encPw) -or -not $encPw.StartsWith('ENC:')) { return '' }
        $plain = Unprotect-FabriqValue -EncryptedValue $encPw -Passphrase $global:FabriqMasterPassphrase
        if ([string]::IsNullOrEmpty($plain)) { return '' }
        return $plain
    }
    catch { return '' }
}

function Test-RdpReachable {
    # Quick TCP probe of <Target>:3389 with a short timeout, so the operator gets a
    # clear "RDP unreachable" hint instead of mstsc's slow generic failure. Best-effort.
    param([string]$Target, [int]$TimeoutMs = 1500)
    if ([string]::IsNullOrWhiteSpace($Target)) { return $false }
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($Target, 3389, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($ok -and $client.Connected) { return $true }
        return $false
    }
    catch { return $false }
    finally { if ($null -ne $client) { try { $client.Close() } catch {} } }
}

function Test-RdpRevertDone {
    # H4: has the migration-LAN revert already run? (the peer IP may then be stale)
    try {
        $snapPath = ''
        $prof = $script:MigrationProfile
        if ($null -ne $prof -and $null -ne $prof.rollback -and `
            -not [string]::IsNullOrWhiteSpace("$($prof.rollback.snapshotPath)") -and `
            "$($prof.rollback.snapshotPath)" -ne '<AUTO>') {
            $snapPath = "$($prof.rollback.snapshotPath)"
        }
        elseif (-not [string]::IsNullOrWhiteSpace($script:BackuperRoot)) {
            $snapPath = Join-Path (Join-Path $script:BackuperRoot '_lanprep') '_rollback_snapshot.json'
        }
        if ([string]::IsNullOrWhiteSpace($snapPath)) { return $false }
        $doneMarker = Join-Path (Split-Path -Parent $snapPath) '_revert_done.json'
        return [bool](Test-Path -LiteralPath $doneMarker)
    }
    catch { return $false }
}

function Remove-RdpCred {
    # Delete a previously injected TERMSRV credential (safe to call after connect).
    param([string]$Target)
    if ([string]::IsNullOrWhiteSpace($Target)) { return }
    try {
        Start-Process -FilePath 'cmdkey.exe' -ArgumentList "/delete:TERMSRV/$Target" `
            -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue | Out-Null
    }
    catch { }
}

function Update-RdpCleanup {
    # Timer tick: delete the cmdkey cred for any tracked mstsc that has exited.
    if (@($script:RdpTracked).Count -eq 0) { return }
    $remain = @()
    foreach ($t in @($script:RdpTracked)) {
        # null Proc (no handle): keep tracked so it is only cleaned by the close
        # sweep (post-connect) -- never deleted early while mstsc may be authenticating.
        if ($null -eq $t.Proc) { $remain += $t; continue }
        $exited = $true
        try { $exited = [bool]$t.Proc.HasExited } catch { $exited = $true }
        if ($exited) { Remove-RdpCred -Target $t.Target } else { $remain += $t }
    }
    $script:RdpTracked = @($remain)
}

function Clear-RdpCleanupAll {
    # App-close sweep: delete every tracked TERMSRV cred. Safe -- mstsc reads the
    # cred only at connect time, so by app close any live session already authed.
    foreach ($t in @($script:RdpTracked)) { Remove-RdpCred -Target $t.Target }
    $script:RdpTracked = @()
}

function Invoke-RemoteDesktop {
    # Pure launcher: optionally cmdkey-inject (user+pass), then start mstsc /v:<Target>.
    # Tracks the injected target for post-connect cleanup. Returns $true if mstsc started.
    param([string]$Target, [string]$Username, [string]$Password)
    if ([string]::IsNullOrWhiteSpace($Target)) { return $false }

    $injected = $false
    if (-not [string]::IsNullOrWhiteSpace($Username) -and -not [string]::IsNullOrWhiteSpace($Password)) {
        try {
            $p = Start-Process -FilePath 'cmdkey.exe' `
                -ArgumentList "/generic:TERMSRV/$Target", "/user:$Username", "/pass:$Password" `
                -WindowStyle Hidden -Wait -PassThru
            if ($null -ne $p -and $p.ExitCode -eq 0) { $injected = $true }
        }
        catch { $injected = $false }
    }

    $proc = $null
    try {
        $proc = Start-Process -FilePath 'mstsc.exe' -ArgumentList "/v:$Target" -PassThru
    }
    catch {
        if ($injected) { Remove-RdpCred -Target $Target }
        Show-Error "Remote Desktop: failed to launch mstsc for $Target : $($_.Exception.Message)"
        return $false
    }

    # Track the injected cred for post-connect cleanup even if -PassThru returned no
    # handle (rare: Start-Process can succeed yet yield $null). A null Proc is kept
    # until the app-close sweep -- never deleted early while mstsc may still be
    # authenticating -- so the TERMSRV cred can never be orphaned in Credential Manager.
    if ($injected) {
        $script:RdpTracked += @{ Target = $Target; Proc = $proc }
    }
    $mode = if ($injected) { 'injected' } else { 'manual' }
    Show-Info "Remote Desktop: launched mstsc to $Target (creds: $mode)."
    return $true
}

function Show-RdpConnectDialog {
    # Editable connect dialog (target / username / password) prefilled with best
    # guesses. On 接続: self-guard + quick 3389 probe (confirm if unreachable) ->
    # Invoke-RemoteDesktop. Returns $true if a session was launched, else $false.
    param(
        [string]$InitialTarget = "",
        [string]$InitialUsername = "",
        [string]$InitialPassword = "",
        [string]$Note = ""
    )

    $script:_rdpConnectResult = $false

    $dialog = New-Object System.Windows.Forms.Form
    Set-FormStyle -Form $dialog -Title "リモートデスクトップ接続" -Width 540 -Height 300
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.StartPosition = "CenterParent"
    if ($null -ne $script:MainForm) { $dialog.Owner = $script:MainForm }

    $lblTarget = New-StyledLabel -Text "接続先:" -X 20 -Y 24 -Width 110 -Height 20 -Font $script:fontBold
    $dialog.Controls.Add($lblTarget)
    $txtTarget = New-Object System.Windows.Forms.TextBox
    $txtTarget.Location = New-Object System.Drawing.Point(140, 22)
    $txtTarget.Size = New-Object System.Drawing.Size(370, 24)
    Set-TextBoxStyle -TextBox $txtTarget
    $txtTarget.Text = $InitialTarget
    $dialog.Controls.Add($txtTarget)

    $hintLbl = New-StyledLabel -Text "移行先の IP またはホスト名 (例: 192.168.250.20)" `
        -X 140 -Y 50 -Width 370 -Height 16 -FgColor $script:fgDim
    $dialog.Controls.Add($hintLbl)

    $lblUser = New-StyledLabel -Text "ユーザ名:" -X 20 -Y 84 -Width 110 -Height 20 -Font $script:fontBold
    $dialog.Controls.Add($lblUser)
    $txtUser = New-Object System.Windows.Forms.TextBox
    $txtUser.Location = New-Object System.Drawing.Point(140, 82)
    $txtUser.Size = New-Object System.Drawing.Size(370, 24)
    Set-TextBoxStyle -TextBox $txtUser
    $txtUser.Text = $InitialUsername
    $dialog.Controls.Add($txtUser)

    $userHint = New-StyledLabel -Text "共有フォルダと同じ資格情報を流用 (空欄可: mstsc 側で入力)" `
        -X 140 -Y 110 -Width 370 -Height 16 -FgColor $script:fgDim
    $dialog.Controls.Add($userHint)

    $lblPwd = New-StyledLabel -Text "パスワード:" -X 20 -Y 142 -Width 110 -Height 20 -Font $script:fontBold
    $dialog.Controls.Add($lblPwd)
    $txtPwd = New-Object System.Windows.Forms.TextBox
    $txtPwd.Location = New-Object System.Drawing.Point(140, 140)
    $txtPwd.Size = New-Object System.Drawing.Size(370, 24)
    Set-TextBoxStyle -TextBox $txtPwd
    $txtPwd.UseSystemPasswordChar = $true
    $txtPwd.Text = $InitialPassword
    $dialog.Controls.Add($txtPwd)

    if (-not [string]::IsNullOrWhiteSpace($Note)) {
        $noteLbl = New-StyledLabel -Text $Note -X 20 -Y 172 -Width 490 -Height 16 -FgColor $script:bgDelete
        $dialog.Controls.Add($noteLbl)
    }

    $btnConnect = New-StyledButton -Text "接続" -X 280 -Y 220 -Width 110 -Height 32 -BgColor $script:bgAccent
    $btnConnect.Font = $script:fontBold
    $dialog.Controls.Add($btnConnect)

    $btnCancel = New-StyledButton -Text "キャンセル" -X 400 -Y 220 -Width 110 -Height 32
    $dialog.Controls.Add($btnCancel)

    $btnConnect.Add_Click({
        $target = $txtTarget.Text.Trim()
        $user   = $txtUser.Text.Trim()
        $pw    = $txtPwd.Text
        if ([string]::IsNullOrWhiteSpace($target)) {
            [System.Windows.Forms.MessageBox]::Show("接続先を入力してください。", "リモートデスクトップ",
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        $self = Get-RdpSelfAddress
        if ((-not [string]::IsNullOrWhiteSpace($self) -and $target -eq $self) -or `
            $target -eq '127.0.0.1' -or $target.ToLower() -eq 'localhost') {
            [System.Windows.Forms.MessageBox]::Show("自分自身には接続できません。", "リモートデスクトップ",
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        # H5: quick 3389 reachability probe (wait cursor); confirm-continue if unreachable.
        $dialog.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $reachable = $false
        try { $reachable = Test-RdpReachable -Target $target } finally { $dialog.Cursor = [System.Windows.Forms.Cursors]::Default }
        if (-not $reachable) {
            $ans = [System.Windows.Forms.MessageBox]::Show(
                ("接続先のリモートデスクトップ ポート (3389) に到達できませんでした。`n" +
                 "移行先で RDP が無効、またはファイアウォールで遮断されている可能性があります。`n`n" +
                 "このまま接続を試みますか?"),
                "リモートデスクトップ",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        if (Invoke-RemoteDesktop -Target $target -Username $user -Password $pw) {
            $script:_rdpConnectResult = $true
            $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dialog.Close()
        }
    })

    $btnCancel.Add_Click({
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dialog.Close()
    })

    # If target + username are prefilled, jump focus to the password field.
    if (-not [string]::IsNullOrWhiteSpace($InitialTarget) -and -not [string]::IsNullOrWhiteSpace($InitialUsername)) {
        $dialog.Add_Shown({ $txtPwd.Focus() })
    }

    [void]$dialog.ShowDialog()
    return [bool]$script:_rdpConnectResult
}

function Start-RemoteDesktopFlow {
    # main_form header button handler: resolve the peer + prefill creds, then show
    # the editable connect dialog (works on source/target/manual, any time).
    $peer = Get-RdpPeerAddress
    $user = Get-RdpPresetUsername
    $pw  = Get-RdpPresetPassword
    $note = ''
    if (Test-RdpRevertDone) {
        $note = '注意: 移行ネットワークは復元済みです。相手の IP が変わっている可能性があります。'
    }
    [void](Show-RdpConnectDialog -InitialTarget $peer -InitialUsername $user -InitialPassword $pw -Note $note)
    $pw = $null   # drop the transient plaintext from this scope promptly
}
