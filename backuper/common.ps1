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
# Run-as-target-user child runner (v0.35.0)
#
# Generalizes the "decrypt in the source user's own session" pattern: some
# secrets (DPAPI / Credential Manager / Protected Storage) can only be read
# inside the owning user's logon session, but the backup itself runs as an
# elevated operator that merely mounts the source user's HKU hive. This
# helper runs a self-contained child .ps1 AS the source user and collects its
# JSON output through a ProgramData IPC file.
#
# First used by outlook_pop (dump_outlook_pw.ps1); the credentials section's
# inline schtasks /IT logic can adopt this in a later round.
#
# Child contract: the child accepts -OutputPath <file> and writes a UTF-8
# JSON document there. It MUST be self-contained (separate process, possibly
# a different, less-privileged user; no dependency on this common.ps1).
#
# Modes:
#   self        : TargetUser empty -> the current process already is the
#                 target user (admin == interactive user). Direct child.
#   schtasks-it : TargetUser = 'DOMAIN\user' -> register a scheduled task with
#                 LogonType=Interactive ("/IT": runs only while the target is
#                 logged on, no password needed), fire it, poll for the file.
#
# Returns @{ Ok; Method; RawJson; IpcPath; Warnings }:
#   Ok      : $true when a JSON file was produced and read.
#   Method  : 'self' | 'schtasks-it' | 'unavailable'
#   RawJson : file contents (string) or $null.
#   Warnings: diagnostic strings (caller logs via Show-*; this helper does not).
# ============================================================
function global:Invoke-ChildAsTargetUser {
    param(
        [Parameter(Mandatory = $true)][string]$ChildScriptPath,
        [string]$TargetUser = $null,
        [int]$TimeoutSeconds = 30,
        [string]$ChildArguments = $null
    )

    $warnings = @()
    $result = @{ Ok = $false; Method = 'self'; RawJson = $null; IpcPath = $null; Warnings = $warnings }

    if (-not (Test-Path -LiteralPath $ChildScriptPath)) {
        $result.Method = 'unavailable'
        $result.Warnings = @("Child script not found: $ChildScriptPath")
        return $result
    }

    $selfMode = [string]::IsNullOrWhiteSpace($TargetUser)
    $result.Method = if ($selfMode) { 'self' } else { 'schtasks-it' }

    # IPC dir: ProgramData is readable/writable by admin and any logged-on
    # user, so the cross-user child can drop its output where the parent reads.
    $ipcDir = Join-Path $env:ProgramData 'FabriqBackUper\ipc'
    if (-not (Test-Path $ipcDir)) {
        try { New-Item -ItemType Directory -Path $ipcDir -Force -ErrorAction Stop | Out-Null }
        catch {
            $result.Method = 'unavailable'
            $result.Warnings = @("Could not create IPC dir $ipcDir : $($_.Exception.Message)")
            return $result
        }
    }
    # Best-effort sweep of stale child_*.json left by a crashed prior run (a run
    # killed between child-write and parent-read would otherwise leave plaintext
    # at rest; timestamped names are never reclaimed otherwise).
    try {
        $ipcCutoff = (Get-Date).AddMinutes(-10)
        Get-ChildItem -LiteralPath $ipcDir -Filter 'child_*.json' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $ipcCutoff } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    } catch { }

    $stamp   = (Get-Date).ToString('yyyyMMdd_HHmmss_fff')
    $ipcJson = Join-Path $ipcDir "child_$stamp.json"
    $result.IpcPath = $ipcJson

    $argStr = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -OutputPath "{1}"' -f $ChildScriptPath, $ipcJson
    if (-not [string]::IsNullOrWhiteSpace($ChildArguments)) {
        $argStr = "$argStr $ChildArguments"
    }

    if ($selfMode) {
        try {
            $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argStr `
                -Wait -WindowStyle Hidden -PassThru -ErrorAction Stop
            if ($proc.ExitCode -ne 0) { $warnings += "child (self) exited with code $($proc.ExitCode)" }
        } catch {
            $warnings += "Failed to launch child (self): $($_.Exception.Message)"
        }
    } else {
        $taskName = "FabriqBackUper_Child_$stamp"
        $taskRegistered = $false
        try {
            $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argStr
            # Dummy far-future trigger required by Register-ScheduledTask; we
            # fire immediately via Start-ScheduledTask.
            $trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddYears(1)
            $principal = New-ScheduledTaskPrincipal -UserId $TargetUser -LogonType Interactive -RunLevel Limited
            $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                            -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
            Register-ScheduledTask -TaskName $taskName `
                -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
                -Force -ErrorAction Stop | Out-Null
            $taskRegistered = $true
            Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
            $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
            while (-not (Test-Path $ipcJson) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
            if (-not (Test-Path $ipcJson)) {
                $warnings += "Target user '$TargetUser' did not produce output within ${TimeoutSeconds}s (likely not logged on, GPO restriction, or AppLocker)"
                $result.Method = 'unavailable'
            }
        } catch {
            $warnings += "schtasks /IT spawn failed: $($_.Exception.Message)"
            $result.Method = 'unavailable'
        } finally {
            if ($taskRegistered) {
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
    }

    if (Test-Path $ipcJson) {
        try { $result.RawJson = Get-Content $ipcJson -Raw -ErrorAction Stop; $result.Ok = $true }
        catch { $warnings += "Failed to read IPC JSON: $($_.Exception.Message)" }
        Remove-Item $ipcJson -Force -ErrorAction SilentlyContinue
    }

    $result.Warnings = $warnings
    return $result
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
    'application'     = '05_アプリケーション情報'
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

function global:Resolve-OperatorHandoffRootLocal {
    # v0.59.0 (t-0006 stage 2): the handoff (集約) folder now lives INSIDE the
    # Backuper install at <BackuperRoot>\Handoff\<yyyy_MM_dd>_<OldPcName>_BK
    # (a sibling of Backup\) instead of the target user's Desktop, so it can be
    # browsed centrally by Fabriq Handoff Viewer and is found by Get-CleanupCandidate
    # (Root 3b). The Desktop variant (Resolve-OperatorHandoffRoot) is kept for
    # back-compat. Naming is identical (_BK + yyyy_MM_dd) so Test-CleanupArtifactRecognized
    # still recognises it. Does NOT create the directory; caller mkdir's + writes README.
    param(
        [Parameter(Mandatory = $true)][string]$BackuperRoot,
        [Parameter(Mandatory = $true)][string]$OldPcName
    )
    $handoffBase = Join-Path $BackuperRoot 'Handoff'
    $date        = Get-Date -Format 'yyyy_MM_dd'
    return (Join-Path $handoffBase ("{0}_{1}_BK" -f $date, $OldPcName))
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
# Printer port classification helpers (shared, v0.39.0)
#
# Single source of truth for "what kind of port is this" and "can a WSD
# port be rescued to a TCP/IP IP". Both the printer backup section
# (backuper/lib/sections/printer/backup.ps1) and the backup view's
# default-selection logic (backuper/lib/ui/backup_view.ps1) call these,
# so the printers the UI default-checks are exactly the ones restore can
# recreate. Previously these lived as local copies inside backup.ps1;
# centralized in v0.39.0 to avoid duplicate-logic divergence.
# ============================================================

function global:Get-PortType {
    param($Port)
    $monitor = $Port.PortMonitor
    if ([string]::IsNullOrEmpty($monitor)) { return 'Other' }
    $m = $monitor.ToLower()
    if ($m -like 'tcpmon*')   { return 'TCPIP' }
    if ($m -like 'lprmon*' -or $m -like 'lpr*') { return 'LPR' }
    if ($m -like 'wsd*')      { return 'WSD' }
    if ($m -like 'localmon*' -or $m -like 'local*') { return 'Local' }
    if ($m -like '*bonjour*' -or $m -like '*mdns*') { return 'Bonjour' }
    return 'Other'
}

# Extract IPv4 from a printer Location string. WSD-discovered printers
# typically store "http://<ip>:80/wsd/mex" (or similar) in Location; we
# mine it so restore can substitute a TCP/IP standard port when the
# source PC was using WSD. Hostnames are skipped: cross-PC restore needs
# an address that survives DNS/WINS asymmetry, and the vast majority of
# WSD-MFP deployments use static IPs anyway.
function global:Get-IPv4FromLocation {
    param([string]$Location)
    if ([string]::IsNullOrWhiteSpace($Location)) { return $null }
    $m = [System.Text.RegularExpressions.Regex]::Match(
        $Location,
        '(?<!\d)((?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3})(?!\d)')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
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
  2. このフォルダの「Restore-Outlook.bat」をダブルクリックし、インポート
     結果のログを確認してください。(UAC 昇格は不要です)
  3. コントロールパネル →「メール (Microsoft Outlook)」を開きます。
  4. 「プロファイルの表示」を開き、そのまま一度閉じてください。
     ※ これをしないと、Outlook 起動時に毎回プロファイルの選択を
        求められます。
  5. 「電子メール アカウント...」(アカウント設定) を開きます。
  6. 各メールアカウントを選び「変更」を開き、【パスワードだけ】入力して
     設定を完了してください。
     ※ DPAPI 制約により、パスワードは PC を跨いで移行できません。ここで
        各アカウントのパスワードを再入力します。
  7. Outlook を起動します。仕分けルールが移行されている場合、そのままだと
     仕分け実行時にエラーになることがあるため、次のリセットを行ってください:
     [ホーム > ルール > 仕分けルールと通知の管理] を開き、
       (a) すべてのルールのチェックを外して [適用]
       (b) もう一度すべてにチェックを入れて [適用]
       (c) [仕分けルールの実行] を一度手動で実行
     ※ ルールを残す必要がなければ、このフォルダの「Outlook を初回起動
        (仕分けルールをクリア)」ショートカットでルールを一括クリアしても
        構いません。
  8. 送受信を実行し、メールが受信できることを確認してください。

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

# ============================================================
# v0.59.1 (t-0009 P0): in-app (GUI) shared app-migration helpers.
#
# Pure functions that mirror the matching + source-load logic embedded in
# the operator .bat body (New-AppMigrationCheckScript) so the Handoff
# Viewer's in-app 突合 GUI and the legacy .bat produce IDENTICAL verdicts.
# The .bat heredoc is a standalone copy (operator desktop, no common.ps1)
# kept until it is retired in a later phase; until then these mirror its
# exact semantics. No UI; I/O limited to reading the given CSV paths.
# ============================================================

function global:Import-AppMigrationList {
    # Load app_migration_list.csv with the same BOM->UTF8 / else Default(CP932)
    # auto-encoding as the operator .bat (Read-CsvAutoEncoding). Returns @() when
    # the file is missing or unreadable.
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return @() }
    $hasBom = $false
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $buf = New-Object byte[] 3
            $read = $fs.Read($buf, 0, 3)
            if ($read -ge 3 -and $buf[0] -eq 0xEF -and $buf[1] -eq 0xBB -and $buf[2] -eq 0xBF) { $hasBom = $true }
        } finally { $fs.Dispose() }
    } catch {}
    $enc = if ($hasBom) { 'UTF8' } else { 'Default' }
    try { return @(Import-Csv -LiteralPath $Path -Encoding $enc) } catch { return @() }
}

function global:Get-AppMigrationSourceApp {
    # Normalize the source-PC inventory CSVs (11_DesktopApps.csv + 11_StoreApps.csv,
    # both UTF-8 from the backup) into the {Name, Publisher, Version, Scope, Source}
    # shape the matcher expects. Store Publisher is blanked (the CSV column is a
    # PublisherId hash, unsuitable for matching) -- identical to the .bat. Missing
    # files are skipped. Returns @() when neither file is present.
    param([string]$DesktopCsvPath, [string]$StoreCsvPath)
    $apps = New-Object System.Collections.Generic.List[object]
    if (-not [string]::IsNullOrWhiteSpace($DesktopCsvPath) -and (Test-Path -LiteralPath $DesktopCsvPath)) {
        $d = @()
        try { $d = @(Import-Csv -LiteralPath $DesktopCsvPath -Encoding UTF8) } catch {}
        foreach ($a in $d) {
            $apps.Add([PSCustomObject]@{
                Name = "$($a.Name)".Trim(); Publisher = "$($a.Publisher)".Trim()
                Version = "$($a.Version)".Trim(); Scope = "$($a.Scope)".Trim(); Source = 'Desktop'
            })
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($StoreCsvPath) -and (Test-Path -LiteralPath $StoreCsvPath)) {
        $s = @()
        try { $s = @(Import-Csv -LiteralPath $StoreCsvPath -Encoding UTF8) } catch {}
        foreach ($a in $s) {
            $apps.Add([PSCustomObject]@{
                Name = "$($a.Name)".Trim(); Publisher = ''
                Version = "$($a.Version)".Trim(); Scope = 'Store'; Source = 'Store'
            })
        }
    }
    return @($apps.ToArray())
}

function global:Compare-AppMigrationList {
    # Match each migration-list entry's MatchPatterns (|-separated, case-insensitive
    # substring via -like '*p*') against the source apps (Desktop hay = "Name | Publisher",
    # Store hay = "Name") -- identical to the operator .bat (New-AppMigrationCheckScript).
    # Returns:
    #   @{ Entries  = @( [pscustomobject]@{Name; IsRequired; Category; Note; MatchPatterns; Matched; Hits=@(app)} );
    #      Unmatched = @( source apps matched by no entry ) }
    param(
        [Parameter(Mandatory = $true)]$ListRows,
        [Parameter(Mandatory = $true)]$SourceApps
    )
    $src = @($SourceApps)
    $entriesOut = New-Object System.Collections.Generic.List[object]
    $skipped    = New-Object System.Collections.Generic.List[string]
    $matchedIdx = New-Object System.Collections.Generic.HashSet[int]
    foreach ($entry in @($ListRows)) {
        $name = "$($entry.Name)".Trim()
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $patternsRaw = "$($entry.MatchPatterns)".Trim()
        $patterns = @($patternsRaw.Split('|') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        # Legacy [SKIP]: a blank-MatchPatterns entry is a config error -- exclude it
        # entirely (the .bat drops it from both 要移行 and 未検出) and report it as
        # 設定不備 rather than masquerading as a genuine 未検出.
        if ($patterns.Count -eq 0) { [void]$skipped.Add($name); continue }
        $hits = New-Object System.Collections.Generic.List[object]
        for ($i = 0; $i -lt $src.Count; $i++) {
            $app = $src[$i]
            $hay = if ("$($app.Source)" -eq 'Desktop') { "$($app.Name) | $($app.Publisher)" } else { "$($app.Name)" }
            foreach ($p in $patterns) {
                if ($hay -like "*$p*") { [void]$hits.Add($app); [void]$matchedIdx.Add($i); break }
            }
        }
        $entriesOut.Add([PSCustomObject]@{
            Name          = $name
            IsRequired    = ("$($entry.Required)".Trim() -eq '1')
            Category      = "$($entry.Category)".Trim()
            Note          = "$($entry.Note)".Trim()
            MatchPatterns = $patternsRaw
            Matched       = ($hits.Count -gt 0)
            Hits          = @($hits.ToArray())
        })
    }
    $unmatched = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $src.Count; $i++) {
        if ($matchedIdx.Contains($i)) { continue }
        if ([string]::IsNullOrWhiteSpace("$($src[$i].Name)")) { continue }  # legacy 補足 skips blank-Name source apps
        [void]$unmatched.Add($src[$i])
    }
    return @{ Entries = @($entriesOut.ToArray()); Unmatched = @($unmatched.ToArray()); Skipped = @($skipped.ToArray()) }
}

# ============================================================
# v0.61.0 (t-0009 P2): installed-app inventory readers (single source).
#
# Lifted verbatim from system_evidence/backup.ps1 §11 so the new
# application backup section AND the viewer's live new-PC query (P3) share
# identical enumeration. Desktop = HKLM (x64 + WOW6432Node) + an optional
# per-user Uninstall root (HKU:\<sid> for cross-user backup, or HKCU: for a
# live current-user query). Store = Get-AppxPackage (current context).
# Output column shape matches 11_DesktopApps.csv / 11_StoreApps.csv exactly.
# ============================================================

function global:Get-InstalledDesktopApp {
    # $PerUserUninstallRoot: a registry root whose \SOFTWARE\...\Uninstall is
    # also scanned (e.g. the HKU:\<SID> PSDrive path from Resolve-HkcuRoot for a
    # cross-user backup, or 'HKCU:' for a live current-user query). When empty,
    # only the machine-wide HKLM roots are scanned.
    param([string]$PerUserUninstallRoot = $null)
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    if (-not [string]::IsNullOrWhiteSpace($PerUserUninstallRoot)) {
        $r = "$PerUserUninstallRoot".TrimEnd('\')
        $paths += "$r\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
        $paths += "$r\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    }
    return @(Get-ItemProperty $paths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName } |
        Select-Object @{N = 'Name'; E = { $_.DisplayName } },
                      @{N = 'Version'; E = { $_.DisplayVersion } },
                      Publisher,
                      InstallDate,
                      @{N = 'Scope'; E = {
                          $p = $_.PSPath
                          if     ($p -match 'HKEY_LOCAL_MACHINE\\SOFTWARE\\WOW6432Node') { 'Machine (x86)' }
                          elseif ($p -match 'HKEY_LOCAL_MACHINE')                        { 'Machine (x64)' }
                          elseif ($p -match 'HKEY_USERS\\.*\\SOFTWARE\\WOW6432Node')     { 'User (x86)' }
                          elseif ($p -match 'HKEY_USERS')                                { 'User (x64)' }
                          elseif ($p -match 'HKEY_CURRENT_USER\\SOFTWARE\\WOW6432Node')  { 'User (x86)' }
                          elseif ($p -match 'HKEY_CURRENT_USER')                         { 'User (x64)' }
                          else                                                           { 'Unknown' }
                      } } |
        Sort-Object Name)
}

function global:Get-InstalledStoreApp {
    # Store / UWP apps for the current context (Get-AppxPackage). Publisher is
    # the PublisherId (hash) -- recorded for reference, not used for matching.
    return @(Get-AppxPackage |
        Select-Object @{N = 'Name'; E = { $_.Name } },
                      @{N = 'Version'; E = { $_.Version } },
                      @{N = 'Publisher'; E = { $_.PublisherId } } |
        Sort-Object Name)
}

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

# ============================================================
# v0.41.0: Backup-completion flag (local-mode handoff signal, P1)
#
# At the end of a non-Failed backup, Invoke-BackuperBackupCore drops this
# typed JSON flag at the DESTINATION ROOT (in the local operation model the
# share root = the target's <BackuperRoot>\Backup). It is a PASSIVE signal:
# the restore side (P2, not yet implemented) polls for it and auto-selects
# the named backup. Mirrors the New-CleanupMarker write style (best-effort,
# UTF-8 no-BOM, never throws).
# ============================================================

$script:BackupCompleteFlagName = '_backup_complete.json'

function global:New-BackupCompleteFlag {
    # Best-effort write of the backup-completion flag at the destination
    # root. Never throws; returns $true on success, $false otherwise.
    param(
        [Parameter(Mandatory = $true)][string]$RootDir,
        [Parameter(Mandatory = $true)][string]$OldPcName,
        [string]$NewPcName = '',
        [Parameter(Mandatory = $true)][string]$Timestamp,
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$BackuperVersion = ''
    )
    try {
        if (-not (Test-Path -LiteralPath $RootDir)) { return $false }
        $flag = [ordered]@{
            schemaVersion   = 1
            manifestType    = 'fabriq-backuper-backup-done'
            oldPcName       = "$OldPcName"
            newPcName       = "$NewPcName"
            timestamp       = "$Timestamp"
            relativePath    = (Join-Path $OldPcName $Timestamp)
            status          = "$Status"
            backuperVersion = "$BackuperVersion"
            placedAt        = (Get-Date).ToString('o')
            placedByHost    = "$env:COMPUTERNAME"
        }
        $path = Join-Path $RootDir $script:BackupCompleteFlagName
        $json = $flag | ConvertTo-Json -Depth 5
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($path, $json, $utf8NoBom)
        return $true
    }
    catch {
        try { Show-Warning "Backup-complete flag write failed in ${RootDir}: $($_.Exception.Message)" } catch {}
        return $false
    }
}

function global:Read-BackupCompleteFlag {
    # Reads the backup-completion flag from a destination root, or $null if
    # absent / unparseable. Consumed by the restore-side poll (P2).
    param([Parameter(Mandatory = $true)][string]$RootDir)
    $path = Join-Path $RootDir $script:BackupCompleteFlagName
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

# ============================================================
# v0.34.0: Artifact cleanup helpers
#
# A "cleanup artifact" is a leftover migration folder that may be
# bulk-deleted after a kitting job: (1) a backup tree, (2) a Desktop
# operator-handoff folder, (3) a LAN-Prep folder (C:\FabriqMigration).
#
# Model (English comments per rule 6; UI text lives in cleanup_view.ps1):
#   - MARKER  _fabriq_artifact.json : per-folder self-describing sentinel
#             written best-effort at placement time. Co-located with the
#             folder it describes (= distributed ledger; no central index).
#   - RECOGNITION two-tier: marker OR intrinsic self-ID file, so a failed
#             marker write is never a miss:
#               backup  -> manifest.json (manifestType fabriq-backuper-snapshot)
#               lanprep -> _rollback_snapshot.json
#               handoff -> name *_<OldPC>_BK AND (README.txt OR a 0N_ subdir)
#   - REVERT GATE: a LAN-Prep folder also holds the network revert key
#             (_rollback_snapshot.json) and is only safe to delete AFTER the
#             PC has been reverted. Reliable signal = _revert_done.json
#             written by Revert-LanMigration.ps1 (share-removal / IP are NOT
#             reliable: removeShare is conditional and the snapshot persists).
#   - PATH SAFETY: a deny/allow contract guards every recursive delete so
#             fabriq main, the repo, system/user roots are never touched.
# ============================================================

$script:CleanupMarkerName        = '_fabriq_artifact.json'
$script:LanPrepRevertMarkerName  = '_revert_done.json'

function global:New-CleanupMarker {
    # Best-effort write of the per-folder cleanup marker. Never throws;
    # returns $true on success, $false on failure (caller continues).
    param(
        [Parameter(Mandatory = $true)][string]$Dir,
        [Parameter(Mandatory = $true)]
        [ValidateSet('backup-tree', 'handoff', 'lanprep')]
        [string]$ArtifactKind,
        [string]$OldPcName = '',
        [string]$NewPcName = '',
        [string]$BackuperVersion = ''
    )
    try {
        if (-not (Test-Path -LiteralPath $Dir)) { return $false }
        $marker = [ordered]@{
            schemaVersion   = 1
            manifestType    = 'fabriq-cleanup-marker'
            artifactKind    = $ArtifactKind
            oldPcName       = "$OldPcName"
            newPcName       = "$NewPcName"
            createdAt       = (Get-Date).ToString('o')
            backuperVersion = "$BackuperVersion"
            placedByHost    = "$env:COMPUTERNAME"
            placedByUser    = "$env:USERDOMAIN\$env:USERNAME"
        }
        $path = Join-Path $Dir $script:CleanupMarkerName
        $json = $marker | ConvertTo-Json -Depth 5
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($path, $json, $utf8NoBom)
        return $true
    }
    catch {
        try { Show-Warning "Cleanup marker write failed in ${Dir}: $($_.Exception.Message)" } catch {}
        return $false
    }
}

function global:Read-CleanupMarker {
    param([Parameter(Mandatory = $true)][string]$Dir)
    $path = Join-Path $Dir $script:CleanupMarkerName
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

function global:Test-LanPrepReverted {
    # The lan-prep folder is safe to delete only after Revert-LanMigration
    # has restored the network and dropped a _revert_done.json marker.
    # Returns @{ Reverted = [bool]; Source = 'marker' | 'no-marker' }.
    param([Parameter(Mandatory = $true)][string]$LanPrepDir)
    $m = Join-Path $LanPrepDir $script:LanPrepRevertMarkerName
    if (Test-Path -LiteralPath $m) {
        return @{ Reverted = $true; Source = 'marker' }
    }
    return @{ Reverted = $false; Source = 'no-marker' }
}

function global:Test-CleanupArtifactRecognized {
    # Two-tier recognition. Returns @{ Kind; OldPcName; RecognizedBy } or
    # $null when the directory is not a recognised fabriq artifact.
    param([Parameter(Mandatory = $true)][string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $null }

    # 1. explicit marker
    $marker = Read-CleanupMarker -Dir $Dir
    if ($null -ne $marker -and "$($marker.manifestType)" -eq 'fabriq-cleanup-marker') {
        return @{ Kind = "$($marker.artifactKind)"; OldPcName = "$($marker.oldPcName)"; RecognizedBy = 'marker' }
    }
    # 2. backup tree -> manifest.json
    $mf = Join-Path $Dir 'manifest.json'
    if (Test-Path -LiteralPath $mf) {
        try {
            $m = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json
            if ("$($m.manifestType)" -eq 'fabriq-backuper-snapshot') {
                return @{ Kind = 'backup-tree'; OldPcName = "$($m.oldPcName)"; RecognizedBy = 'manifest' }
            }
        }
        catch {}
    }
    # 3. lan-prep -> _rollback_snapshot.json (host id is recovered later from
    #    any nested backup; the snapshot itself carries no oldPcName)
    if (Test-Path -LiteralPath (Join-Path $Dir '_rollback_snapshot.json')) {
        return @{ Kind = 'lanprep'; OldPcName = ''; RecognizedBy = 'snapshot' }
    }
    # 4. handoff -> name *_<OldPC>_BK AND (README.txt OR a 0N_ subdir)
    $leaf = Split-Path -Leaf $Dir
    if ($leaf -match '_BK$') {
        $hasReadme = Test-Path -LiteralPath (Join-Path $Dir 'README.txt')
        $hasSub = $false
        try {
            $hasSub = @(Get-ChildItem -LiteralPath $Dir -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -match '^0\d_' }).Count -gt 0
        }
        catch {}
        if ($hasReadme -or $hasSub) {
            $oldPc = ''
            if ($leaf -match '^\d{4}_\d{2}_\d{2}_(.+)_BK$') { $oldPc = $matches[1] }
            return @{ Kind = 'handoff'; OldPcName = $oldPc; RecognizedBy = 'name+intrinsic' }
        }
    }
    return $null
}

function global:Get-CleanupSourceLabel {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$BackuperRoot)
    $p = $Path.ToLowerInvariant()
    if ($p -match '\\desktop\\') { return 'Desktop' }
    $bk = (Join-Path $BackuperRoot 'Backup').TrimEnd('\').ToLowerInvariant()
    if ($p.StartsWith($bk + '\') -or $p -eq $bk) { return 'Backup(local/USB)' }
    # v0.59.0 (t-0006 stage 2): handoff folders relocated under <BackuperRoot>\Handoff\
    # (were on the Desktop -> matched above). Label them before the LAN-share fallback.
    $hoff = (Join-Path $BackuperRoot 'Handoff').TrimEnd('\').ToLowerInvariant()
    if ($p.StartsWith($hoff + '\') -or $p -eq $hoff) { return 'Handoff(Backuper)' }
    return 'LAN-share' #
}

function global:Test-CleanupPathSafe {
    # Guards every recursive delete. Normalises the path, then denies:
    #   - drive roots / shallow UNC roots (\\server, \\server\share)
    #   - C:\Windows (+subtree) / C:\Users / a user-profile root / a Desktop root
    #   - any SubtreeDenyRoot (fabriq main) and everything beneath it
    #   - any ProtectedRoot exactly, or a path that is an ancestor of one
    #     (BackuperRoot / RepoRoot / BackuperRoot\Backup -- their deep
    #      children like Backup\<OldPC>\<ts> remain deletable)
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$SubtreeDenyRoots = @(),
        [string[]]$ProtectedRoots = @()
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $full = $null
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { return $false }
    $norm = $full.TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($norm)) { return $false }
    $lower = $norm.ToLowerInvariant()

    # drive root  (C:)
    if ($norm -match '^[A-Za-z]:$') { return $false }
    # shallow UNC root  (\\server  or  \\server\share)
    if ($norm -match '^\\\\') {
        $parts = @($norm.TrimStart('\') -split '\\' | Where-Object { $_ -ne '' })
        if ($parts.Count -le 2) { return $false }
    }
    # system / user roots
    $sysRoot   = "$env:SystemRoot".TrimEnd('\').ToLowerInvariant()
    $usersRoot = (Join-Path $env:SystemDrive 'Users').TrimEnd('\').ToLowerInvariant()
    if ($lower -eq $sysRoot -or $lower.StartsWith($sysRoot + '\')) { return $false }
    if ($lower -eq $usersRoot) { return $false }
    if ($lower.StartsWith($usersRoot + '\')) {
        $rest = $norm.Substring($usersRoot.Length).Trim('\')
        $restParts = @($rest -split '\\' | Where-Object { $_ -ne '' })
        if ($restParts.Count -le 1) { return $false }                                   # <user> root
        if ($restParts.Count -eq 2 -and $restParts[1].ToLowerInvariant() -eq 'desktop') { return $false }  # Desktop root
    }
    # subtree-deny roots (fabriq main): deny self + everything underneath
    foreach ($sr in $SubtreeDenyRoots) {
        if ([string]::IsNullOrWhiteSpace($sr)) { continue }
        $srn = ''
        try { $srn = ([System.IO.Path]::GetFullPath($sr)).TrimEnd('\').ToLowerInvariant() } catch { continue }
        if ([string]::IsNullOrWhiteSpace($srn)) { continue }
        if ($lower -eq $srn -or $lower.StartsWith($srn + '\')) { return $false }
    }
    # protected roots: deny exact, and deny if path is an ancestor of one
    foreach ($pr in $ProtectedRoots) {
        if ([string]::IsNullOrWhiteSpace($pr)) { continue }
        $prn = ''
        try { $prn = ([System.IO.Path]::GetFullPath($pr)).TrimEnd('\').ToLowerInvariant() } catch { continue }
        if ([string]::IsNullOrWhiteSpace($prn)) { continue }
        if ($lower -eq $prn) { return $false }
        if ($prn.StartsWith($lower + '\')) { return $false }
    }
    return $true
}

function global:ConvertTo-CleanupLongPath {
    # Win32 \\?\ long-path prefix so the .NET BCL (PS 5.1) can act on paths
    # longer than MAX_PATH (deep robocopy'd backup trees exceed 260 chars).
    # UNC -> \\?\UNC\server\share ; local -> \\?\C:\...
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    if ($Path.StartsWith('\\?\')) { return $Path }
    if ($Path.StartsWith('\\'))   { return ('\\?\UNC\' + $Path.Substring(2)) }
    return ('\\?\' + $Path)
}

function global:Remove-CleanupArtifactTree {
    # Recursive delete that:
    #   (a) clears the read-only attribute before deleting each file -- backup
    #       trees are copied with robocopy /COPYALL, which preserves ReadOnly,
    #       and [IO.File]::Delete throws UnauthorizedAccessException on those;
    #   (b) is long-path safe via the \\?\ prefix (deep user-data trees);
    #   (c) does NOT follow reparse points (junctions/symlinks are unlinked,
    #       never recursed into), so the delete can never escape the subtree.
    param([Parameter(Mandatory = $true)][string]$TargetPath)
    $lp = ConvertTo-CleanupLongPath -Path $TargetPath

    $attrs = [System.IO.File]::GetAttributes($lp)
    if ([bool]($attrs -band [System.IO.FileAttributes]::ReparsePoint)) {
        [System.IO.Directory]::Delete($lp, $false)
        return
    }
    # EnumerateFileSystemEntries on a \\?\ path returns \\?\-prefixed children,
    # so they remain long-path safe when passed back into this function.
    foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($lp)) {
        $eAttrs = [System.IO.File]::GetAttributes($entry)
        $isDir  = [bool]($eAttrs -band [System.IO.FileAttributes]::Directory)
        if ([bool]($eAttrs -band [System.IO.FileAttributes]::ReparsePoint)) {
            if ($isDir) { [System.IO.Directory]::Delete($entry, $false) }
            else {
                try { [System.IO.File]::SetAttributes($entry, [System.IO.FileAttributes]::Normal) } catch {}
                [System.IO.File]::Delete($entry)
            }
        }
        elseif ($isDir) {
            Remove-CleanupArtifactTree -TargetPath $entry
        }
        else {
            try { [System.IO.File]::SetAttributes($entry, [System.IO.FileAttributes]::Normal) } catch {}
            [System.IO.File]::Delete($entry)
        }
    }
    # clear the directory's own read-only bit (keep the Directory flag) then drop it
    try { [System.IO.File]::SetAttributes($lp, [System.IO.FileAttributes]::Directory) } catch {}
    [System.IO.Directory]::Delete($lp, $false)
}

function global:Remove-CleanupArtifact {
    # Path-safe delete of a single artifact. Returns
    # @{ Path; Status('Deleted'|'Skipped'|'Failed'); Error }.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$SubtreeDenyRoots = @(),
        [string[]]$ProtectedRoots = @()
    )
    $res = [PSCustomObject]@{ Path = $Path; Status = 'Failed'; Error = $null }
    if (-not (Test-CleanupPathSafe -Path $Path -SubtreeDenyRoots $SubtreeDenyRoots -ProtectedRoots $ProtectedRoots)) {
        $res.Error = 'Path failed safety check (protected/system path)'
        return $res
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        $res.Status = 'Skipped'; $res.Error = 'not found'
        return $res
    }
    try {
        Remove-CleanupArtifactTree -TargetPath $Path
        $res.Status = 'Deleted'
    }
    catch {
        $res.Error = $_.Exception.Message
    }
    return $res
}

function global:Get-CleanupCandidate {
    # Scans the bounded set of known roots, recognises artifacts, attributes
    # each to a host, links nested backups to their lan-prep parent, and
    # filters to $OldPcName. Returns an array of candidate PSCustomObjects.
    param(
        [Parameter(Mandatory = $true)][string]$BackuperRoot,
        $MigrationProfile = $null,
        [Parameter(Mandatory = $true)][string]$OldPcName
    )
    $dirs = New-Object System.Collections.Generic.List[string]

    # Root 1: USB / local backup  <BackuperRoot>\Backup\<OldPcName>\*
    $localHostRoot = Join-Path (Join-Path $BackuperRoot 'Backup') $OldPcName
    if (Test-Path -LiteralPath $localHostRoot) {
        Get-ChildItem -LiteralPath $localHostRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $dirs.Add($_.FullName) }
    }

    # Root 2: LAN-Prep folder from the profile (+ nested backups under it)
    $lanPrepDir = $null
    if ($null -ne $MigrationProfile) {
        if ($MigrationProfile.share -and -not [string]::IsNullOrWhiteSpace("$($MigrationProfile.share.localPath)")) {
            $lanPrepDir = "$($MigrationProfile.share.localPath)"
        }
        if ($MigrationProfile.rollback -and -not [string]::IsNullOrWhiteSpace("$($MigrationProfile.rollback.snapshotPath)")) {
            $snapParent = Split-Path -Parent "$($MigrationProfile.rollback.snapshotPath)"
            if (-not [string]::IsNullOrWhiteSpace($snapParent)) { $lanPrepDir = $snapParent }
        }
    }
    if ($lanPrepDir -and (Test-Path -LiteralPath $lanPrepDir)) {
        $dirs.Add($lanPrepDir)
        $nested = Join-Path $lanPrepDir $OldPcName
        if (Test-Path -LiteralPath $nested) {
            Get-ChildItem -LiteralPath $nested -Directory -ErrorAction SilentlyContinue | ForEach-Object { $dirs.Add($_.FullName) }
        }
    }

    # Root 2b: shallow fixed-drive root scan for a renamed lan-prep folder
    try {
        foreach ($drv in @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady })) {
            Get-ChildItem -LiteralPath $drv.RootDirectory.FullName -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                if (Test-Path -LiteralPath (Join-Path $_.FullName '_rollback_snapshot.json')) {
                    $dirs.Add($_.FullName)
                    $nb = Join-Path $_.FullName $OldPcName
                    if (Test-Path -LiteralPath $nb) {
                        Get-ChildItem -LiteralPath $nb -Directory -ErrorAction SilentlyContinue | ForEach-Object { $dirs.Add($_.FullName) }
                    }
                }
            }
        }
    }
    catch {}

    # Root 3: handoff folders on every local user's Desktop
    try {
        $usersDir = Join-Path $env:SystemDrive 'Users'
        if (Test-Path -LiteralPath $usersDir) {
            foreach ($prof in @(Get-ChildItem -LiteralPath $usersDir -Directory -ErrorAction SilentlyContinue)) {
                $desk = Join-Path $prof.FullName 'Desktop'
                if (Test-Path -LiteralPath $desk) {
                    Get-ChildItem -LiteralPath $desk -Directory -Filter '*_BK' -ErrorAction SilentlyContinue | ForEach-Object { $dirs.Add($_.FullName) }
                }
            }
        }
    }
    catch {}

    # Root 3b: handoff folders relocated under <BackuperRoot>\Handoff\ (v0.59.0, t-0006).
    # Same _BK naming as the Desktop variant, so Test-CleanupArtifactRecognized handles them.
    try {
        $handoffBase = Join-Path $BackuperRoot 'Handoff'
        if (Test-Path -LiteralPath $handoffBase) {
            Get-ChildItem -LiteralPath $handoffBase -Directory -Filter '*_BK' -ErrorAction SilentlyContinue | ForEach-Object { $dirs.Add($_.FullName) }
        }
    }
    catch {}

    # Recognise + attribute
    $list = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($d in $dirs) {
        $full = $null
        try { $full = [System.IO.Path]::GetFullPath($d) } catch { $full = $d }
        $key = $full.TrimEnd('\').ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $rec = Test-CleanupArtifactRecognized -Dir $full
        if ($null -eq $rec) { continue }
        $seen[$key] = $true
        $size = 0L
        try { $size = [long]((Get-ChildItem -LiteralPath $full -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum) } catch {}
        $created = ''
        try { $created = (Get-Item -LiteralPath $full -ErrorAction SilentlyContinue).CreationTime.ToString('yyyy-MM-dd HH:mm:ss') } catch {}
        $reverted = $true
        if ("$($rec.Kind)" -eq 'lanprep') { $reverted = [bool](Test-LanPrepReverted -LanPrepDir $full).Reverted }
        $list.Add([PSCustomObject]@{
            Path           = $full
            Kind           = "$($rec.Kind)"
            AttributedHost = "$($rec.OldPcName)"
            Source         = (Get-CleanupSourceLabel -Path $full -BackuperRoot $BackuperRoot)
            SizeBytes      = $size
            CreatedAt      = $created
            RecognizedBy   = "$($rec.RecognizedBy)"
            ParentPath     = $null
            IsLanPrep      = ("$($rec.Kind)" -eq 'lanprep')
            Reverted       = $reverted
            Unidentified   = $false
        })
    }

    # Containment + recover lan-prep host from a nested backup
    foreach ($c in $list) {
        $cp = $c.Path.TrimEnd('\').ToLowerInvariant()
        foreach ($p in $list) {
            if ([object]::ReferenceEquals($c, $p)) { continue }
            if (-not $p.IsLanPrep) { continue }
            $pp = $p.Path.TrimEnd('\').ToLowerInvariant()
            if ($cp.StartsWith($pp + '\')) {
                $c.ParentPath = $p.Path
                if ([string]::IsNullOrWhiteSpace($p.AttributedHost) -and "$($c.Kind)" -eq 'backup-tree' -and -not [string]::IsNullOrWhiteSpace($c.AttributedHost)) {
                    $p.AttributedHost = $c.AttributedHost
                }
            }
        }
    }

    # Host filter (lan-prep with no resolvable host is shown but flagged)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($c in $list) {
        $h = "$($c.AttributedHost)"
        if ($h -ieq $OldPcName) { $out.Add($c) }
        elseif ([string]::IsNullOrWhiteSpace($h) -and $c.IsLanPrep) {
            $c.Unidentified = $true
            $out.Add($c)
        }
    }
    # NOTE: return $out.ToArray(), NOT @($out): in this PS 5.1 build the
    # array-subexpression operator @() throws "argument types do not match"
    # when applied directly to a List[object]. ToArray() is safe and the
    # caller wraps the result in @() (which works on a real array).
    return $out.ToArray()
}

function global:Write-CleanupHistory {
    # Append a UTF-8 (BOM) line to the deletion history log. Falls back to
    # %TEMP% when <BackuperRoot>\Backup is read-only (e.g. USB media).
    param(
        [Parameter(Mandatory = $true)][string]$BackuperRoot,
        [Parameter(Mandatory = $true)][string]$Line
    )
    $targets = @(
        (Join-Path (Join-Path $BackuperRoot 'Backup') '_cleanup_history.txt'),
        (Join-Path $env:TEMP 'fabriq_backuper_cleanup_history.txt')
    )
    foreach ($p in $targets) {
        try {
            $dir = Split-Path -Parent $p
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
            $existing = ''
            if (Test-Path -LiteralPath $p) { $existing = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) }
            $utf8Bom = New-Object System.Text.UTF8Encoding($true)
            [System.IO.File]::WriteAllText($p, $existing + $Line + "`r`n", $utf8Bom)
            return $p
        }
        catch { continue }
    }
    return $null
}

# v0.54.0 (t-0001): moved here from cleanup_view.ps1 so BOTH the restore-side D4
# (Invoke-RestoreEntryDelete) and the standalone cleanup tool resolve it from the
# engine. Returns @{ Subtree=[]; Protected=[] } that Remove-CleanupArtifact must
# never delete: fabriq main subtree (deny everything under it) + repo / backuper
# root / the Backup root itself (exact + ancestor deny; deep children like
# Backup\<OldPC>\<ts> stay deletable). Uses $script:BackuperRoot / $script:FabriqRoot.
function global:Get-CleanupProtectedRoots {
    $repoRoot = $null
    if (-not [string]::IsNullOrWhiteSpace($script:BackuperRoot)) {
        $repoRoot = Split-Path -Parent $script:BackuperRoot
    }
    $protected = @()
    if (-not [string]::IsNullOrWhiteSpace($script:BackuperRoot)) {
        $protected += $script:BackuperRoot
        $protected += (Join-Path $script:BackuperRoot 'Backup')
    }
    if (-not [string]::IsNullOrWhiteSpace($repoRoot)) { $protected += $repoRoot }
    $subtree = @()
    if (-not [string]::IsNullOrWhiteSpace($script:FabriqRoot)) { $subtree += $script:FabriqRoot }
    return @{ Subtree = $subtree; Protected = $protected }
}

