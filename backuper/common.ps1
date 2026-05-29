# ============================================================
# Fabriq BackUper - Common Function Library (Stage 1 prototype)
#
# Vendored from fabriq kernel/common.ps1 + fabriq_checksheet/checksheet
# /common.ps1. This file has NO runtime dependency on fabriq main; it is
# loaded by backuper/main.ps1 from $PSScriptRoot. Fabriq main is consulted
# only for hostlist.csv / passphrase_verify.txt / KERNEL_VERSION at runtime
# via Find-FabriqRoot auto-discovery.
#
# Vendor scope (15 functions):
#   Console window  : Hide-ConsoleWindow, Show-ConsoleWindow
#   Display         : Show-Separator, Show-Info, Show-Success, Show-Warning,
#                     Show-Error, Show-Skip
#   Crypto          : Unprotect-FabriqValue, Test-MasterPassphrase
#   CSV             : Import-CsvSafe, Test-CsvColumns, Import-ModuleCsv
#   Admin / HKCU    : Test-AdminPrivilege, _Resolve-LoggedOnUser,
#                     Resolve-HkcuRoot
#   Discovery       : Find-FabriqRoot
#
# Sources:
#   checksheet      : 9 functions (Show-* x6, Unprotect-FabriqValue,
#                     Test-MasterPassphrase, Import-CsvSafe, Find-FabriqRoot,
#                     Hide/Show-ConsoleWindow)
#   kernel/common   : 5 functions (Test-AdminPrivilege, _Resolve-LoggedOnUser,
#                     Resolve-HkcuRoot, Test-CsvColumns, Import-ModuleCsv)
# ============================================================

# ============================================================
# Console Window Management (verbatim from checksheet/common.ps1)
# ============================================================
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class ConsoleFocus {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
'@ -ErrorAction SilentlyContinue

function global:Hide-ConsoleWindow {
    $hwnd = [ConsoleFocus]::GetConsoleWindow()
    if ($hwnd -ne [IntPtr]::Zero) {
        [ConsoleFocus]::ShowWindow($hwnd, 0) | Out-Null
    }
}

function global:Show-ConsoleWindow {
    $hwnd = [ConsoleFocus]::GetConsoleWindow()
    if ($hwnd -ne [IntPtr]::Zero) {
        [ConsoleFocus]::ShowWindow($hwnd, 5) | Out-Null
        [ConsoleFocus]::SetForegroundWindow($hwnd) | Out-Null
    }
}

# ============================================================
# Console Display Functions (verbatim from checksheet/common.ps1
# which were originally transcribed from kernel/common.ps1)
# ============================================================

function global:Show-Separator {
    Write-Host "========================================" -ForegroundColor Cyan
}

function global:Show-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function global:Show-Success {
    param([string]$Message)
    Write-Host "[SUCCESS] $Message" -ForegroundColor Green
}

function global:Show-Warning {
    param([string]$Message)
    Write-Host "[WARNING] $Message" -ForegroundColor Yellow
}

function global:Show-Error {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function global:Show-Skip {
    param([string]$Message)
    Write-Host "[SKIP] $Message" -ForegroundColor DarkGray
}

# ============================================================
# Crypto / Passphrase (verbatim from checksheet/common.ps1)
#
# AES-256-CBC decryption of "ENC:..." values, parameters must match
# fabriq main's CryptoPoC byte-for-byte (fixed salt, 100k PBKDF2 iters).
# ============================================================

function global:Unprotect-FabriqValue {
    param(
        [Parameter(Mandatory)][string]$EncryptedValue,
        [Parameter(Mandatory)][string]$Passphrase
    )

    # Pass-through if not ENC-prefixed (plain value).
    if (-not $EncryptedValue.StartsWith('ENC:')) {
        return $EncryptedValue
    }
    $base64 = $EncryptedValue.Substring(4)

    # Crypto parameters - must match fabriq main exactly.
    $salt       = [System.Text.Encoding]::UTF8.GetBytes("fabriq-fixed-salt-2024")
    $iterations = 100000
    $keySize    = 32   # AES-256
    $ivSize     = 16   # AES block size

    # PBKDF2-HMAC-SHA256 key derivation
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
        $Passphrase, $salt, $iterations,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256
    )
    $key = $kdf.GetBytes($keySize)
    $iv  = $kdf.GetBytes($ivSize)
    $kdf.Dispose()

    # AES-256-CBC decryption
    $aes         = [System.Security.Cryptography.Aes]::Create()
    $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key     = $key
    $aes.IV      = $iv

    $cipherBytes = [Convert]::FromBase64String($base64)
    $decryptor   = $aes.CreateDecryptor()
    $ms          = New-Object System.IO.MemoryStream(, $cipherBytes)
    $cs          = New-Object System.Security.Cryptography.CryptoStream(
                       $ms, $decryptor,
                       [System.Security.Cryptography.CryptoStreamMode]::Read)
    $sr          = New-Object System.IO.StreamReader($cs, [System.Text.Encoding]::UTF8)
    $plainText   = $sr.ReadToEnd()

    $sr.Dispose(); $cs.Dispose(); $ms.Dispose(); $decryptor.Dispose(); $aes.Dispose()
    return $plainText
}

function global:Test-MasterPassphrase {
    param(
        [Parameter(Mandatory)][string]$Passphrase,
        [Parameter(Mandatory)][string]$VerifyTokenPath
    )
    $VERIFY_PLAINTEXT = "surkitinisme"

    $token = (Get-Content -Path $VerifyTokenPath -Raw -ErrorAction Stop).Trim()
    if ([string]::IsNullOrWhiteSpace($token) -or -not $token.StartsWith('ENC:')) {
        Show-Warning "Verification token file is invalid."
        return $false
    }
    try {
        $decrypted = Unprotect-FabriqValue -EncryptedValue $token -Passphrase $Passphrase
        return ($decrypted -eq $VERIFY_PLAINTEXT)
    }
    catch {
        return $false
    }
}

# ============================================================
# CSV Functions
#   Import-CsvSafe     : verbatim from checksheet
#   Test-CsvColumns    : verbatim from kernel/common.ps1
#   Import-ModuleCsv   : vendored from kernel/common.ps1; telemetry
#                        block stripped (Write-TelemetryEvent is not
#                        vendored)
# ============================================================

function global:Import-CsvSafe {
    param(
        [string]$Path,
        [string]$Description = "CSV",
        [string]$FileEncoding = "Default"
    )

    if (-not (Test-Path $Path)) {
        Show-Error "${Description} not found: $Path"
        return $null
    }

    try {
        $data = @(Import-Csv -Path $Path -Encoding $FileEncoding)
        if ($data.Count -eq 0) {
            Show-Warning "${Description} has no data: $Path"
            return @()
        }
        return $data
    }
    catch {
        Show-Error "Failed to load ${Description}: $_"
        return $null
    }
}

function global:Test-CsvColumns {
    param(
        [array]$CsvData,
        [string[]]$RequiredColumns,
        [string]$CsvName = "CSV"
    )

    if ($null -eq $CsvData -or $CsvData.Count -eq 0) {
        return $false
    }

    $firstRow = $CsvData[0]
    $existingColumns = $firstRow.PSObject.Properties.Name

    $missingColumns = @()
    foreach ($col in $RequiredColumns) {
        if ($col -notin $existingColumns) {
            $missingColumns += $col
        }
    }

    if ($missingColumns.Count -gt 0) {
        Show-Error "${CsvName} is missing required columns: $($missingColumns -join ', ')"
        return $false
    }

    return $true
}

function global:Import-ModuleCsv {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [switch]$FilterEnabled,
        [string[]]$RequiredColumns,
        [string]$Segment = $env:FABRIQ_SEGMENT
    )

    $allItems = Import-CsvSafe -Path $Path -Description ([System.IO.Path]::GetFileName($Path))
    if ($null -eq $allItems) { return $null }
    if ($allItems.Count -eq 0) { return $null }

    # Transparent decryption: decrypt ENC: prefixed values if master passphrase is available
    if (-not [string]::IsNullOrWhiteSpace($global:FabriqMasterPassphrase)) {
        foreach ($item in $allItems) {
            foreach ($prop in $item.PSObject.Properties) {
                if ($prop.Value -is [string] -and $prop.Value.StartsWith('ENC:')) {
                    try {
                        $prop.Value = Unprotect-FabriqValue -EncryptedValue $prop.Value -Passphrase $global:FabriqMasterPassphrase
                    }
                    catch {
                        Show-Warning "Failed to decrypt field '$($prop.Name)' in $([System.IO.Path]::GetFileName($Path)): $_"
                    }
                }
            }
        }
    }

    if ($RequiredColumns) {
        if (-not (Test-CsvColumns -CsvData $allItems -RequiredColumns $RequiredColumns -CsvName ([System.IO.Path]::GetFileName($Path)))) {
            return $null
        }
    }

    $totalCount = @($allItems).Count

    if ($FilterEnabled) {
        $filtered = @($allItems | Where-Object { $_.Enabled -eq "1" })
        if ($filtered.Count -eq 0) {
            Show-Skip "No enabled entries in $([System.IO.Path]::GetFileName($Path))"
            return @()
        }
        $allItems = $filtered
    }

    # Segment filtering: strict match (empty matches empty, value matches value)
    $csvColumns = $allItems[0].PSObject.Properties.Name
    if ('Segment' -in $csvColumns) {
        $effectiveSegment = if ([string]::IsNullOrWhiteSpace($Segment)) { "" } else { $Segment.Trim() }
        $beforeCount = $allItems.Count
        $allItems = @($allItems | Where-Object {
            $rowSegment = if ([string]::IsNullOrWhiteSpace($_.Segment)) { "" } else { $_.Segment.Trim() }
            $rowSegment -eq $effectiveSegment
        })
        if (-not [string]::IsNullOrWhiteSpace($effectiveSegment)) {
            Show-Info "Segment filter [$effectiveSegment]: $($allItems.Count) of $beforeCount entries matched"
        }
        if ($allItems.Count -eq 0) {
            $segLabel = if ($effectiveSegment -eq "") { "(default)" } else { "'$effectiveSegment'" }
            Show-Skip "No entries matched Segment $segLabel in $([System.IO.Path]::GetFileName($Path))"
            return @()
        }
    }

    if ($FilterEnabled) {
        Show-Info "Loaded $($allItems.Count) enabled entries (total: $totalCount)"
    }

    # NOTE: kernel/common.ps1's Write-TelemetryEvent csv.load block is
    # intentionally omitted; backuper does not participate in fabriq main
    # telemetry pipeline.

    return $allItems
}

# ============================================================
# Admin Privilege Check (verbatim from kernel/common.ps1:4134-4138)
# ============================================================

function global:Test-AdminPrivilege {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ============================================================
# Logged-On User Resolution (cache + HKCU redirection)
#
# When running elevated (Run As Administrator) from a different user
# account, HKCU: and %USERPROFILE% point to the admin's profile.
# Resolve-HkcuRoot returns the correct hive path for the logged-on
# user using HKU:\<SID> when redirection is required.
#
# Vendored verbatim from kernel/common.ps1:4147-4280.
# ============================================================

# Cache for logged-on user info (populated on first call)
$script:_LoggedOnUserProfile = $null
$script:_LoggedOnUserResolved = $false
$script:_LoggedOnUserSid = $null
$script:_LoggedOnUserName = $null

# Internal helper: detect logged-on user and populate cache
function _Resolve-LoggedOnUser {
    if ($script:_LoggedOnUserResolved) { return }
    $script:_LoggedOnUserResolved = $true
    try {
        if (-not (Test-AdminPrivilege)) { return }
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $loggedOnUser = $cs.UserName
        if ([string]::IsNullOrWhiteSpace($loggedOnUser)) { return }
        $username = $loggedOnUser.Split('\')[-1]
        $currentUser = [System.Environment]::UserName
        # Only apply correction when elevated user differs from logged-on user
        if ($username -eq $currentUser) { return }
        $sid = (New-Object System.Security.Principal.NTAccount($loggedOnUser)).Translate(
            [System.Security.Principal.SecurityIdentifier]
        ).Value
        $script:_LoggedOnUserSid = $sid
        $script:_LoggedOnUserName = $username
        $profilePath = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction Stop).ProfileImagePath
        if (Test-Path $profilePath) {
            $script:_LoggedOnUserProfile = @{
                UserProfile  = $profilePath
                LocalAppData = Join-Path $profilePath "AppData\Local"
                AppData      = Join-Path $profilePath "AppData\Roaming"
            }
        }
    }
    catch {
        # Detection failed - cache remains null (fallback behavior)
    }
}

function global:Resolve-HkcuRoot {
    _Resolve-LoggedOnUser

    if ($null -ne $script:_LoggedOnUserSid) {
        $sid = $script:_LoggedOnUserSid
        # Ensure HKU PSDrive exists.
        #
        # v0.17.0 fix (deviation from vendored kernel/common.ps1): added
        # -Scope Global. Without it, New-PSDrive creates the drive in
        # this function's local scope and the drive vanishes the moment
        # the function returns, so the caller's `Test-Path "HKU:\$sid\..."`
        # fails with "ドライブが見つかりません" / "drive 'HKU' does not
        # exist". Resolve-HkcuRoot still returns Redirected=$true (because
        # the in-function Test-Path succeeded), but every subsequent
        # provider call from the section script silently misses. Observed
        # 2026-05-22 on OLD-PC-01 (cross-user admin elevation, Outlook
        # 2013), where outlook_pop loudly skipped its entire section and
        # printer's per-user DEVMODE capture silently no-op'd. The fabriq
        # main kernel/common.ps1 carries the same defect; that is a
        # separate upstream concern outside this repo's scope.
        if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
            New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -Scope Global | Out-Null
        }
        if (Test-Path "HKU:\$sid") {
            return @{
                PsDrivePath = "HKU:\$sid"
                RegExePath  = "HKEY_USERS\$sid"
                Label       = "$($script:_LoggedOnUserName) (via HKU)"
                Redirected  = $true
                SID         = $sid
            }
        }
        else {
            Show-Warning "Logged-on user hive not found in HKU. HKCU will target the elevated admin user."
        }
    }

    return @{
        PsDrivePath = "HKCU:"
        RegExePath  = "HKEY_CURRENT_USER"
        Label       = "Current User"
        Redirected  = $false
        SID         = $null
    }
}

# ============================================================
# Outlook Running Detection / Graceful Shutdown
#
# v0.23.0 addition (NOT vendored from kernel/common.ps1). Used by
# backup_view to pre-check before running outlook_pop backup: if
# OUTLOOK.EXE is alive in the source user's session, the registry
# profile keys and PST files are likely held in inconsistent state
# (Outlook flushes on close). The caller pops up a confirmation
# dialog, then Stop-OutlookForSource gracefully closes + (if needed)
# force-kills.
#
# SID scoping is critical: when the backuper process is admin-elevated
# under a different account than the interactive source user, naive
# enumeration would also see (and try to kill) the admin's own Outlook.
# The Get-CimInstance + GetOwnerSid filter restricts to the source
# user's processes only.
# ============================================================

function global:Test-OutlookRunningForSource {
    # Enumerate OUTLOOK.EXE processes owned by the source user (SID).
    # Returns an array of [PSCustomObject]@{ ProcessId } objects, empty
    # when nothing matches.
    #
    # If $SourceUserSid is omitted, the SID is resolved via Resolve-HkcuRoot
    # (admin-elevated cross-user case) or falls back to the current
    # process identity SID.
    param([string]$SourceUserSid = $null)

    if ([string]::IsNullOrWhiteSpace($SourceUserSid)) {
        $hkcuInfo = Resolve-HkcuRoot
        if ($hkcuInfo -and -not [string]::IsNullOrWhiteSpace($hkcuInfo.SID)) {
            $SourceUserSid = $hkcuInfo.SID
        } else {
            $SourceUserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        }
    }

    $matched = @()
    $procs = @()
    try {
        $procs = @(Get-CimInstance -ClassName Win32_Process `
                       -Filter "Name='OUTLOOK.EXE'" -ErrorAction Stop)
    } catch {
        Show-Warning "OUTLOOK.EXE enumeration failed: $($_.Exception.Message)"
        return @()
    }

    foreach ($p in $procs) {
        $ownerSid = $null
        try {
            $result = Invoke-CimMethod -InputObject $p `
                          -MethodName GetOwnerSid -ErrorAction Stop
            if ($result -and $result.ReturnValue -eq 0) {
                $ownerSid = "$($result.Sid)"
            }
        } catch { }
        if ($ownerSid -eq $SourceUserSid) {
            $matched += [PSCustomObject]@{
                ProcessId = [int]$p.ProcessId
                OwnerSid  = $ownerSid
            }
        }
    }
    return @($matched)
}

function global:Stop-OutlookForSource {
    # Graceful close + force-kill chain for source-user OUTLOOK.EXE.
    #
    # Phase 1: enumerate via Test-OutlookRunningForSource.
    # Phase 2: send CloseMainWindow (WM_CLOSE equivalent) to each so
    #          Outlook can prompt the operator for unsaved drafts and
    #          exit cleanly when possible.
    # Phase 3: poll for up to GracefulWaitSeconds; break early if all
    #          processes have exited.
    # Phase 4: Stop-Process -Force any survivor.
    # Phase 5: brief settling sleep so subsequent reg.exe export sees a
    #          quiesced hive.
    #
    # Returns a hashtable:
    #   Result          : 'NoneRunning' | 'KilledGraceful' | 'KilledForce'
    #   AttemptedIds    : int[] - PIDs that were targeted
    #   ForceKilledIds  : int[] - PIDs that survived graceful close and were force-killed
    param(
        [string]$SourceUserSid = $null,
        [int]$GracefulWaitSeconds = 5
    )

    $procInfos = Test-OutlookRunningForSource -SourceUserSid $SourceUserSid
    if ($procInfos.Count -eq 0) {
        return @{
            Result         = 'NoneRunning'
            AttemptedIds   = @()
            ForceKilledIds = @()
        }
    }

    $attemptedIds = @($procInfos | ForEach-Object { $_.ProcessId })

    # Phase 2: graceful close request per process.
    foreach ($processId in $attemptedIds) {
        try {
            $proc = Get-Process -Id $processId -ErrorAction Stop
            if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
                [void]$proc.CloseMainWindow()
            }
        } catch { }
    }

    # Phase 3: poll for graceful exit.
    $deadline = (Get-Date).AddSeconds($GracefulWaitSeconds)
    while ((Get-Date) -lt $deadline) {
        $stillAlive = $false
        foreach ($processId in $attemptedIds) {
            try {
                $p = Get-Process -Id $processId -ErrorAction Stop
                if (-not $p.HasExited) { $stillAlive = $true; break }
            } catch { }
        }
        if (-not $stillAlive) { break }
        Start-Sleep -Milliseconds 500
    }

    # Phase 4: force-kill survivors.
    $forceKilled = @()
    foreach ($processId in $attemptedIds) {
        try {
            $p = Get-Process -Id $processId -ErrorAction Stop
            if (-not $p.HasExited) {
                Stop-Process -Id $processId -Force -ErrorAction Stop
                $forceKilled += $processId
            }
        } catch { }
    }

    # Phase 5: settling delay so the next reg.exe export sees a flushed hive.
    Start-Sleep -Milliseconds 1000

    return @{
        Result         = if ($forceKilled.Count -gt 0) { 'KilledForce' } else { 'KilledGraceful' }
        AttemptedIds   = $attemptedIds
        ForceKilledIds = $forceKilled
    }
}

# ============================================================
# Fabriq Root Discovery (verbatim from checksheet/common.ps1)
#
# Two-tier fallback for locating the parent fabriq directory:
#   Tier 1 (preferred): directory whose name contains "fabriq" AND
#                       has kernel\csv\hostlist.csv
#   Tier 2 (fallback) : Tier 1 empty -> structural marker only
#                       (kernel\csv\hostlist.csv present)
# Self-directory is excluded. Returns array of DirectoryInfo;
# caller decides whether to picker-prompt for multiple candidates.
# ============================================================

function global:Find-FabriqRoot {
    param(
        [Parameter(Mandatory)][string]$ParentDir
    )

    $selfDir = (Resolve-Path ".").Path

    # All directories with the structural marker (kernel\csv\hostlist.csv)
    $structural = @(Get-ChildItem -Path $ParentDir -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -ne $selfDir -and
            (Test-Path (Join-Path $_.FullName "kernel\csv\hostlist.csv"))
        })

    # Tier 1: name contains "fabriq"
    $named = @($structural | Where-Object { $_.Name -like "*fabriq*" })
    if ($named.Count -gt 0) { return $named }

    # Tier 2: structural marker only (rescues renamed fabriq dirs)
    return $structural
}

# ============================================================
# Operator Handoff Folder helpers (v0.25.0)
#
# Builds a single per-restore Desktop folder that consolidates
# operator-facing artifacts (credential payload, Outlook account
# settings text) instead of scattering them across Documents and
# per-PST folders.
#
# Layout:
#   <TargetUserProfile>\Desktop\<yyyy_MM_dd>_<OldPCname>_BK\
#     README.txt                            (handoff folder guide)
#     01_資格情報\                           (credentials section)
#     02_outlook_アカウント情報\              (outlook_pop section)
#
# Section -> subdir name mapping is fixed across releases so
# operator runbooks don't drift. Sections without operator-facing
# files (printer, userdata, msime_dict) are intentionally absent.
#
# The handoff is opt-in via a checkbox in restore_view.ps1
# (default ON when invoked). When OFF, sections emit to their
# legacy locations (Documents\FabriqCredentialsBackup_*, PST
# folders, backup-source sectionDir) -- 100% v0.24.x behaviour
# preserved.
# ============================================================

$script:OperatorHandoffSubdirs = [ordered]@{
    'credentials'     = '01_資格情報'
    'outlook_pop'     = '02_outlook_アカウント情報'
    'system_evidence' = '03_移行元PC情報'
    'printer'         = '04_プリンタ'
}

function global:Resolve-OperatorHandoffRoot {
    # Returns <TargetUserProfile>\Desktop\<yyyy_MM_dd>_<OldPCname>_BK
    # without creating the directory. Caller mkdir's + writes README.
    param(
        [Parameter(Mandatory = $true)][string]$TargetUserProfilePath,
        [Parameter(Mandatory = $true)][string]$OldPcName
    )
    $desktop = Join-Path $TargetUserProfilePath 'Desktop'
    $date    = Get-Date -Format 'yyyy_MM_dd'
    return (Join-Path $desktop ("{0}_{1}_BK" -f $date, $OldPcName))
}

function global:Resolve-OperatorHandoffSectionDir {
    # Returns the per-section subdir path under a handoff root, or $null
    # if the section has no operator-facing files (= not registered in
    # $script:OperatorHandoffSubdirs). Caller does the mkdir lazily when
    # actually deploying.
    param(
        [Parameter(Mandatory = $true)][string]$HandoffRoot,
        [Parameter(Mandatory = $true)][string]$SectionName
    )
    if (-not $script:OperatorHandoffSubdirs.Contains($SectionName)) {
        return $null
    }
    return (Join-Path $HandoffRoot $script:OperatorHandoffSubdirs[$SectionName])
}

# ============================================================
# v0.29.0 Phase 4a: printer section handoff text generators
#
# These two helpers exist in common.ps1 (BOM-tagged UTF-8) so the
# Japanese string literals they emit are NOT subject to the
# CLAUDE.md rule 5 PS5.1 ANSI mis-decode issue that affects
# backuper/lib/sections/printer/restore.ps1 (which is ASCII-only).
# restore.ps1 calls these helpers and then writes the returned
# strings via [System.IO.File]::WriteAllText with UTF8Encoding($true)
# so the .txt files arrive on the operator's Desktop in BOM-tagged
# UTF-8 with intact Japanese content.
# ============================================================

function global:New-PrinterHandoffReadme {
    # Returns the operator-facing README.txt body for the printer
    # handoff folder. Caller decides where to write it and which
    # encoding (BOM-tagged UTF-8 is required for Notepad to display
    # Japanese without mojibake).
    param(
        [Parameter(Mandatory = $true)]$Manifest
    )

    $computerName = if ($null -ne $Manifest.computerName) { $Manifest.computerName } else { '(unknown)' }
    $collectedAt  = if ($null -ne $Manifest.collectedAt)  { $Manifest.collectedAt  } else { '(unknown)' }

    @"
============================================================
  Fabriq プリンタリストア - はじめに
============================================================

このフォルダには、移行元 PC のプリンタ環境を移行先 PC に再現する
ためのファイル一式が入っています。

【使い方】
  1. 復元対象ユーザ (= このフォルダのあるユーザ) でログインして
     ください。
  2. 「Install-Printers.bat」をダブルクリックしてください。
  3. UAC ダイアログが出たら「はい」をクリックしてください。
  4. PowerShell ウィンドウが開き、プリンタの登録が進みます。
  5. 「完了」表示まで待ち、Enter キーで閉じてください。

【失敗時】
  - 「失敗」と表示されたプリンタは手動で再追加してください。
    コントロールパネル → デバイスとプリンター → プリンターの追加
  - プリンタ名 / IP アドレス / ドライバ名は _printer_settings.txt
    をご覧ください。

【印刷設定について】
  _printer_settings.txt に、移行元 PC のプリンタ一覧と採取できた
  設定情報のサマリがあります。Install-Printers.bat 実行で DEVMODE
  binary や hwconfig が採取できていたプリンタは自動で印刷設定
  (用紙サイズ / 給紙 / カラー / 両面 等) が復元されます。
  採取できていない項目は driver の初期値が使われるので、必要に
  応じて移行先 PC で「印刷設定」から手動で変更してください。

【WSD ポートのプリンタ】
  WSD ポート (Web Services for Devices) を使うプリンタは、自動で
  TCP/IP 標準ポート (RAW 9100) に救済されます。それでも認識しない
  場合は、コントロールパネルから手動でプリンタを追加してください。

【共有プリンタ】
  \\server\printer 形式の共有プリンタは自動再追加されません。
  「ネットワーク上のプリンターを参照」から手動で再追加してください。

このフォルダは作業完了後に削除して構いません。

移行元 PC : $computerName
採取日時  : $collectedAt
============================================================
"@
}

function global:New-PrinterSettingsText {
    # Returns the body of _printer_settings.txt - a human-readable
    # summary of each printer in the manifest plus which capture
    # artifacts are present (DEVMODE / hwconfig / properties /
    # PrintConfiguration). Paper / color / duplex transcription is
    # NOT attempted because Get-PrintConfiguration / Get-PrinterProperty
    # are unreliable on real hardware (observed empty/null on
    # production data).
    param(
        [Parameter(Mandatory = $true)]$Manifest
    )

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("============================================================")
    [void]$lines.Add("  移行元 PC のプリンタ情報 (Fabriq BackUper)")
    [void]$lines.Add("============================================================")
    [void]$lines.Add("  移行元 PC      : $($Manifest.computerName)")
    [void]$lines.Add("  採取日時       : $($Manifest.collectedAt)")
    [void]$lines.Add("  プリンタ件数   : $($Manifest.counts.printer)")
    $defLabel = if ([string]::IsNullOrWhiteSpace($Manifest.defaultPrinter)) { '(なし)' } else { $Manifest.defaultPrinter }
    [void]$lines.Add("  既定プリンタ   : $defLabel")
    [void]$lines.Add("============================================================")
    [void]$lines.Add("")

    $manifestPorts = @($Manifest.items.ports)
    $printerIdx = 0
    foreach ($pp in @($Manifest.items.printers)) {
        $printerIdx++
        $defaultMark = if ($pp.name -eq $Manifest.defaultPrinter) { "  ★既定プリンタ" } else { "" }
        [void]$lines.Add("【$printerIdx】 $($pp.name)$defaultMark")
        [void]$lines.Add("  ドライバ         : $($pp.driverName)")

        $portInfo = $manifestPorts | Where-Object { $_.name -eq $pp.portName } | Select-Object -First 1
        if ($null -ne $portInfo) {
            switch ($portInfo.portType) {
                'TCPIP' {
                    [void]$lines.Add("  ポート           : $($portInfo.printerHostAddress)  (TCP/IP standard, RAW $($portInfo.portNumber))")
                }
                'LPR' {
                    [void]$lines.Add("  ポート           : $($portInfo.lprHostName) / queue=$($portInfo.lprQueueName)  (LPR)")
                }
                'WSD' {
                    if (-not [string]::IsNullOrWhiteSpace($portInfo.wsdResolvedHost)) {
                        [void]$lines.Add("  ポート           : $($portInfo.wsdResolvedHost)  (WSD → TCP/IP 9100 救済)")
                    } else {
                        [void]$lines.Add("  ポート           : (WSD、IP 解決不可 → 手動再追加が必要)")
                    }
                }
                'Local' {
                    [void]$lines.Add("  ポート           : $($portInfo.name)  (ローカル / 内部)")
                }
                default {
                    [void]$lines.Add("  ポート           : $($portInfo.name)  (type=$($portInfo.portType))")
                }
            }
        } else {
            [void]$lines.Add("  ポート           : $($pp.portName)  (詳細情報なし)")
        }

        $inboxLabel = if ($pp.isInboxDriver) {
            'YES (Windows 標準ドライバ)'
        } else {
            'NO (サードパーティ、Install-Printers.bat で自動 install)'
        }
        [void]$lines.Add("  Inbox driver     : $inboxLabel")

        $sharedLabel = if ($pp.shared -and -not [string]::IsNullOrWhiteSpace($pp.shareName)) {
            "共有中 (`"$($pp.shareName)`")"
        } else {
            '未共有'
        }
        [void]$lines.Add("  共有             : $sharedLabel")

        if (-not [string]::IsNullOrWhiteSpace($pp.comment))  { [void]$lines.Add("  コメント         : $($pp.comment)") }
        if (-not [string]::IsNullOrWhiteSpace($pp.location)) { [void]$lines.Add("  場所             : $($pp.location)") }

        [void]$lines.Add("  採取データ:")
        $devLabel  = if (-not [string]::IsNullOrWhiteSpace($pp.devModeFile))      { '採取済 (Install-Printers.bat で復元)' } else { '未採取 (driver 初期値を使用)' }
        $hwLabel   = if (-not [string]::IsNullOrWhiteSpace($pp.hwConfigFile))     { '採取済 (Install-Printers.bat で復元)' } else { '未採取' }
        $propLabel = if (-not [string]::IsNullOrWhiteSpace($pp.propertiesFile))   { '採取済 (Install-Printers.bat で適用)' } else { '未採取' }
        $cfgLabel  = if (-not [string]::IsNullOrWhiteSpace($pp.printSettingsFile)){ '採取済' } else { '未採取 (用紙 / カラー / 両面 等は driver 初期値)' }
        [void]$lines.Add("    DEVMODE binary : $devLabel")
        [void]$lines.Add("    HW config      : $hwLabel")
        [void]$lines.Add("    PrinterProperty: $propLabel")
        [void]$lines.Add("    PrintConfig    : $cfgLabel")
        [void]$lines.Add("")
    }

    [void]$lines.Add("============================================================")
    [void]$lines.Add("  メモ")
    [void]$lines.Add("============================================================")
    [void]$lines.Add("  - 「採取済」の項目は Install-Printers.bat 実行時に自動復元")
    [void]$lines.Add("    されます。")
    [void]$lines.Add("  - 「未採取」の項目は driver の初期値が使われます。必要に")
    [void]$lines.Add("    応じて移行先 PC で「印刷設定」から手動で変更してください。")
    [void]$lines.Add("  - 失敗したプリンタの再追加には上記の IP / ドライバ名を")
    [void]$lines.Add("    ご利用ください。")
    [void]$lines.Add("")

    return ($lines -join "`r`n")
}

# ============================================================
# v0.32.0: outlook_pop section handoff README generator
#
# Lives in common.ps1 (BOM-tagged UTF-8) for the same reason as the
# printer helpers above: the Japanese string literals would be
# ANSI-mis-decoded by PS5.1 if they lived inside the ASCII-only
# outlook_pop/restore.ps1 here-strings. restore.ps1 forwards the
# returned string to [System.IO.File]::WriteAllText with
# UTF8Encoding($true) so README.txt arrives BOM-tagged.
# ============================================================

function global:New-OutlookHandoffReadme {
    # Returns the operator-facing README.txt body for the Outlook handoff
    # folder (02_outlook_アカウント情報). Explains the run-as-target-user
    # batch model, the IMAP-manual split, and the "launch Outlook twice"
    # follow-up. AutoProfiles / ManualProfiles are arrays of profile-name
    # strings (POP-only auto-restored vs IMAP-containing manual).
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [string[]]$AutoProfiles = @(),
        [string[]]$ManualProfiles = @()
    )

    $computerName = if ($null -ne $Manifest.computerName) { $Manifest.computerName } else { '(unknown)' }
    $collectedAt  = if ($null -ne $Manifest.collectedAt)  { $Manifest.collectedAt  } else { '(unknown)' }
    $autoLabel    = if ($AutoProfiles.Count   -gt 0) { ($AutoProfiles   -join ', ') } else { '(なし)' }
    $manualLabel  = if ($ManualProfiles.Count -gt 0) { ($ManualProfiles -join ', ') } else { '(なし)' }

    @"
============================================================
  Fabriq Outlook アカウント復元 - はじめに
============================================================

このフォルダには、移行元 PC の Outlook (POP) アカウント設定を
移行先 PC に再現するためのファイル一式が入っています。

【使い方 (POP アカウントの自動復元)】
  1. 移行先 (新 PC) に【復元対象ユーザ】でログインしてください。
     ※ 管理者として実行しないでください。レジストリは「いま操作して
        いるユーザ」の HKCU に取り込まれます。別ユーザ (管理者) で実行
        すると、間違ったプロファイルにアカウントが登録されます。
  2. このフォルダの「Restore-Outlook.bat」をダブルクリックしてください。
     (UAC 昇格は不要です)
  3. 画面のログでインポート結果を確認してください。
  4. 完了後、Outlook を「2 回」起動します:
     - 1 回目: 「PST のリンクのため再起動が必要」と表示され Outlook が
       自動的に閉じます。これは想定動作です。そのまま閉じてください。
     - 2 回目: 各アカウントでパスワードを尋ねられたら入力してください。
       (DPAPI 制約により、パスワードは PC を跨いで移行できません)
       パスワード入力後に送受信が動作します。

  自動復元対象 (POP-only) プロファイル : $autoLabel

【IMAP を含むプロファイル (手動セットアップ)】
  手動セットアップが必要なプロファイル : $manualLabel
  IMAP を含むプロファイルは自動復元の対象外です (オフラインでの
  安全な再構築ができないため)。Outlook を起動し、
  「ファイル > アカウント追加」から手動で設定してください。
  サーバ / ポート等の設定値は _account_settings.txt に記載しています。

【PST ファイルについて】
  メール本体 (PST) は移行先ユーザのプロファイル配下
  (Documents\Outlook ファイル\) に配置済みです。Restore-Outlook.bat は
  レジストリの取り込みのみを行います。

【うまくいかない場合 (手動セットアップ)】
  - _account_settings.txt に全アカウントのサーバ / ポート / PST パスを
    記載しています。
  - RESTORE_INSTRUCTIONS.txt に手動セットアップ手順を記載しています。
  - Outlook を起動 > ファイル > アカウント追加 から、各メールアドレスを
    入力してください (autodiscover が大半の設定を補完します)。

【内部ファイル】
  _data\ サブフォルダにはバッチ本体 (Restore-Outlook.ps1) と取り込み用
  レジストリ (.reg)・manifest 等の内部ファイルが入っています。操作者が
  直接開く必要はありません (Restore-Outlook.bat が自動で参照します)。

このフォルダは作業完了後に削除して構いません。

移行元 PC : $computerName
採取日時  : $collectedAt
============================================================
"@
}

# ============================================================
# v0.31.0: app migration check helpers (system_evidence section)
#
# Returns the body of Check-AppMigration.{bat,ps1} that get
# deployed to the operator handoff folder so the operator can
# cross-check the project's app migration list against the
# source PC's installed software (captured in 11_DesktopApps.csv
# + 11_StoreApps.csv).
#
# Why these live in common.ps1 (BOM-tagged) rather than inside
# system_evidence/restore.ps1 (ASCII-only by Write-tool
# constraint, CLAUDE.md rule 5): the ps1 body contains Japanese
# operator-facing labels ("要移行" etc.) that would be ANSI-
# misinterpreted by PS5.1 if persisted via the Write tool. Same
# pattern as printer's New-PrinterHandoffReadme.
#
# The caller writes the returned string with UTF8Encoding($true)
# via [System.IO.File]::WriteAllText so the file lands on the
# operator's desktop in BOM-tagged UTF-8.
# ============================================================

function global:New-AppMigrationCheckBat {
    # Plain ASCII batch wrapper.
    #
    # Design note: deliberately avoids passing the handoff root as an
    # argument. The classic Windows trap is that `"%~dp0"` expands with a
    # trailing backslash that the PowerShell quoted-argument parser then
    # treats as an escape for the closing quote (so $HandoffDir ends up
    # containing a literal `"`). Instead, the ps1 derives its handoff
    # root from $PSScriptRoot (which resolves to `<handoff>\_data\`) and
    # walks one level up. This mirrors printer/Install-Printers.bat.
    #
    # `%*` is forwarded so operator-facing flags like `/verbose` reach
    # the ps1 via $args.
    #
    # `chcp 65001` switches the console code page so Write-Host of
    # non-ASCII characters renders correctly. The ps1 still sets
    # [Console]::OutputEncoding=UTF8 as a second guard (one without the
    # other is insufficient on PS5.1).
    @"
@echo off
chcp 65001 >nul
title Fabriq BackUper - App Migration Check
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0_data\Check-AppMigration.ps1" %*
echo.
pause
"@
}

function global:New-AppMigrationCheckScript {
    # Returns the PowerShell body that performs:
    #   1. Load app_migration_list.csv (BOM-aware: UTF8 if BOM, CP932 fallback)
    #   2. Load 11_DesktopApps.csv + 11_StoreApps.csv (always UTF8 -- written by
    #      Export-Csv -Encoding UTF8 in backup.ps1, which yields BOM on PS5.1)
    #   3. Match each entry's MatchPatterns (`|`-separated, case-insensitive
    #      substring) against source app Name (+ Publisher for Desktop apps;
    #      StoreApps.Publisher is actually PublisherId/hash and unsuitable)
    #   4. Emit three sections to console + _AppMigrationReport.txt:
    #        - 要移行 (matched entries with source hits)
    #        - 未検出 (entries with no source hit)
    #        - 補足   (source apps not covered by any entry; /verbose only)
    @'
# This script lives at <handoff>\_data\Check-AppMigration.ps1.
# Derive the handoff root from $PSScriptRoot rather than accepting it as
# a parameter -- passing "%~dp0" from the bat trips the Windows
# trailing-backslash-as-escape trap on the PowerShell argv parser.

$ErrorActionPreference = 'Stop'

# Force UTF-8 console output regardless of CHCP / system locale.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$verboseMode = $args -contains '/verbose'

$HandoffDir = Split-Path -Parent $PSScriptRoot
$listPath    = Join-Path $HandoffDir 'app_migration_list.csv'
$samplePath  = Join-Path $HandoffDir 'app_migration_list.sample.csv'
$desktopPath = Join-Path $HandoffDir '11_DesktopApps.csv'
$storePath   = Join-Path $HandoffDir '11_StoreApps.csv'
$reportPath  = Join-Path $HandoffDir '_AppMigrationReport.txt'

$output = New-Object System.Collections.ArrayList

function Write-Both {
    param([string]$Text)
    Write-Host $Text
    [void]$output.Add($Text)
}

function Save-Report {
    $u = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($reportPath, ($output -join "`r`n"), $u)
}

function Read-CsvAutoEncoding {
    # BOM detection -> UTF8 / Default. Excel "CSV UTF-8" save = BOM,
    # Excel "CSV (comma-separated)" save = CP932 on JP Windows.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $hasBom = $false
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $buf = New-Object byte[] 3
            $read = $fs.Read($buf, 0, 3)
            if ($read -ge 3 -and $buf[0] -eq 0xEF -and $buf[1] -eq 0xBB -and $buf[2] -eq 0xBF) {
                $hasBom = $true
            }
        } finally { $fs.Dispose() }
    } catch {}
    $enc = if ($hasBom) { 'UTF8' } else { 'Default' }
    return @(Import-Csv -LiteralPath $Path -Encoding $enc)
}

Write-Both "============================================================"
Write-Both "  Fabriq BackUper - アプリ移行チェック"
Write-Both "============================================================"

if (-not (Test-Path -LiteralPath $listPath)) {
    Write-Both ""
    Write-Both "[ERROR] 案件定義 CSV が見つかりません:"
    Write-Both "        $listPath"
    Write-Both ""
    if (Test-Path -LiteralPath $samplePath) {
        Write-Both "サンプルが同梱されています:"
        Write-Both "  $samplePath"
        Write-Both ""
        Write-Both "上記サンプルを app_migration_list.csv にコピーしてから"
        Write-Both "Excel 等で編集し、再度このバッチをダブルクリック"
        Write-Both "してください。"
        Write-Both ""
        Write-Both "※ Excel で保存する際は「CSV UTF-8 (BOM 付き) (*.csv)」"
        Write-Both "   を選ぶと日本語文字化けを防げます。"
        Write-Both "   通常の「CSV (カンマ区切り)」でも本ツールは読み込めますが、"
        Write-Both "   日本語の表記ゆれパターンを書く場合は BOM 付きを推奨します。"
    } else {
        Write-Both "app_migration_list.csv または app_migration_list.sample.csv"
        Write-Both "のどちらかをこのフォルダに配置してください。"
    }
    Save-Report
    exit 1
}

$entries = @(Read-CsvAutoEncoding -Path $listPath)
if ($entries.Count -eq 0) {
    Write-Both "[WARN] 案件定義 CSV は空でした: $listPath"
    Save-Report
    exit 0
}

# Source PC apps
$sourceApps = New-Object System.Collections.ArrayList
$desktopCount = 0
$storeCount   = 0
if (Test-Path -LiteralPath $desktopPath) {
    $d = @(Import-Csv -LiteralPath $desktopPath -Encoding UTF8)
    $desktopCount = $d.Count
    foreach ($a in $d) {
        [void]$sourceApps.Add([PSCustomObject]@{
            Name      = "$($a.Name)".Trim()
            Publisher = "$($a.Publisher)".Trim()
            Version   = "$($a.Version)".Trim()
            Scope     = "$($a.Scope)".Trim()
            Source    = 'Desktop'
        })
    }
} else {
    Write-Both "[WARN] 11_DesktopApps.csv が見つかりません: $desktopPath"
}
if (Test-Path -LiteralPath $storePath) {
    $s = @(Import-Csv -LiteralPath $storePath -Encoding UTF8)
    $storeCount = $s.Count
    foreach ($a in $s) {
        [void]$sourceApps.Add([PSCustomObject]@{
            Name      = "$($a.Name)".Trim()
            Publisher = ''   # StoreApps の Publisher 列は PublisherId (hash) のため照合対象外
            Version   = "$($a.Version)".Trim()
            Scope     = 'Store'
            Source    = 'Store'
        })
    }
} else {
    Write-Both "[WARN] 11_StoreApps.csv が見つかりません: $storePath"
}

if ($sourceApps.Count -eq 0) {
    Write-Both ""
    Write-Both "[ERROR] 移行元 PC のアプリ一覧が無いため照合できません。"
    Write-Both "        backup 取得時に system_evidence section が走っていない"
    Write-Both "        可能性があります (v0.26.0 未満の古いバックアップ?)。"
    Save-Report
    exit 1
}

# Match
$matched           = New-Object System.Collections.ArrayList
$notFound          = New-Object System.Collections.ArrayList
$matchedAppIndices = New-Object System.Collections.Generic.HashSet[int]

foreach ($entry in $entries) {
    $name = "$($entry.Name)".Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $patternsRaw = "$($entry.MatchPatterns)".Trim()
    if ([string]::IsNullOrWhiteSpace($patternsRaw)) {
        Write-Both "[SKIP] '$name' は MatchPatterns 空欄のため照合不能"
        continue
    }
    $patterns = @($patternsRaw.Split('|') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })

    $hits = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $sourceApps.Count; $i++) {
        $app = $sourceApps[$i]
        $hay = if ($app.Source -eq 'Desktop') {
            "$($app.Name) | $($app.Publisher)"
        } else {
            "$($app.Name)"
        }
        $matched1 = $false
        foreach ($p in $patterns) {
            if ($hay -like "*$p*") { $matched1 = $true; break }
        }
        if ($matched1) {
            [void]$hits.Add($app)
            [void]$matchedAppIndices.Add($i)
        }
    }
    $isRequired = ("$($entry.Required)".Trim() -eq '1')
    $row = [PSCustomObject]@{
        Entry      = $entry
        Hits       = @($hits)
        IsRequired = $isRequired
    }
    if ($hits.Count -gt 0) { [void]$matched.Add($row) }
    else                   { [void]$notFound.Add($row) }
}

Write-Both "  案件定義件数   : $($entries.Count)"
Write-Both ("  移行元アプリ   : {0} 件 (Desktop={1}, Store={2})" -f $sourceApps.Count, $desktopCount, $storeCount)
Write-Both "  チェック実行   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Both "============================================================"
Write-Both ""

Write-Both "【要移行 (案件定義に該当 & 移行元 PC に存在)】"
if ($matched.Count -eq 0) {
    Write-Both "  (該当なし)"
} else {
    foreach ($m in $matched) {
        $req = if ($m.IsRequired) { '[必須]' } else { '[任意]' }
        $cat = if ([string]::IsNullOrWhiteSpace($m.Entry.Category)) { '' } else { "  ($($m.Entry.Category))" }
        Write-Both ("  o {0} {1}{2}" -f $req, $m.Entry.Name, $cat)
        foreach ($h in $m.Hits) {
            $ver   = if ([string]::IsNullOrWhiteSpace($h.Version)) { '' } else { "  v$($h.Version)" }
            $scope = if ([string]::IsNullOrWhiteSpace($h.Scope))   { '' } else { "  ($($h.Scope))" }
            Write-Both ("      -> {0}{1}{2}" -f $h.Name, $ver, $scope)
        }
        if (-not [string]::IsNullOrWhiteSpace($m.Entry.Note)) {
            Write-Both ("      備考: $($m.Entry.Note)")
        }
    }
}
Write-Both ""

Write-Both "【案件定義あるが移行元 PC に未検出】"
if ($notFound.Count -eq 0) {
    Write-Both "  (該当なし)"
} else {
    foreach ($m in $notFound) {
        $req = if ($m.IsRequired) { '[必須]' } else { '[任意]' }
        $cat = if ([string]::IsNullOrWhiteSpace($m.Entry.Category)) { '' } else { "  ($($m.Entry.Category))" }
        Write-Both ("  x {0} {1}{2}" -f $req, $m.Entry.Name, $cat)
        Write-Both ("      MatchPatterns: $($m.Entry.MatchPatterns)")
        if (-not [string]::IsNullOrWhiteSpace($m.Entry.Note)) {
            Write-Both ("      備考: $($m.Entry.Note)")
        }
    }
}
Write-Both ""

if ($verboseMode) {
    Write-Both "【補足: 移行元 PC にあるが案件定義に未登録】"
    $verboseCount = 0
    for ($i = 0; $i -lt $sourceApps.Count; $i++) {
        if ($matchedAppIndices.Contains($i)) { continue }
        $app = $sourceApps[$i]
        if ([string]::IsNullOrWhiteSpace($app.Name)) { continue }
        $verboseCount++
        $ver = if ([string]::IsNullOrWhiteSpace($app.Version)) { '' } else { "  v$($app.Version)" }
        $pub = if ([string]::IsNullOrWhiteSpace($app.Publisher)) { '' } else { "  ($($app.Publisher))" }
        Write-Both ("    [{0}] {1}{2}{3}" -f $app.Source, $app.Name, $ver, $pub)
    }
    if ($verboseCount -eq 0) { Write-Both "  (該当なし)" }
    Write-Both ""
}

Write-Both "============================================================"
Write-Both "【サマリ】"
Write-Both ("  要移行         : {0} 件" -f $matched.Count)
Write-Both ("  未検出         : {0} 件" -f $notFound.Count)
Write-Both ("  移行元全件     : {0} 件" -f $sourceApps.Count)
if (-not $verboseMode) {
    Write-Both "  (補足を見るには Check-AppMigration.bat /verbose で再実行)"
}
Write-Both ("  レポート       : {0}" -f $reportPath)
Write-Both "============================================================"

Save-Report
'@
}

