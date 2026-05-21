# ============================================================
# Resolve-OutlookAccountMapping.ps1
# ----------------------------------------------------------------
# Offline re-parser for outlook_pop backup data (Phase 1 PoC).
#
# Re-derives the Account <-> PST file mapping and the full set of
# POP3 / IMAP / SMTP fields by parsing the raw profile_<name>.reg
# files captured by backuper/lib/sections/outlook_pop/backup.ps1,
# WITHOUT touching the existing manifest.json. This proves the
# new parser logic on real-world data before porting it to the
# live backup.ps1.
#
# Why this exists:
#   - The current backup.ps1 parser fails on Outlook 365's
#     production "mspst.dll" EntryID format -> PST mapping breaks
#     when a profile has multiple PSTs (today's failure mode).
#   - It also doesn't read several 365-era field names
#     (SMTP Secure Connection, Leave on Server, etc.).
#   - The raw .reg file captured by reg.exe export contains ALL
#     the data we need -- the gap is purely in interpretation.
#
# Inputs:
#   -BackupDir    : path to a backup timestamp folder
#                   (e.g. E:\test\outlookbktest\2026_05_21\2026_05_21_184156)
#                   The script reads <BackupDir>\sections\outlook_pop\
#                   profile_*.reg and manifest.json from there.
#
# Outputs (written into <BackupDir>\sections\outlook_pop\):
#   _account_mapping_v2.txt   : human-readable, operator-friendly
#   _account_mapping_v2.json  : machine-readable, structured
#
# This script is standalone -- it does not dot-source the repo's
# common.ps1 and has no runtime dependency on the rest of
# fabriq_backuper. Run it from any PowerShell 5.1+ session.
# ============================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BackupDir
)

$ErrorActionPreference = 'Stop'

# ============================================================
# Small console helpers (kept English-only per project policy)
# ============================================================
function Write-PocInfo    { param([string]$m) Write-Host "[INFO] $m"    -ForegroundColor Cyan }
function Write-PocOk      { param([string]$m) Write-Host "[OK]   $m"    -ForegroundColor Green }
function Write-PocWarn    { param([string]$m) Write-Host "[WARN] $m"    -ForegroundColor Yellow }
function Write-PocErr     { param([string]$m) Write-Host "[ERR]  $m"    -ForegroundColor Red }

# ============================================================
# .reg file parser (UTF-16LE -> structured hash)
# ============================================================
function Read-RegFile {
    # Parse a Windows Registry Editor 5.00 (.reg) file into a hash
    # keyed by subkey path. Each subkey maps to an ordered hash of
    # value-name -> @{ Type; Data; [HexType] }.
    #
    # Type:
    #   'String' : REG_SZ      (Data = string)
    #   'DWord'  : REG_DWORD   (Data = [long] decimal)
    #   'Binary' : REG_BINARY  (Data = [byte[]], HexType = 3 by default)
    #              also covers REG_EXPAND_SZ (hex(2)), REG_MULTI_SZ
    #              (hex(7)), REG_QWORD (hex(b)) via the HexType slot
    #              for callers that care.
    #   'Unknown': anything else (Data = raw text after =)
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "reg file not found: $Path"
    }

    # UTF-16LE (reg.exe export default). ReadAllText handles BOM.
    $content = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::Unicode)

    # Strip BOM if still present (defensive)
    if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) {
        $content = $content.Substring(1)
    }

    # Drop the "Windows Registry Editor Version 5.00" header line
    $content = $content -replace '^Windows Registry Editor Version [\d.]+\s*[\r\n]+', ''

    # Collapse hex multi-line continuations: a line ending with '\'
    # plus a CR/LF plus whitespace on the next line is one logical line.
    $content = $content -replace '\\\r?\n\s+', ''

    $lines = $content -split '\r?\n'

    $subkeys = [ordered]@{}
    $currentKey = $null

    foreach ($rawLine in $lines) {
        $line = $rawLine.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.StartsWith(';')) { continue }    # comments

        # Subkey header: [HKEY_...\...]
        if ($line -match '^\[(.+)\]$') {
            $currentKey = $matches[1]
            if (-not $subkeys.Contains($currentKey)) {
                $subkeys[$currentKey] = [ordered]@{}
            }
            continue
        }

        if ($null -eq $currentKey) { continue }

        # "name"=<value>  (default value is @=<value>)
        $name = $null
        $rest = $null
        if ($line -match '^"((?:[^"\\]|\\.)*)"=(.+)$') {
            $name = $matches[1] -replace '\\"', '"' -replace '\\\\', '\'
            $rest = $matches[2]
        }
        elseif ($line -match '^@=(.+)$') {
            $name = '(default)'
            $rest = $matches[1]
        }
        else {
            continue
        }

        $parsed = $null

        if ($rest -match '^"((?:[^"\\]|\\.)*)"$') {
            $strVal = $matches[1] -replace '\\"', '"' -replace '\\\\', '\'
            $parsed = @{ Type = 'String'; Data = $strVal }
        }
        elseif ($rest -match '^dword:([0-9a-fA-F]+)$') {
            $parsed = @{ Type = 'DWord'; Data = [Convert]::ToInt64($matches[1], 16) }
        }
        elseif ($rest -match '^hex(?:\(([0-9a-fA-F]+)\))?:(.*)$') {
            $hexType = if ($matches[1]) { [Convert]::ToInt32($matches[1], 16) } else { 3 }  # REG_BINARY default
            $raw = $matches[2]
            $byteList = New-Object System.Collections.Generic.List[byte]
            foreach ($token in $raw -split ',') {
                $t = $token.Trim()
                if ($t -match '^[0-9a-fA-F]{1,2}$') {
                    $byteList.Add([byte]("0x$t")) | Out-Null
                }
            }
            $parsed = @{ Type = 'Binary'; Data = $byteList.ToArray(); HexType = $hexType }
        }
        else {
            $parsed = @{ Type = 'Unknown'; Data = $rest }
        }

        $subkeys[$currentKey][$name] = $parsed
    }

    return $subkeys
}

# ============================================================
# Value helpers
# ============================================================
function Get-RegString {
    # Returns the string form of a value. Accepts:
    #   - REG_SZ ('String')             -> returned as-is
    #   - REG_BINARY containing UTF-16LE-encoded text -> decoded
    # Returns $null if not present.
    param($Values, [string]$Name)
    if ($null -eq $Values) { return $null }
    if (-not $Values.Contains($Name)) { return $null }
    $v = $Values[$Name]
    if ($null -eq $v) { return $null }
    switch ($v.Type) {
        'String' { return $v.Data }
        'Binary' {
            $bytes = [byte[]]$v.Data
            if ($null -eq $bytes -or $bytes.Length -eq 0) { return '' }
            $s = [System.Text.Encoding]::Unicode.GetString($bytes)
            return $s.TrimEnd([char]0)
        }
        default { return [string]$v.Data }
    }
}

function Get-RegDword {
    # Returns DWord as [int64], or $null if not present / not numeric.
    param($Values, [string]$Name)
    if ($null -eq $Values) { return $null }
    if (-not $Values.Contains($Name)) { return $null }
    $v = $Values[$Name]
    if ($null -eq $v) { return $null }
    if ($v.Type -eq 'DWord') { return [long]$v.Data }
    return $null
}

function Get-RegBytes {
    # Returns the raw byte[] of a binary value, or $null.
    param($Values, [string]$Name)
    if ($null -eq $Values) { return $null }
    if (-not $Values.Contains($Name)) { return $null }
    $v = $Values[$Name]
    if ($null -eq $v) { return $null }
    if ($v.Type -eq 'Binary') { return [byte[]]$v.Data }
    return $null
}

# ============================================================
# PST detection helpers
# ============================================================
function Get-PstPathsFromSubkeys {
    # Walk all parsed subkeys looking for a PR_PST_PATH-style value
    # ('001f6700') whose decoded UTF-16LE string ends in .pst.
    # Returns an array of full filesystem paths (deduplicated, in
    # the order first encountered).
    param($Subkeys)

    $found = New-Object System.Collections.Generic.List[string]
    $seen = New-Object System.Collections.Generic.HashSet[string]
    foreach ($subkeyPath in $Subkeys.Keys) {
        $values = $Subkeys[$subkeyPath]
        $bytes = Get-RegBytes -Values $values -Name '001f6700'
        if ($null -eq $bytes -or $bytes.Length -lt 4) { continue }
        try {
            $s = [System.Text.Encoding]::Unicode.GetString($bytes).TrimEnd([char]0)
        } catch { continue }
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        if ($s -notmatch '^[A-Za-z]:\\') { continue }
        if ($s -notmatch '\.pst$') { continue }
        if ($seen.Add($s)) {
            $found.Add($s) | Out-Null
        }
    }
    return @($found.ToArray())
}

function Get-PstPathFromEntryIdBytes {
    # Production Outlook (mspst.dll wrapped) EntryID parser.
    #
    # Strategy: scan the binary for a UTF-16LE drive letter pattern
    # ([A-Z] 00 3A 00 5C 00 = "X:\"), then read until a UTF-16LE
    # null terminator (00 00 aligned on even offset). Validate that
    # the resulting string ends in .pst.
    #
    # This is format-agnostic: works whether the EntryID is the
    # documented EIDMSW sample wrapper, the production mspst.dll
    # wrapper, or any future variant that still embeds a UTF-16LE
    # path somewhere. The drive letter pattern is highly unlikely
    # to appear by chance in the surrounding MAPI binary data.
    param([byte[]]$EntryIdBytes)

    if ($null -eq $EntryIdBytes -or $EntryIdBytes.Length -lt 12) {
        return $null
    }

    for ($i = 0; $i -le $EntryIdBytes.Length - 6; $i++) {
        # Drive letter must sit on an even offset (UTF-16LE alignment)
        if (($i % 2) -ne 0) { continue }

        $b0 = $EntryIdBytes[$i]
        if (-not (($b0 -ge 0x41 -and $b0 -le 0x5A) -or `
                  ($b0 -ge 0x61 -and $b0 -le 0x7A))) { continue }   # A-Z or a-z
        if ($EntryIdBytes[$i + 1] -ne 0x00) { continue }
        if ($EntryIdBytes[$i + 2] -ne 0x3A) { continue }    # ':'
        if ($EntryIdBytes[$i + 3] -ne 0x00) { continue }
        if ($EntryIdBytes[$i + 4] -ne 0x5C) { continue }    # '\'
        if ($EntryIdBytes[$i + 5] -ne 0x00) { continue }

        # Found a drive letter prefix. Read UTF-16LE forward until
        # 00 00 aligned terminator OR the end of the buffer.
        $end = $i
        while (($end + 1) -lt $EntryIdBytes.Length) {
            if ($EntryIdBytes[$end] -eq 0x00 -and $EntryIdBytes[$end + 1] -eq 0x00) {
                break
            }
            $end += 2
        }
        if ($end -le $i) { continue }

        $path = [System.Text.Encoding]::Unicode.GetString(
                    $EntryIdBytes, $i, $end - $i)

        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if ($path -match '\.pst$') {
            return $path
        }
        # If it's not a .pst, keep scanning -- some EntryIDs embed
        # both an .ost and a .pst path; we want the latter.
    }
    return $null
}

# ============================================================
# Account-subkey identification
# ============================================================
$INTERNET_ACCOUNT_GUID = '9375CFF0413111d3B88A00104B2A6676'

function Test-AccountSubkey {
    # An "internet account" subkey looks like
    #   <profileBase>\9375CFF0413111d3B88A00104B2A6676\NNNNNNNN
    # The clsid value distinguishes the actual account record
    # ({ED475411-...}) from sibling MAPI service-name records
    # ({ED475414-...}) which share the same numeric suffix space.
    param([string]$SubkeyPath, $Values)

    if ($SubkeyPath -notmatch ('\\' + [regex]::Escape($INTERNET_ACCOUNT_GUID) + '\\[0-9A-Fa-f]{8}$')) {
        return $false
    }
    $clsid = Get-RegString -Values $Values -Name 'clsid'
    # ED475411 = account record. ED475414 = service name record (skip).
    if ($null -ne $clsid -and $clsid -match 'ED475411') { return $true }
    # Even without clsid, if POP3 Server / IMAP Server is present, treat as account.
    if ($null -ne (Get-RegString -Values $Values -Name 'POP3 Server')) { return $true }
    if ($null -ne (Get-RegString -Values $Values -Name 'IMAP Server')) { return $true }
    return $false
}

# ============================================================
# Account data extraction
# ============================================================
function Get-AccountData {
    # Extract all relevant fields from a single account subkey.
    # Handles POP3 and IMAP; classification falls back to 'other'
    # if neither server value is present.
    param(
        [string]$SubkeyPath,
        $Values
    )

    $subKeyName = Split-Path $SubkeyPath -Leaf
    $pop3Server = Get-RegString -Values $Values -Name 'POP3 Server'
    $imapServer = Get-RegString -Values $Values -Name 'IMAP Server'

    $type = if (-not [string]::IsNullOrWhiteSpace($pop3Server)) { 'pop3' }
            elseif (-not [string]::IsNullOrWhiteSpace($imapServer)) { 'imap' }
            else { 'other' }

    $entry = [ordered]@{
        subKey        = $subKeyName
        type          = $type
        accountName   = (Get-RegString -Values $Values -Name 'Account Name')
        displayName   = (Get-RegString -Values $Values -Name 'Display Name')
        email         = (Get-RegString -Values $Values -Name 'Email')
        replyEmail    = (Get-RegString -Values $Values -Name 'Reply E-mail')
        organization  = (Get-RegString -Values $Values -Name 'Organization')
    }

    if ($type -eq 'pop3') {
        $entry.pop3 = [ordered]@{
            server           = $pop3Server
            userName         = (Get-RegString -Values $Values -Name 'POP3 User')
            port             = (Get-RegDword  -Values $Values -Name 'POP3 Port')
            useSSL           = (Get-RegDword  -Values $Values -Name 'POP3 Use SSL')
            useSPA           = (Get-RegDword  -Values $Values -Name 'POP3 Use Sicily')
            # 365-era field; may be present even when 'Use SSL' is absent
            secureConnection = (Get-RegDword  -Values $Values -Name 'POP3 Secure Connection')
        }
        $entry.options = [ordered]@{
            leaveOnServer = (Get-RegDword -Values $Values -Name 'Leave on Server')
        }
    }
    elseif ($type -eq 'imap') {
        $entry.imap = [ordered]@{
            server           = $imapServer
            userName         = (Get-RegString -Values $Values -Name 'IMAP User')
            port             = (Get-RegDword  -Values $Values -Name 'IMAP Port')
            useSSL           = (Get-RegDword  -Values $Values -Name 'IMAP Use SSL')
            folderPath       = (Get-RegString -Values $Values -Name 'IMAP Folder Path')
            secureConnection = (Get-RegDword  -Values $Values -Name 'IMAP Secure Connection')
        }
    }

    if ($type -ne 'other') {
        $entry.smtp = [ordered]@{
            server           = (Get-RegString -Values $Values -Name 'SMTP Server')
            userName         = (Get-RegString -Values $Values -Name 'SMTP User')
            port             = (Get-RegDword  -Values $Values -Name 'SMTP Port')
            useSSL           = (Get-RegDword  -Values $Values -Name 'SMTP Use SSL')
            useAuth          = (Get-RegDword  -Values $Values -Name 'SMTP Use Auth')
            authMethod       = (Get-RegDword  -Values $Values -Name 'SMTP Auth Method')
            secureConnection = (Get-RegDword  -Values $Values -Name 'SMTP Secure Connection')
        }
        $entry.passwordStored = [ordered]@{
            pop3 = ($null -ne (Get-RegBytes -Values $Values -Name 'POP3 Password'))
            imap = ($null -ne (Get-RegBytes -Values $Values -Name 'IMAP Password'))
            smtp = ($null -ne (Get-RegBytes -Values $Values -Name 'SMTP Password'))
        }
    }

    # Cache the raw EntryID for downstream PST resolution
    $entry._deliveryStoreEntryIdBytes = Get-RegBytes -Values $Values -Name 'Delivery Store EntryID'
    return $entry
}

# ============================================================
# PST <-> account resolution (3-stage chain)
# ============================================================
function Resolve-PstForAccount {
    # Three-stage chain:
    #   1. Filename match: PST file basename == account email (case-insensitive).
    #      Highest confidence; Outlook 2010+ default naming convention.
    #   2. EntryID binary scan: extract path from the production
    #      mspst.dll EntryID wrapper.
    #   3. Single-candidate fallback: if exactly one PST exists in
    #      the profile (no ambiguity to resolve), pick it.
    #   Failure: emit candidate list for operator triage.
    param(
        $Account,
        [string[]]$PstCandidates
    )

    $email = $Account.email
    if ([string]::IsNullOrWhiteSpace($email)) { $email = $Account.accountName }

    # --- Stage 1: filename match ---
    if (-not [string]::IsNullOrWhiteSpace($email)) {
        foreach ($p in $PstCandidates) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($p)
            if ($base -ieq $email) {
                return [ordered]@{
                    path             = $p
                    fileName         = (Split-Path $p -Leaf)
                    detectionMethod  = 'filename-match'
                    confidence       = 'high'
                    reason           = "PST filename matches account email"
                }
            }
        }
    }

    # --- Stage 2: EntryID binary scan ---
    $entryIdBytes = $Account._deliveryStoreEntryIdBytes
    if ($null -ne $entryIdBytes -and $entryIdBytes.Length -gt 0) {
        $parsed = Get-PstPathFromEntryIdBytes -EntryIdBytes $entryIdBytes
        if (-not [string]::IsNullOrWhiteSpace($parsed)) {
            # Prefer a candidate that matches the parsed path; otherwise
            # use the parsed path as-is.
            $matched = $PstCandidates | Where-Object { $_ -ieq $parsed } | Select-Object -First 1
            return [ordered]@{
                path             = if ($matched) { $matched } else { $parsed }
                fileName         = (Split-Path $parsed -Leaf)
                detectionMethod  = if ($matched) { 'entryid-scan-confirmed' } else { 'entryid-scan' }
                confidence       = if ($matched) { 'high' } else { 'medium' }
                reason           = "Path extracted from Delivery Store EntryID"
            }
        }
    }

    # --- Stage 3: single-candidate fallback ---
    if ($PstCandidates.Count -eq 1) {
        return [ordered]@{
            path             = $PstCandidates[0]
            fileName         = (Split-Path $PstCandidates[0] -Leaf)
            detectionMethod  = 'single-candidate'
            confidence       = 'medium'
            reason           = "Only one PST in profile, no ambiguity"
        }
    }

    # --- Failure ---
    return [ordered]@{
        path             = $null
        fileName         = $null
        detectionMethod  = 'unresolved'
        confidence       = 'none'
        reason           = "No deterministic match; operator must verify manually"
        candidates       = @($PstCandidates)
    }
}

# ============================================================
# Output formatting
# ============================================================
function Format-DwordHex {
    param($v)
    if ($null -eq $v) { return '(値なし)' }
    return ("0x{0:X8}" -f [long]$v) + " (=" + [string]$v + ")"
}

function Format-SecureConnectionDesc {
    param($v)
    if ($null -eq $v) { return '(値なし)' }
    switch ([int]$v) {
        0       { return "0 (暗号化なし)" }
        1       { return "1 (STARTTLS)" }
        2       { return "2 (SSL/TLS direct)" }
        default { return "$v (不明)" }
    }
}

function Format-AccountMappingText {
    param($Snapshot)

    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine('========================================')
    $null = $sb.AppendLine(' Outlook アカウント <-> PST 紐付け情報 (v2 オフライン再解析)')
    $null = $sb.AppendLine('========================================')
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine("Source backup  : $($Snapshot.sourceBackup)")
    $null = $sb.AppendLine("Source PC      : $($Snapshot.sourceComputer)")
    $null = $sb.AppendLine("Source user    : $($Snapshot.sourceUser)")
    $null = $sb.AppendLine("Outlook version: $($Snapshot.outlookVersion)")
    $null = $sb.AppendLine("Generated at   : $($Snapshot.generatedAt)")
    $null = $sb.AppendLine('')

    foreach ($prof in $Snapshot.profiles) {
        $null = $sb.AppendLine('========================================')
        $null = $sb.AppendLine(" Profile: $($prof.name)")
        $null = $sb.AppendLine("   accounts=$($prof.accounts.Count), pstCandidates=$($prof.pstCandidates.Count)")
        $null = $sb.AppendLine('========================================')
        $null = $sb.AppendLine('')

        $idx = 0
        foreach ($acct in $prof.accounts) {
            $idx++
            $null = $sb.AppendLine("[アカウント $idx] $($acct.email)")
            $null = $sb.AppendLine("  種別          : $($acct.type.ToUpper())")
            $null = $sb.AppendLine("  表示名        : $($acct.displayName)")
            $null = $sb.AppendLine("  アカウント名  : $($acct.accountName)")
            $null = $sb.AppendLine('')

            if ($acct.type -eq 'pop3') {
                $null = $sb.AppendLine('  --- 受信 (POP3) ---')
                $null = $sb.AppendLine("    サーバ           : $($acct.pop3.server)")
                $null = $sb.AppendLine("    ユーザ名         : $($acct.pop3.userName)")
                $null = $sb.AppendLine("    ポート           : $(if ($null -eq $acct.pop3.port) { '(記録なし - autodiscover に依存、SSL 環境なら通常 995, 非SSL なら 110)' } else { $acct.pop3.port })")
                $null = $sb.AppendLine("    SSL              : $(if ($null -eq $acct.pop3.useSSL) { '(記録なし - autodiscover に依存)' } else { $acct.pop3.useSSL })")
                $null = $sb.AppendLine("    SPA (Sicily)     : $(if ($null -eq $acct.pop3.useSPA) { '(記録なし)' } else { $acct.pop3.useSPA })")
                $null = $sb.AppendLine("    Secure Connection: $(Format-SecureConnectionDesc $acct.pop3.secureConnection)")
                if ($null -ne $acct.options -and $null -ne $acct.options.leaveOnServer) {
                    $null = $sb.AppendLine("    Leave on Server  : $(Format-DwordHex $acct.options.leaveOnServer)")
                }
            }
            elseif ($acct.type -eq 'imap') {
                $null = $sb.AppendLine('  --- 受信 (IMAP) ---')
                $null = $sb.AppendLine("    サーバ           : $($acct.imap.server)")
                $null = $sb.AppendLine("    ユーザ名         : $($acct.imap.userName)")
                $null = $sb.AppendLine("    ポート           : $(if ($null -eq $acct.imap.port) { '(記録なし - autodiscover に依存、SSL 環境なら通常 993, 非SSL なら 143)' } else { $acct.imap.port })")
                $null = $sb.AppendLine("    SSL              : $(if ($null -eq $acct.imap.useSSL) { '(記録なし - autodiscover に依存)' } else { $acct.imap.useSSL })")
                $null = $sb.AppendLine("    Folder path      : $(if ([string]::IsNullOrWhiteSpace($acct.imap.folderPath)) { '(未設定)' } else { $acct.imap.folderPath })")
                $null = $sb.AppendLine("    Secure Connection: $(Format-SecureConnectionDesc $acct.imap.secureConnection)")
            }

            if ($acct.type -ne 'other') {
                $null = $sb.AppendLine('')
                $null = $sb.AppendLine('  --- 送信 (SMTP) ---')
                $null = $sb.AppendLine("    サーバ           : $($acct.smtp.server)")
                $null = $sb.AppendLine("    ユーザ名         : $(if ([string]::IsNullOrWhiteSpace($acct.smtp.userName)) { '(受信と同じ / 未設定)' } else { $acct.smtp.userName })")
                $null = $sb.AppendLine("    ポート           : $(if ($null -eq $acct.smtp.port) { '(記録なし)' } else { $acct.smtp.port })")
                $null = $sb.AppendLine("    認証             : $(if ($null -eq $acct.smtp.useAuth) { '(記録なし)' } else { $acct.smtp.useAuth })")
                $null = $sb.AppendLine("    Use SSL (legacy) : $(if ($null -eq $acct.smtp.useSSL) { '(記録なし)' } else { $acct.smtp.useSSL })")
                $null = $sb.AppendLine("    Secure Connection: $(Format-SecureConnectionDesc $acct.smtp.secureConnection)")
                $null = $sb.AppendLine("    認証方式 (Auth Method): $(if ($null -eq $acct.smtp.authMethod) { '(記録なし)' } else { $acct.smtp.authMethod })")

                $null = $sb.AppendLine('')
                $null = $sb.AppendLine('  --- パスワード保存状態 ---')
                $null = $sb.AppendLine("    POP3 password stored: $(if ($acct.passwordStored.pop3) { 'YES (DPAPI暗号化、移行先 PC では復号不可)' } else { 'no' })")
                $null = $sb.AppendLine("    IMAP password stored: $(if ($acct.passwordStored.imap) { 'YES' } else { 'no' })")
                $null = $sb.AppendLine("    SMTP password stored: $(if ($acct.passwordStored.smtp) { 'YES' } else { 'no' })")
            }

            $null = $sb.AppendLine('')
            $null = $sb.AppendLine('  --- PST ---')
            if ($null -ne $acct.pst.path) {
                $null = $sb.AppendLine("    ファイルパス     : $($acct.pst.path)")
                $null = $sb.AppendLine("    ファイル名       : $($acct.pst.fileName)")
                $null = $sb.AppendLine("    検出方法         : $($acct.pst.detectionMethod) (信頼度: $($acct.pst.confidence))")
                $null = $sb.AppendLine("    検出理由         : $($acct.pst.reason)")
            } else {
                $null = $sb.AppendLine("    ファイルパス     : (解決できず)")
                $null = $sb.AppendLine("    理由             : $($acct.pst.reason)")
                if ($acct.pst.candidates) {
                    $null = $sb.AppendLine("    候補 ($($acct.pst.candidates.Count) 件、operator が手動選択):")
                    foreach ($c in $acct.pst.candidates) {
                        $null = $sb.AppendLine("      - $c")
                    }
                }
            }
            $null = $sb.AppendLine('')
            $null = $sb.AppendLine('----------------------------------------')
            $null = $sb.AppendLine('')
        }
    }

    $null = $sb.AppendLine('========================================')
    $null = $sb.AppendLine(' 移行先 PC での手動セットアップ手順 (operator 向け)')
    $null = $sb.AppendLine('========================================')
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine(' 1. 上記の PST ファイルは userdata セクションにより')
    $null = $sb.AppendLine('    Documents\Outlook ファイル\ にコピー済みです。')
    $null = $sb.AppendLine('    存在しない場合は手動で配置してください。')
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine(' 2. 移行先 PC で Outlook を起動し、各アカウントを「ファイル >')
    $null = $sb.AppendLine('    アカウントの追加」からメールアドレスで追加してください。')
    $null = $sb.AppendLine('    autodiscover が大半の項目 (ポート / 暗号化等) を自動入力します。')
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine(' 3. ウィザードで「データファイルを選択」を求められたら、')
    $null = $sb.AppendLine('    上記の対応する PST を選択してください。')
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine(' 4. パスワードは初回送受信時に入力してください。')
    $null = $sb.AppendLine('    (DPAPI 制約により PC 間でパスワードは持ち運び不可)')
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('========================================')

    return $sb.ToString()
}

function Convert-AccountToOutput {
    # Strip the internal _deliveryStoreEntryIdBytes field from the
    # account dict before serializing to JSON / text output.
    param($Account)
    $copy = [ordered]@{}
    foreach ($k in $Account.Keys) {
        if ($k -eq '_deliveryStoreEntryIdBytes') { continue }
        $copy[$k] = $Account[$k]
    }
    return $copy
}

# ============================================================
# Main flow
# ============================================================
function Invoke-Reparse {
    param([string]$BackupDir)

    if (-not (Test-Path -LiteralPath $BackupDir -PathType Container)) {
        throw "BackupDir not found or not a directory: $BackupDir"
    }
    $sectionDir = Join-Path $BackupDir 'sections\outlook_pop'
    if (-not (Test-Path -LiteralPath $sectionDir -PathType Container)) {
        throw "outlook_pop section dir not found: $sectionDir"
    }

    $regFiles = @(Get-ChildItem -LiteralPath $sectionDir -Filter 'profile_*.reg' -File -ErrorAction Stop)
    if ($regFiles.Count -eq 0) {
        throw "No profile_*.reg file in: $sectionDir"
    }

    Write-PocInfo "Section dir : $sectionDir"
    Write-PocInfo "Found $($regFiles.Count) profile reg file(s)"

    # Load existing manifest for context (sourceUser, computerName, etc.)
    $manifestPath = Join-Path $sectionDir 'manifest.json'
    $oldManifest = $null
    if (Test-Path -LiteralPath $manifestPath) {
        try {
            $oldManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            Write-PocWarn "Failed to parse existing manifest.json: $($_.Exception.Message)"
        }
    }

    $profilesOut = @()
    foreach ($regFile in $regFiles) {
        Write-PocInfo "Parsing : $($regFile.Name)"
        $subkeys = Read-RegFile -Path $regFile.FullName
        Write-PocOk  "  subkeys parsed: $($subkeys.Count)"

        # Derive profile name from the first subkey header
        $rootKey = $subkeys.Keys | Select-Object -First 1
        $profileName = if ($rootKey -match '\\Profiles\\([^\\]+)') { $matches[1] } else { '(unknown)' }

        # Find all PST file candidates referenced anywhere in this profile
        $pstCandidates = Get-PstPathsFromSubkeys -Subkeys $subkeys
        Write-PocInfo "  PST candidates: $($pstCandidates.Count)"
        foreach ($p in $pstCandidates) { Write-PocInfo "    - $p" }

        # Find all account subkeys (POP3 / IMAP, skip MAPI service-name siblings)
        $accountSubkeyPaths = @($subkeys.Keys | Where-Object {
            Test-AccountSubkey -SubkeyPath $_ -Values $subkeys[$_]
        })
        Write-PocInfo "  account subkeys: $($accountSubkeyPaths.Count)"

        $accounts = @()
        foreach ($subkeyPath in $accountSubkeyPaths) {
            $values = $subkeys[$subkeyPath]
            $acct = Get-AccountData -SubkeyPath $subkeyPath -Values $values
            $resolution = Resolve-PstForAccount -Account $acct -PstCandidates $pstCandidates
            $acct.pst = $resolution
            Write-PocOk ("    [{0}] type={1} email={2} -> PST={3} ({4})" -f `
                $acct.subKey, $acct.type, $acct.email,
                ($(if ($null -eq $resolution.path) { '(unresolved)' } else { Split-Path $resolution.path -Leaf })),
                $resolution.detectionMethod)
            $accounts += (Convert-AccountToOutput -Account $acct)
        }

        $profilesOut += [ordered]@{
            name           = $profileName
            regFile        = $regFile.Name
            pstCandidates  = @($pstCandidates)
            accounts       = @($accounts)
        }
    }

    $snapshot = [ordered]@{
        schemaVersion   = 1
        manifestType    = 'fabriq-outlook-account-mapping-v2'
        sourceBackup    = $BackupDir
        generatedAt     = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
        sourceComputer  = if ($oldManifest) { "$($oldManifest.computerName)" } else { '(unknown)' }
        sourceUser      = if ($oldManifest -and $oldManifest.sourceUser) { "$($oldManifest.sourceUser.userName)" } else { '(unknown)' }
        outlookVersion  = if ($oldManifest) { "$($oldManifest.outlookVersion)" } else { '(unknown)' }
        profiles        = $profilesOut
    }

    return @{ Snapshot = $snapshot; SectionDir = $sectionDir }
}

# ============================================================
# Entry point
# ============================================================
$res = Invoke-Reparse -BackupDir $BackupDir
$snapshot = $res.Snapshot
$sectionDir = $res.SectionDir

# Write JSON
$jsonPath = Join-Path $sectionDir '_account_mapping_v2.json'
$snapshot | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8 -Force
Write-PocOk "Wrote: $jsonPath"

# Write text
$txtPath = Join-Path $sectionDir '_account_mapping_v2.txt'
$txt = Format-AccountMappingText -Snapshot $snapshot
$txt | Out-File -FilePath $txtPath -Encoding UTF8 -Force
Write-PocOk "Wrote: $txtPath"

Write-Host ''
Write-PocOk "Reparse complete. Total profiles: $($snapshot.profiles.Count), total accounts: $(@($snapshot.profiles | ForEach-Object { $_.accounts.Count }) | Measure-Object -Sum | Select-Object -ExpandProperty Sum)"
