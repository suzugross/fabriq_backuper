# ============================================================
# FabriqBackUper Section: outlook_pop / backup (Phase 2.9.0 Phase A)
#
# Enumerates Outlook (classic 2016/2019/2021/365, registry version
# 16.0; falls back to 15.0 for Outlook 2013) Mail Profiles under
#   HKCU\Software\Microsoft\Office\<ver>\Outlook\Profiles\<prof>\
#     9375CFF0413111d3B88A00104B2A6676\<NN>
# and emits a portable JSON manifest of every POP3 account it finds.
#
# Notes:
#   - The well-known GUID 9375CFF0413111d3B88A00104B2A6676 is the
#     MAPI "Internet Account" service identifier (POP / IMAP / SMTP).
#   - String values under this key are stored as REG_BINARY with a
#     UTF-16LE encoding (often null-terminated); numeric values are
#     REG_DWORD.
#   - Passwords are DPAPI-encrypted per-user/per-machine and CANNOT
#     be decrypted on another box. Microsoft's PRF format also does
#     not deploy passwords on import (Outlook 2016+ silently drops
#     them). This section therefore intentionally skips password
#     blobs entirely — the operator re-enters on first send/receive.
#   - IMAP accounts (POP3 Server value absent, IMAP Server present)
#     are enumerated with type='imap' (Phase 2.13.0+); no pst block is
#     emitted because OST files are per-machine DPAPI-encrypted and not
#     migrated (Outlook re-syncs from server on first launch).
#
# SectionParams (hashtable, all optional):
#   SourceUserProfilePath : profile path of the user whose HKCU to
#                           enumerate. Matches the same parameter used
#                           by the userdata section. Resolve-HkcuRoot
#                           handles the SID lookup.
# ============================================================

param(
    [Parameter(Mandatory = $true)][string]$BackuperRoot,
    [Parameter(Mandatory = $true)][string]$FabriqRoot,
    [Parameter(Mandatory = $true)][string]$OldPcName,
    [Parameter(Mandatory = $true)][string]$AggregateBackupDir,
    [hashtable]$SectionParams = @{}
)

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$warnings = @()

# ----------------------------------------------------------
# Parse SectionParams
# ----------------------------------------------------------
$sourceUserProfilePath = $null
if ($SectionParams.ContainsKey('SourceUserProfilePath') -and `
    -not [string]::IsNullOrWhiteSpace($SectionParams['SourceUserProfilePath'])) {
    $sourceUserProfilePath = "$($SectionParams['SourceUserProfilePath'])"
}

# ----------------------------------------------------------
# Section output dir
# ----------------------------------------------------------
$sectionDir = Join-Path $AggregateBackupDir 'sections\outlook_pop'
try {
    $null = New-Item -ItemType Directory -Path $sectionDir -Force -ErrorAction Stop
} catch {
    return [PSCustomObject]@{
        Status               = 'Failed'
        ElapsedMs            = [int]$sw.ElapsedMilliseconds
        Summary              = [ordered]@{}
        Warnings             = @("Failed to create section output dir: $($_.Exception.Message)")
        ExternalOutputDir    = $null
        ExternalManifestPath = $null
    }
}

Show-Info "Section output: $sectionDir"

# ----------------------------------------------------------
# Resolve HKCU root (handles admin elevation / cross-user)
# ----------------------------------------------------------
$hkcuInfo = Resolve-HkcuRoot
if ($null -eq $hkcuInfo -or [string]::IsNullOrWhiteSpace($hkcuInfo.PsDrivePath)) {
    return [PSCustomObject]@{
        Status               = 'Failed'
        ElapsedMs            = [int]$sw.ElapsedMilliseconds
        Summary              = [ordered]@{}
        Warnings             = @('Resolve-HkcuRoot returned null/empty PsDrivePath')
        ExternalOutputDir    = $null
        ExternalManifestPath = $null
    }
}
if ($hkcuInfo.Redirected) {
    Show-Info "HKCU source: $($hkcuInfo.Label) [SID=$($hkcuInfo.SID)]"
}

# ----------------------------------------------------------
# Locate the Outlook Profiles key (try 16.0 first, then 15.0)
# ----------------------------------------------------------
$outlookVersions = @('16.0', '15.0')
$profilesKeyPath = $null
$outlookVersion  = $null
foreach ($v in $outlookVersions) {
    $candidate = "$($hkcuInfo.PsDrivePath)\Software\Microsoft\Office\$v\Outlook\Profiles"
    if (Test-Path $candidate) {
        $profilesKeyPath = $candidate
        $outlookVersion  = $v
        break
    }
}
if ($null -eq $profilesKeyPath) {
    Show-Skip "No Outlook 16.0 or 15.0 mail profile registry found — skipping section"
    return [PSCustomObject]@{
        Status               = 'Skipped'
        ElapsedMs            = [int]$sw.ElapsedMilliseconds
        Summary              = [ordered]@{ note = 'no Outlook 16.0/15.0 profile registry' }
        Warnings             = @()
        ExternalOutputDir    = $null
        ExternalManifestPath = $null
    }
}
Show-Info "Outlook version: $outlookVersion"
Show-Info "Profiles root  : $profilesKeyPath"

# ----------------------------------------------------------
# Helpers
# ----------------------------------------------------------
$INTERNET_ACCOUNT_GUID = '9375CFF0413111d3B88A00104B2A6676'

function Get-OutlookInstallInfo {
    # Phase 2.11.0: detect Outlook installation on the local machine.
    # Currently used for diagnostic / manifest recording only; no branching
    # decisions are made on the result. Future phases (per-version restore
    # behaviour, e.g. Outlook 2013 PRF fallback) will key off these fields.
    #
    # Returns a hashtable with:
    #   Installed         : $true/$false
    #   RegistryVersion   : '15.0' / '16.0' / $null   (highest version present)
    #   ProductFamily     : 'Outlook 2013' / 'Outlook 2016/2019/365' / $null
    #   InstallType       : 'ClickToRun' / 'MSI' / $null
    #   ProductReleaseIds : raw value from C2R Configuration (or $null)
    #   OutlookExePath    : full path to OUTLOOK.EXE (or $null)
    #   OutlookExeVersion : FileVersion of OUTLOOK.EXE (or $null)
    #   AllVersionsFound  : array of every detected version ('16.0','15.0')
    #
    # Detection probes (in order):
    #   1. HKLM:\SOFTWARE\Microsoft\Office\<ver>\Outlook\InstallRoot.Path
    #      and the WOW6432Node sibling. OUTLOOK.EXE must exist under .Path.
    #   2. HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration to
    #      distinguish C2R installs (365 / 2019 / 2016 Retail) from MSI.
    $result = @{
        Installed         = $false
        RegistryVersion   = $null
        ProductFamily     = $null
        InstallType       = $null
        ProductReleaseIds = $null
        OutlookExePath    = $null
        OutlookExeVersion = $null
        AllVersionsFound  = @()
    }

    $versionsToProbe = @('16.0', '15.0')
    $found = @()
    foreach ($v in $versionsToProbe) {
        $candidateKeys = @(
            "HKLM:\SOFTWARE\Microsoft\Office\$v\Outlook\InstallRoot",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\$v\Outlook\InstallRoot"
        )
        $exePath = $null
        foreach ($k in $candidateKeys) {
            if (-not (Test-Path -LiteralPath $k)) { continue }
            try {
                $p = (Get-ItemProperty -LiteralPath $k -ErrorAction Stop).Path
                if ([string]::IsNullOrWhiteSpace($p)) { continue }
                $candidate = Join-Path $p 'OUTLOOK.EXE'
                if (Test-Path -LiteralPath $candidate) {
                    $exePath = $candidate
                    break
                }
            } catch { }
        }
        if ($null -ne $exePath) {
            $found += [PSCustomObject]@{ Version = $v; ExePath = $exePath }
        }
    }

    if ($found.Count -eq 0) { return $result }

    $result.Installed = $true
    $result.AllVersionsFound = @($found | ForEach-Object { $_.Version })

    # Probe order is 16.0 then 15.0, so $found[0] is the highest present.
    $primary = $found[0]
    $result.RegistryVersion = $primary.Version
    $result.OutlookExePath  = $primary.ExePath

    try {
        $vi = (Get-Item -LiteralPath $primary.ExePath).VersionInfo
        if ($vi) { $result.OutlookExeVersion = $vi.FileVersion }
    } catch { }

    if ($primary.Version -eq '15.0') {
        $result.ProductFamily = 'Outlook 2013'
    } else {
        $result.ProductFamily = 'Outlook 2016/2019/365'
    }

    $c2rKey = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    if (Test-Path -LiteralPath $c2rKey) {
        try {
            $cfg = Get-ItemProperty -LiteralPath $c2rKey -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace("$($cfg.ProductReleaseIds)")) {
                $result.ProductReleaseIds = "$($cfg.ProductReleaseIds)"
                $result.InstallType = 'ClickToRun'
            }
        } catch { }
    }
    if ($null -eq $result.InstallType) {
        $result.InstallType = 'MSI'
    }

    return $result
}

function ConvertFrom-RegBinaryUtf16 {
    # REG_BINARY containing UTF-16LE text, often with a trailing null
    # pair (0x00 0x00). Strip nulls and return the resulting string.
    param($Value)
    if ($null -eq $Value) { return '' }
    $bytes = [byte[]]$Value
    if ($bytes.Length -eq 0) { return '' }
    $s = [System.Text.Encoding]::Unicode.GetString($bytes)
    return $s.TrimEnd([char]0)
}

function Get-RegValueRaw {
    # Returns the raw value (whatever type) or $null if absent.
    param(
        [Parameter(Mandatory = $true)]$RegKey,
        [Parameter(Mandatory = $true)][string]$Name
    )
    try { return $RegKey.GetValue($Name, $null) } catch { return $null }
}

function Get-RegValueString {
    # POP3-account string values are stored as REG_BINARY UTF-16LE.
    # Some installations store them as REG_SZ (rare but seen);
    # accept both.
    #
    # Phase 2.11.2 hotfix: read the value directly via $RegKey.GetValue()
    # instead of going through Get-RegValueRaw. Windows PowerShell 5.1's
    # function-return semantics enumerate [byte[]] across the function
    # boundary and re-collect into [System.Object[]], breaking the
    # `-is [byte[]]` type check. Outlook 2013 hives reproduced this
    # consistently (manifest stored "115 0 117 0 ..." in place of the
    # decoded UTF-16LE string); 2016+ hives happened to slip through but
    # the fix is uniform. A defensive [byte[]] coercion is also added for
    # the array-but-not-typed-[byte[]] case to cover any remaining edge.
    param(
        [Parameter(Mandatory = $true)]$RegKey,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $v = $null
    try { $v = $RegKey.GetValue($Name, $null) } catch { return $null }
    if ($null -eq $v) { return $null }
    if ($v -is [byte[]]) { return (ConvertFrom-RegBinaryUtf16 -Value $v) }
    if ($v -is [System.Array]) {
        try {
            return (ConvertFrom-RegBinaryUtf16 -Value ([byte[]]$v))
        } catch { }
    }
    return [string]$v
}

function Get-RegValueDword {
    param(
        [Parameter(Mandatory = $true)]$RegKey,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $v = Get-RegValueRaw -RegKey $RegKey -Name $Name
    if ($null -eq $v) { return $null }
    return [int]$v
}

function Get-PstPathsFromProfile {
    # Phase 2.9.2a-v2: recursive walk of the Outlook profile registry to
    # find every subkey that has a '001f6700' value — that's the PST
    # file path (REG_BINARY UTF-16LE, null-terminated) for a Personal
    # Folders store. Returns an array of file path strings.
    #
    # This is the more reliable detection path; the EntryID parser
    # below (Get-PstPathFromDeliveryStoreEntryId) only works for the
    # "wrapped PST store provider" SAMPLE format, not the production
    # Outlook PST provider which embeds "mspst.dll" plus undocumented
    # bytes before the actual path.
    param([Parameter(Mandatory = $true)][string]$ProfileKeyPath)

    $results = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($ProfileKeyPath)

    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        $key = $null
        try { $key = Get-Item -LiteralPath $current -ErrorAction Stop } catch { continue }
        if ($null -eq $key) { continue }

        # Check this key for the PST path value (REG_BINARY UTF-16LE).
        try {
            $raw = $key.GetValue('001f6700', $null)
            if ($null -ne $raw -and $raw -is [byte[]] -and $raw.Length -gt 0) {
                $s = [System.Text.Encoding]::Unicode.GetString([byte[]]$raw)
                $s = $s.TrimEnd([char]0)
                if (-not [string]::IsNullOrWhiteSpace($s) -and `
                    $s -match '^[A-Za-z]:\\' -and $s -match '\.pst$') {
                    [void]$results.Add($s)
                }
            }
        } catch { }

        # Recurse into subkeys
        try {
            foreach ($sub in (Get-ChildItem -LiteralPath $current -ErrorAction Stop)) {
                $stack.Push($sub.PSPath)
            }
        } catch { }
    }

    return @($results)
}

function Get-PstPathFromDeliveryStoreEntryId {
    # Extract the PST file path embedded in a Delivery Store EntryID.
    #
    # Background:
    #   Original Phase 2.9.2a implementation assumed the documented
    #   wrapped PST sample provider format (EIDMS/EIDMSW). On production
    #   Outlook 365 / 2016+ the actual format is the "mspst.dll" wrapped
    #   variant, which has additional service-identifier bytes before
    #   the path, so the fixed offset 21 assumption was wrong and PST
    #   mapping silently failed on multi-PST profiles (confirmed v0.15
    #   PoC: 0/4 accounts resolved on K_iuchi 365 environment).
    #
    # New strategy (v0.16):
    #   Format-agnostic binary scan. Walk through the EntryID bytes
    #   looking for a UTF-16LE drive letter pattern [A-Za-z] 00 3A 00
    #   5C 00 (i.e. "X:\"), then read until UTF-16LE null terminator
    #   and validate the resulting string ends in .pst.
    #
    #   The scan is restricted to even byte offsets (UTF-16LE
    #   alignment). Surrounding MAPI binary structures contain
    #   random data, but the probability of a 6-byte aligned drive
    #   letter pattern appearing by accident is astronomically low.
    #
    # Handles both:
    #   - mspst.dll wrapped format (production Outlook 2010+/365)
    #   - EIDMSW sample format (legacy wrapped PST sample provider)
    param([byte[]]$EntryIdBytes)

    if ($null -eq $EntryIdBytes -or $EntryIdBytes.Length -lt 12) { return $null }

    for ($i = 0; $i -le $EntryIdBytes.Length - 6; $i += 2) {
        $b0 = $EntryIdBytes[$i]
        if (-not ((($b0 -ge 0x41) -and ($b0 -le 0x5A)) -or `
                  (($b0 -ge 0x61) -and ($b0 -le 0x7A)))) { continue }
        if ($EntryIdBytes[$i + 1] -ne 0x00) { continue }
        if ($EntryIdBytes[$i + 2] -ne 0x3A) { continue }
        if ($EntryIdBytes[$i + 3] -ne 0x00) { continue }
        if ($EntryIdBytes[$i + 4] -ne 0x5C) { continue }
        if ($EntryIdBytes[$i + 5] -ne 0x00) { continue }

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
        # not .pst (could be .ost embedded earlier) - keep scanning
    }
    return $null
}

function Resolve-AccountPst {
    # 3-stage PST resolution chain (v0.16, refactored from v0.15 inline
    # logic to consolidate behaviour and apply filename-match-first).
    #
    # Stage 1 (highest confidence): filename match against email.
    #   Outlook 2010+ default naming convention is "<email>.pst" for
    #   POP3 accounts. When this matches deterministically, no further
    #   lookup is needed and the result is unambiguous even when the
    #   profile contains multiple PSTs.
    #
    # Stage 2 (medium confidence): EntryID binary scan.
    #   Falls through when filename match fails (e.g. PST manually
    #   renamed). Uses Get-PstPathFromDeliveryStoreEntryId, which is
    #   format-agnostic for production mspst.dll EntryIDs.
    #
    # Stage 3 (medium confidence): single-candidate fallback.
    #   When the profile has exactly one PST and no other resolution
    #   succeeded, attribute it to this account. Avoids "unavailable"
    #   for trivially obvious cases.
    #
    # Returns: hashtable @{ Path; Method; Reason }
    #   Path   : full PST file path, or $null when no match
    #   Method : 'filename-match' | 'entryid-scan' | 'single-candidate' | 'unresolved'
    #   Reason : human-readable diagnostic
    param(
        [Parameter(Mandatory)][string]$Email,
        [byte[]]$EntryIdBytes,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$PstCandidates
    )

    # --- Stage 1: filename match (case-insensitive on basename) ---
    if (-not [string]::IsNullOrWhiteSpace($Email)) {
        foreach ($p in $PstCandidates) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($p)
            if ($base -ieq $Email) {
                return @{
                    Path   = $p
                    Method = 'filename-match'
                    Reason = 'PST filename matches account email'
                }
            }
        }
    }

    # --- Stage 2: EntryID binary scan ---
    if ($null -ne $EntryIdBytes -and $EntryIdBytes.Length -gt 0) {
        $parsed = Get-PstPathFromDeliveryStoreEntryId -EntryIdBytes $EntryIdBytes
        if (-not [string]::IsNullOrWhiteSpace($parsed)) {
            # Prefer a candidate that matches the parsed path; otherwise
            # use the parsed path as-is (the file may be in a non-default
            # location that the registry walk did not find).
            $matched = $PstCandidates | Where-Object { $_ -ieq $parsed } | Select-Object -First 1
            return @{
                Path   = if ($matched) { $matched } else { $parsed }
                Method = if ($matched) { 'entryid-scan-confirmed' } else { 'entryid-scan' }
                Reason = 'Path extracted from Delivery Store EntryID'
            }
        }
    }

    # --- Stage 3: single-candidate fallback ---
    if ($PstCandidates.Count -eq 1) {
        return @{
            Path   = $PstCandidates[0]
            Method = 'single-candidate'
            Reason = 'Only one PST in profile, no ambiguity'
        }
    }

    # --- Failure ---
    return @{
        Path   = $null
        Method = 'unresolved'
        Reason = if ($PstCandidates.Count -eq 0) {
                     'No PST found in profile'
                 } else {
                     "$($PstCandidates.Count) PST candidates but none matched filename or EntryID"
                 }
    }
}

# ----------------------------------------------------------
# Phase 2.11.0: probe local Outlook installation for diagnostic recording.
# Called here (after the helpers block) so the function definition is in
# scope - PowerShell scripts are sequential and a function called before
# its definition raises "term not recognized" at runtime.
# No decisions branch on this yet; the data is recorded into the manifest
# so that future restore-side logic (e.g. 2013 fallback path) can read it.
# ----------------------------------------------------------
$outlookInstallInfo = Get-OutlookInstallInfo
if ($outlookInstallInfo.Installed) {
    Show-Info ("Outlook install: $($outlookInstallInfo.ProductFamily) " +
               "(reg=$($outlookInstallInfo.RegistryVersion), " +
               "type=$($outlookInstallInfo.InstallType), " +
               "exeVer=$($outlookInstallInfo.OutlookExeVersion))")
    if ($outlookInstallInfo.ProductReleaseIds) {
        Show-Info ("  ProductReleaseIds: $($outlookInstallInfo.ProductReleaseIds)")
    }
    if (@($outlookInstallInfo.AllVersionsFound).Count -gt 1) {
        Show-Info ("  side-by-side detected: " +
                   ($outlookInstallInfo.AllVersionsFound -join ', '))
    }
} else {
    Show-Warning "Outlook install: not detected via HKLM probe (profile registry still found, continuing)"
}

# ----------------------------------------------------------
# Walk profiles -> internet-account subkeys -> POP3 entries
# ----------------------------------------------------------
$manifestProfiles = @()
$totalPop = 0
$totalImap = 0
$totalOther = 0

$profileKeys = @()
try {
    $profileKeys = @(Get-ChildItem -LiteralPath $profilesKeyPath -ErrorAction Stop)
} catch {
    $warnings += "Failed to enumerate profiles: $($_.Exception.Message)"
}

foreach ($profKey in $profileKeys) {
    $profileName = Split-Path -Path $profKey.PSPath -Leaf
    Show-Info "[profile] $profileName"

    # Phase 2.9.2a-v2: enumerate all PSTs in this profile up front via
    # registry walk. Used as the deterministic mapping source for each
    # POP account in the same profile.
    $profilePstPaths = @(Get-PstPathsFromProfile -ProfileKeyPath $profKey.PSPath)
    if ($profilePstPaths.Count -gt 0) {
        Show-Info "  PST stores found in profile: $($profilePstPaths.Count)"
        foreach ($p in $profilePstPaths) { Show-Info "    - $p" }
    } else {
        Show-Info "  PST stores found in profile: 0"
    }

    $accountsRoot = Join-Path $profKey.PSPath $INTERNET_ACCOUNT_GUID
    if (-not (Test-Path $accountsRoot)) {
        Show-Skip "  no internet-account subkey ($INTERNET_ACCOUNT_GUID) - skipping"
        continue
    }

    $accountEntries = @()
    $accountKeys = @()
    try {
        $accountKeys = @(Get-ChildItem -LiteralPath $accountsRoot -ErrorAction Stop)
    } catch {
        $warnings += "Failed to enumerate accounts in '$profileName': $($_.Exception.Message)"
        continue
    }

    foreach ($acctKey in $accountKeys) {
        $subKeyName = Split-Path -Path $acctKey.PSPath -Leaf
        # Each subkey is named like 00000001, 00000002, ...
        if ($subKeyName -notmatch '^[0-9A-Fa-f]{8}$') {
            $totalOther++
            Show-Skip "  [$subKeyName] non-account subkey - skipping"
            continue
        }

        # Open with .Net registry API so we can read raw byte[] for REG_BINARY.
        $rk = $null
        try {
            $rk = (Get-Item -LiteralPath $acctKey.PSPath -ErrorAction Stop)
        } catch {
            $warnings += "Failed to open account subkey ${profileName}/${subKeyName}: $($_.Exception.Message)"
            continue
        }

        $pop3Server = Get-RegValueString -RegKey $rk -Name 'POP3 Server'
        $imapServer = Get-RegValueString -RegKey $rk -Name 'IMAP Server'

        if ([string]::IsNullOrWhiteSpace($pop3Server) -and `
            [string]::IsNullOrWhiteSpace($imapServer)) {
            $totalOther++
            Show-Skip "  [$subKeyName] no POP3/IMAP server value - skipping"
            continue
        }

        # Phase 2.13.0: IMAP enumeration. Build IMAP entry separately (no
        # pst block; OST is per-machine encrypted, not migrated).
        if (-not [string]::IsNullOrWhiteSpace($imapServer) -and `
            [string]::IsNullOrWhiteSpace($pop3Server)) {
            $imapEntry = [ordered]@{
                subKey       = $subKeyName
                type         = 'imap'
                accountName  = (Get-RegValueString -RegKey $rk -Name 'Account Name')
                displayName  = (Get-RegValueString -RegKey $rk -Name 'Display Name')
                email        = (Get-RegValueString -RegKey $rk -Name 'Email')
                replyEmail   = (Get-RegValueString -RegKey $rk -Name 'Reply E-mail')
                organization = (Get-RegValueString -RegKey $rk -Name 'Organization')
                imap         = [ordered]@{
                    server           = $imapServer
                    userName         = (Get-RegValueString -RegKey $rk -Name 'IMAP User')
                    port             = (Get-RegValueDword  -RegKey $rk -Name 'IMAP Port')
                    useSSL           = (Get-RegValueDword  -RegKey $rk -Name 'IMAP Use SSL')
                    folderPath       = (Get-RegValueString -RegKey $rk -Name 'IMAP Folder Path')
                    # v0.16: 365 / modern Outlook uses Secure Connection (0=none,
                    # 1=STARTTLS, 2=SSL/TLS direct) in addition to or instead of
                    # the legacy Use SSL flag. Capture both.
                    secureConnection = (Get-RegValueDword  -RegKey $rk -Name 'IMAP Secure Connection')
                }
                smtp         = [ordered]@{
                    server           = (Get-RegValueString -RegKey $rk -Name 'SMTP Server')
                    userName         = (Get-RegValueString -RegKey $rk -Name 'SMTP User')
                    port             = (Get-RegValueDword  -RegKey $rk -Name 'SMTP Port')
                    useSSL           = (Get-RegValueDword  -RegKey $rk -Name 'SMTP Use SSL')
                    useAuth          = (Get-RegValueDword  -RegKey $rk -Name 'SMTP Use Auth')
                    authMethod       = (Get-RegValueDword  -RegKey $rk -Name 'SMTP Auth Method')
                    secureConnection = (Get-RegValueDword  -RegKey $rk -Name 'SMTP Secure Connection')
                }
                passwordStored = [ordered]@{
                    imap = ($null -ne (Get-RegValueRaw -RegKey $rk -Name 'IMAP Password'))
                    smtp = ($null -ne (Get-RegValueRaw -RegKey $rk -Name 'SMTP Password'))
                }
            }
            Show-Success ("  [$subKeyName] $($imapEntry.accountName)  <$($imapEntry.email)>  " +
                          "imap=$($imapEntry.imap.server):$($imapEntry.imap.port)")
            Show-Info    '             ost=(not migrated; Outlook re-syncs from server on first launch)'
            $accountEntries += $imapEntry
            $totalImap++
            continue
        }

        $entry = [ordered]@{
            subKey       = $subKeyName
            type         = 'pop3'
            accountName  = (Get-RegValueString -RegKey $rk -Name 'Account Name')
            displayName  = (Get-RegValueString -RegKey $rk -Name 'Display Name')
            email        = (Get-RegValueString -RegKey $rk -Name 'Email')
            replyEmail   = (Get-RegValueString -RegKey $rk -Name 'Reply E-mail')
            organization = (Get-RegValueString -RegKey $rk -Name 'Organization')
            pop3         = [ordered]@{
                server           = $pop3Server
                # Phase 2.9.0a: corrected value names verified against an
                # actual registry dump. Outlook stores these without the
                # "Name" suffix and uses "SMTP Use Auth" (not "Use Sicily")
                # for the outgoing-server-auth flag. "POP3 Use Sicily" is
                # correct as the SPA flag, even though SMTP doesn't use
                # the "Sicily" name for auth.
                userName         = (Get-RegValueString -RegKey $rk -Name 'POP3 User')
                port             = (Get-RegValueDword  -RegKey $rk -Name 'POP3 Port')
                useSSL           = (Get-RegValueDword  -RegKey $rk -Name 'POP3 Use SSL')
                useSPA           = (Get-RegValueDword  -RegKey $rk -Name 'POP3 Use Sicily')
                # v0.16: 365 environments often omit POP3 Port / Use SSL
                # entirely (relies on Outlook defaults or autodiscover).
                # POP3 Secure Connection (0/1/2) is the modern flag when
                # present.
                secureConnection = (Get-RegValueDword  -RegKey $rk -Name 'POP3 Secure Connection')
            }
            smtp         = [ordered]@{
                server           = (Get-RegValueString -RegKey $rk -Name 'SMTP Server')
                userName         = (Get-RegValueString -RegKey $rk -Name 'SMTP User')
                port             = (Get-RegValueDword  -RegKey $rk -Name 'SMTP Port')
                useSSL           = (Get-RegValueDword  -RegKey $rk -Name 'SMTP Use SSL')
                useAuth          = (Get-RegValueDword  -RegKey $rk -Name 'SMTP Use Auth')
                authMethod       = (Get-RegValueDword  -RegKey $rk -Name 'SMTP Auth Method')
                secureConnection = (Get-RegValueDword  -RegKey $rk -Name 'SMTP Secure Connection')
            }
            options      = [ordered]@{
                # POP3-specific bit field: "Leave on Server" + days-to-keep
                # + delete-from-server-on-removal flags packed into one DWORD.
                # We record the raw value for the operator to interpret.
                leaveOnServer = (Get-RegValueDword -RegKey $rk -Name 'Leave on Server')
            }
            # Diagnostic: whether a password blob is stored for this
            # account. We never read the actual encrypted bytes (DPAPI,
            # not portable). Just record presence as a hint to the
            # operator that a re-prompt will be needed at restore time.
            passwordStored = [ordered]@{
                pop3 = ($null -ne (Get-RegValueRaw -RegKey $rk -Name 'POP3 Password'))
                smtp = ($null -ne (Get-RegValueRaw -RegKey $rk -Name 'SMTP Password'))
            }
        }

        # v0.16: 3-stage PST resolution chain via Resolve-AccountPst.
        # Stage 1 (filename match against email, highest confidence) is
        # tried first, which deterministically resolves the common case
        # of Outlook 2010+ default naming (<email>.pst) — including the
        # multi-PST profiles that v0.15 mis-mapped.
        $entryIdBytes = Get-RegValueRaw -RegKey $rk -Name 'Delivery Store EntryID'
        $pstCandidates = @($profilePstPaths)
        $resolution = Resolve-AccountPst `
            -Email          $entry.email `
            -EntryIdBytes   $entryIdBytes `
            -PstCandidates  $pstCandidates

        $pstPath   = $resolution.Path
        $pstReason = if ($null -eq $pstPath) { $resolution.Reason } else { $null }
        $pstStatus = if ($null -eq $pstPath) {
                         'unavailable'
                     } elseif (Test-Path -LiteralPath $pstPath) {
                         'present'
                     } else {
                         'path-only'
                     }

        if ($null -eq $pstPath -and $null -ne $entryIdBytes) {
            # Diagnostic: dump up to 128 bytes of the EntryID for future
            # offline analysis when neither filename match nor EntryID
            # scan succeeded.
            $maxIdx = [Math]::Min(127, $entryIdBytes.Length - 1)
            $hex = ($entryIdBytes[0..$maxIdx] |
                    ForEach-Object { '{0:X2}' -f $_ }) -join ' '
            $warnings += "PST mapping unavailable for ${profileName}/${subKeyName}: $pstReason. " +
                         "Profile PSTs found: $($pstCandidates.Count). " +
                         "EntryID head (max 128 bytes): $hex"
        }

        $entry.pst = [ordered]@{
            sourcePath        = $pstPath
            sourceFileName    = if ($pstPath) { Split-Path $pstPath -Leaf } else { $null }
            detectionMethod   = $resolution.Method
            detectionStatus   = $pstStatus
            detectionReason   = $pstReason
            profileCandidates = @($pstCandidates)
        }

        Show-Success "  [$subKeyName] $($entry.accountName)  <$($entry.email)>  pop=$($entry.pop3.server):$($entry.pop3.port)"
        if ($pstPath) {
            Show-Info "             pst=$pstPath  ($pstStatus, $($resolution.Method))"
        } else {
            Show-Warning "             pst=(unavailable: $pstReason)"
        }
        $accountEntries += $entry
        $totalPop++
    }

    $manifestProfiles += [ordered]@{
        name     = $profileName
        accounts = @($accountEntries)
    }
}

# ----------------------------------------------------------
# Phase 2.10.1: profile registry hive export (Strategy B data)
#
# For every profile that captured at least one POP3 account, dump the
# entire profile registry subtree to a .reg file via reg.exe export.
# This is the raw data the restore path (Phase 2.10.2) imports into
# the target user's HKCU to reconstitute POP3 + SMTP + Contacts +
# message-store wiring without operator-typed settings (only the
# password remains user-entered on first send/receive).
#
# Failure is recorded as a warning; the section still returns its
# normal status because the manifest + PST placement path (Strategy A,
# Phase 2.10.0) remains viable as a fallback.
# ----------------------------------------------------------
$regExports = @()
foreach ($prof in $manifestProfiles) {
    if (@($prof.accounts).Count -le 0) { continue }
    $profName = $prof.name
    $sanitizedName = ($profName -replace '[\\/:\*\?"<>\|]', '_').Trim()
    if ([string]::IsNullOrWhiteSpace($sanitizedName)) { $sanitizedName = 'unnamed' }

    $regFileName = "profile_$sanitizedName.reg"
    $regOutPath  = Join-Path $sectionDir $regFileName
    $regSrcPath  = "$($hkcuInfo.RegExePath)\Software\Microsoft\Office\$outlookVersion\Outlook\Profiles\$profName"

    Show-Info "[reg-export] $regSrcPath"
    Show-Info "[reg-export] -> $regFileName"

    $regStdout = & reg.exe export $regSrcPath $regOutPath /y 2>&1
    $regExitCode = $LASTEXITCODE

    if ($regExitCode -ne 0 -or -not (Test-Path -LiteralPath $regOutPath)) {
        $msg = "reg.exe export failed for profile '$profName' (exit=$regExitCode): $regStdout"
        $warnings += $msg
        Show-Warning "  reg.exe export failed (exit=$regExitCode)"
        continue
    }

    $regSize = (Get-Item -LiteralPath $regOutPath).Length
    Show-Success "  reg.exe export OK ($regSize bytes)"

    $regExports += [ordered]@{
        profileName = $profName
        regFile     = $regFileName
        sourceKey   = $regSrcPath
        sizeBytes   = [int]$regSize
    }
}

# ----------------------------------------------------------
# Build manifest (fabriq-outlook-pop-backup schemaVersion=1)
# ----------------------------------------------------------
$hwUid = $null
try { $hwUid = (Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop |
                Select-Object -First 1).UUID } catch { }
$osArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' }
          elseif ([Environment]::Is64BitOperatingSystem) { 'amd64' }
          else { 'x86' }
$osVersion = [System.Environment]::OSVersion.Version.ToString()
$kernelVersionFile = Join-Path $FabriqRoot 'kernel\KERNEL_VERSION'
$kernelVersion = if (Test-Path $kernelVersionFile) { (Get-Content $kernelVersionFile -Raw).Trim() } else { 'unknown' }
$moduleVersionFile = Join-Path $BackuperRoot 'VERSION'
if (-not (Test-Path $moduleVersionFile)) {
    # Detached repo layout (E:\fabriq_backuper\): VERSION sits at the
    # repo root, one level above $BackuperRoot (= backuper/). The original
    # apps/fabriq_backuper layout had VERSION in the same dir.
    $moduleVersionFile = Join-Path (Split-Path -Parent $BackuperRoot) 'VERSION'
}
$moduleVersion = if (Test-Path $moduleVersionFile) { (Get-Content $moduleVersionFile -Raw).Trim() } else { 'unknown' }

$sourceUserName = $null
if (-not [string]::IsNullOrWhiteSpace($sourceUserProfilePath)) {
    try { $sourceUserName = Split-Path $sourceUserProfilePath -Leaf } catch { }
}

$profileCountWithPop  = @($manifestProfiles | Where-Object { @($_.accounts | Where-Object { $_.type -eq 'pop3' }).Count -gt 0 }).Count
$profileCountWithImap = @($manifestProfiles | Where-Object { @($_.accounts | Where-Object { $_.type -eq 'imap' }).Count -gt 0 }).Count

$manifest = [ordered]@{
    schemaVersion       = 1
    manifestType        = 'fabriq-outlook-pop-backup'
    backupVersion       = $moduleVersion
    fabriqKernelVersion = $kernelVersion
    collectedAt         = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    computerName        = $OldPcName
    hardwareUniqueId    = $hwUid
    osVersion           = $osVersion
    osArch              = $osArch
    outlookVersion      = $outlookVersion
    installedOutlook    = [ordered]@{
        installed         = [bool]$outlookInstallInfo.Installed
        registryVersion   = $outlookInstallInfo.RegistryVersion
        productFamily     = $outlookInstallInfo.ProductFamily
        installType       = $outlookInstallInfo.InstallType
        productReleaseIds = $outlookInstallInfo.ProductReleaseIds
        outlookExePath    = $outlookInstallInfo.OutlookExePath
        outlookExeVersion = $outlookInstallInfo.OutlookExeVersion
        allVersionsFound  = @($outlookInstallInfo.AllVersionsFound)
    }
    sourceUser          = [ordered]@{
        profilePath = $sourceUserProfilePath
        userName    = $sourceUserName
        sid         = $hkcuInfo.SID
        redirected  = [bool]$hkcuInfo.Redirected
    }
    counts              = [ordered]@{
        profile           = @($manifestProfiles).Count
        profileWithPop    = $profileCountWithPop
        profileWithImap   = $profileCountWithImap
        popAccount        = $totalPop
        imapAccount       = $totalImap
        otherSkipped      = $totalOther
    }
    items               = [ordered]@{
        profiles   = @($manifestProfiles)
        regExports = @($regExports)
    }
    warnings            = @($warnings)
    notes               = @(
        'Passwords are DPAPI-encrypted per-user/per-machine and excluded from this manifest.',
        'POP3 and IMAP accounts are both enumerated (Phase 2.13.0+). Exchange / Office365 OAuth accounts are still excluded.',
        'IMAP entries (type=imap) have no pst block: OST files are per-machine DPAPI-encrypted and not migrated. Outlook re-syncs all folders from the IMAP server on first launch.',
        'Strategy A restore: derive the localized "Outlook Files" folder name from items.profiles[].accounts[].pst.sourcePath (POP entries only), recreate it under the target user Documents, place each PST as <email>.pst, and let Outlook path-collision-attach on first launch (operator copies POP/SMTP settings from RESTORE_INSTRUCTIONS.txt).',
        'Strategy B restore: import items.regExports[].regFile into target user HKCU via reg.exe import, then place PST, then Outlook prompts only for password on first launch.'
    )
}

$manifestPath = Join-Path $sectionDir 'manifest.json'
$manifest | ConvertTo-Json -Depth 8 | Out-File -FilePath $manifestPath -Encoding UTF8 -Force

$sw.Stop()

$status = if (($totalPop + $totalImap) -eq 0) { 'Skipped' } else { 'Success' }
Show-Info "Accounts captured: POP=$totalPop  IMAP=$totalImap  (other skipped: $totalOther)"

return [PSCustomObject]@{
    Status               = $status
    ElapsedMs            = [int]$sw.ElapsedMilliseconds
    Summary              = [ordered]@{
        profileCount        = @($manifestProfiles).Count
        popAccountCount     = $totalPop
        imapAccountCount    = $totalImap
        otherSkipped        = $totalOther
        outlookVersion      = $outlookVersion
        installedFamily     = $outlookInstallInfo.ProductFamily
        installedType       = $outlookInstallInfo.InstallType
        installedExeVersion = $outlookInstallInfo.OutlookExeVersion
    }
    Warnings             = $warnings
    ExternalOutputDir    = $null
    ExternalManifestPath = $null
    InternalSectionDir   = $sectionDir
    InternalManifestPath = $manifestPath
}
