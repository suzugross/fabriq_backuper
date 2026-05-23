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
