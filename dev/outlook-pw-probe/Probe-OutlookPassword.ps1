<#
.SYNOPSIS
  Read-only diagnostic probe for saved Outlook account passwords (registry-XOR
  and Credential Manager forms).

.DESCRIPTION
  Confirms, on a real test machine, HOW saved Outlook POP/IMAP/SMTP passwords are
  stored, so the Fabriq BackUper "recover saved password at backup time" feature
  can be implemented against VERIFIED bytes.

  Field finding (2026-06-03, CONFIRMED by byte analysis): on a machine with 2 POP
  accounts, Credential Manager held NO mail credential, yet NirSoft Mail PassView
  recovered the passwords. The 'POP3 Password' REG_BINARY value (273 bytes,
  prefix byte 0x02) is a standard user-scoped DPAPI blob (dwVersion=1, provider
  GUID df9d8cd0-1501-11d1-..., szDescription "POP3 Password", CALG_AES_256 +
  CALG_SHA_512, salt/hmac/ciphertext/signature). So the modern Outlook password
  is NOT in Credential Manager and NOT a static-XOR payload - it is a DPAPI blob
  stored directly in the registry, decryptable with CryptUnprotectData IN THE
  OWNING USER'S SESSION (DPAPI is user-bound). mailpv's tag-0x02 path therefore
  calls CryptUnprotectData (the decompiled "CredReadA" reading was a garbled
  artifact). Production implication: recovery must run as the source user (the
  credentials-section schtasks /IT child pattern), not from an offline HKU read.

  This probe:
    1. Recursively walks every registry root Mail PassView scans (modern Outlook
       Profiles, MAPI Windows Messaging Subsystem, OMI Account Manager, Internet
       Account Manager) and reports EVERY value whose name contains "Password",
       regardless of subkey depth or value type.
    2. For each binary password value, attempts BOTH decryptors and reports which
       works: (a) CryptUnprotectData with the 0x02 tag stripped (offset 1) and on
       the whole value (offset 0) - the modern DPAPI path; (b) the legacy static-
       XOR (key {0x75,0x18,0x15,0x14}, from decompiled FUN_00469be0) at several
       offsets - for old Outlook Express / Outlook 2002-2010. With -ExpectedPassword
       it flags MATCH without revealing the secret.

  EXECUTION CONTEXT:
    Run AS THE OUTLOOK USER (own HKCU). No administrator rights required. For the
    DPAPI form the user session IS required to decrypt (that is the whole point),
    so running as the account owner is what proves the production path.

  SAFETY (read this):
    100% READ-ONLY. No registry writes, no vault changes, no scheduled tasks.
    Only the JSON report at -OutPath is written.
    Recovered passwords are MASKED by default; raw *Password* bytes are REDACTED.
    With -ExpectedPassword you get a definitive MATCH/NO-MATCH (and a decryptOk
    flag) WITHOUT exposing anything - safe to share. Use -RevealPlaintext only on
    a box where you accept seeing the plaintext (e.g. your own machine or a VM).
    Pass the REAL account password as -ExpectedPassword to get MATCH without
    sharing it.

.PARAMETER OutPath
  JSON report path. Default: <Desktop>\outlook_pw_probe_<timestamp>.json

.PARAMETER ExpectedPassword
  Known test password. Each candidate decryption is compared (case-sensitive) and
  reported as MATCH / NO-MATCH, without printing the secret.

.PARAMETER RevealPlaintext
  Print recovered passwords AND the raw encrypted bytes in clear. VM only.

.PARAMETER MaxDepth
  Max registry recursion depth under each root (default 8).

.PARAMETER MaxHexBytes
  Cap on hex-dump length per value when -RevealPlaintext (default 512).

.EXAMPLE
  .\Probe-OutlookPassword.ps1 -ExpectedPassword 'TestPass2026!'
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'ExpectedPassword',
    Justification = 'Diagnostic tool: a plain known test password is compared to produce a MATCH/NO-MATCH check without revealing secrets; SecureString would defeat the test-friendly design.')]
param(
    [string]$OutPath,
    [string]$ExpectedPassword,
    [switch]$RevealPlaintext,
    [int]$MaxDepth = 8,
    [int]$MaxHexBytes = 512
)

$ErrorActionPreference = 'Stop'
$script:HasExpected = $PSBoundParameters.ContainsKey('ExpectedPassword') -and -not [string]::IsNullOrEmpty($ExpectedPassword)

# ============================================================
# Win32 Credential Manager P/Invoke (CredEnumerateW / CredReadW)
# ============================================================
Add-Type -Namespace OutlookPwProbe -Name CredApi -MemberDefinition @"
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

# ============================================================
# Win32 DPAPI P/Invoke (CryptUnprotectData) - the real decryptor for the
# modern Outlook 'POP3 Password' value, which is a user-scoped DPAPI blob
# (AES-256/SHA-512) prefixed with a 0x02 tag byte.
# ============================================================
Add-Type -Namespace OutlookPwProbe -Name Dpapi -MemberDefinition @"
[StructLayout(LayoutKind.Sequential)]
public struct DATA_BLOB { public int cbData; public IntPtr pbData; }

[DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern bool CryptUnprotectData(
    ref DATA_BLOB pDataIn, ref IntPtr ppszDataDescr, IntPtr pOptionalEntropy,
    IntPtr pvReserved, IntPtr pPromptStruct, int dwFlags, ref DATA_BLOB pDataOut);

[DllImport("kernel32.dll")]
public static extern IntPtr LocalFree(IntPtr hMem);
"@ -ErrorAction Stop

# ----------------------------------------------------------
# Helpers
# ----------------------------------------------------------
function _ReadStr([IntPtr]$Ptr) {
    if ($Ptr -eq [IntPtr]::Zero) { return $null }
    return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($Ptr)
}

function _TypeName([uint32]$t) {
    switch ($t) {
        1 { 'Generic' }; 2 { 'DomainPassword' }; 3 { 'DomainCertificate' }
        4 { 'DomainVisiblePassword' }; 5 { 'GenericCertificate' }; 6 { 'DomainExtended' }
        default { "Unknown($t)" }
    }
}

# $s intentionally UNTYPED so $null survives (a [string] param coerces $null -> '').
function Format-Secret($s) {
    if ($null -eq $s) { return $null }
    if ($RevealPlaintext) { return $s }
    if ($s.Length -eq 0) { return '(empty)' }
    if ($s.Length -le 2) { return ('*** (len={0})' -f $s.Length) }
    $first = $s.Substring(0, 1)
    $last  = $s.Substring($s.Length - 1, 1)
    return ('{0}***{1} (len={2})' -f $first, $last, $s.Length)
}

function Test-SecretMatch($s) {
    if (-not $script:HasExpected) { return $null }
    if ($null -eq $s) { return $null }
    return ([string]$s -ceq $ExpectedPassword)
}

function Format-HexDump([byte[]]$Bytes, [int]$Max) {
    if ($null -eq $Bytes) { return @() }
    $n = [Math]::Min($Bytes.Length, $Max)
    $lines = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $n; $i += 16) {
        $hex = ''
        $asc = ''
        for ($j = 0; $j -lt 16; $j++) {
            if ($i + $j -lt $n) {
                $b = $Bytes[$i + $j]
                $hex += ('{0:x2} ' -f $b)
                if ($b -ge 0x20 -and $b -le 0x7e) { $asc += [char]$b } else { $asc += '.' }
            } else { $hex += '   ' }
        }
        $lines.Add(('{0:x4}  {1} {2}' -f $i, $hex, $asc)) | Out-Null
    }
    if ($Bytes.Length -gt $Max) { $lines.Add(('... ({0} more bytes truncated)' -f ($Bytes.Length - $Max))) | Out-Null }
    return $lines.ToArray()
}

# ============================================================
# Static-XOR decryptor - faithful port of FUN_00469be0
#   key {0x75,0x18,0x15,0x14}; CBC-like feedback; tail_shift = 4-(len%4)
#   for the final partial block. kidx stays within 0..3 (proven).
# ============================================================
function Invoke-MailpvXor([byte[]]$Cipher) {
    $len = $Cipher.Length
    $out = New-Object byte[] $len
    if ($len -eq 0) { return ,$out }
    $state = [byte[]]@(0x75, 0x18, 0x15, 0x14)
    $full  = [int]([Math]::Floor($len / 4)) * 4
    $mod   = $len - $full
    for ($i = 0; $i -lt $len; $i++) {
        $tail = 0
        if ($full -le $i) { $tail = 4 - $mod }
        $kidx = $tail + ($i -band 3)
        if ($i -ge 4) {
            $ci = $tail + $i - 4
            $state[$kidx] = [byte]((($state[$kidx] -bxor $Cipher[$ci]) -band 0xFF))
        }
        $out[$i] = [byte]((($state[$kidx] -bxor $Cipher[$i]) -band 0xFF))
    }
    return ,$out
}

# Try the static-XOR decryption at several candidate (offset,length) layouts and
# report which yields the known test password. Tag-0x01 spec layout: byte0=tag,
# byte1=subtag, byte2=payload len, byte3-5=pad, byte6..=cipher.
function New-XorAttempts([byte[]]$Raw) {
    $attempts = New-Object System.Collections.Generic.List[object]
    $L = $Raw.Length
    $candidates = New-Object System.Collections.Generic.List[object]
    if ($L -gt 2) { $candidates.Add(@{ name = 'spec (off=6,len=byte[2])'; off = 6; len = [int]$Raw[2] }) | Out-Null }
    if ($L -gt 6) { $candidates.Add(@{ name = 'tail (off=6)';             off = 6; len = ($L - 6) }) | Out-Null }
    if ($L -gt 1) { $candidates.Add(@{ name = 'tail (off=1)';             off = 1; len = ($L - 1) }) | Out-Null }
    $candidates.Add(@{ name = 'whole (off=0)'; off = 0; len = $L }) | Out-Null

    foreach ($c in $candidates) {
        $off = [int]$c.off; $len = [int]$c.len
        if ($off -lt 0 -or $len -le 0 -or ($off + $len) -gt $L) { continue }
        $cipher = New-Object byte[] $len
        [Array]::Copy($Raw, $off, $cipher, 0, $len)
        $plain = Invoke-MailpvXor $cipher
        $ascii = ([System.Text.Encoding]::ASCII.GetString($plain)).TrimEnd([char]0)
        $utf16 = ([System.Text.Encoding]::Unicode.GetString($plain)).TrimEnd([char]0)
        $attempts.Add([ordered]@{
            candidate   = $c.name
            offset      = $off
            len         = $len
            asciiMasked = (Format-Secret $ascii)
            asciiMatch  = (Test-SecretMatch $ascii)
            utf16Masked = (Format-Secret $utf16)
            utf16Match  = (Test-SecretMatch $utf16)
        }) | Out-Null
    }
    return $attempts.ToArray()
}

# Tag-0x02 (Credential Manager) value: bytes after the tag are the CredMan target.
function Get-TagText([byte[]]$Bytes) {
    if ($null -eq $Bytes -or $Bytes.Length -lt 2) { return @{ utf16 = $null; ascii = $null } }
    $tail = New-Object byte[] ($Bytes.Length - 1)
    [Array]::Copy($Bytes, 1, $tail, 0, $Bytes.Length - 1)
    $utf16 = $null; $ascii = $null
    try { $utf16 = ([System.Text.Encoding]::Unicode.GetString($tail)).Trim([char]0) } catch {}
    try { $ascii = ([System.Text.Encoding]::ASCII.GetString($tail)).Trim([char]0) } catch {}
    return @{ utf16 = $utf16; ascii = $ascii }
}

# Decrypt a DPAPI blob via CryptUnprotectData in the CURRENT user's context.
# Returns @{ ok; bytes; descr; error }. No optional entropy (Outlook uses none).
function Invoke-DpapiUnprotect([byte[]]$Blob) {
    if ($null -eq $Blob -or $Blob.Length -eq 0) { return @{ ok = $false; bytes = $null; descr = $null; error = -1 } }
    $pin = [System.Runtime.InteropServices.GCHandle]::Alloc($Blob, [System.Runtime.InteropServices.GCHandleType]::Pinned)
    try {
        $in = New-Object OutlookPwProbe.Dpapi+DATA_BLOB
        $in.cbData = $Blob.Length
        $in.pbData = $pin.AddrOfPinnedObject()
        $out = New-Object OutlookPwProbe.Dpapi+DATA_BLOB
        $descrPtr = [IntPtr]::Zero
        $ok = [OutlookPwProbe.Dpapi]::CryptUnprotectData([ref]$in, [ref]$descrPtr, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, 0, [ref]$out)
        if ($ok) {
            $bytes = New-Object byte[] $out.cbData
            if ($out.cbData -gt 0) { [System.Runtime.InteropServices.Marshal]::Copy($out.pbData, $bytes, 0, $out.cbData) }
            $descr = $null
            if ($descrPtr -ne [IntPtr]::Zero) { $descr = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($descrPtr) }
            [void][OutlookPwProbe.Dpapi]::LocalFree($out.pbData)
            if ($descrPtr -ne [IntPtr]::Zero) { [void][OutlookPwProbe.Dpapi]::LocalFree($descrPtr) }
            return @{ ok = $true; bytes = $bytes; descr = $descr; error = 0 }
        }
        return @{ ok = $false; bytes = $null; descr = $null; error = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error() }
    } finally { $pin.Free() }
}

# Try CryptUnprotectData with the 0x02 tag stripped (offset 1) and on the whole
# value (offset 0). Reports decryptOk + the recovered plaintext (masked) + match.
function New-DpapiAttempts([byte[]]$Raw) {
    $attempts = New-Object System.Collections.Generic.List[object]
    $L = $Raw.Length
    foreach ($off in @(1, 0)) {
        if ($off -ge $L) { continue }
        $blob = New-Object byte[] ($L - $off)
        [Array]::Copy($Raw, $off, $blob, 0, $L - $off)
        $r = Invoke-DpapiUnprotect $blob
        $ascii = $null; $utf16 = $null
        if ($r.ok -and $r.bytes) {
            $ascii = ([System.Text.Encoding]::ASCII.GetString($r.bytes)).TrimEnd([char]0)
            $utf16 = ([System.Text.Encoding]::Unicode.GetString($r.bytes)).TrimEnd([char]0)
        }
        $attempts.Add([ordered]@{
            offsetStripped = $off
            decryptOk      = [bool]$r.ok
            win32Error     = $r.error
            description    = $r.descr
            asciiMasked    = (Format-Secret $ascii)
            asciiMatch     = (Test-SecretMatch $ascii)
            utf16Masked    = (Format-Secret $utf16)
            utf16Match     = (Test-SecretMatch $utf16)
        }) | Out-Null
    }
    return $attempts.ToArray()
}

# Decode an arbitrary registry value for human-readable context display.
function Read-RegValueForDisplay([Microsoft.Win32.RegistryKey]$Key, [string]$Name) {
    $kind = $Key.GetValueKind($Name).ToString()
    $v = $Key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if ($kind -eq 'Binary') {
        $bytes = [byte[]]$v
        $txt = ([System.Text.Encoding]::Unicode.GetString($bytes)).TrimEnd([char]0)
        if ($txt -match '^[\x20-\x7e]+$') { return $txt }
        if ($bytes.Length -eq 4) { return [System.BitConverter]::ToInt32($bytes, 0) }
        return ('(binary {0} bytes)' -f $bytes.Length)
    } elseif ($kind -eq 'DWord') {
        return [int]$v
    }
    return [string]$v
}

# ============================================================
# Credential Manager vault enumeration (this user)
# ============================================================
function Get-VaultEntries {
    $count = 0; $arrayPtr = [IntPtr]::Zero
    $CRED_ENUMERATE_ALL = 1; $ERROR_NOT_FOUND = 1168
    $result = [ordered]@{ apiSuccess = $false; apiLastError = -1; entries = @() }

    $ok = [OutlookPwProbe.CredApi]::CredEnumerate([IntPtr]::Zero, $CRED_ENUMERATE_ALL, [ref]$count, [ref]$arrayPtr)
    if (-not $ok) {
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($err -eq $ERROR_NOT_FOUND) { $result.apiSuccess = $true; $result.apiLastError = 0; return $result }
        $result.apiLastError = $err; return $result
    }
    $list = New-Object System.Collections.Generic.List[object]
    try {
        $ptrSize = [System.IntPtr]::Size
        for ($i = 0; $i -lt $count; $i++) {
            $credPtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($arrayPtr, $i * $ptrSize)
            $cred = [System.Runtime.InteropServices.Marshal]::PtrToStructure($credPtr, [type][OutlookPwProbe.CredApi+CREDENTIAL])
            $blobText = ''
            if ($cred.CredentialBlobSize -gt 0 -and $cred.CredentialBlob -ne [IntPtr]::Zero) {
                $blob = New-Object byte[] ([int]$cred.CredentialBlobSize)
                [System.Runtime.InteropServices.Marshal]::Copy($cred.CredentialBlob, $blob, 0, [int]$cred.CredentialBlobSize)
                $blobText = ([System.Text.Encoding]::Unicode.GetString($blob)).TrimEnd([char]0)
            }
            $list.Add([PSCustomObject][ordered]@{
                target   = _ReadStr $cred.TargetName
                type     = _TypeName $cred.Type
                userName = _ReadStr $cred.UserName
                comment  = _ReadStr $cred.Comment
                blobSize = [int]$cred.CredentialBlobSize
                blobMasked = (Format-Secret $blobText)
                blobMatch  = (Test-SecretMatch $blobText)
            }) | Out-Null
        }
    } finally { [OutlookPwProbe.CredApi]::CredFree($arrayPtr) }
    $result.apiSuccess = $true; $result.apiLastError = 0; $result.entries = $list.ToArray()
    return $result
}

# ============================================================
# Recursive registry walk: find EVERY *Password* value under the roots
# Mail PassView scans, regardless of depth or value type.
# ============================================================
function Add-PasswordFindings([string]$Path, [int]$Depth, [int]$Max, $Sink) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Path)
    if ($null -eq $key) { return }
    try {
        $valueNames = @($key.GetValueNames())
        $pwNames = @($valueNames | Where-Object { $_ -match 'Password' })
        if ($pwNames.Count -gt 0) {
            $context = [ordered]@{}
            foreach ($vn in $valueNames) {
                if ($vn -match 'Server|User|Email|Display Name|Account Name|Port|Connection|SPA|SMTP|Protocol') {
                    try { $context[$vn] = (Read-RegValueForDisplay $key $vn) } catch { $context[$vn] = '(decode error)' }
                }
            }
            foreach ($pwn in $pwNames) {
                $kind = $key.GetValueKind($pwn).ToString()
                $raw = $null
                if ($kind -eq 'Binary') { try { $raw = [byte[]]$key.GetValue($pwn) } catch { $raw = $null } }

                $tag = -1
                if ($null -ne $raw -and $raw.Length -gt 0) { $tag = [int]$raw[0] }
                $tagByteStr = if ($tag -ge 0) { '0x{0:x2}' -f $tag } else { 'n/a' }
                $tagMeaning = switch ($tag) {
                    1       { 'tag 0x01 = PStore/XOR (registry-recoverable, context-free)' }
                    2       { 'tag 0x02 = Credential Manager (DPAPI, needs user session)' }
                    default { 'unknown / non-binary' }
                }
                $byteLen = $null
                if ($null -ne $raw) { $byteLen = $raw.Length }

                $finding = [ordered]@{
                    keyPath    = $Path
                    valueName  = $pwn
                    valueKind  = $kind
                    byteLength = $byteLen
                    tagByte    = $tagByteStr
                    tagMeaning = $tagMeaning
                    context    = $context
                }
                if ($null -ne $raw) {
                    if ($RevealPlaintext) {
                        $finding.hexDump   = (Format-HexDump $raw $MaxHexBytes)
                        $finding.rawBase64 = [System.Convert]::ToBase64String($raw)
                    } else {
                        $finding.hexDump   = @('[redacted: encrypted *Password* bytes are effectively the plaintext under the public XOR; use -RevealPlaintext on a throwaway VM]')
                        $finding.rawBase64 = '[redacted]'
                    }
                    $finding.xorAttempts   = (New-XorAttempts $raw)
                    $finding.dpapiAttempts = (New-DpapiAttempts $raw)
                    if ($tag -eq 2) {
                        $tt = Get-TagText $raw
                        $finding.credTargetUtf16 = $tt.utf16
                        $finding.credTargetAscii = $tt.ascii
                    }
                }
                $Sink.Add([PSCustomObject]$finding) | Out-Null
            }
        }
        if ($Depth -lt $Max) {
            foreach ($sub in $key.GetSubKeyNames()) {
                Add-PasswordFindings "$Path\$sub" ($Depth + 1) $Max $Sink
            }
        }
    } catch {
        # ignore per-key access errors; keep walking
    } finally { $key.Close() }
}

# ============================================================
# Run
# ============================================================
$ident = "$env:USERDOMAIN\$env:USERNAME"
$ts    = (Get-Date).ToString('yyyyMMdd_HHmmss')
if ([string]::IsNullOrWhiteSpace($OutPath)) {
    $OutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) "outlook_pw_probe_$ts.json"
}

$ROOTS = @(
    'Software\Microsoft\Office\16.0\Outlook\Profiles'
    'Software\Microsoft\Office\15.0\Outlook\Profiles'
    'Software\Microsoft\Office\14.0\Outlook\Profiles'
    'Software\Microsoft\Windows Messaging Subsystem\Profiles'
    'Software\Microsoft\Windows NT\CurrentVersion\Windows Messaging Subsystem\Profiles'
    'Software\Microsoft\Office\Outlook\OMI Account Manager\Accounts'
    'Software\Microsoft\Internet Account Manager\Accounts'
)

Write-Host ''
Write-Host '=== Outlook saved-password probe (READ-ONLY) ===' -ForegroundColor Cyan
Write-Host ("Running as : {0}" -f $ident)
Write-Host ("Reveal     : {0}   ExpectedPassword : {1}" -f $RevealPlaintext.IsPresent, $script:HasExpected)
if (-not $RevealPlaintext -and -not $script:HasExpected) {
    Write-Host 'TIP: pass -ExpectedPassword to get a definitive MATCH/NO-MATCH per candidate layout.' -ForegroundColor DarkYellow
}
Write-Host ''

Write-Host '[1/2] Scanning registry roots for *Password* values...' -ForegroundColor Yellow
$findingsList = New-Object System.Collections.Generic.List[object]
$rootsPresent = New-Object System.Collections.Generic.List[object]
foreach ($r in $ROOTS) {
    $exists = $null -ne [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($r)
    $rootsPresent.Add([ordered]@{ root = $r; exists = $exists }) | Out-Null
    Add-PasswordFindings $r 0 $MaxDepth $findingsList
}
$findings = @($findingsList.ToArray())
Write-Host ("      *Password* values found : {0}" -f $findings.Count)

Write-Host '[2/2] Enumerating Credential Manager vault (this user)...' -ForegroundColor Yellow
$vault = Get-VaultEntries
if (-not $vault.apiSuccess) {
    Write-Host ("      CredEnumerate FAILED (Win32 error {0})." -f $vault.apiLastError) -ForegroundColor Red
} else {
    Write-Host ("      vault entries : {0}" -f $vault.entries.Count)
}

# ---- Console summary ----
Write-Host ''
Write-Host '--- Registry roots ---' -ForegroundColor Cyan
foreach ($rp in $rootsPresent) {
    $col = if ($rp.exists) { 'Gray' } else { 'DarkGray' }
    Write-Host ("  [{0}] {1}" -f ($(if ($rp.exists) { 'present' } else { 'absent ' })), $rp.root) -ForegroundColor $col
}

Write-Host ''
Write-Host '--- *Password* values ---' -ForegroundColor Cyan
if ($findings.Count -eq 0) {
    Write-Host '  (none found under any scanned root)' -ForegroundColor Yellow
}
foreach ($f in $findings) {
    Write-Host ("  {0}" -f $f.keyPath) -ForegroundColor White
    Write-Host ("    value='{0}' kind={1} bytes={2} {3}" -f $f.valueName, $f.valueKind, $f.byteLength, $f.tagMeaning)
    # context (account identity)
    if ($f.context -and $f.context.Keys.Count -gt 0) {
        $ctxStr = ($f.context.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '  '
        Write-Host ("    context: {0}" -f $ctxStr) -ForegroundColor DarkGray
    }
    if ($f.dpapiAttempts) {
        foreach ($da in $f.dpapiAttempts) {
            $tag = if ($da.asciiMatch -eq $true -or $da.utf16Match -eq $true) { 'MATCH' } elseif ($da.decryptOk) { 'decrypted-OK' } else { "fail(err=$($da.win32Error))" }
            $col = if ($da.asciiMatch -eq $true -or $da.utf16Match -eq $true) { 'Green' } elseif ($da.decryptOk) { 'Cyan' } else { 'DarkGray' }
            Write-Host ("      DPAPI strip={0} {1,-12} descr='{2}' ascii={3} utf16={4}" -f `
                $da.offsetStripped, $tag, $da.description, $da.asciiMasked, $da.utf16Masked) -ForegroundColor $col
        }
    }
    if ($f.xorAttempts) {
        foreach ($at in $f.xorAttempts) {
            if ($at.asciiMatch -ne $true -and $at.utf16Match -ne $true) { continue }   # only show XOR if it actually matched
            Write-Host ("      XOR {0,-22} ascii={1} utf16={2}" -f $at.candidate, $at.asciiMasked, $at.utf16Masked) -ForegroundColor Green
        }
    }
}

# ---- JSON report ----
$anyMatch = $false; $anyDpapiMatch = $false; $dpapiOk = $false
foreach ($f in $findings) {
    if ($f.xorAttempts) {
        foreach ($at in $f.xorAttempts) {
            if ($at.asciiMatch -eq $true -or $at.utf16Match -eq $true) { $anyMatch = $true }
        }
    }
    if ($f.dpapiAttempts) {
        foreach ($da in $f.dpapiAttempts) {
            if ($da.decryptOk) { $dpapiOk = $true }
            if ($da.asciiMatch -eq $true -or $da.utf16Match -eq $true) { $anyDpapiMatch = $true }
        }
    }
}
$tag01 = @($findings | Where-Object { $_.tagByte -eq '0x01' }).Count
$tag02 = @($findings | Where-Object { $_.tagByte -eq '0x02' }).Count

$report = [ordered]@{
    schemaVersion    = 2
    reportType       = 'outlook-pw-probe'
    generatedAt      = (Get-Date).ToString('o')
    runningAs        = $ident
    revealPlaintext  = [bool]$RevealPlaintext
    expectedProvided = [bool]$script:HasExpected
    summary          = [ordered]@{
        passwordValueCount = $findings.Count
        tag01Count         = $tag01
        tag02Count         = $tag02
        anyXorMatch        = $anyMatch
        dpapiDecryptOk     = $dpapiOk
        anyDpapiMatch      = $anyDpapiMatch
        vaultEntryCount    = $vault.entries.Count
    }
    rootsScanned     = $rootsPresent.ToArray()
    passwordFindings = $findings
    vault            = [ordered]@{
        apiSuccess   = $vault.apiSuccess
        apiLastError = $vault.apiLastError
        entryCount   = $vault.entries.Count
        entries      = $vault.entries
    }
}

$report | ConvertTo-Json -Depth 14 | Set-Content -Path $OutPath -Encoding UTF8
Write-Host ''
Write-Host ("Report written: {0}" -f $OutPath) -ForegroundColor Cyan
Write-Host 'Safe to share (without -RevealPlaintext): only tag bytes, byte lengths, candidate-layout MATCH flags,' -ForegroundColor DarkGray
Write-Host 'and account context (server/user/email) are included; encrypted password bytes and plaintext are redacted/masked.' -ForegroundColor DarkGray
Write-Host ''
