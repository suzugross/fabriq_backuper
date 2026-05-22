# ============================================================
# FabriqBackUper Section: outlook_pop / restore (Phase 2.10.2)
#
# Two-strategy restore with automatic fallback:
#
#   Strategy B (primary, new in 2.10.2):
#     - Import the source profile registry hive (.reg files captured
#       by backup Phase 2.10.1) into the target user's HKCU. Outlook
#       starts up fully configured; the operator only types the
#       password on first send/receive (DPAPI restriction).
#     - Verified empirically 2026-05-16 on s_suzuki -> Administrator
#       and 365 -> 2019 cross-user / cross-version cases.
#
#   Strategy A (fallback, preserved from 2.10.0):
#     - Place PSTs at expected target paths and generate a
#       RESTORE_INSTRUCTIONS.txt cheat sheet for fully-manual operator
#       Outlook wizard setup. Used when Strategy B is not viable
#       (missing reg exports, version mismatch, import failure, or
#       post-import verification mismatch).
#
# Common to both strategies: PST file placement at the target user's
# Documents\<localized-Outlook-Files>\<email>.pst. The userdata
# section is expected to have done the actual file copy; this section
# performs the idempotent rename and verifies presence.
#
# SectionParams (hashtable, all optional):
#   TargetUserProfilePath : profile path of the user whose HKCU to
#                           target. Mirrors the userdata section.
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
# Strategy B helper functions
# ----------------------------------------------------------

function Get-OutlookInstallInfo {
    # Phase 2.11.0: detect Outlook installation on the local machine.
    # Mirror of the helper in backup.ps1 (identical implementation).
    # Currently used for diagnostic / Summary recording only; no branching
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

function Get-RegFileSourceHive {
    # Inspect a .reg file (UTF-16LE) and return the hive prefix used by
    # its first [HIVE\...] header. Examples:
    #   [HKEY_CURRENT_USER\Software\...]          -> 'HKEY_CURRENT_USER'
    #   [HKEY_USERS\S-1-5-21-...\Software\...]    -> 'HKEY_USERS\S-1-5-21-...'
    # Returns $null if no recognisable header is found.
    param([Parameter(Mandatory = $true)][string]$RegPath)
    $text = [System.IO.File]::ReadAllText($RegPath, [System.Text.Encoding]::Unicode)
    $pattern = '\[(HKEY_CURRENT_USER|HKEY_USERS\\[^\\\]]+)\\'
    $m = [System.Text.RegularExpressions.Regex]::Match($text, $pattern)
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Convert-RegFileToTargetHive {
    # Rewrite all '[<SourcePrefix>\...]' headers in a .reg file to use
    # '<TargetPrefix>' instead, producing a new temp .reg with the same
    # UTF-16LE BOM encoding. Returns the temp path. If prefixes match,
    # returns the input path unchanged (no temp file created).
    param(
        [Parameter(Mandatory = $true)][string]$SrcRegPath,
        [Parameter(Mandatory = $true)][string]$SourcePrefix,
        [Parameter(Mandatory = $true)][string]$TargetPrefix
    )
    if ($SourcePrefix -eq $TargetPrefix) { return $SrcRegPath }

    $text = [System.IO.File]::ReadAllText($SrcRegPath, [System.Text.Encoding]::Unicode)
    $escSrc = [System.Text.RegularExpressions.Regex]::Escape($SourcePrefix)
    $rewritten = [System.Text.RegularExpressions.Regex]::Replace(
        $text, "\[$escSrc\\", "[$TargetPrefix\")
    $rewritten = [System.Text.RegularExpressions.Regex]::Replace(
        $rewritten, "\[$escSrc\]", "[$TargetPrefix]")

    $tempBase = [System.IO.Path]::GetTempFileName()
    $tempReg = [System.IO.Path]::ChangeExtension($tempBase, '.reg')
    if (Test-Path -LiteralPath $tempBase) {
        Remove-Item -LiteralPath $tempBase -Force -ErrorAction SilentlyContinue
    }
    [System.IO.File]::WriteAllText($tempReg, $rewritten, [System.Text.Encoding]::Unicode)
    return $tempReg
}

function Invoke-RegImport {
    # Run reg.exe import and capture stdout/stderr + exit code via file
    # redirection. Returns @{ Success; ExitCode; Output }.
    #
    # WHY Start-Process with file redirection instead of '& reg.exe ... 2>&1':
    # reg.exe import writes its success message ("operation completed
    # successfully" / localized variant) to STDERR, not STDOUT. PowerShell's
    # 2>&1 merges stderr into the error stream as ErrorRecord objects;
    # when fabriq's engine sets $ErrorActionPreference = 'Stop' (the
    # default for sections), encountering an ErrorRecord terminates the
    # section even though reg import itself succeeded with exit 0. Using
    # Start-Process with separate file redirects sidesteps the PS stream
    # merge entirely.
    param([Parameter(Mandatory = $true)][string]$RegPath)

    $tempOut = [System.IO.Path]::GetTempFileName()
    $tempErr = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath 'reg.exe' `
            -ArgumentList @('import', $RegPath) `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $tempOut `
            -RedirectStandardError  $tempErr
        $exit = $proc.ExitCode
        $stdout = if (Test-Path -LiteralPath $tempOut) { (Get-Content -LiteralPath $tempOut -Raw) } else { '' }
        $stderr = if (Test-Path -LiteralPath $tempErr) { (Get-Content -LiteralPath $tempErr -Raw) } else { '' }
        $combined = (@($stdout, $stderr) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join " | "
        return @{
            Success  = ($exit -eq 0)
            ExitCode = $exit
            Output   = $combined.Trim()
        }
    } finally {
        Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tempErr -Force -ErrorAction SilentlyContinue
    }
}

function Test-AccountImported {
    # Walk the target hive to verify a specific account subkey exists
    # with the expected server value. Returns
    # @{ Verified=$true/$false; Reason=<string-or-null> }.
    #
    # Phase 2.13.0: ServerValueName parameterised to support both POP3
    # ('POP3 Server') and IMAP ('IMAP Server') accounts.
    param(
        [Parameter(Mandatory = $true)][string]$HiveDrivePath,
        [Parameter(Mandatory = $true)][string]$OutlookVersion,
        [Parameter(Mandatory = $true)][string]$ProfileName,
        [Parameter(Mandatory = $true)][string]$SubKey,
        [Parameter(Mandatory = $true)][string]$ExpectedServer,
        [string]$ServerValueName = 'POP3 Server'
    )
    $accountKey = "$HiveDrivePath\Software\Microsoft\Office\$OutlookVersion\Outlook\Profiles\" +
                  "$ProfileName\9375CFF0413111d3B88A00104B2A6676\$SubKey"
    if (-not (Test-Path -LiteralPath $accountKey)) {
        return @{ Verified = $false; Reason = "subkey not found: $accountKey" }
    }
    try {
        $rk = Get-Item -LiteralPath $accountKey -ErrorAction Stop
        $raw = $rk.GetValue($ServerValueName, $null)
        if ($null -eq $raw) {
            return @{ Verified = $false; Reason = "$ServerValueName value missing at imported subkey" }
        }
        $imported = if ($raw -is [byte[]]) {
            [System.Text.Encoding]::Unicode.GetString([byte[]]$raw).TrimEnd([char]0)
        } else { [string]$raw }
        if ($imported -eq $ExpectedServer) {
            return @{ Verified = $true; Reason = $null }
        }
        return @{ Verified = $false; Reason = "$ServerValueName mismatch: expected '$ExpectedServer', imported '$imported'" }
    } catch {
        return @{ Verified = $false; Reason = "verify exception: $($_.Exception.Message)" }
    }
}

function Convert-RegFileToStrategyBLight {
    # Phase 2.10.3 / extended in Phase 2.12.0 for cross-version + IMAP /
    # v0.18.2: T7 reverted, T5 trigger reverted to cross-version only.
    # IMAP-containing profiles are now gated out at the main-flow level
    # BEFORE reaching this transform, so the function only ever processes
    # POP-only profiles. T7 (IMAP subkey drop) and the expanded T5
    # (IMAP-drop-triggered OST drop) became dead code and were removed.
    #
    # Pre-process a profile .reg file to make Outlook's account-to-store
    # binding cross-PC-portable. Five transforms, all section-aware where
    # needed:
    #
    #   T1 (Phase 2.12.0, cross-version only):
    #     Rewrite '\Office\<srcVer>\Outlook\' -> '\Office\<dstVer>\Outlook\'
    #     in every section header and value path. Applied only when
    #     SourceVersion -ne TargetVersion. No-op for same-version restore.
    #
    #   T2 (Phase 2.10.3 baseline):
    #     Strip "Delivery Store EntryID" / "Delivery Folder EntryID" from
    #     POP/IMAP account subkeys (\9375CFF0...\NNNNNNNN). Scope-limited
    #     so 365's native service-def subkeys are not affected.
    #
    #   T3 (Phase 2.12.0, IMAP cross-PC support):
    #     Strip "IMAP Store EID" from POP/IMAP account subkeys
    #     (\9375CFF0...\NNNNNNNN). IMAP Store EID encodes a binary MAPI
    #     EntryID pointing to the source PC's OST file via per-machine
    #     MAPIUID -> unresolvable on target. Scope-limited same as T2.
    #
    #     IMPORTANT: do NOT strip "Service UID" -- it is load-bearing for
    #     the MAPI service-def loader (Phase 2.12.0 PoC v3 corrupted the
    #     profile this way: Account Settings dialog won't open, dialog
    #     buttons unresponsive, UAC prompts on Profile Management).
    #     Similarly, do NOT strip "Preferences UID" (also present in POP
    #     account subkey, would risk POP regression).
    #
    #   T4 (Phase 2.10.3 baseline / extended in Phase 2.12.2):
    #     Rewrite plain UTF-16LE hex path values, replacing source
    #     username with target username. Targets:
    #       - "001f6700" (PR_PST_PATH-like, primary local store path)
    #       - "001f0433" (sharing.xml path)
    #       - "001f6610" (additional store path, present in OST
    #         service-def subkeys alongside 001f6700; added Phase 2.12.2
    #         after same-version IMAP restore exposed Outlook reading
    #         this value with the stale source-user path)
    #     All three are plain UTF-16LE strings with no binary offset
    #     tables, safe to extend.
    #
    #   T6 (Phase 2.12.2, OST cross-PC support) -- SAME-VERSION ONLY:
    #     For OST-bearing service-def subkeys (identified by 001f6700
    #     ending in ".ost"), strip "01020fff" (PR_ENTRYID) and "01020ffb"
    #     (related PR_RECORD_KEY-style binary). These contain wrapped
    #     binary EntryIDs with the source-user OST path embedded in
    #     internal offsets; they cannot be safely rewritten (binary
    #     offset tables break when path length changes -- empirically
    #     confirmed via Tier 1 PoC). Stripping is safe because Outlook
    #     regenerates these properties on first open from the surviving
    #     001f6700 / 001f6610 path values (which T4 has rewritten to the
    #     target user).
    #
    #     Same-version only because cross-version drops the entire OST
    #     subkey via T5; T6 would be redundant there.
    #
    #   T5 (Phase 2.12.0, OST cross-PC support) -- CROSS-VERSION ONLY:
    #     Drop any subkey whose "001f6700" value decodes to a path ending
    #     in ".ost". These are MAPI service-def subkeys for IMAP message
    #     stores; their OST file references point to source PC paths that
    #     either don't exist or can't be DPAPI-decrypted on the target.
    #
    #     Gating: cross-version only (Phase 2.12.1 hotfix rationale,
    #     reinstated in v0.18.2 after v0.18.0's expanded trigger was
    #     proven unsafe). The drop creates dangling MAPIUID references in
    #     surviving subkeys (IMAP account "Service UID", MAPI section
    #     provider 0a0d02... etc). Outlook 365 importing a 2013 (15.0) reg
    #     goes through a lenient "schema migration" path that tolerates
    #     these, but Outlook 365 importing its own (16.0) reg validates
    #     strictly and fails to open the profile ("cannot open this folder
    #     set"). v0.18.0 attempted to side-step this by also dropping the
    #     IMAP account subkey via T7 -- but well-known subkeys in same-ver
    #     still hold the now-dangling MAPIUID and Outlook silently crashes
    #     on startup. v0.18.2 abandons that path: IMAP-containing profiles
    #     skip B-light entirely at the main-flow gate, so this function
    #     only sees POP-only profiles. POP-only profiles have no OST
    #     subkeys to begin with, so T5 is effectively a no-op for them,
    #     but the cross-version condition is preserved for completeness.
    #
    # Returns the path to a new temp .reg with the transforms applied.
    param(
        [Parameter(Mandatory = $true)][string]$SrcRegPath,
        [Parameter(Mandatory = $true)][string]$SourceUserName,
        [Parameter(Mandatory = $true)][string]$TargetUserName,
        [string]$SourceVersion = $null,
        [string]$TargetVersion = $null
    )

    $intAcctRe = '\\9375CFF0413111d3B88A00104B2A6676\\[0-9A-Fa-f]{8}$'

    $content = [System.IO.File]::ReadAllText($SrcRegPath, [System.Text.Encoding]::Unicode)

    # Pre-fix: defensive patch for continuation lines missing trailing
    # '\' (seen in some reg.exe export output edge cases)
    $preLines = $content -split "`r?`n"
    $preFixed = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $preLines.Count; $i++) {
        $cur = $preLines[$i]
        if ($cur -match '[0-9a-f]{2},?$' -and ($i + 1) -lt $preLines.Count) {
            $next = $preLines[$i + 1]
            if ($next -match '^\s+[0-9a-f]{2}' -and $cur -notmatch '\\$') {
                $cur = $cur.TrimEnd() + '\'
            }
        }
        $preFixed.Add($cur)
    }
    $content = $preFixed -join "`r`n"

    # Collapse continuations into single logical lines
    $normalized = $content -replace '\\\r?\n\s+', ''

    # ---- T1: version path rewrite (only when versions differ) ----
    $t1Count = 0
    if (-not [string]::IsNullOrWhiteSpace($SourceVersion) -and
        -not [string]::IsNullOrWhiteSpace($TargetVersion) -and
        $SourceVersion -ne $TargetVersion) {
        $srcVerEsc   = [regex]::Escape($SourceVersion)
        $pathPattern = "\\Office\\$srcVerEsc\\Outlook\\"
        $pathReplace = "\Office\$TargetVersion\Outlook\"
        $t1Count = ([regex]::Matches($normalized, $pathPattern)).Count
        $normalized = $normalized -replace $pathPattern, $pathReplace
    }

    # ---- Pre-scan: identify OST-bearing service-def subkeys.
    # Always scanned; the resulting set is consumed differently per
    # version mode (T5 drops them when cross-version, T6 strips internal
    # binary path values when same-version POP-only). In practice from
    # v0.18.2+ this function only sees POP-only profiles (IMAP-containing
    # profiles are gated out earlier), so ostSections is typically empty
    # and both T5/T6 become no-ops. The scan is preserved for safety. ----
    $isCrossVersion = -not [string]::IsNullOrWhiteSpace($SourceVersion) -and
                      -not [string]::IsNullOrWhiteSpace($TargetVersion) -and
                      $SourceVersion -ne $TargetVersion
    $lines = $normalized -split "`r?`n"
    $ostSections = New-Object System.Collections.Generic.HashSet[string]
    $currentKey = $null
    foreach ($line in $lines) {
        if ($line -match '^\[(.+)\]\s*$') {
            $currentKey = $matches[1]
            continue
        }
        if ($null -ne $currentKey -and $line -match '^"001f6700"=hex:(.*)$') {
            $hex = $matches[1] -split ','
            try {
                $bytes = $hex | ForEach-Object { [byte]("0x$_") }
                $s = [System.Text.Encoding]::Unicode.GetString([byte[]]$bytes).TrimEnd([char]0)
                if ($s -match '\.ost$') {
                    [void]$ostSections.Add($currentKey)
                }
            } catch { }
        }
    }

    # Username UTF-16LE hex for T4 rewrite
    $srcUserBytes = [System.Text.Encoding]::Unicode.GetBytes($SourceUserName)
    $dstUserBytes = [System.Text.Encoding]::Unicode.GetBytes($TargetUserName)
    $srcUserHex = ($srcUserBytes | ForEach-Object { '{0:x2}' -f $_ }) -join ','
    $dstUserHex = ($dstUserBytes | ForEach-Object { '{0:x2}' -f $_ }) -join ','

    # ---- Main pass: T2/T3/T4 inline, T5 section drop (cross-ver only),
    # T6 binary EntryID strip in OST subkey (same-ver POP-only) ----
    $processedLines = New-Object System.Collections.Generic.List[string]
    $currentKey    = $null
    $inAcctSubkey  = $false
    $inOstSubkey   = $false
    $dropSection   = $false
    $stripPop      = 0
    $stripImap     = 0
    $rewritePath   = 0
    $droppedSec    = 0
    $stripOstBin   = 0
    foreach ($line in $lines) {
        if ($line -match '^\[(.+)\]\s*$') {
            $currentKey = $matches[1]
            $inAcctSubkey = $currentKey -match $intAcctRe
            $inOstSubkey  = $ostSections.Contains($currentKey)
            # T5: drop entire OST service-def section when cross-version.
            # Same-version IMAP-mixed profiles are gated out at the
            # main-flow level so we don't reach here for them; for
            # POP-only profiles ostSections is empty so this branch is
            # essentially never taken.
            if ($inOstSubkey -and $isCrossVersion) {
                $dropSection = $true
                $droppedSec++
                continue
            } else {
                $dropSection = $false
                $processedLines.Add($line)
            }
            continue
        }
        if ($dropSection) { continue }

        # T6: same-version OST binding strip (binary EntryID values
        # carrying source-user OST path embedded; Outlook regenerates).
        if ($inOstSubkey -and -not $isCrossVersion) {
            if ($line -match '^"01020fff"=hex:' -or
                $line -match '^"01020ffb"=hex:') {
                $stripOstBin++
                continue
            }
        }

        if ($inAcctSubkey) {
            if ($line -match '^"Delivery Store EntryID"=' -or
                $line -match '^"Delivery Folder EntryID"=') {
                $stripPop++
                continue
            }
            if ($line -match '^"IMAP Store EID"=') {
                $stripImap++
                continue
            }
        }
        if ($line -match '^"001f6700"=hex:' -or
            $line -match '^"001f0433"=hex:' -or
            $line -match '^"001f6610"=hex:') {
            $before = $line
            $line = $line -replace [regex]::Escape($srcUserHex), $dstUserHex
            if ($before -ne $line) { $rewritePath++ }
        }
        $processedLines.Add($line)
    }

    $t5Label = if ($isCrossVersion) { "T5 OST-drop=$droppedSec" }
               else { 'T5 OST-drop=0 (same-version)' }
    $t6Label = if ($isCrossVersion) { 'T6 OST-bin-strip=0 (skipped: cross-version)' }
               else { "T6 OST-bin-strip=$stripOstBin" }
    Show-Info ("  [BL-transform] T1 version-path=$t1Count  T2 POP-strip=$stripPop  " +
               "T3 IMAP-strip=$stripImap  T4 path-rewrite=$rewritePath  $t5Label  $t6Label")

    # Re-flow hex value lines back to <=80 cols with '\' continuation
    $outputLines = New-Object System.Collections.Generic.List[string]
    $maxLen = 80
    foreach ($line in $processedLines) {
        if ($line -match '^("[^"]+"=hex:)(.*)$') {
            $header = $matches[1]
            $body   = $matches[2]
            $bytes  = @($body -split ',')
            $singleLine = $header + ($bytes -join ',')
            if ($singleLine.Length -le $maxLen) {
                $outputLines.Add($singleLine)
                continue
            }
            $currentLine = $header
            $indent      = '  '
            $i = 0
            while ($i -lt $bytes.Count) {
                $tok = $bytes[$i]
                $sep = if ($currentLine -eq $header -or $currentLine -eq $indent) { '' } else { ',' }
                $needed = $sep.Length + $tok.Length
                $isLast = ($i -eq ($bytes.Count - 1))
                $reserved = if ($isLast) { 0 } else { 2 }
                if (($currentLine.Length + $needed + $reserved) -le $maxLen) {
                    $currentLine = $currentLine + $sep + $tok
                    $i++
                } else {
                    $outputLines.Add($currentLine + ',\')
                    $currentLine = $indent
                }
            }
            $outputLines.Add($currentLine)
        } else {
            $outputLines.Add($line)
        }
    }

    $finalText = $outputLines -join "`r`n"

    $tempBase = [System.IO.Path]::GetTempFileName()
    $tempReg = [System.IO.Path]::ChangeExtension($tempBase, '.reg')
    if (Test-Path -LiteralPath $tempBase) {
        Remove-Item -LiteralPath $tempBase -Force -ErrorAction SilentlyContinue
    }
    [System.IO.File]::WriteAllText($tempReg, $finalText, [System.Text.Encoding]::Unicode)
    return $tempReg
}

function New-OutlookRuleClearShortcut {
    # Phase 0.15.0: generate a Desktop shortcut on the TARGET user that
    # launches Outlook with the documented /cleanclientrules switch. The
    # operator clicks this on first launch to purge any stale rules that
    # the migrated PST carries over from the source PC -- those rules
    # often hold MAPI Entry IDs that the new profile cannot resolve, which
    # is what causes the "rule exists but errors on incoming mail" symptom.
    #
    # /cleanclientrules is scoped to client-side rules only; server-side
    # rules (IMAP / Exchange) live on the mail server and are not touched.
    # Outlook re-syncs them on first IMAP/Exchange sync.
    #
    # Returns hashtable: @{ Success; ShortcutPath; Reason }
    param(
        [Parameter(Mandatory = $true)][string]$TargetUserProfilePath,
        [Parameter(Mandatory = $true)][string]$OutlookExePath
    )

    $result = @{ Success = $false; ShortcutPath = $null; Reason = $null }

    if (-not (Test-Path -LiteralPath $OutlookExePath)) {
        $result.Reason = "OUTLOOK.EXE が見つかりません: $OutlookExePath"
        return $result
    }

    $desktopPath = Join-Path $TargetUserProfilePath 'Desktop'
    if (-not (Test-Path -LiteralPath $desktopPath)) {
        $result.Reason = "対象ユーザの Desktop が見つかりません: $desktopPath"
        return $result
    }

    $shortcutPath = Join-Path $desktopPath 'Outlook を初回起動 (仕分けルールをクリア).lnk'
    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath        = $OutlookExePath
        $shortcut.Arguments         = '/cleanclientrules'
        $shortcut.IconLocation      = "$OutlookExePath,0"
        $shortcut.WorkingDirectory  = Split-Path -Path $OutlookExePath -Parent
        $shortcut.Description       = "移行後の初回起動用。クライアントサイドの仕分けルールをクリアして Outlook を起動します。初回起動後は通常の Outlook アイコンから起動してください。"
        $shortcut.Save()
    } catch {
        $result.Reason = "ショートカット生成に失敗: $($_.Exception.Message)"
        return $result
    } finally {
        if ($null -ne $shell) {
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
        }
    }

    $result.Success = $true
    $result.ShortcutPath = $shortcutPath
    return $result
}

function New-OutlookAccountInfoText {
    # Build a human-readable account-info text used by:
    #   (a) Strategy A fallback -> aggregate/sections/outlook_pop/
    #       RESTORE_INSTRUCTIONS.txt (engineer / operator)
    #   (b) Always-on target-folder copy -> <target_user>\Documents\
    #       <localized_outlook_files>\_account_settings.txt (operator
    #       safety net, travels with the PST file)
    #
    # v0.18.3 scope shrink: the function now emits ONLY account data
    # (source/target metadata + per-account server settings + PST file
    # references). All operator-facing procedural content was removed --
    # manual setup steps, cross-version cleanup, OST/PST behaviour
    # explanations, and the /cleanclientrules shortcut callout are now
    # handled in separate documentation/tooling (out of scope for this
    # repo). Body is in Japanese because the file is read by on-site
    # operators (UI policy applies to operator-facing artifacts).
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$TargetUserProfilePath,
        [Parameter(Mandatory = $true)]$PlannedAccounts,
        [Parameter(Mandatory = $true)]$ResultsByAccount,
        [string]$ProfileFilter = $null
    )

    # Optional per-profile filter: when writing the target-folder copy
    # we want only the accounts whose PST sits in that profile's folder.
    $effectiveResults = $ResultsByAccount
    if (-not [string]::IsNullOrWhiteSpace($ProfileFilter)) {
        $effectiveResults = @($ResultsByAccount | Where-Object { $_.profile -eq $ProfileFilter })
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('========================================') | Out-Null
    $lines.Add(' Outlook アカウント情報') | Out-Null
    $lines.Add('========================================') | Out-Null
    $lines.Add('') | Out-Null

    $lines.Add("移行元 PC     : $($Manifest.computerName)") | Out-Null
    if ($Manifest.sourceUser -and $Manifest.sourceUser.userName) {
        $lines.Add("移行元ユーザ  : $($Manifest.sourceUser.userName)") | Out-Null
    }
    $tgtUserName = Split-Path $TargetUserProfilePath -Leaf
    $lines.Add("対象ユーザ    : $tgtUserName  ($TargetUserProfilePath)") | Out-Null
    $lines.Add("復元日時      : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')") | Out-Null
    $lines.Add("Outlook バージョン: $($Manifest.outlookVersion)") | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($ProfileFilter)) {
        $lines.Add("プロファイル  : $ProfileFilter") | Out-Null
    }
    $lines.Add('') | Out-Null

    $accountIndex = 0
    foreach ($r in $effectiveResults) {
        $accountIndex++
        $acct = ($PlannedAccounts | Where-Object {
            $_.ProfileName -eq $r.profile -and $_.Account.subKey -eq $r.accountSubKey
        } | Select-Object -First 1).Account

        $lines.Add('----------------------------------------') | Out-Null
        # Status enum stays English to match the manifest/section result
        # contract; only surrounding labels are translated.
        $lines.Add(" アカウント $accountIndex : $($r.email)   [$($r.status)]") | Out-Null
        $lines.Add('----------------------------------------') | Out-Null

        if ($r.status -ne 'Success') {
            $lines.Add('  ** アカウント情報を取得できませんでした **') | Out-Null
            $lines.Add("  理由: $($r.reason)") | Out-Null
            $lines.Add('') | Out-Null
            continue
        }

        $isImap = ("$($acct.type)" -eq 'imap')

        $lines.Add('') | Out-Null
        $lines.Add('  アカウント基本情報:') | Out-Null
        $lines.Add("    表示名            : $($acct.displayName)") | Out-Null
        $lines.Add("    メールアドレス    : $($acct.email)") | Out-Null
        $lines.Add("    アカウント種別    : $(if ($isImap) { 'IMAP' } else { 'POP' })") | Out-Null
        $lines.Add('') | Out-Null

        # v0.16: helper closures for "(autodiscover に依存)" hint when
        # a value is null (Outlook 365 often omits POP3 Port / Use SSL
        # entirely, relying on autodiscover / industry defaults).
        $fmtPort = {
            param($v, $sslDefault, $nonSslDefault)
            if ($null -eq $v) {
                "(値なし - autodiscover に依存、SSL なら $sslDefault, 非 SSL なら $nonSslDefault が業界標準)"
            } else { "$v" }
        }
        $fmtSsl = {
            param($v)
            if ($null -eq $v) {
                '(値なし - autodiscover に依存)'
            } elseif ($v -eq 1) { 'はい (必須)' }
            else { 'いいえ' }
        }
        # SMTP Secure Connection (0=なし / 1=STARTTLS / 2=SSL/TLS direct)
        # is the 365-era authoritative flag; capture both legacy useSSL and
        # this modern value when present.
        $fmtSecCon = {
            param($v)
            if ($null -eq $v) { return '(値なし)' }
            switch ([int]$v) {
                0       { '0 (暗号化なし)' }
                1       { '1 (STARTTLS)' }
                2       { '2 (SSL/TLS direct)' }
                default { "$v (不明)" }
            }
        }

        if ($isImap) {
            $lines.Add('  受信サーバ (IMAP):') | Out-Null
            $lines.Add("    サーバ              : $($acct.imap.server)") | Out-Null
            $lines.Add("    ポート              : $(& $fmtPort $acct.imap.port 993 143)") | Out-Null
            $lines.Add("    SSL/TLS (legacy)    : $(& $fmtSsl $acct.imap.useSSL)") | Out-Null
            if ($null -ne $acct.imap.PSObject.Properties['secureConnection']) {
                $lines.Add("    Secure Connection   : $(& $fmtSecCon $acct.imap.secureConnection)") | Out-Null
            }
            $lines.Add("    ユーザ名            : $($acct.imap.userName)") | Out-Null
            if (-not [string]::IsNullOrWhiteSpace("$($acct.imap.folderPath)")) {
                $lines.Add("    ルートフォルダパス  : $($acct.imap.folderPath)") | Out-Null
            }
        } else {
            $lines.Add('  受信サーバ (POP3):') | Out-Null
            $lines.Add("    サーバ              : $($acct.pop3.server)") | Out-Null
            $lines.Add("    ポート              : $(& $fmtPort $acct.pop3.port 995 110)") | Out-Null
            $lines.Add("    SSL/TLS (legacy)    : $(& $fmtSsl $acct.pop3.useSSL)") | Out-Null
            if ($null -ne $acct.pop3.PSObject.Properties['secureConnection']) {
                $lines.Add("    Secure Connection   : $(& $fmtSecCon $acct.pop3.secureConnection)") | Out-Null
            }
            $lines.Add("    SPA (Sicily)        : $(& $fmtSsl $acct.pop3.useSPA)") | Out-Null
            $lines.Add("    ユーザ名            : $($acct.pop3.userName)") | Out-Null
            # v0.16: POP3 specific "Leave on Server" bit field.
            if ($null -ne $acct.PSObject.Properties['options'] -and `
                $null -ne $acct.options.leaveOnServer) {
                $lines.Add(("    Leave on Server     : 0x{0:X8} (raw DWORD)" `
                    -f [long]$acct.options.leaveOnServer)) | Out-Null
            }
        }
        $lines.Add('') | Out-Null

        $lines.Add('  送信サーバ (SMTP):') | Out-Null
        $lines.Add("    サーバ              : $($acct.smtp.server)") | Out-Null
        $lines.Add("    ポート              : $(& $fmtPort $acct.smtp.port 587 25)") | Out-Null
        $lines.Add("    SSL/TLS (legacy)    : $(& $fmtSsl $acct.smtp.useSSL)") | Out-Null
        if ($null -ne $acct.smtp.PSObject.Properties['secureConnection']) {
            $lines.Add("    Secure Connection   : $(& $fmtSecCon $acct.smtp.secureConnection)") | Out-Null
        }
        $lines.Add("    認証                : $(& $fmtSsl $acct.smtp.useAuth)") | Out-Null
        $sameAsLabel = if ($isImap) { '(IMAP と同じ)' } else { '(POP3 と同じ)' }
        $smtpUser = if ($acct.smtp.userName) { $acct.smtp.userName } else { $sameAsLabel }
        $lines.Add("    SMTP ユーザ名       : $smtpUser") | Out-Null
        $lines.Add('') | Out-Null

        if ($isImap) {
            $lines.Add('  ローカルデータファイル (OST):') | Out-Null
            $lines.Add('    移行対象外 (per-machine DPAPI 暗号化のため)') | Out-Null
        } else {
            $lines.Add('  データファイル (PST):') | Out-Null
            $lines.Add("    binding             : $($r.targetPstPath)") | Out-Null
            # v0.17 update: マルチ PST プロファイル時は同一フォルダ内の他 PST を
            # データとして列挙する (v0.18.3: 手順的な advice を削除、列挙のみ)。
            if ($r.PSObject.Properties.Name -contains 'renameSkipped' -and `
                $r.renameSkipped -and `
                $r.PSObject.Properties.Name -contains 'otherPstsAtTarget' -and `
                $r.otherPstsAtTarget.Count -gt 0) {
                $lines.Add("    その他同居 PST:") | Out-Null
                foreach ($op in $r.otherPstsAtTarget) {
                    $lines.Add("      - $op") | Out-Null
                }
            }
        }
        $lines.Add('') | Out-Null
    }

    # v0.18.3: all procedural sections removed. The file is account-data
    # only -- manual setup steps, cross-version cleanup notes, OST/PST
    # behaviour explanations, and the /cleanclientrules shortcut callout
    # are handled by separate documentation/tooling (out of scope here).

    $lines.Add('========================================') | Out-Null

    return ($lines -join "`r`n")
}

# ----------------------------------------------------------
# Parse SectionParams
# ----------------------------------------------------------
$targetUserProfilePath = $null
if ($SectionParams.ContainsKey('TargetUserProfilePath') -and `
    -not [string]::IsNullOrWhiteSpace($SectionParams['TargetUserProfilePath'])) {
    $targetUserProfilePath = "$($SectionParams['TargetUserProfilePath'])"
}
if ([string]::IsNullOrWhiteSpace($targetUserProfilePath)) {
    $targetUserProfilePath = $env:USERPROFILE
}

# Phase 0.15.0: defaults to $false here -- callers that want the rule-clear
# launcher shortcut must opt in via the UI checkbox in restore_view.ps1.
$createRuleClearShortcut = $false
if ($SectionParams.ContainsKey('CreateRuleClearShortcut')) {
    $createRuleClearShortcut = [bool]$SectionParams['CreateRuleClearShortcut']
}

# v0.17.0: Strategy B-light (registry auto-rebuild) is now OFF by default.
# Reason: the T1-T6 MAPI registry transforms are heuristic-based and have a
# track record of subtle profile corruption (cf. restore.ps1:260+ T-series
# comments). Operator manual setup (Strategy A) via the generated
# _account_settings.txt + RESTORE_INSTRUCTIONS.txt is the recommended path.
# The UI checkbox in restore_view.ps1 ("レジストリ自動再構築 (実験的)") gates
# this; callers that omit the flag will skip Strategy B entirely and go
# straight to Strategy A operator handoff.
$attemptStrategyB = $false
if ($SectionParams.ContainsKey('AttemptStrategyB')) {
    $attemptStrategyB = [bool]$SectionParams['AttemptStrategyB']
}

# ----------------------------------------------------------
# Stage 1: read backup manifest, flatten plannedAccounts
# ----------------------------------------------------------
$sectionDir = Join-Path $AggregateBackupDir 'sections\outlook_pop'
$manifestPath = Join-Path $sectionDir 'manifest.json'
if (-not (Test-Path $manifestPath)) {
    return [PSCustomObject]@{
        Status = 'Failed'; ElapsedMs = [int]$sw.ElapsedMilliseconds
        Summary = [ordered]@{}; Warnings = @("manifest.json not found at: $manifestPath")
    }
}
$manifest = $null
try { $manifest = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json } catch {
    return [PSCustomObject]@{
        Status = 'Failed'; ElapsedMs = [int]$sw.ElapsedMilliseconds
        Summary = [ordered]@{}; Warnings = @("manifest.json parse error: $($_.Exception.Message)")
    }
}
if ($manifest.manifestType -ne 'fabriq-outlook-pop-backup') {
    return [PSCustomObject]@{
        Status = 'Failed'; ElapsedMs = [int]$sw.ElapsedMilliseconds
        Summary = [ordered]@{}; Warnings = @("Unexpected manifestType: $($manifest.manifestType)")
    }
}

# ----------------------------------------------------------
# Phase 2.11.0: log source-side install info (from manifest, if backup
# was taken with Phase 2.11.0+ backup.ps1) and probe target-side install.
# Detection only - no branching on these values yet.
# ----------------------------------------------------------
$sourceInstall = $null
if ($manifest.PSObject.Properties.Name -contains 'installedOutlook' -and `
    $null -ne $manifest.installedOutlook) {
    $sourceInstall = $manifest.installedOutlook
    $srcFam  = if ($sourceInstall.productFamily) { $sourceInstall.productFamily } else { 'unknown' }
    $srcType = if ($sourceInstall.installType) { $sourceInstall.installType } else { 'unknown' }
    $srcExe  = if ($sourceInstall.outlookExeVersion) { $sourceInstall.outlookExeVersion } else { 'unknown' }
    Show-Info ("Source Outlook (from manifest): $srcFam (type=$srcType, exeVer=$srcExe)")
} else {
    Show-Info 'Source Outlook (from manifest): not recorded (pre-2.11.0 backup)'
}

$targetInstall = Get-OutlookInstallInfo
if ($targetInstall.Installed) {
    Show-Info ("Target Outlook (this PC): $($targetInstall.ProductFamily) " +
               "(reg=$($targetInstall.RegistryVersion), " +
               "type=$($targetInstall.InstallType), " +
               "exeVer=$($targetInstall.OutlookExeVersion))")
    if ($targetInstall.ProductReleaseIds) {
        Show-Info ("  ProductReleaseIds: $($targetInstall.ProductReleaseIds)")
    }
    if (@($targetInstall.AllVersionsFound).Count -gt 1) {
        Show-Info ("  side-by-side detected: " +
                   ($targetInstall.AllVersionsFound -join ', '))
    }
} else {
    Show-Warning 'Target Outlook (this PC): not detected via HKLM probe'
}

# Cross-family advisory (logged only; no branching). The Strategy B path
# was empirically verified across the 365 -> 2019 case; other cross-family
# combinations may require a future fallback path.
if ($sourceInstall -and $sourceInstall.productFamily -and `
    $targetInstall.Installed -and `
    $sourceInstall.productFamily -ne $targetInstall.ProductFamily) {
    Show-Warning ("Outlook family mismatch: source=$($sourceInstall.productFamily) " +
                  "target=$($targetInstall.ProductFamily) " +
                  "(continuing with current restore path)")
}

# ----------------------------------------------------------
# Phase 2.12.0: cross-version detection.
# Manifest schema 1 records source registry version both at the top level
# (manifest.outlookVersion, present since Phase 2.9.0) and inside
# installedOutlook.registryVersion (Phase 2.11.0+). Target is probed live
# above. When the two registry versions differ, Strategy B-light is
# invoked with version args -> activates T1 (path rewrite) and triggers
# the cross-version operator cleanup section in _account_settings.txt.
# ----------------------------------------------------------
$srcRegVer = "$($manifest.outlookVersion)"
if ($sourceInstall -and $sourceInstall.registryVersion) {
    $srcRegVer = "$($sourceInstall.registryVersion)"
}
$tgtRegVer = $null
if ($targetInstall.Installed) { $tgtRegVer = "$($targetInstall.RegistryVersion)" }

$isCrossVersion = $false
$crossVersionDirection = $null
if (-not [string]::IsNullOrWhiteSpace($srcRegVer) -and
    -not [string]::IsNullOrWhiteSpace($tgtRegVer) -and
    $srcRegVer -ne $tgtRegVer) {
    $isCrossVersion = $true
    $crossVersionDirection = "$srcRegVer -> $tgtRegVer"
    Show-Info ("Cross-version restore detected: $crossVersionDirection " +
               "(Strategy B-light T1 path rewrite will be applied)")
    # 16.0 -> 15.0 direction is unvalidated; 365-only values (Account UID,
    # New Signature, etc.) may confuse 2013. Emit a warning so the operator
    # is aware. Same caveat for 15.0 -> 15.0 (unanticipated equal-version
    # case but logically should reduce to same-version B-light).
    if ($srcRegVer -eq '16.0' -and $tgtRegVer -eq '15.0') {
        Show-Warning ('Cross-version direction 16.0 -> 15.0 is unvalidated. ' +
                      '365-only profile values may not be accepted by Outlook 2013. ' +
                      'Manual operator cleanup or Strategy A fallback may be required.')
    }
}

# v0.18.3: removed the global $imapPresent detection block. The flag was
# previously consumed by the Stage 5a popup's "elseif ($imapPresent)"
# branch (v0.18.2 removed it -- replaced by per-profile partial-skip
# logic that uses $bLightSkippedImapProfileNames) and by
# New-OutlookAccountInfoText's IMAP wizard re-add section (also removed
# in v0.18.2). With both consumers gone the variable was dead code.
# Per-profile IMAP detection still happens inline at the Strategy B-light
# safety gate via $profileHasImap.

$plannedAccounts = @()
foreach ($prof in @($manifest.items.profiles)) {
    foreach ($acct in @($prof.accounts)) {
        $plannedAccounts += [PSCustomObject]@{
            ProfileName = $prof.name
            Account     = $acct
        }
    }
}
if ($plannedAccounts.Count -eq 0) {
    return [PSCustomObject]@{
        Status = 'Skipped'; ElapsedMs = [int]$sw.ElapsedMilliseconds
        Summary = [ordered]@{ note = 'no POP accounts in manifest' }
        Warnings = @($warnings)
    }
}

Show-Info "Preparing $($plannedAccounts.Count) POP account(s) for restore"

# Progress entries: one per POP account
try {
    $uiEntries = foreach ($pa in $plannedAccounts) {
        @{ Id = "$($pa.ProfileName)/$($pa.Account.subKey)"; Label = "$($pa.Account.email)" }
    }
    Initialize-ProgressEntries -Entries @($uiEntries)
} catch { }

$sourceUserProfile = $null
if ($manifest.sourceUser -and $manifest.sourceUser.profilePath) {
    $sourceUserProfile = "$($manifest.sourceUser.profilePath)".TrimEnd('\','/')
}

# ----------------------------------------------------------
# Stage 2: PST placement (common to Strategy A and B)
# Per account: verify PST exists at rebased target path and rename to
# <email>.pst (idempotent). Records per-account result for use by
# subsequent strategy decision.
# ----------------------------------------------------------
$successCount = 0
$failCount    = 0
$resultsByAccount = @()

foreach ($pa in $plannedAccounts) {
    $profileName = $pa.ProfileName
    $a           = $pa.Account
    $entryId     = "$profileName/$($a.subKey)"
    try { Set-EntryStatus -Id $entryId -Status 'InProgress' } catch { }
    Show-Info "[$entryId] $($a.email)"

    $accountResult = [ordered]@{
        profile           = $profileName
        accountSubKey     = $a.subKey
        accountType       = "$($a.type)"
        email             = $a.email
        status            = 'Failed'
        reason            = $null
        targetPstPath     = $null
        # v0.17 update: マルチ PST 環境ではリネームを skip し、operator が
        # Outlook wizard で明示選択することを期待する。下記 2 フィールドで
        # _account_settings.txt 等の operator 向け文言に反映する。
        renameSkipped     = $false
        otherPstsAtTarget = @()
        verifyResult      = $null
    }

    # Phase 2.13.0: IMAP accounts have no PST to place (OST is per-machine
    # encrypted, not migrated). Skip Stage 2 PST logic entirely and mark
    # ready for Strategy B reg-import + first-launch IMAP sync.
    if ("$($a.type)" -eq 'imap') {
        Show-Info '  [imap] no PST placement (OST will auto-recreate on first IMAP sync)'
        $accountResult.status = 'Success'
        $accountResult.targetPstPath = $null
        $resultsByAccount += $accountResult
        $successCount++
        try { Set-EntryStatus -Id $entryId -Status 'Done' } catch { }
        continue
    }

    if (-not $a.pst -or [string]::IsNullOrWhiteSpace($a.pst.sourcePath)) {
        $msg = "no pst.sourcePath in manifest for $entryId - backup may have failed PST detection."
        $warnings += $msg
        Show-Warning "  $msg"
        $accountResult.reason = 'PST mapping unavailable in manifest'
        $resultsByAccount += $accountResult
        $failCount++
        try { Set-EntryStatus -Id $entryId -Status 'Failed' } catch { }
        continue
    }

    # Cross-user rebase: source\path -> target\path
    $srcPath = "$($a.pst.sourcePath)"
    $rebasedPath = $null
    if ($null -ne $sourceUserProfile -and $srcPath.Length -ge $sourceUserProfile.Length -and `
        $srcPath.Substring(0, $sourceUserProfile.Length) -ieq $sourceUserProfile) {
        $rest = $srcPath.Substring($sourceUserProfile.Length)
        $rebasedPath = "$($targetUserProfilePath.TrimEnd('\','/'))$rest"
    } else {
        $rebasedPath = $srcPath
    }
    Show-Info "  expected PST path at target: $rebasedPath"

    # Target rename path: <folder>\<email>.pst (path-collision-attach)
    $targetDir = Split-Path -Path $rebasedPath -Parent
    $renamedPath = Join-Path $targetDir "$($a.email).pst"

    if (-not (Test-Path -LiteralPath $rebasedPath) -and -not (Test-Path -LiteralPath $renamedPath)) {
        $msg = "PST not at target: '$rebasedPath' and not at '$renamedPath'. Engineer: ensure userdata section includes the Outlook Files folder."
        $warnings += $msg
        Show-Error "  $msg"
        $accountResult.reason = 'PST not found at target'
        $accountResult.targetPstPath = $rebasedPath
        $resultsByAccount += $accountResult
        $failCount++
        try { Set-EntryStatus -Id $entryId -Status 'Failed' } catch { }
        continue
    }

    # v0.17 update: マルチ PST プロファイルではリネームを skip する。
    #
    # Why: <email>.pst という名前の他 PST (古いアーカイブ等) が同じプロファイル
    # に共存していた場合、リネームすると古いアーカイブを active な PST として
    # auto-attach させてしまう。EntryID で正しく解決した PST を上書きせず
    # 原名のまま保持し、operator が Outlook wizard で「Browse」で明示選択する
    # 運用とする。_account_settings.txt にどの PST を選ぶべきかを明記。
    #
    # Detection: profileCandidates に sourcePath 以外の PST が存在すれば
    # マルチ PST と判定。
    $otherPstsInProfile = @()
    if ($null -ne $a.pst.profileCandidates) {
        $otherPstsInProfile = @($a.pst.profileCandidates | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and ($_ -ine $srcPath)
        })
    }
    $isMultiPstProfile = ($otherPstsInProfile.Count -gt 0)

    if ($isMultiPstProfile) {
        # Rebase each other PST to the target user path so that the
        # operator-facing _account_settings.txt can reference them by
        # their actual filesystem location post-userdata-copy.
        $otherPstsAtTarget = @($otherPstsInProfile | ForEach-Object {
            $op = "$_"
            if ($null -ne $sourceUserProfile -and `
                $op.Length -ge $sourceUserProfile.Length -and `
                $op.Substring(0, $sourceUserProfile.Length) -ieq $sourceUserProfile) {
                "$($targetUserProfilePath.TrimEnd('\','/'))$($op.Substring($sourceUserProfile.Length))"
            } else { $op }
        })

        Show-Info "  Multi-PST profile detected ($($otherPstsInProfile.Count + 1) PSTs in profile), skipping rename"
        Show-Info "  PST preserved at original name: $rebasedPath"
        foreach ($op in $otherPstsAtTarget) {
            Show-Info "    other PST in profile: $op"
        }
        $accountResult.renameSkipped     = $true
        $accountResult.otherPstsAtTarget = $otherPstsAtTarget
        $accountResult.targetPstPath     = $rebasedPath
        $accountResult.status            = 'Success'
        $resultsByAccount += $accountResult
        $successCount++
        try { Set-EntryStatus -Id $entryId -Status 'Done' } catch { }
        continue
    }

    # Single-PST profile: 従来の path-collision-attach 用リネームを実施
    if ($rebasedPath -ine $renamedPath) {
        if (Test-Path -LiteralPath $renamedPath) {
            Show-Info "  rename target already at <email>.pst (idempotent skip): $renamedPath"
            if (Test-Path -LiteralPath $rebasedPath) {
                $msg = "both '$rebasedPath' and '$renamedPath' exist; will use the renamed one. Engineer: original-name file is orphaned."
                $warnings += $msg
                Show-Warning "  $msg"
            }
        } else {
            try {
                Move-Item -LiteralPath $rebasedPath -Destination $renamedPath -ErrorAction Stop
                Show-Success "  renamed PST -> $renamedPath"
            } catch {
                $msg = "PST rename failed: $($_.Exception.Message). Source: $rebasedPath -> $renamedPath"
                $warnings += $msg
                Show-Error "  $msg"
                $accountResult.reason = "rename failed: $($_.Exception.Message)"
                $accountResult.targetPstPath = $renamedPath
                $resultsByAccount += $accountResult
                $failCount++
                try { Set-EntryStatus -Id $entryId -Status 'Failed' } catch { }
                continue
            }
        }
    }
    $accountResult.targetPstPath = $renamedPath
    $accountResult.status = 'Success'
    $resultsByAccount += $accountResult
    $successCount++
    try { Set-EntryStatus -Id $entryId -Status 'Done' } catch { }
}

# ----------------------------------------------------------
# Stage 3 + 4: Strategy B attempt (reg import + per-account verify)
#
# Viability gate: items.regExports[] must exist and be non-empty.
# Older 2.10.0 backups have no regExports; those go straight to A.
# ----------------------------------------------------------
$regExports = @()
if ($manifest.items.PSObject.Properties.Name -contains 'regExports') {
    $regExports = @($manifest.items.regExports)
}

$strategyBAttempted = $false
$strategyBSucceeded = $false
$strategyBDetails = @()

if (-not $attemptStrategyB) {
    # v0.17.0: default flow. Strategy B-light skipped; operator manual
    # setup via Strategy A is the canonical path. Falls through to Stage 5
    # which generates RESTORE_INSTRUCTIONS.txt + _account_settings.txt and
    # presents an operator-friendly popup.
    Show-Info 'Strategy B-light: skipped (UI opt-in not selected). Strategy A operator manual setup is the v0.17+ default path.'
} elseif ($regExports.Count -gt 0 -and $successCount -gt 0) {
    $strategyBAttempted = $true
    Show-Info ('Strategy B: reg-import path is viable (' + $regExports.Count + ' profile export(s))')

    # Resolve target hive
    $hkcuInfo = Resolve-HkcuRoot
    if ($null -eq $hkcuInfo -or [string]::IsNullOrWhiteSpace($hkcuInfo.PsDrivePath)) {
        $warnings += 'Strategy B: Resolve-HkcuRoot returned null - falling back to Strategy A'
        Show-Warning '  Resolve-HkcuRoot returned null - falling back to Strategy A'
    } else {
        $targetHivePsDrive = $hkcuInfo.PsDrivePath
        $targetHivePrefix  = $hkcuInfo.RegExePath
        if ($hkcuInfo.Redirected) {
            Show-Info "  target hive: $($hkcuInfo.Label) [SID=$($hkcuInfo.SID)]"
        } else {
            Show-Info "  target hive: $($hkcuInfo.Label)"
        }
        Show-Info "  target hive prefix: $targetHivePrefix"

        $outlookVersion = "$($manifest.outlookVersion)"
        if ([string]::IsNullOrWhiteSpace($outlookVersion)) { $outlookVersion = '16.0' }

        # Phase 2.10.3: derive source/target user names for B-light path
        # rewrite. Defaults are safe: if either side is missing the
        # transform's path-rewrite step becomes a no-op (delivery-strip
        # step still runs).
        $blSrcUserName = $null
        if ($manifest.sourceUser -and $manifest.sourceUser.userName) {
            $blSrcUserName = "$($manifest.sourceUser.userName)"
        } elseif ($null -ne $sourceUserProfile) {
            $blSrcUserName = Split-Path -Path $sourceUserProfile -Leaf
        }
        $blDstUserName = Split-Path -Path $targetUserProfilePath -Leaf
        if ([string]::IsNullOrWhiteSpace($blSrcUserName)) { $blSrcUserName = $blDstUserName }
        Show-Info "  [BL-transform] user rewrite: $blSrcUserName -> $blDstUserName"

        # v0.18.2: per-profile B-light tracking. POP-only profiles go
        # through B-light; IMAP-containing profiles skip B-light entirely
        # (gate just below) and fall through to Strategy A for their
        # accounts. The two name arrays let the post-loop logic distinguish
        # "everything auto-restored" from "some auto, some wizard" and
        # "all manual" without losing per-profile granularity.
        $allProfilesVerified = $true
        $bLightVerifiedProfileNames = @()
        $bLightSkippedImapProfileNames = @()
        foreach ($re in $regExports) {
            $profName = "$($re.profileName)"
            $regFile  = "$($re.regFile)"
            $regPath  = Join-Path $sectionDir $regFile

            $perProfile = [ordered]@{
                profileName     = $profName
                regFile         = $regFile
                blTransformed   = $false
                hiveRewrite     = $null
                importSucceeded = $false
                importExitCode  = $null
                importOutput    = $null
                verifyResults   = @()
            }

            if (-not (Test-Path -LiteralPath $regPath)) {
                $msg = "Strategy B: reg file missing for profile '$profName' at $regPath"
                $warnings += $msg
                Show-Warning "  $msg"
                $allProfilesVerified = $false
                $strategyBDetails += $perProfile
                break
            }

            # v0.18.2 GATE: skip B-light entirely for any profile that
            # contains IMAP accounts (any version).
            #
            # History (why we ended up here):
            #   v0.17.0  : kept IMAP accounts in the imported reg -> OST
            #              recreate worked on 15.0->16.0 (lenient migration)
            #              but on 16.0->16.0 the imported state caused
            #              "send/receive can't reach server" until the
            #              operator manually deleted the IMAP account.
            #   v0.18.0  : added T7 (drop IMAP account subkeys) + expanded
            #              T5 (drop their OST service-def subkeys) so that
            #              same-version IMAP-mixed could keep auto-restoring
            #              the POP side. This left dangling MAPIUID refs in
            #              well-known subkeys (MAPI Section Provider
            #              0a0d02..., Service Provider 8503...) which the
            #              same-version strict validator rejects -> Outlook
            #              silently crashed at startup (observed 2026-05-22
            #              16.0 MSI -> 16.0 365 C2R, 1 POP + 1 IMAP).
            #   v0.18.1  : safety gate for same-version IMAP-mixed only.
            #              Cross-version IMAP-mixed still went through T7+T5.
            #   v0.18.2  : decision -- B-light is only safe for POP-only
            #              profiles, full stop. IMAP-containing profiles
            #              fall back to Strategy A (operator wizard) which
            #              leaves the registry untouched and avoids both
            #              traps. T7 and the T5 expansion are reverted
            #              (the gate makes them dead code).
            #
            # `continue` (not `break`) so the remaining profiles in a
            # multi-profile setup can still be B-light if they are
            # POP-only.
            $profileHasImap = @($plannedAccounts | Where-Object {
                $_.ProfileName -eq $profName -and "$($_.Account.type)" -eq 'imap'
            }).Count -gt 0
            if ($profileHasImap) {
                $msg = ("Strategy B: profile '$profName' contains IMAP account(s). " +
                        "Skipping B-light for this profile (POP-only profiles still " +
                        "processed); its accounts fall back to Strategy A operator " +
                        "wizard. Rationale: cleanly auto-restoring IMAP-mixed " +
                        "profiles via reg-import is not possible -- the MAPIUID " +
                        "cross-reference graph in well-known subkeys cannot be " +
                        "safely pruned offline.")
                $warnings += $msg
                Show-Warning "  $msg"
                $bLightSkippedImapProfileNames += $profName
                $perProfile.importSucceeded = $false
                $perProfile.importOutput = 'skipped by safety gate: profile contains IMAP'
                $strategyBDetails += $perProfile
                continue
            }

            # Apply B-light pre-processing. POP-only profiles only reach
            # this point. Five transforms cover: cross-version path rewrite
            # (T1, only when version args differ), POP delivery-binding
            # strip (T2), IMAP Store EID strip (T3, no-op on POP-only),
            # user-path rewrite (T4), OST service-def drop (T5, no-op
            # because POP-only profiles have no OST subkeys), OST internal-
            # binary strip (T6, same-version POP-only, no-op when no OST).
            $blPath = Convert-RegFileToStrategyBLight `
                -SrcRegPath $regPath `
                -SourceUserName $blSrcUserName `
                -TargetUserName $blDstUserName `
                -SourceVersion $srcRegVer `
                -TargetVersion $tgtRegVer
            $perProfile.blTransformed = $true

            $sourcePrefix = Get-RegFileSourceHive -RegPath $blPath
            if ([string]::IsNullOrWhiteSpace($sourcePrefix)) {
                $msg = "Strategy B: could not detect source hive prefix in $regFile - falling back"
                $warnings += $msg
                Show-Warning "  $msg"
                if ($blPath -ne $regPath -and (Test-Path -LiteralPath $blPath)) {
                    Remove-Item -LiteralPath $blPath -Force -ErrorAction SilentlyContinue
                }
                $allProfilesVerified = $false
                $strategyBDetails += $perProfile
                break
            }
            $perProfile.hiveRewrite = if ($sourcePrefix -eq $targetHivePrefix) { 'none' }
                                     else { "$sourcePrefix -> $targetHivePrefix" }
            Show-Info "  [$profName] hive rewrite: $($perProfile.hiveRewrite)"

            $importPath = Convert-RegFileToTargetHive `
                -SrcRegPath $blPath `
                -SourcePrefix $sourcePrefix `
                -TargetPrefix $targetHivePrefix

            $importResult = Invoke-RegImport -RegPath $importPath
            $perProfile.importExitCode = $importResult.ExitCode
            $perProfile.importOutput   = $importResult.Output
            $perProfile.importSucceeded = $importResult.Success

            # Cleanup temp .reg files (both BL-transformed and hive-rewritten)
            foreach ($tmp in @($blPath, $importPath)) {
                if ($tmp -ne $regPath -and (Test-Path -LiteralPath $tmp)) {
                    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                }
            }

            if (-not $importResult.Success) {
                $msg = "Strategy B: reg.exe import failed for '$profName' (exit=$($importResult.ExitCode)): $($importResult.Output)"
                $warnings += $msg
                Show-Warning "  $msg"
                $allProfilesVerified = $false
                $strategyBDetails += $perProfile
                break
            }
            Show-Success "  [$profName] reg import OK"

            # Per-account verify. v0.18.2: only POP accounts reach here
            # (IMAP-containing profiles were gated out above). Track
            # per-profile success so the post-loop summary can distinguish
            # "this profile was auto-restored" from "this profile was
            # skipped due to IMAP" vs "this profile actually failed".
            $profileAccounts = @($plannedAccounts | Where-Object { $_.ProfileName -eq $profName })
            $thisProfileVerified = $true
            foreach ($pa in $profileAccounts) {
                $a = $pa.Account
                $expectedServer = "$($a.pop3.server)"
                $serverValueName = 'POP3 Server'
                $vr = Test-AccountImported `
                    -HiveDrivePath $targetHivePsDrive `
                    -OutlookVersion $outlookVersion `
                    -ProfileName $profName `
                    -SubKey $a.subKey `
                    -ExpectedServer $expectedServer `
                    -ServerValueName $serverValueName
                $perProfile.verifyResults += [ordered]@{
                    subKey    = $a.subKey
                    type      = "$($a.type)"
                    email     = $a.email
                    verified  = $vr.Verified
                    reason    = $vr.Reason
                }
                if ($vr.Verified) {
                    Show-Success "    [verify] $($a.email): OK"
                    # Reflect Strategy B success on the per-account result block
                    $accountResultRef = $resultsByAccount | Where-Object {
                        $_.profile -eq $profName -and $_.accountSubKey -eq $a.subKey
                    } | Select-Object -First 1
                    if ($null -ne $accountResultRef) {
                        $accountResultRef.verifyResult = 'verified'
                    }
                } else {
                    Show-Warning "    [verify] $($a.email): NG - $($vr.Reason)"
                    $warnings += "Strategy B verify failed for $profName/$($a.subKey) ($($a.email)): $($vr.Reason)"
                    $thisProfileVerified = $false
                    $allProfilesVerified = $false
                }
            }

            if ($thisProfileVerified) {
                $bLightVerifiedProfileNames += $profName
            }

            $strategyBDetails += $perProfile
        }

        # v0.18.2 overall verdict:
        #   $strategyBSucceeded is true when at least one profile was
        #   auto-restored AND no attempted profile failed mid-verify.
        #   Profiles skipped at the IMAP gate are NOT failures -- they
        #   are intentional handoffs to Strategy A. Per-profile branching
        #   downstream uses $bLightVerifiedProfileNames /
        #   $bLightSkippedImapProfileNames to keep the operator messaging
        #   accurate for mixed multi-profile setups.
        if ($bLightVerifiedProfileNames.Count -gt 0 -and $allProfilesVerified) {
            $strategyBSucceeded = $true
            if ($bLightSkippedImapProfileNames.Count -gt 0) {
                Show-Success ("Strategy B: $($bLightVerifiedProfileNames.Count) profile(s) " +
                              "auto-restored; $($bLightSkippedImapProfileNames.Count) IMAP-containing " +
                              "profile(s) handed off to Strategy A wizard")
            } else {
                Show-Success 'Strategy B: all profiles imported and verified'
            }
        } elseif ($bLightSkippedImapProfileNames.Count -gt 0 -and
                  $bLightVerifiedProfileNames.Count -eq 0 -and
                  $allProfilesVerified) {
            Show-Warning ('Strategy B: every reg-export profile contains IMAP -- ' +
                          'B-light skipped for all; falling back to Strategy A')
        } else {
            Show-Warning 'Strategy B: at least one profile/account failed - falling back to Strategy A'
        }
    }
}

# ----------------------------------------------------------
# Stage 4.5 (Phase 0.15.0): rule-clear launcher shortcut
#
# Generated before Stage 5 so the popup / instruction text below can
# reference $shortcutResult. Runs regardless of Strategy B success /
# Strategy A fallback because either path can carry over stale PST
# rules; the operator should always have the option to start clean.
#
# Failure here does NOT block the section's return status -- the
# shortcut is a convenience artifact, not a restore prerequisite.
# ----------------------------------------------------------
$shortcutResult = $null
if ($createRuleClearShortcut) {
    if ($targetInstall.Installed -and `
        -not [string]::IsNullOrWhiteSpace($targetInstall.OutlookExePath)) {
        $shortcutResult = New-OutlookRuleClearShortcut `
            -TargetUserProfilePath $targetUserProfilePath `
            -OutlookExePath        $targetInstall.OutlookExePath
        if ($shortcutResult.Success) {
            Show-Success "Rule-clear shortcut written: $($shortcutResult.ShortcutPath)"
        } else {
            $warnings += "Rule-clear shortcut creation skipped: $($shortcutResult.Reason)"
            Show-Warning "Rule-clear shortcut creation skipped: $($shortcutResult.Reason)"
        }
    } else {
        $warnings += "Rule-clear shortcut skipped: OUTLOOK.EXE not detected via HKLM probe"
        Show-Warning "Rule-clear shortcut skipped: OUTLOOK.EXE not detected via HKLM probe"
    }
}

# ----------------------------------------------------------
# Stage 5: operator communication
# ----------------------------------------------------------
$instructionsPath = $null

if ($strategyBSucceeded) {
    # ---- Stage 5a: Strategy B success popup (full or partial in v0.18.2) ----
    # Title differs based on whether all profiles were B-light verified
    # or whether IMAP-containing profiles were intentionally skipped to
    # Strategy A. Body always describes the auto-restored part the same
    # way; the partial case appends a section enumerating the wizard-
    # required profiles.
    $emails = ($resultsByAccount | Where-Object { $_.verifyResult -eq 'verified' } |
               ForEach-Object { $_.email }) -join ', '
    $verifiedPopCount = @($resultsByAccount | Where-Object { $_.verifyResult -eq 'verified' }).Count
    $hasSkippedImapProfiles = $bLightSkippedImapProfileNames.Count -gt 0
    $popupTitle = if ($hasSkippedImapProfiles) {
        'Outlook POP - 一部自動復元 / IMAP profile は wizard 手動'
    } else {
        'Outlook POP - 復元完了 (実験機能)'
    }
    $popupBody  = "*** レジストリ自動再構築 (実験機能) で復元 ***`r`n" +
                  "POP3 $verifiedPopCount 件のアカウントを自動復元しました:`r`n  $emails`r`n`r`n" +
                  "操作者の対応が必要 (Outlook を 2 回起動):`r`n" +
                  "  1. Outlook を起動。'PST のリンクのため再起動が必要' という通知が出て`r`n" +
                  "     Outlook が自動終了します。想定動作なのでそのまま閉じてください。`r`n" +
                  "  2. もう一度 Outlook を起動。各アカウントでパスワードを尋ねられたら入力。`r`n" +
                  "     パスワード入力後に送受信が動作します。`r`n" +
                  "     (DPAPI 制約: パスワードは PC を跨いで移行できません)`r`n`r`n" +
                  "PST ファイルとメール履歴は保持されます。連絡先は起動直後から表示されます。`r`n`r`n" +
                  "アカウント設定 (サーバ / ポート / ユーザ名 / PST パス) は手動再設定が必要な場合に備え`r`n" +
                  "PST ファイルと同じフォルダに _account_settings.txt として保存されています。"
    if ($isCrossVersion) {
        $popupBody += "`r`n`r`n*** 異バージョン復元 ($crossVersionDirection) ***`r`n" +
                      "初回起動時に追加の手動クリーンアップ手順が必要です:`r`n" +
                      "  - 'IMAP 検索フォルダ' 警告ポップアップ -> OK を押す`r`n" +
                      "  - 自動作成された空の Outlook.pst -> 移行した PST を既定に設定し、`r`n" +
                      "    Outlook.pst を削除、POP アカウントの 'フォルダの変更' を実施`r`n" +
                      "  - 初回送受信時に POP / IMAP のパスワードを入力`r`n" +
                      "詳細な手順は _account_settings.txt の '異バージョン復元時のクリーンアップ手順'`r`n" +
                      "セクションを参照してください。"
    }
    # v0.18.2: partial-restore notice for multi-profile mixed setups.
    # Single-profile IMAP-mixed case falls into the else branch (Strategy A
    # fallback) since $strategyBSucceeded would be $false there.
    if ($hasSkippedImapProfiles) {
        $skippedList = $bLightSkippedImapProfileNames -join ', '
        $popupBody += "`r`n`r`n*** IMAP を含むため wizard 手動セットアップが必要なプロファイル ***`r`n" +
                      "$skippedList`r`n`r`n" +
                      "上記のプロファイルは IMAP アカウントを含むため Strategy B-light の対象外です。`r`n" +
                      "コントロールパネル > Mail > プロファイルの表示 で該当プロファイルを選び、`r`n" +
                      "Outlook で  ファイル > アカウント追加 から全アカウントを wizard で手動セットアップ`r`n" +
                      "してください。各 PST フォルダ内の _account_settings.txt にサーバ設定を記載しています。"
    }
    # Phase 0.15.0: rule-clear shortcut callout. Inserted last so it sits
    # visually adjacent to the operator's next action ("launch Outlook").
    if ($null -ne $shortcutResult -and $shortcutResult.Success) {
        $popupBody += "`r`n`r`n*** 重要: Outlook の初回起動 ***`r`n" +
                      "Desktop の [Outlook を初回起動 (仕分けルールをクリア).lnk] から`r`n" +
                      "起動してください。`r`n" +
                      "移行された仕分けルールは移行先 PC で正しく動作しない可能性があるため、`r`n" +
                      "初回起動時にクライアントサイドのルールをクリアします。`r`n" +
                      "必要なルールは Outlook 上で手動で再設定してください。`r`n" +
                      "初回起動後は通常の Outlook アイコンから起動して問題ありません。"
    }
    try {
        Show-CompletionPopup -Title $popupTitle -Body $popupBody -Status 'Success'
    } catch { }
} else {
    # ---- Stage 5b: Strategy A fallback - RESTORE_INSTRUCTIONS.txt ----
    # v0.18.3: file content is account-data only now (procedures moved
    # out of this repo); the filename is preserved for backward
    # compatibility with operator-facing tooling that references it.
    $instructionsPath = Join-Path $sectionDir 'RESTORE_INSTRUCTIONS.txt'
    try {
        $instructionsText = New-OutlookAccountInfoText `
            -Manifest $manifest `
            -TargetUserProfilePath $targetUserProfilePath `
            -PlannedAccounts $plannedAccounts `
            -ResultsByAccount $resultsByAccount
        $instructionsText | Out-File -FilePath $instructionsPath -Encoding UTF8 -Force
        Show-Info "Wrote instruction file: $instructionsPath"
    } catch {
        $warnings += "Failed to write instructions file: $($_.Exception.Message)"
        Show-Error "Failed to write instructions file: $($_.Exception.Message)"
    }

    try {
        # v0.17.0: 2 種類の popup body. AttemptStrategyB=false (= 新デフォルト
        # 動作で意図的に skip) のときは「正常に PST 配置完了、operator 手動
        # セットアップへ」という安心感ある文言。AttemptStrategyB=true (= UI
        # で opt-in したが Strategy B 失敗) のときは従来通り fallback を示唆
        # する文言を維持。
        $popupTitle = if (-not $attemptStrategyB) {
            'Outlook POP/IMAP - PST 配置完了'
        } else {
            'Outlook POP - 手動セットアップが必要'
        }
        $popupBody = if (-not $attemptStrategyB) {
            "PST ファイルは移行先パスに配置済みです。$($plannedAccounts.Count) 件のアカウントを" +
            "Outlook で手動で追加してください。`r`n`r`n" +
            "手順:`r`n" +
            "  1. Outlook を起動 > ファイル > アカウント追加`r`n" +
            "  2. 各メールアドレスを入力 (autodiscover が大半の設定を自動補完)`r`n" +
            "  3. データファイルを求められたら、配置済みの <email>.pst を選択`r`n" +
            "  4. パスワードは初回送受信時に入力`r`n`r`n" +
            "詳細手順書 (アカウントごとのサーバ設定・PST パスを記載):`r`n$instructionsPath`r`n`r`n" +
            "各 PST 配置先のフォルダにも _account_settings.txt が併設されています。"
        } else {
            "$($plannedAccounts.Count) 件の Outlook アカウント (POP / IMAP) で手動セットアップが必要です。`r`n`r`n" +
            "PST ファイルは移行先パスに配置済みです。操作者が一致するメールアドレスでアカウントを" +
            "追加すると、Outlook のウィザードが自動で PST をアタッチします。`r`n`r`n" +
            "手順書を開いて手順に従ってください:`r`n$instructionsPath"
        }
        if ($null -ne $shortcutResult -and $shortcutResult.Success) {
            $popupBody += "`r`n`r`n*** 重要: Outlook の初回起動 ***`r`n" +
                          "アカウント追加が済んだら、Desktop の`r`n" +
                          "[Outlook を初回起動 (仕分けルールをクリア).lnk] から起動してください。`r`n" +
                          "移行された仕分けルールが PST に残っている場合のクリーンアップとして機能します。"
        }
        # v0.17.0: Status は AttemptStrategyB=false (= 正常デフォルト) なら Success、
        # opt-in したが Strategy B 失敗なら Partial。
        $popupStatus = if (-not $attemptStrategyB) { 'Success' } else { 'Partial' }
        Show-CompletionPopup -Title $popupTitle -Body $popupBody -Status $popupStatus
    } catch { }

    # v0.17.0: notepad.exe による RESTORE_INSTRUCTIONS.txt の自動オープンを削除。
    # operator が popup の指示に従って明示的に開く運用に変更。
}

# ----------------------------------------------------------
# Stage 5.5: always-on per-profile account-settings file in target
# Outlook Files folder. Travels with the PST so the operator (or a
# future engineer) can manually reconfigure the account if anything
# goes wrong. Written regardless of Strategy B success / Strategy A
# fallback. Filename: _account_settings.txt (leading underscore sorts
# above the PST file in Explorer alphabetical view).
# ----------------------------------------------------------
$targetSettingsWritten = @()
try {
    $profileDirMap = @{}
    foreach ($r in $resultsByAccount) {
        if ([string]::IsNullOrWhiteSpace($r.targetPstPath)) { continue }
        if ($r.status -ne 'Success') { continue }
        $dir = Split-Path -Path $r.targetPstPath -Parent
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        if (-not $profileDirMap.ContainsKey($r.profile)) {
            $profileDirMap[$r.profile] = $dir
        }
    }
    foreach ($profName in $profileDirMap.Keys) {
        $dir = $profileDirMap[$profName]
        if (-not (Test-Path -LiteralPath $dir)) {
            $warnings += "target dir missing for profile '$profName': $dir - skipping settings file"
            continue
        }
        $settingsPath = Join-Path $dir '_account_settings.txt'
        # v0.18.3: account-data only. The per-profile B-light status that
        # this caller used to compute and pass via $StrategyBSucceeded is
        # no longer rendered in the file body, so it isn't forwarded.
        $settingsText = New-OutlookAccountInfoText `
            -Manifest $manifest `
            -TargetUserProfilePath $targetUserProfilePath `
            -PlannedAccounts $plannedAccounts `
            -ResultsByAccount $resultsByAccount `
            -ProfileFilter $profName
        $settingsText | Out-File -FilePath $settingsPath -Encoding UTF8 -Force
        $targetSettingsWritten += $settingsPath
        Show-Info "Wrote target settings file: $settingsPath"
    }
} catch {
    $warnings += "Failed to write target settings file(s): $($_.Exception.Message)"
    Show-Warning "Failed to write target settings file(s): $($_.Exception.Message)"
}

$sw.Stop()

$status = if ($strategyBSucceeded) {
    'Success'
} elseif ($failCount -gt 0 -and $successCount -eq 0) {
    'Failed'
} elseif ($failCount -gt 0) {
    'Partial'
} else {
    'Success'
}

return [PSCustomObject]@{
    Status               = $status
    ElapsedMs            = [int]$sw.ElapsedMilliseconds
    Summary              = [ordered]@{
        accountTotal           = $plannedAccounts.Count
        accountReady           = $successCount
        accountFail            = $failCount
        strategy               = if ($strategyBSucceeded) { 'B (reg-import)' }
                                 elseif ($strategyBAttempted) { 'A (fallback after B failure)' }
                                 else { 'A (no regExports in manifest)' }
        instructionsFile       = $instructionsPath
        targetSettingsFiles    = @($targetSettingsWritten)
        regProfilesImported    = @($strategyBDetails | Where-Object { $_.importSucceeded }).Count
        sourceOutlookFamily    = if ($sourceInstall) { $sourceInstall.productFamily } else { $null }
        targetOutlookFamily    = $targetInstall.ProductFamily
        targetOutlookType      = $targetInstall.InstallType
        targetOutlookExeVer    = $targetInstall.OutlookExeVersion
        crossVersionTransform  = [bool]$isCrossVersion
        crossVersionDirection  = $crossVersionDirection
        # Phase 0.15.0: rule-clear launcher shortcut. $null when caller
        # opted out (UI checkbox unchecked) or generation failed.
        ruleClearShortcut      = if ($null -ne $shortcutResult -and $shortcutResult.Success) {
                                     $shortcutResult.ShortcutPath
                                 } else { $null }
    }
    Warnings             = $warnings
    ExternalOutputDir    = $null
    ExternalManifestPath = $null
    AccountResults       = @($resultsByAccount)
    StrategyBDetails     = @($strategyBDetails)
}
