# ============================================================
# Fabriq BackUper - Credentials Section PoC
# Test 03: Full integration (admin -> spawn target user -> dump creds)
#
# Purpose:
#   Verify the full backup flow that will be used by the production
#   section:
#     1) Parent (admin context) writes a child script that calls
#        CredEnumerate and serializes results to JSON.
#     2) Parent spawns the child as the target user via
#        scheduled-task /IT (no password needed, target must be
#        logged on).
#     3) Child runs in target user's token => CredEnumerate
#        decrypts target user's vault via DPAPI.
#     4) Parent reads the JSON back and prints the result.
#
# Expected outcome:
#   - Child identity == target user
#   - Credential count > 0 (or 0 if vault is empty)
#   - List of target user's credentials (target / type / userName /
#     persist / lastWritten), passwords intentionally not dumped.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass `
#     -File dev\credentials_poc\03_full_integration.ps1 `
#     -TargetUser "DOMAIN\yuki"
# ============================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$TargetUser,

    [int]$TimeoutSec = 30
)

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------
# IPC dir
# ----------------------------------------------------------
$ipcDir = Join-Path $env:ProgramData 'FabriqBackUper\poc'
if (-not (Test-Path $ipcDir)) {
    New-Item -ItemType Directory -Path $ipcDir -Force | Out-Null
}

$stamp       = (Get-Date).ToString('yyyyMMdd_HHmmss_fff')
$childScript = Join-Path $ipcDir "creds_dump_$stamp.ps1"
$outputJson  = Join-Path $ipcDir "creds_dump_$stamp.json"

# ----------------------------------------------------------
# Child script body (CredEnumerate -> JSON)
#
# NOTE: outer is a single-quoted here-string @'...'@; $ refs
# inside are preserved literally and only resolved when the
# child PowerShell process parses this file. The inner
# Add-Type uses a double-quoted here-string @"..."@ which the
# child's parser handles normally (no $ in the C# block).
# ----------------------------------------------------------
$childBody = @'
param([string]$OutputPath)

$ErrorActionPreference = 'Stop'

Add-Type -Namespace FabriqBackUper.PoC -Name CredApi -MemberDefinition @"
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct CREDENTIAL {
    public UInt32 Flags;
    public UInt32 Type;
    public IntPtr TargetName;
    public IntPtr Comment;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
    public UInt32 CredentialBlobSize;
    public IntPtr CredentialBlob;
    public UInt32 Persist;
    public UInt32 AttributeCount;
    public IntPtr Attributes;
    public IntPtr TargetAlias;
    public IntPtr UserName;
}

[DllImport("Advapi32.dll", SetLastError = true, EntryPoint = "CredEnumerateW", CharSet = CharSet.Unicode)]
public static extern bool CredEnumerate(IntPtr filter, int flag, out int count, out IntPtr credentialsArray);

[DllImport("Advapi32.dll", SetLastError = false)]
public static extern void CredFree(IntPtr cred);
"@

function _ReadStr([IntPtr]$p) {
    if ($p -eq [IntPtr]::Zero) { return $null }
    return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($p)
}

function _FtToIso($ft) {
    if ($ft.dwHighDateTime -eq 0 -and $ft.dwLowDateTime -eq 0) { return $null }
    $hi = ([int64]$ft.dwHighDateTime) -band 0xFFFFFFFF
    $lo = ([int64]$ft.dwLowDateTime)  -band 0xFFFFFFFF
    $val = ($hi -shl 32) -bor $lo
    try { return [datetime]::FromFileTimeUtc($val).ToString('o') } catch { return $null }
}

function _TypeName($t) {
    switch ($t) {
        1 { 'Generic' }
        2 { 'DomainPassword' }
        3 { 'DomainCertificate' }
        4 { 'DomainVisiblePassword' }
        5 { 'GenericCertificate' }
        6 { 'DomainExtended' }
        default { "Unknown($t)" }
    }
}

function _PersistName($p) {
    switch ($p) {
        1 { 'Session' }
        2 { 'LocalMachine' }
        3 { 'Enterprise' }
        default { "Unknown($p)" }
    }
}

$count    = 0
$arrayPtr = [IntPtr]::Zero
$lastErr  = 0

$ok = [FabriqBackUper.PoC.CredApi]::CredEnumerate([IntPtr]::Zero, 1, [ref]$count, [ref]$arrayPtr)
if (-not $ok) {
    $lastErr = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
}

$entries = New-Object System.Collections.Generic.List[object]
if ($ok) {
    try {
        $ptrSize = [System.IntPtr]::Size
        for ($i = 0; $i -lt $count; $i++) {
            $credPtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($arrayPtr, $i * $ptrSize)
            $cred    = [System.Runtime.InteropServices.Marshal]::PtrToStructure(
                $credPtr, [type][FabriqBackUper.PoC.CredApi+CREDENTIAL])

            $entries.Add([PSCustomObject]@{
                target      = _ReadStr $cred.TargetName
                type        = _TypeName $cred.Type
                userName    = _ReadStr $cred.UserName
                persist     = _PersistName $cred.Persist
                comment     = _ReadStr $cred.Comment
                lastWritten = _FtToIso $cred.LastWritten
                blobSize    = [int]$cred.CredentialBlobSize
            }) | Out-Null
        }
    } finally {
        [FabriqBackUper.PoC.CredApi]::CredFree($arrayPtr)
    }
}

$payload = [PSCustomObject]@{
    timestamp     = (Get-Date).ToString('o')
    userDomain    = $env:USERDOMAIN
    userName      = $env:USERNAME
    apiSuccess    = [bool]$ok
    apiLastError  = $lastErr
    credentials   = $entries
}
$payload | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputPath -Encoding UTF8
'@

# Write child as UTF-8 with BOM
$bom   = [byte[]](0xEF, 0xBB, 0xBF)
$bytes = $bom + [System.Text.Encoding]::UTF8.GetBytes($childBody)
[System.IO.File]::WriteAllBytes($childScript, $bytes)

# ----------------------------------------------------------
# Spawn via scheduled task /IT
# ----------------------------------------------------------
$taskName = "FabriqBackUper_PoC_CredDump_$stamp"

Write-Host ('=' * 64) -ForegroundColor Cyan
Write-Host ("Parent identity : {0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)
Write-Host ("Target user     : {0}" -f $TargetUser)
Write-Host ("Task name       : {0}" -f $taskName)
Write-Host ('=' * 64) -ForegroundColor Cyan
Write-Host ''

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}" "{1}"' -f $childScript, $outputJson)

$trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddYears(1)
$principal = New-ScheduledTaskPrincipal -UserId $TargetUser -LogonType Interactive -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 2)

try {
    Register-ScheduledTask -TaskName $taskName `
        -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName
    Write-Host "Task registered and started." -ForegroundColor Green
} catch {
    Write-Host ("Task setup FAILED: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item $childScript -ErrorAction SilentlyContinue
    exit 1
}

# ----------------------------------------------------------
# Wait for child output
# ----------------------------------------------------------
Write-Host ("Waiting up to {0}s for child output..." -f $TimeoutSec)
$deadline = (Get-Date).AddSeconds($TimeoutSec)
while (-not (Test-Path $outputJson) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 300
}

if (Test-Path $outputJson) {
    $payload = Get-Content $outputJson -Raw | ConvertFrom-Json
    Write-Host ''
    Write-Host ('-' * 64) -ForegroundColor Cyan
    Write-Host ("Child identity   : {0}\{1}" -f $payload.userDomain, $payload.userName) -ForegroundColor Green
    Write-Host ("API success      : {0}" -f $payload.apiSuccess)
    if (-not $payload.apiSuccess) {
        Write-Host ("API last error   : {0}" -f $payload.apiLastError) -ForegroundColor Yellow
    }
    $credCount = if ($null -ne $payload.credentials) { @($payload.credentials).Count } else { 0 }
    Write-Host ("Credential count : {0}" -f $credCount)
    Write-Host ('-' * 64) -ForegroundColor Cyan
    Write-Host ''
    if ($credCount -gt 0) {
        $payload.credentials | Format-Table -AutoSize -Wrap type, target, userName, persist, blobSize, lastWritten
    }
} else {
    Write-Host "TIMEOUT - child did not produce output." -ForegroundColor Red
    Write-Host ("(see PoC 02 diagnostics for typical failure modes)")
    try {
        $info = Get-ScheduledTask -TaskName $taskName | Get-ScheduledTaskInfo
        Write-Host ("  LastTaskResult : 0x{0:X}" -f $info.LastTaskResult) -ForegroundColor Yellow
    } catch {}
}

# ----------------------------------------------------------
# Cleanup
# ----------------------------------------------------------
Write-Host ''
Write-Host "Cleaning up..."
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item $childScript -ErrorAction SilentlyContinue
Remove-Item $outputJson  -ErrorAction SilentlyContinue
Write-Host "PoC 03 complete." -ForegroundColor Cyan
