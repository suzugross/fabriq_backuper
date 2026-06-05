# ============================================================
# Fabriq BackUper - Session Setup Form
# ============================================================
# Unified initial dialog combining master passphrase entry +
# target host selection + Backup/Restore action choice. Mirrors
# the family pattern used by:
#   - apps/fabriq_operator/lib/session_form.ps1
#   - fabriq_checksheet/checksheet/lib/session_form.ps1
# but trims worker selection (backuper has no worker concept)
# and replaces the single "Start Session" button with two
# action buttons (Backup / Restore).
#
# Hostlist note: this form is shown BEFORE the master passphrase
# is verified, so ENC: encrypted values (OldPCname / NewPCname)
# are displayed as-is. The caller (main.ps1) is responsible for
# re-loading the hostlist with the verified passphrase after
# this form returns, then resolving the selected row by index.
#
# Returns hashtable:
#   Mode             : 'Backup' / 'Restore' (selected action)
#   SelectedHostIndex: index into $HostList (-1 if cancelled)
#   MasterPassphrase : verified plain-text passphrase
#   Cancelled        : $true if cancelled / Esc / window close
# ============================================================

function global:Show-BackuperSessionForm {
    param(
        [Parameter(Mandatory)][array]$HostList,
        [Parameter(Mandatory)][string]$VerifyTokenPath,
        [string]$CurrentPCName = $env:COMPUTERNAME,
        # v0.23.0: optional LAN migration profile. When provided, a banner is
        # shown under the title; otherwise layout is identical to v0.22.x.
        $MigrationProfile = $null,
        # v0.43.0 (P3): optional automation pre-selection passed from main.ps1
        # (derived from FABRIQ_BACKUPER_ROLE / FABRIQ_BACKUPER_AUTO_HOST env,
        # which LAN-Prep sets in P5). PreselectMode = '' / 'Backup' / 'Restore';
        # PreselectOldPcName = the host row's OldPCname to pre-select. The
        # passphrase is STILL typed by the operator (never passed via env).
        [string]$PreselectMode      = '',
        [string]$PreselectOldPcName = ''
    )

    $result = @{
        Mode              = ""
        SelectedHostIndex = -1
        MasterPassphrase  = ""
        Cancelled         = $true
    }

    # When a migration profile is loaded, reserve 24 px below the title for
    # a profile banner. Otherwise keep the original v0.22.x layout exactly.
    $hasProfile = ($null -ne $MigrationProfile)
    $formHeight = if ($hasProfile) { 534 } else { 510 }

    $form = New-Object System.Windows.Forms.Form
    Set-FormStyle -Form $form -Title 'Fabriq BackUper - セッション設定' -Width 620 -Height $formHeight
    $form.KeyPreview = $true

    $yPos = 15

    # ========================================
    # Title
    # ========================================
    $titleLabel = New-StyledLabel -Text 'Fabriq BackUper' `
        -X 20 -Y $yPos -Width 560 -Height 32 `
        -Font $script:fontTitle -FgColor $script:bgAccent
    $form.Controls.Add($titleLabel)
    $yPos += 38

    # ========================================
    # LAN migration profile banner (v0.23.0, optional)
    # Shown only when the caller supplied a profile object; absent profile
    # leaves $yPos at the same value as v0.22.x (full back-compat layout).
    # ========================================
    if ($hasProfile) {
        $bannerText = "LAN 移行 profile: $($MigrationProfile.profileName)"
        $bannerLabel = New-StyledLabel -Text $bannerText `
            -X 20 -Y $yPos -Width 560 -Height 20 `
            -Font $script:fontBold -FgColor $script:bgAccent
        $form.Controls.Add($bannerLabel)
        $yPos += 24
    }

    # ========================================
    # Host Selection Section
    # ========================================
    $hostLabel = New-StyledLabel -Text '対象ホスト' `
        -X 20 -Y $yPos -Width 560 -Height 20 `
        -Font $script:fontBold -FgColor $script:fgHeader
    $form.Controls.Add($hostLabel)
    $yPos += 24

    # ---- Search row (case-insensitive substring on OldPCname + NewPCname) ----
    $searchLabel = New-StyledLabel -Text '検索:' -X 20 -Y $yPos -Width 50 -Height 22 -FgColor $script:fgDim
    $form.Controls.Add($searchLabel)

    $searchBox = New-Object System.Windows.Forms.TextBox
    $searchBox.Location = New-Object System.Drawing.Point(75, $yPos)
    $searchBox.Size     = New-Object System.Drawing.Size(390, 22)
    Set-TextBoxStyle -TextBox $searchBox
    $form.Controls.Add($searchBox)

    $totalHosts = $HostList.Count
    $countLabel = New-StyledLabel -Text "$totalHosts / $totalHosts" `
        -X 470 -Y $yPos -Width 110 -Height 22 -FgColor $script:fgDim
    $countLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $form.Controls.Add($countLabel)
    $yPos += 30

    # ---- Host grid ----
    $hostGrid = New-Object System.Windows.Forms.DataGridView
    $hostGrid.Location = New-Object System.Drawing.Point(20, $yPos)
    $hostGrid.Size     = New-Object System.Drawing.Size(560, 160)
    Set-GridStyle -Grid $hostGrid

    $colOld = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colOld.Name = 'OldPCname'
    $colOld.HeaderText = 'OldPCname'
    $colOld.Width = 240
    $colOld.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::Automatic
    $hostGrid.Columns.Add($colOld) | Out-Null

    $colNew = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colNew.Name = 'NewPCname'
    $colNew.HeaderText = 'NewPCname'
    $colNew.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    $colNew.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::Automatic
    $hostGrid.Columns.Add($colNew) | Out-Null

    # Track auto-detect by object reference so it survives filter redraws
    # (DataGridView indices shift when Rows.Clear()+rebuild).
    # v0.44.0 (P4): role-aware COMPUTERNAME auto-detect (Backup/source ->
    # OldPCname first; Restore/target/manual -> NewPCname first then OldPCname
    # fallback). Shared with LAN-Prep via hostlist_reader.ps1.
    $autoSelectedHost = Resolve-HostByComputerName `
        -HostList $HostList -ComputerName $CurrentPCName -PreferMode $PreselectMode
    # v0.43.0 (P3): an explicit automation pre-selection wins over the
    # COMPUTERNAME auto-detect. PreselectOldPcName identifies the migration
    # pair by its OldPCname (on the target this is the source whose backup we
    # restore). Empty -> keep the COMPUTERNAME fallback above.
    if (-not [string]::IsNullOrWhiteSpace($PreselectOldPcName)) {
        foreach ($h in $HostList) {
            if ("$($h.OldPCname)" -eq $PreselectOldPcName) {
                $autoSelectedHost = $h
                break
            }
        }
    }

    # Live filter / refresh scriptblock
    $refreshHostGrid = {
        param([string]$searchText)
        $hostGrid.Rows.Clear()
        $needle = ''
        if ($searchText) { $needle = $searchText.Trim().ToLowerInvariant() }
        $matched = 0
        foreach ($h in $HostList) {
            $oldPc = "$($h.OldPCname)"
            $newPc = if ($h.PSObject.Properties.Name -contains 'NewPCname') { "$($h.NewPCname)" } else { '' }
            $visible = $true
            if ($needle) {
                $visible = ($oldPc.ToLowerInvariant().Contains($needle)) -or
                           ($newPc.ToLowerInvariant().Contains($needle))
            }
            if ($visible) {
                $rowIdx = $hostGrid.Rows.Add($oldPc, $newPc)
                # Store the source object reference + its absolute index in $HostList
                $hostGrid.Rows[$rowIdx].Tag = $h
                $matched++
            }
        }
        $countLabel.Text = "$matched / $totalHosts"
        if ($hostGrid.Rows.Count -eq 0) { return }
        $hostGrid.ClearSelection()
        # No search + auto-detected host => reselect that host
        if (-not $needle -and $null -ne $autoSelectedHost) {
            foreach ($r in $hostGrid.Rows) {
                if ([object]::ReferenceEquals($r.Tag, $autoSelectedHost)) {
                    $r.Selected = $true
                    try { $hostGrid.FirstDisplayedScrollingRowIndex = $r.Index } catch { }
                    return
                }
            }
        }
        # Otherwise pick first visible row
        $hostGrid.Rows[0].Selected = $true
        try { $hostGrid.FirstDisplayedScrollingRowIndex = 0 } catch { }
    }
    & $refreshHostGrid ''
    $form.Controls.Add($hostGrid)
    $yPos += 166

    # Auto-detect hint
    if ($null -ne $autoSelectedHost) {
        $autoLabel = New-StyledLabel `
            -Text "* 自動検出: $CurrentPCName" `
            -X 20 -Y $yPos -Width 560 -Height 18 `
            -FgColor ([System.Drawing.Color]::FromArgb(46, 125, 50))
        $form.Controls.Add($autoLabel)
    }
    $yPos += 22

    # ========================================
    # Master Passphrase Section
    # ========================================
    $ppLabel = New-StyledLabel -Text 'マスターパスフレーズ' `
        -X 20 -Y $yPos -Width 560 -Height 20 `
        -Font $script:fontBold -FgColor $script:fgHeader
    $form.Controls.Add($ppLabel)
    $yPos += 24

    $ppBox = New-Object System.Windows.Forms.TextBox
    $ppBox.Location = New-Object System.Drawing.Point(20, $yPos)
    $ppBox.Size     = New-Object System.Drawing.Size(560, 24)
    $ppBox.UseSystemPasswordChar = $true
    Set-TextBoxStyle -TextBox $ppBox
    $form.Controls.Add($ppBox)
    $yPos += 32

    # Message label (validation errors)
    $msgLabel = New-StyledLabel -Text '' `
        -X 20 -Y $yPos -Width 560 -Height 20 `
        -FgColor $script:bgDelete
    $form.Controls.Add($msgLabel)
    $yPos += 26

    # ========================================
    # Action buttons (left -> right): Quit / Backup (lavender) / Restore
    # (green). Backup precedes Restore in left-to-right reading order --
    # backup is the natural first step of the kitting workflow, restore
    # comes later. (v0.54.0: post-migration cleanup moved to the standalone
    # Fabriq Cleanup tool; no longer a session-start action here.)
    # ========================================
    $btnQuit = New-StyledButton -Text '終了' `
        -X 20 -Y $yPos -Width 80 -Height 34
    $form.Controls.Add($btnQuit)

    $btnBackup = New-StyledButton -Text 'バックアップ' `
        -X 115 -Y $yPos -Width 130 -Height 34 -BgColor $script:bgAccent
    $btnBackup.Font = $script:fontBold
    $form.Controls.Add($btnBackup)

    $btnRestore = New-StyledButton -Text 'リストア' `
        -X 258 -Y $yPos -Width 110 -Height 34 -BgColor $script:bgAdd
    $btnRestore.ForeColor = $script:fgWhite
    $btnRestore.Font = $script:fontBold
    $form.Controls.Add($btnRestore)

    # v0.43.0 (P3): which button the passphrase-box Enter triggers. Default is
    # Backup (unchanged); an automation pre-selection (role->mode) redirects it
    # to Restore so the operator just types the passphrase and presses Enter to
    # land on the right screen. Clicking any button still works as before.
    $defaultActionButton = $btnBackup
    if ($PreselectMode -eq 'Restore') { $defaultActionButton = $btnRestore }

    # v0.55.0 (t-0005): when LAN-Prep handed off a role (PreselectMode set), lock
    # the session to that role's action by disabling the OTHER button, so the
    # operator cannot mis-click into the wrong mode. source->Backup locks リストア;
    # target->Restore locks バックアップ. Manual launch (PreselectMode = '') leaves
    # both enabled. Enter still triggers $defaultActionButton (the enabled role
    # button); the role banner below explains the lock. FlatStyle keeps a custom
    # BackColor even when disabled, so we also recolor the locked button to a
    # neutral gray + dim text so it reads as clearly inactive (not just accent+grey).
    if ($PreselectMode -eq 'Backup' -or $PreselectMode -eq 'Restore') {
        $lockedBtn = if ($PreselectMode -eq 'Restore') { $btnBackup } else { $btnRestore }
        $lockedBtn.Enabled   = $false
        $lockedBtn.BackColor = $script:bgButton
        $lockedBtn.ForeColor = $script:fgDim
        $lockedBtn.Cursor    = [System.Windows.Forms.Cursors]::Default
    }

    # ========================================
    # Common submit scriptblock (parametrised by Mode)
    # ========================================
    $doSubmit = {
        param([string]$mode)

        # v0.43.0: validation messages are errors -> ensure the label is red
        # even if the initial P3 automation hint set it to info-green.
        $msgLabel.ForeColor = $script:bgDelete

        # Host resolution via Row.Tag (stable across sort/filter)
        if ($hostGrid.SelectedRows.Count -eq 0) {
            $msgLabel.Text = 'ホストを選択してください。'
            return
        }
        $selectedHostObj = $hostGrid.SelectedRows[0].Tag
        if ($null -eq $selectedHostObj) {
            $msgLabel.Text = '無効なホスト選択です。'
            return
        }

        # Passphrase validation
        $pp = $ppBox.Text
        if ([string]::IsNullOrWhiteSpace($pp)) {
            $msgLabel.Text = 'マスターパスフレーズを入力してください。'
            $ppBox.Focus()
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

        # Resolve selected host index in original $HostList by reference
        $idx = -1
        for ($i = 0; $i -lt $HostList.Count; $i++) {
            if ([object]::ReferenceEquals($HostList[$i], $selectedHostObj)) {
                $idx = $i
                break
            }
        }
        if ($idx -lt 0) {
            $msgLabel.Text = 'ホスト解決に失敗しました。'
            return
        }

        $result.Mode              = $mode
        $result.SelectedHostIndex = $idx
        $result.MasterPassphrase  = $pp
        $result.Cancelled         = $false
        $form.Close()
    }

    # Event handlers
    $btnBackup.Add_Click({  & $doSubmit 'Backup' })
    $btnRestore.Add_Click({ & $doSubmit 'Restore' })
    $btnQuit.Add_Click({
        $result.Cancelled = $true
        $form.Close()
    })

    # Search box: live filter + Esc clears + Enter focuses passphrase
    $searchBox.Add_TextChanged({
        $msgLabel.Text = ''
        & $refreshHostGrid $searchBox.Text
    })
    $searchBox.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            $searchBox.Text = ''
            $_.Handled = $true
            $_.SuppressKeyPress = $true
        } elseif ($_.KeyCode -eq [System.Windows.Forms.Keys]::Return) {
            $ppBox.Focus()
            $_.Handled = $true
            $_.SuppressKeyPress = $true
        }
    })

    # Passphrase Enter = the default action (Backup, or Restore under a v0.43.0
    # P3 automation pre-selection).
    $ppBox.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Return) {
            $defaultActionButton.PerformClick()
            $_.Handled = $true
            $_.SuppressKeyPress = $true
        }
    })

    # Form-level Esc = Quit
    $form.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            $btnQuit.PerformClick()
        }
    })

    # v0.43.0 (P3): automation pre-selection hint in the message area (replaced
    # by a validation message if entry fails). Only nudge a blind Enter when the
    # target host was reliably pre-selected ($autoSelectedHost set via explicit
    # AUTO_HOST match or COMPUTERNAME auto-detect); otherwise WARN so the
    # operator picks the host manually instead of submitting the first row.
    if ($PreselectMode -eq 'Backup' -or $PreselectMode -eq 'Restore') {
        $roleJp = if ($PreselectMode -eq 'Restore') { '移行先 → リストア' } else { '移行元 → バックアップ' }
        if ($null -ne $autoSelectedHost) {
            # Info-green (same as the COMPUTERNAME auto-detect hint), not error-red.
            $msgLabel.ForeColor = [System.Drawing.Color]::FromArgb(46, 125, 50)
            $msgLabel.Text = "自動連携: $roleJp。対象ホストを選択済み。パスフレーズを入力して Enter。"
        } else {
            # Mode known but host NOT confidently identified -> keep the red
            # error color and tell the operator to select the host manually.
            $msgLabel.Text = "自動連携: $roleJp。ただし対象ホストを自動特定できません。ホストを手動で選択してください。"
        }
    }

    $form.Add_Shown({
        $form.Activate()
        $ppBox.Focus()
    })
    [void]$form.ShowDialog()
    $form.Dispose()

    return $result
}
