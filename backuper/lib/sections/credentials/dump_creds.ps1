# ============================================================
# FabriqBackUper Section: credentials / dump_creds.ps1 (v0.19.0)
#
# Standalone child script. Reads the CALLING process user's
# Windows Credential Manager vault via Win32 CredEnumerate and
# serializes metadata + blob byte length per entry to a JSON
# file at -OutputPath.
#
# Spawned by backup.ps1 via Register-ScheduledTask /
# LogonType=Interactive when the target user differs from the
# admin process user. May also be invoked directly (out-of-band)
# for diagnostics.
#
# Password blobs (CredentialBlob bytes) are NEVER decoded or
# written - only their byte length is recorded.
#
# Output schema (UTF-8 JSON):
#   {
#     "schemaVersion": 1,
#     "timestamp":     "ISO8601",
#     "userDomain":    "...",
#     "userName":      "...",
#     "apiSuccess":    true|false,
#     "apiLastError":  <Win32 error code; 0 on success>,
#     "credentials":   [ { target, type, userName, persist,
#                          comment, lastWritten, blobSize }, ... ]
#   }
#
# Exit codes:
#   0  - success (apiSuccess=true), or vault empty (ERROR_NOT_FOUND)
#   1  - any other failure; JSON still written with apiSuccess=false
#        and apiLastError populated when possible.
#
# No dependency on backuper/common.ps1 (child runs in a separate
# process, possibly with limited privileges, and we want the
# script self-contained for diagnostic re-runs).
# ============================================================

param(
    [Parameter(Mandatory = $true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------
# P/Invoke definitions
#
# Notes:
#   - filter is declared as IntPtr (not string) because PowerShell's
#     string marshaling converts $null to "" which is rejected by
#     CredEnumerateW with ERROR_INVALID_FLAGS (1004). Passing
#     IntPtr::Zero gives a true NULL filter.
#   - CharSet=Unicode -> CredEnumerateW (W variant), so all string
#     pointers in the returned CREDENTIAL struct are LPWSTR.
# ----------------------------------------------------------
Add-Type -Namespace FabriqBackUper -Name CredApi -MemberDefinition @"
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
"@ -ErrorAction Stop

# ----------------------------------------------------------
# Conversion helpers
# ----------------------------------------------------------
function _ReadStr([IntPtr]$Ptr) {
    if ($Ptr -eq [IntPtr]::Zero) { return $null }
    return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($Ptr)
}

function _FtToIso($Ft) {
    if ($Ft.dwHighDateTime -eq 0 -and $Ft.dwLowDateTime -eq 0) { return $null }
    # FILETIME.dwLow/HighDateTime are Int32 in System.Runtime.InteropServices.ComTypes;
    # mask to lower 32 bits to suppress sign-extension when the high bit is set, then
    # assemble as the unsigned-equivalent Int64. The mask MUST be decimal: 0xFFFFFFFF
    # parses as Int32 -1 in PowerShell and turns the -band into a no-op; 4294967295
    # exceeds Int32 range so it parses as Int64, giving the correct lower-32-bit mask.
    $hi = ([int64]$Ft.dwHighDateTime) -band [int64]4294967295
    $lo = ([int64]$Ft.dwLowDateTime)  -band [int64]4294967295
    $val = ($hi -shl 32) -bor $lo
    try { return [datetime]::FromFileTimeUtc($val).ToString('o') } catch { return $null }
}

function _TypeName([uint32]$t) {
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

function _PersistName([uint32]$p) {
    switch ($p) {
        1 { 'Session' }
        2 { 'LocalMachine' }
        3 { 'Enterprise' }
        default { "Unknown($p)" }
    }
}

# ----------------------------------------------------------
# Enumerate
# ----------------------------------------------------------
$count    = 0
$arrayPtr = [IntPtr]::Zero
$lastErr  = 0
$entries  = New-Object System.Collections.Generic.List[object]
$CRED_ENUMERATE_ALL_CREDENTIALS = 1
$ERROR_NOT_FOUND = 1168

$ok = [FabriqBackUper.CredApi]::CredEnumerate([IntPtr]::Zero, $CRED_ENUMERATE_ALL_CREDENTIALS, [ref]$count, [ref]$arrayPtr)
if (-not $ok) {
    $lastErr = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    # Empty vault is a legitimate success - treat as ok with count=0
    if ($lastErr -eq $ERROR_NOT_FOUND) {
        $ok = $true
        $count = 0
        $lastErr = 0
    }
}

if ($ok -and $count -gt 0) {
    try {
        $ptrSize = [System.IntPtr]::Size
        for ($i = 0; $i -lt $count; $i++) {
            $credPtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($arrayPtr, $i * $ptrSize)
            $cred    = [System.Runtime.InteropServices.Marshal]::PtrToStructure(
                $credPtr, [type][FabriqBackUper.CredApi+CREDENTIAL])

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
        [FabriqBackUper.CredApi]::CredFree($arrayPtr)
    }
}

# ----------------------------------------------------------
# Emit JSON
# ----------------------------------------------------------
$payload = [PSCustomObject]@{
    schemaVersion = 1
    timestamp     = (Get-Date).ToString('o')
    userDomain    = $env:USERDOMAIN
    userName      = $env:USERNAME
    apiSuccess    = [bool]$ok
    apiLastError  = [int]$lastErr
    credentials   = $entries
}

try {
    # Ensure parent directory exists
    $outDir = Split-Path -Parent $OutputPath
    if (-not (Test-Path $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    $payload | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputPath -Encoding UTF8
} catch {
    # Last-ditch: write a minimal error JSON
    try {
        [PSCustomObject]@{
            schemaVersion = 1
            apiSuccess    = $false
            apiLastError  = -1
            error         = $_.Exception.Message
        } | ConvertTo-Json | Set-Content -Path $OutputPath -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {}
    exit 1
}

if ($ok) { exit 0 } else { exit 1 }
