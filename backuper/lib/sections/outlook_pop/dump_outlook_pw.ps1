# ============================================================
# FabriqBackUper Section: outlook_pop / dump_outlook_pw.ps1 (v0.35.0)
#
# Standalone child script. Recovers saved Outlook (2016/2019/2021/365 = 16.0,
# 2013 = 15.0) POP3/IMAP/SMTP account passwords for the CALLING process user
# and serializes them to a JSON file at -OutputPath.
#
# Why a child: modern Outlook stores each saved password as a user-scoped
# DPAPI blob in the registry value (a 0x02 tag byte followed by the output of
# CryptProtectData). DPAPI can only be decrypted inside the OWNING user's
# logon session, so this script must run AS the source user. The backup
# section spawns it via Invoke-ChildAsTargetUser (direct child when admin ==
# source user, else a LogonType=Interactive scheduled task).
#
# Storage format (confirmed on real machines, byte-verified):
#   value 'POP3 Password' (or 'IMAP Password' / 'SMTP Password') REG_BINARY:
#     [0]      = 0x02 tag
#     [1..]    = standard DPAPI blob (AES-256/SHA-512), szDescription = the
#                value name. CryptUnprotectData (no entropy) returns the
#                password as a UTF-16LE string.
#
# Output schema (UTF-8 JSON):
#   {
#     "schemaVersion": 1,
#     "type":          "fabriq-outlook-pw-dump",
#     "timestamp":     "ISO8601",
#     "userDomain":    "...",
#     "userName":      "...",
#     "accounts": [
#       { "version":"16.0", "profile":"Outlook", "subKey":"00000002",
#         "email":"...", "accountName":"...",
#         "passwords": { "pop3":"...", "smtp":"...", "imap":"..." } },
#       ...
#     ]
#   }
#   Only passwords that decrypted successfully are included.
#
# Exit codes:
#   0  - JSON written (with zero or more accounts).
#   1  - failed to write JSON.
#
# No dependency on backuper/common.ps1 (separate process, possibly limited
# privileges; kept self-contained for diagnostic re-runs).
# ============================================================

param(
    [Parameter(Mandatory = $true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------
# DPAPI P/Invoke (CryptUnprotectData)
# ----------------------------------------------------------
Add-Type -Namespace FabriqOutlookPw -Name Dpapi -MemberDefinition @"
[StructLayout(LayoutKind.Sequential)]
public struct DATA_BLOB { public int cbData; public IntPtr pbData; }

[DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern bool CryptUnprotectData(
    ref DATA_BLOB pDataIn, ref IntPtr ppszDataDescr, IntPtr pOptionalEntropy,
    IntPtr pvReserved, IntPtr pPromptStruct, int dwFlags, ref DATA_BLOB pDataOut);

[DllImport("kernel32.dll")]
public static extern IntPtr LocalFree(IntPtr hMem);
"@ -ErrorAction Stop

function Get-DpapiPlaintext([byte[]]$Raw) {
    # $Raw is the full REG_BINARY value. Strip the leading 0x02 tag, DPAPI-
    # decrypt the remainder, and return the password as a UTF-16LE string.
    # Returns $null when the value is not a decryptable 0x02 DPAPI blob.
    if ($null -eq $Raw -or $Raw.Length -lt 2) { return $null }
    if ($Raw[0] -ne 0x02) { return $null }
    $blob = New-Object byte[] ($Raw.Length - 1)
    [Array]::Copy($Raw, 1, $blob, 0, $Raw.Length - 1)

    $pin = [System.Runtime.InteropServices.GCHandle]::Alloc($blob, [System.Runtime.InteropServices.GCHandleType]::Pinned)
    try {
        $in = New-Object FabriqOutlookPw.Dpapi+DATA_BLOB
        $in.cbData = $blob.Length
        $in.pbData = $pin.AddrOfPinnedObject()
        $out = New-Object FabriqOutlookPw.Dpapi+DATA_BLOB
        $descrPtr = [IntPtr]::Zero
        $ok = [FabriqOutlookPw.Dpapi]::CryptUnprotectData([ref]$in, [ref]$descrPtr, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, 0, [ref]$out)
        if (-not $ok) { return $null }
        try {
            if ($out.cbData -le 0) { return '' }
            $plain = New-Object byte[] $out.cbData
            [System.Runtime.InteropServices.Marshal]::Copy($out.pbData, $plain, 0, $out.cbData)
            return ([System.Text.Encoding]::Unicode.GetString($plain)).TrimEnd([char]0)
        } finally {
            if ($out.pbData -ne [IntPtr]::Zero) { [void][FabriqOutlookPw.Dpapi]::LocalFree($out.pbData) }
            if ($descrPtr -ne [IntPtr]::Zero) { [void][FabriqOutlookPw.Dpapi]::LocalFree($descrPtr) }
        }
    } finally {
        $pin.Free()
    }
}

function Get-RegBinary([Microsoft.Win32.RegistryKey]$Key, [string]$Name) {
    $v = $Key.GetValue($Name, $null)
    if ($null -eq $v) { return $null }
    if ($v -is [byte[]]) { return ,([byte[]]$v) }
    return $null
}

function Get-RegText([Microsoft.Win32.RegistryKey]$Key, [string]$Name) {
    $v = $Key.GetValue($Name, $null)
    if ($null -eq $v) { return $null }
    if ($v -is [byte[]]) {
        try { return ([System.Text.Encoding]::Unicode.GetString([byte[]]$v)).TrimEnd([char]0) } catch { return $null }
    }
    return [string]$v
}

# ----------------------------------------------------------
# Enumerate Outlook profiles -> internet-account subkeys
# ----------------------------------------------------------
$ACCOUNT_GUID = '9375CFF0413111d3B88A00104B2A6676'
$PW_VALUES = @(
    @{ proto = 'pop3'; name = 'POP3 Password' }
    @{ proto = 'imap'; name = 'IMAP Password' }
    @{ proto = 'smtp'; name = 'SMTP Password' }
)

$accounts = New-Object System.Collections.Generic.List[object]

foreach ($ver in @('16.0', '15.0')) {
    $profilesPath = "Software\Microsoft\Office\$ver\Outlook\Profiles"
    $profilesKey  = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($profilesPath)
    if ($null -eq $profilesKey) { continue }
    try {
        foreach ($profileName in $profilesKey.GetSubKeyNames()) {
            $containerPath = "$profilesPath\$profileName\$ACCOUNT_GUID"
            $cKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($containerPath)
            if ($null -eq $cKey) { continue }
            try {
                foreach ($subKey in $cKey.GetSubKeyNames()) {
                    if ($subKey -notmatch '^[0-9A-Fa-f]{8}$') { continue }
                    $aKey = $cKey.OpenSubKey($subKey)
                    if ($null -eq $aKey) { continue }
                    try {
                        $pwObj = [ordered]@{}
                        foreach ($pv in $PW_VALUES) {
                            $raw = Get-RegBinary $aKey $pv.name
                            if ($null -eq $raw) { continue }
                            $plain = Get-DpapiPlaintext $raw
                            if (-not [string]::IsNullOrEmpty($plain)) { $pwObj[$pv.proto] = $plain }
                        }
                        if ($pwObj.Count -gt 0) {
                            $accounts.Add([ordered]@{
                                version     = $ver
                                profile     = $profileName
                                subKey      = $subKey
                                email       = (Get-RegText $aKey 'Email')
                                accountName = (Get-RegText $aKey 'Account Name')
                                passwords   = $pwObj
                            }) | Out-Null
                        }
                    } finally { $aKey.Close() }
                }
            } finally { $cKey.Close() }
        }
    } finally { $profilesKey.Close() }
}

# ----------------------------------------------------------
# Emit JSON
# ----------------------------------------------------------
$payload = [ordered]@{
    schemaVersion = 1
    type          = 'fabriq-outlook-pw-dump'
    timestamp     = (Get-Date).ToString('o')
    userDomain    = $env:USERDOMAIN
    userName      = $env:USERNAME
    accounts      = $accounts.ToArray()
}

try {
    $outDir = Split-Path -Parent $OutputPath
    if ($outDir -and -not (Test-Path $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    $payload | ConvertTo-Json -Depth 6 | Set-Content -Path $OutputPath -Encoding UTF8
} catch {
    try {
        [PSCustomObject]@{ schemaVersion = 1; type = 'fabriq-outlook-pw-dump'; error = $_.Exception.Message } |
            ConvertTo-Json | Set-Content -Path $OutputPath -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {}
    exit 1
}

exit 0
