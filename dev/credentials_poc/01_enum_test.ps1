# ============================================================
# Fabriq BackUper - Credentials Section PoC
# Test 01: CredEnumerate P/Invoke
#
# Purpose:
#   Verify that we can enumerate the current process user's
#   credential vault via the Win32 Credential Manager API
#   (Advapi32!CredEnumerateW + CredFree).
#
# Expected output:
#   - Process identity (USERDOMAIN\USERNAME)
#   - Total credential count
#   - Per-entry: Type / Target / UserName / Persist / BlobSize / LastWritten
#
# Notes:
#   - Password blobs (CredentialBlob bytes) are intentionally NOT
#     decoded or printed. Only metadata is enumerated.
#   - DPAPI per-user constraint: the API decrypts only the calling
#     user's vault. Running this as an admin different from the
#     interactive user will show admin's credentials, not the
#     interactive user's.
#   - No side effects on the OS or the credential store.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass `
#     -File dev\credentials_poc\01_enum_test.ps1
# ============================================================

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------
# P/Invoke definitions (CredEnumerateW + CredFree)
# ----------------------------------------------------------
Add-Type -Namespace FabriqBackUper.PoC -Name CredApi -MemberDefinition @'
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
'@ -ErrorAction Stop

function ConvertFrom-CredType {
    param([uint32]$Type)
    switch ($Type) {
        1 { 'Generic' }
        2 { 'DomainPassword' }
        3 { 'DomainCertificate' }
        4 { 'DomainVisiblePassword' }
        5 { 'GenericCertificate' }
        6 { 'DomainExtended' }
        default { "Unknown($Type)" }
    }
}

function ConvertFrom-CredPersist {
    param([uint32]$Persist)
    switch ($Persist) {
        1 { 'Session' }
        2 { 'LocalMachine' }
        3 { 'Enterprise' }
        default { "Unknown($Persist)" }
    }
}

function ConvertFrom-Win32FileTime {
    param($Ft)
    if ($Ft.dwHighDateTime -eq 0 -and $Ft.dwLowDateTime -eq 0) { return $null }
    # FILETIME members are Int32 in System.Runtime.InteropServices.ComTypes.FILETIME;
    # mask to lower 32 bits to suppress sign-extension when the high bit is set, then
    # combine into the unsigned-equivalent Int64. The mask MUST be decimal: 0xFFFFFFFF
    # parses as Int32 -1 in PowerShell and turns the -band into a no-op; 4294967295
    # exceeds Int32 range so it parses as Int64, giving the correct lower-32-bit mask.
    $hi = ([int64]$Ft.dwHighDateTime) -band [int64]4294967295
    $lo = ([int64]$Ft.dwLowDateTime)  -band [int64]4294967295
    $val = ($hi -shl 32) -bor $lo
    try { return [datetime]::FromFileTimeUtc($val) } catch { return $null }
}

function Read-LPWStr {
    param([IntPtr]$Ptr)
    if ($Ptr -eq [IntPtr]::Zero) { return $null }
    return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($Ptr)
}

# ----------------------------------------------------------
# Enumerate
# ----------------------------------------------------------
$sep = '=' * 64
Write-Host $sep -ForegroundColor Cyan
Write-Host ("CredEnumerate PoC - process user = {0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)
Write-Host $sep -ForegroundColor Cyan

$count    = 0
$arrayPtr = [IntPtr]::Zero
$CRED_ENUMERATE_ALL_CREDENTIALS = 1

$ok = [FabriqBackUper.PoC.CredApi]::CredEnumerate([IntPtr]::Zero, $CRED_ENUMERATE_ALL_CREDENTIALS, [ref]$count, [ref]$arrayPtr)
if (-not $ok) {
    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($err -eq 1168) {
        # ERROR_NOT_FOUND - vault is empty (legitimate)
        Write-Host "No credentials found (ERROR_NOT_FOUND, vault is empty)." -ForegroundColor Yellow
        exit 0
    }
    throw "CredEnumerate failed: Win32Error=$err"
}

Write-Host ("Credential count: {0}" -f $count) -ForegroundColor Green
Write-Host ''

$entries = New-Object System.Collections.Generic.List[object]
try {
    $ptrSize = [System.IntPtr]::Size
    for ($i = 0; $i -lt $count; $i++) {
        $credPtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($arrayPtr, $i * $ptrSize)
        $cred    = [System.Runtime.InteropServices.Marshal]::PtrToStructure(
            $credPtr, [type][FabriqBackUper.PoC.CredApi+CREDENTIAL])

        $entries.Add([PSCustomObject]@{
            Idx         = $i
            Type        = ConvertFrom-CredType $cred.Type
            Target      = Read-LPWStr $cred.TargetName
            UserName    = Read-LPWStr $cred.UserName
            Persist     = ConvertFrom-CredPersist $cred.Persist
            BlobSize    = [int]$cred.CredentialBlobSize
            Comment     = Read-LPWStr $cred.Comment
            LastWritten = ConvertFrom-Win32FileTime $cred.LastWritten
        }) | Out-Null
    }
} finally {
    [FabriqBackUper.PoC.CredApi]::CredFree($arrayPtr)
}

$entries | Format-Table -AutoSize -Wrap Idx, Type, Target, UserName, Persist, BlobSize, LastWritten

Write-Host ''
Write-Host "PoC 01 complete." -ForegroundColor Cyan
