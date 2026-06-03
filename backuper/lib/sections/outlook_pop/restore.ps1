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
    #   T2 (Phase 2.10.3 baseline) -- SUPERSEDED by T8 in v0.33.0:
    #     Originally stripped "Delivery Store EntryID" / "Delivery Folder
    #     EntryID" from account subkeys. That strip is what caused the multi-
    #     POP store-collapse (no per-account delivery pointer => Outlook re-
    #     binds all accounts to the default store). REPLACED by T8 (see below
    #     and the main pass): keep both, rewrite the DSE embedded path, keep
    #     the DFE record key verbatim.
    #
    #   T8 (v0.33.0, multi-POP delivery-binding preservation):
    #     For POP account subkeys (\9375CFF0...\NNNNNNNN), do NOT strip the
    #     delivery binding. "Delivery Store EntryID" = 54-byte constant mspst
    #     header + tail UTF-16LE PST path + 00 00 (no length field); rewrite
    #     the source-user path segment to the target user (same pass as
    #     001f6700). "Delivery Folder EntryID" = 00000000 + store PR_RECORD_KEY
    #     (01020ff9) + 82800000; keep VERBATIM (path-free, valid across
    #     import). Byte-proven 2026-05-30 against an operator-fixed target
    #     export AND confirmed live (Outlook PST association correct). Each
    #     POP account stays bound to its own PST. The shared 0a0d02 folder-set
    #     index is intentionally left as-is (its stale source paths are
    #     tolerated by Outlook, confirmed in the working target export + live).
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
        [string]$TargetVersion = $null,
        # v0.33.1: full source/target profile paths for the path rebase. When
        # both are supplied, the path rewrite rebases the FULL source profile
        # prefix -> target profile prefix (matching the Stage 2 PST placement),
        # so it also handles different-drive / redirected / non-\Users\
        # ProfilesDirectory layouts. When absent, falls back to the
        # \Users\<user>\ directory anchor.
        [string]$SourceProfilePath = $null,
        [string]$TargetProfilePath = $null
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

    # v0.33.0/.1: rebase the PST path's profile-DIRECTORY prefix, anchored so
    # the rewrite can NEVER touch the <email>.pst filename, the mspst header,
    # or anything outside the directory prefix. A naive bare-username replace
    # over-matched the username inside the filename (login 'suzuki' + suzuki@...
    # -> the file "suzuki@....pst" became "<target>@....pst", a non-existent
    # file, so that POP account collapsed; confirmed live 2026-05-30,
    # suzuki->test).
    #   Preferred (v0.33.1): rebase the FULL source profile prefix -> target
    #   profile prefix (e.g. C:\Users\y_suzuki\ -> C:\Users\test\), exactly
    #   like the Stage 2 PST file placement. This additionally handles
    #   different-drive, redirected, and non-\Users\ ProfilesDirectory layouts.
    #   Fallback (profile paths absent): the \Users\<user>\ directory anchor.
    # Either way only the directory prefix is rewritten; the filename stays
    # intact and the GOLD byte-match for the standard C:\Users\<user>\ case is
    # preserved byte-for-byte (the full-prefix and \Users\ anchor produce the
    # same output bytes when source/target are both C:\Users\<user>).
    if (-not [string]::IsNullOrWhiteSpace($SourceProfilePath) -and
        -not [string]::IsNullOrWhiteSpace($TargetProfilePath)) {
        $srcRebase = $SourceProfilePath.TrimEnd('\','/') + '\'
        $dstRebase = $TargetProfilePath.TrimEnd('\','/') + '\'
    } else {
        $srcRebase = "\Users\$SourceUserName\"
        $dstRebase = "\Users\$TargetUserName\"
    }
    $srcDirHex = ([System.Text.Encoding]::Unicode.GetBytes($srcRebase) | ForEach-Object { '{0:x2}' -f $_ }) -join ','
    $dstDirHex = ([System.Text.Encoding]::Unicode.GetBytes($dstRebase) | ForEach-Object { '{0:x2}' -f $_ }) -join ','

    # ---- Main pass: T2/T3/T4 inline, T5 section drop (cross-ver only),
    # T6 binary EntryID strip in OST subkey (same-ver POP-only) ----
    $processedLines = New-Object System.Collections.Generic.List[string]
    $currentKey    = $null
    $inAcctSubkey  = $false
    $inOstSubkey   = $false
    $dropSection   = $false
    $rewriteDse    = 0
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
            # v0.33.0 T8: KEEP the per-account delivery binding instead of
            # stripping it (the old T2 dropped both Delivery Store/Folder
            # EntryID, which left every POP account with no delivery pointer
            # so Outlook re-bound them all to the default store = the multi-
            # POP collapse). Byte-proven 2026-05-30 against an operator-fixed
            # target export AND confirmed live (Outlook PST association
            # correct): the only per-account values Outlook writes for a
            # correct binding are these two.
            #   - "Delivery Store EntryID": 54-byte constant mspst header +
            #     tail UTF-16LE PST path + 00 00, no length field. The source-
            #     user segment in that path is rewritten to the target user
            #     below (same dir-anchored \Users\<u>\ pass as 001f6700), so
            #     each POP account stays bound to its OWN PST. The rewritten
            #     EID is byte-identical to the one Outlook itself writes.
            #   - "Delivery Folder EntryID": 00000000 + the store's 16-byte
            #     PR_RECORD_KEY (01020ff9) + 82800000. Path-free and valid
            #     across import (the store subkey is imported verbatim), so it
            #     is KEPT VERBATIM (falls through to $processedLines.Add).
            # IMAP-containing profiles never reach this function (gated at the
            # main flow), so the mspst header always matches here; the IMAP
            # Store EID strip is retained only defensively.
            if ($line -match '^"IMAP Store EID"=') {
                $stripImap++
                continue
            }
        }
        if ($line -match '^"001f6700"=hex:' -or
            $line -match '^"001f0433"=hex:' -or
            $line -match '^"001f6610"=hex:') {
            $before = $line
            $line = $line -replace [regex]::Escape($srcDirHex), $dstDirHex
            if ($before -ne $line) { $rewritePath++ }
        }
        elseif ($inAcctSubkey -and $line -match '^"Delivery Store EntryID"=hex:') {
            # T8 DSE path rewrite (header has no username; the source-user
            # UTF-16LE hex occurs once, inside the tail path region).
            $before = $line
            $line = $line -replace [regex]::Escape($srcDirHex), $dstDirHex
            if ($before -ne $line) { $rewriteDse++ }
        }
        $processedLines.Add($line)
    }

    $t5Label = if ($isCrossVersion) { "T5 OST-drop=$droppedSec" }
               else { 'T5 OST-drop=0 (same-version)' }
    $t6Label = if ($isCrossVersion) { 'T6 OST-bin-strip=0 (skipped: cross-version)' }
               else { "T6 OST-bin-strip=$stripOstBin" }
    Show-Info ("  [BL-transform] T1 version-path=$t1Count  T8 DSE-rewrite=$rewriteDse(DFE kept)  " +
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
        [Parameter(Mandatory = $true)][string]$OutlookExePath,
        # v0.33.4: where to place the .lnk. Prefer the operator handoff folder
        # (02_outlook_アカウント情報) so it sits with the other Outlook restore
        # files; fall back to the target user's Desktop (handoff-OFF legacy path).
        [string]$DestinationDir = $null
    )

    $result = @{ Success = $false; ShortcutPath = $null; Reason = $null }

    if (-not (Test-Path -LiteralPath $OutlookExePath)) {
        $result.Reason = "OUTLOOK.EXE が見つかりません: $OutlookExePath"
        return $result
    }

    $destDir = $null
    if (-not [string]::IsNullOrWhiteSpace($DestinationDir)) {
        if (-not (Test-Path -LiteralPath $DestinationDir)) {
            try { $null = New-Item -ItemType Directory -Path $DestinationDir -Force -ErrorAction Stop } catch {}
        }
        if (Test-Path -LiteralPath $DestinationDir) { $destDir = $DestinationDir }
    }
    if ($null -eq $destDir) {
        $destDir = Join-Path $TargetUserProfilePath 'Desktop'
    }
    if (-not (Test-Path -LiteralPath $destDir)) {
        $result.Reason = "ショートカット配置先フォルダが見つかりません: $destDir"
        return $result
    }

    $shortcutPath = Join-Path $destDir 'Outlook を初回起動 (仕分けルールをクリア).lnk'
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
        [string]$ProfileFilter = $null,
        # v0.35.0: optional recovered plaintext passwords, keyed
        # "<profile>|<subKey>" -> object with .pop3/.imap/.smtp. When a key is
        # present its password is rendered after the matching username line.
        # Empty by default (older backups / password-free outputs unaffected).
        [hashtable]$SecretsByKey = @{}
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

        # v0.35.0: recovered plaintext for this account (or $null).
        $secKey = "$($r.profile)|$($r.accountSubKey)"
        $acctSecrets = if ($SecretsByKey.ContainsKey($secKey)) { $SecretsByKey[$secKey] } else { $null }

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
            if ($acctSecrets -and $acctSecrets.imap) {
                $lines.Add("    パスワード          : $($acctSecrets.imap)") | Out-Null
            }
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
            if ($acctSecrets -and $acctSecrets.pop3) {
                $lines.Add("    パスワード          : $($acctSecrets.pop3)") | Out-Null
            }
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
        if ($acctSecrets -and $acctSecrets.smtp) {
            $lines.Add("    SMTP パスワード     : $($acctSecrets.smtp)") | Out-Null
        }
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

# v0.32.0: AttemptStrategyB now means "generate the auto-restore BATCH into
# the operator handoff folder" (it no longer performs an in-engine reg.exe
# import). The pre-baked import-ready .reg + Restore-Outlook.bat are emitted
# into 02_outlook_アカウント情報\; the operator runs the batch AS THE TARGET
# USER (not admin), so the reg import lands in that user's own HKCU directly
# -- no Resolve-HkcuRoot SID redirection. Mirrors the printer v0.29.0 handoff
# model (Install-Printers.bat) and the credentials 登録.bat run-as-user model.
#
# Default is ON (v0.32.0). The T1-T6 transforms still run at restore time
# (case-by-case POP-only gating, IMAP -> Strategy A), so the heuristic engine
# stays in one place; the batch only imports + verifies. Operators who want
# Strategy-A-only (no batch) opt OUT via the UI checkbox in restore_view.ps1.
$attemptStrategyB = $true
if ($SectionParams.ContainsKey('AttemptStrategyB')) {
    $attemptStrategyB = [bool]$SectionParams['AttemptStrategyB']
}

# v0.25.0: optional OperatorHandoffSubdir. When non-empty:
#   - Stage 5b RESTORE_INSTRUCTIONS.txt is written into the handoff
#     subdir instead of $sectionDir (backup-source folder).
#   - Stage 5.5 per-PST-folder _account_settings.txt loop is REPLACED
#     by a single _account_settings.txt at the handoff subdir
#     (ProfileFilter omitted, so the file contains every account in
#     every profile - acceptable because the realistic case is 1
#     profile and the operator wants one consolidated view anyway).
# Absent / null / empty = legacy behaviour (v0.24.5 compatible).
$operatorHandoffSubdir = if ($SectionParams.ContainsKey('OperatorHandoffSubdir') -and `
    -not [string]::IsNullOrWhiteSpace($SectionParams['OperatorHandoffSubdir'])) {
    "$($SectionParams['OperatorHandoffSubdir'])"
} else {
    $null
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
# v0.35.0: load recovered account passwords (sidecar, optional). Keyed
# "<profile>|<subKey>" so New-OutlookAccountInfoText can render each password
# next to its account in the operator handoff text. Absent for older backups
# or when password recovery was unavailable at backup time.
# ----------------------------------------------------------
$secretsByKey = @{}
$secretsPath = Join-Path $sectionDir '_account_secrets.json'
if (Test-Path -LiteralPath $secretsPath) {
    try {
        $secretsDoc = Get-Content -Path $secretsPath -Raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($sa in @($secretsDoc.accounts)) {
            if ([string]::IsNullOrWhiteSpace($sa.profile) -or [string]::IsNullOrWhiteSpace($sa.subKey)) { continue }
            $secretsByKey["$($sa.profile)|$($sa.subKey)"] = $sa.passwords
        }
        Show-Info "Loaded recovered passwords for $(@($secretsDoc.accounts).Count) account(s) from _account_secrets.json"
    } catch {
        # No exception-message interpolation: a malformed-JSON error could echo a
        # fragment of the sidecar (which holds plaintext passwords) into the
        # persisted restore warnings / _execution_log.txt.
        $warnings += 'Failed to parse _account_secrets.json (malformed JSON; passwords omitted)'
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
# v0.33.3: predicate for "this profile will be auto-restored via the
# Strategy B-light handoff batch (reg import)" vs Strategy A (operator
# manual wizard). Stage 2 uses it to SKIP the single-PST '<email>.pst'
# rename for B-light profiles. Rationale: the reg import's per-account
# Delivery Store EntryID (DSE) binds the account to its PST by the
# dir-rebased ORIGINAL filename (T8 rebases only the directory prefix and
# keeps the filename verbatim). Renaming the on-disk file to '<email>.pst'
# would point that byte-proven DSE at a file that no longer exists (desync).
# Multi-PST B-light profiles already skip the rename for the same reason;
# this extends the same behaviour to single-PST B-light profiles so the
# placed file stays where the (unchanged) DSE points. The final Stage 3
# classification still applies its own checks (transform success / hive
# prefix); this is the early rename-gating subset, all inputs known here.
# Eligible == AttemptStrategyB AND handoff folder present AND the profile
# has a regExport in the manifest AND the profile is POP-only (no IMAP).
# ----------------------------------------------------------
function Test-OutlookProfileAutoEligible {
    param(
        [Parameter(Mandatory = $true)][string]$ProfileName,
        [bool]$AttemptStrategyB,
        [bool]$HandoffPresent,
        [string[]]$RegExportProfileNames = @(),
        $PlannedAccounts = @()
    )
    if (-not $AttemptStrategyB) { return $false }
    if (-not $HandoffPresent)   { return $false }
    if (@($RegExportProfileNames) -notcontains $ProfileName) { return $false }
    $hasImap = @($PlannedAccounts | Where-Object {
        "$($_.ProfileName)" -eq $ProfileName -and "$($_.Account.type)" -eq 'imap'
    }).Count -gt 0
    if ($hasImap) { return $false }
    return $true
}

# Stage-2-time inputs for the eligibility predicate (all known before Stage 2).
$blRegExportNames = @()
if ($manifest.items.PSObject.Properties.Name -contains 'regExports') {
    $blRegExportNames = @($manifest.items.regExports | ForEach-Object { "$($_.profileName)" })
}
$handoffPresent = -not [string]::IsNullOrWhiteSpace($operatorHandoffSubdir)

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

    # Single-PST profile: rename to <email>.pst for Strategy A's
    # path-collision-attach. (従来の path-collision-attach 用リネーム)
    if ($rebasedPath -ine $renamedPath) {
        # v0.33.3: SKIP the rename when this profile will be auto-restored via
        # Strategy B-light (reg import). The imported Delivery Store EntryID
        # binds the account to its PST by the dir-rebased ORIGINAL filename;
        # renaming the file to <email>.pst points that byte-proven DSE at a
        # missing file (desync). Keep the original name so the placed file
        # matches the DSE -- identical to how multi-PST profiles already behave.
        $autoEligible = Test-OutlookProfileAutoEligible `
            -ProfileName           $profileName `
            -AttemptStrategyB      $attemptStrategyB `
            -HandoffPresent        $handoffPresent `
            -RegExportProfileNames $blRegExportNames `
            -PlannedAccounts       $plannedAccounts
        if ($autoEligible) {
            Show-Info "  Strategy B-light profile: keeping PST at original name (DSE binds it): $rebasedPath"
            $accountResult.renameSkipped = $true
            $accountResult.targetPstPath = $rebasedPath
            $accountResult.status        = 'Success'
            $resultsByAccount += $accountResult
            $successCount++
            try { Set-EntryStatus -Id $entryId -Status 'Done' } catch { }
            continue
        }
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
# Stage 3 + 4 (v0.32.0): pre-bake import-ready .reg + emit auto-restore batch
#
# REPLACES the legacy in-engine reg.exe import. For POP-only profiles we
# pre-apply the T1-T6 transforms, rewrite the .reg hive prefix to
# HKEY_CURRENT_USER, and write the import-ready .reg into the handoff
# 02_outlook_アカウント情報\_data\ folder alongside a generated
# Restore-Outlook.bat + Restore-Outlook.ps1. The operator runs the batch
# AS THE MIGRATION TARGET USER (not admin) -> the reg import lands in that
# user's own HKCU directly, so no Resolve-HkcuRoot SID redirection and no
# admin are needed. The reg import + per-account verify now happen inside
# the batch (Restore-Outlook.ps1) on the target PC, not here. IMAP-
# containing profiles are still gated out to Strategy A (manual wizard).
# Mirrors the printer v0.29.0 Install-Printers.bat handoff model.
#
# Viability gate: AttemptStrategyB ON + operator handoff folder present +
# items.regExports[] non-empty. Otherwise only the Strategy A files
# (_account_settings.txt / RESTORE_INSTRUCTIONS.txt) are written.
# ----------------------------------------------------------
$regExports = @()
if ($manifest.items.PSObject.Properties.Name -contains 'regExports') {
    $regExports = @($manifest.items.regExports)
}

$autoProfiles    = @()   # @{ profileName; importReg } for POP-only profiles baked into the batch
$manualProfiles  = @()   # profile names handed to Strategy A (IMAP / missing reg / transform failure)
$strategyBDetails = @()
$batchGenerated  = $false
$handoffDataDir  = $null

if (-not $attemptStrategyB) {
    Show-Info 'Auto-restore batch: disabled (UI opt-out). Strategy A operator manual setup only.'
} elseif ([string]::IsNullOrWhiteSpace($operatorHandoffSubdir)) {
    Show-Warning 'Auto-restore batch: operator handoff folder is OFF; cannot place the batch. Writing Strategy A files only.'
} elseif ($regExports.Count -eq 0) {
    Show-Info 'Auto-restore batch: no regExports in manifest (pre-2.10.x backup). Strategy A only.'
} else {
    Show-Info ("Auto-restore batch: pre-baking import-ready .reg for POP-only profile(s) (" + $regExports.Count + " export(s))")

    # Phase 2.10.3-derived source/target user names for the T4 path rewrite.
    $blSrcUserName = $null
    if ($manifest.sourceUser -and $manifest.sourceUser.userName) {
        $blSrcUserName = "$($manifest.sourceUser.userName)"
    } elseif ($null -ne $sourceUserProfile) {
        $blSrcUserName = Split-Path -Path $sourceUserProfile -Leaf
    }
    $blDstUserName = Split-Path -Path $targetUserProfilePath -Leaf
    if ([string]::IsNullOrWhiteSpace($blSrcUserName)) { $blSrcUserName = $blDstUserName }
    Show-Info "  [BL-transform] user rewrite: $blSrcUserName -> $blDstUserName"

    # Ensure the handoff _data\ folder exists (import-ready .reg land here,
    # next to the generated Restore-Outlook.ps1 - same layout as printer).
    $handoffDataDir = Join-Path $operatorHandoffSubdir '_data'
    try {
        if (-not (Test-Path -LiteralPath $handoffDataDir)) {
            $null = New-Item -ItemType Directory -Path $handoffDataDir -Force -ErrorAction Stop
        }
    } catch {
        $warnings += "Auto-restore: could not create handoff _data dir '$handoffDataDir': $($_.Exception.Message)"
        Show-Warning "  $($warnings[-1])"
        $handoffDataDir = $null
    }

    if ($null -ne $handoffDataDir) {
        foreach ($re in $regExports) {
            $profName = "$($re.profileName)"
            $regFile  = "$($re.regFile)"
            $regPath  = Join-Path $sectionDir $regFile
            $perProfile = [ordered]@{
                profileName   = $profName
                regFile       = $regFile
                blTransformed = $false
                importReg     = $null
                imapSkipped   = $false
                hiveRewrite   = $null
            }

            if (-not (Test-Path -LiteralPath $regPath)) {
                $msg = "Auto-restore: reg file missing for profile '$profName' at $regPath (handed to Strategy A)"
                $warnings += $msg; Show-Warning "  $msg"
                $manualProfiles += $profName
                $strategyBDetails += $perProfile
                continue
            }

            # IMAP gate (unchanged rationale, v0.18.2): B-light is only safe
            # for POP-only profiles. IMAP-containing profiles fall back to
            # Strategy A operator wizard (the MAPIUID cross-reference graph
            # in well-known subkeys cannot be safely pruned offline).
            $profileHasImap = @($plannedAccounts | Where-Object {
                $_.ProfileName -eq $profName -and "$($_.Account.type)" -eq 'imap'
            }).Count -gt 0
            if ($profileHasImap) {
                $msg = "Auto-restore: profile '$profName' contains IMAP account(s); handed to Strategy A (manual wizard)."
                $warnings += $msg; Show-Warning "  $msg"
                $manualProfiles += $profName
                $perProfile.imapSkipped = $true
                $strategyBDetails += $perProfile
                continue
            }

            # T1-T6 transform (single source of the delicate engine; lives
            # here in restore.ps1, NOT duplicated into the batch).
            $blPath = Convert-RegFileToStrategyBLight `
                -SrcRegPath $regPath `
                -SourceUserName $blSrcUserName `
                -TargetUserName $blDstUserName `
                -SourceVersion $srcRegVer `
                -TargetVersion $tgtRegVer `
                -SourceProfilePath $sourceUserProfile `
                -TargetProfilePath $targetUserProfilePath
            $perProfile.blTransformed = $true

            $sourcePrefix = Get-RegFileSourceHive -RegPath $blPath
            if ([string]::IsNullOrWhiteSpace($sourcePrefix)) {
                $msg = "Auto-restore: could not detect source hive prefix in $regFile (handed to Strategy A)"
                $warnings += $msg; Show-Warning "  $msg"
                if ($blPath -ne $regPath -and (Test-Path -LiteralPath $blPath)) {
                    Remove-Item -LiteralPath $blPath -Force -ErrorAction SilentlyContinue
                }
                $manualProfiles += $profName
                $strategyBDetails += $perProfile
                continue
            }

            # Bake the hive prefix to HKEY_CURRENT_USER: the batch runs AS the
            # migration target user, so their own HKCU is the correct target
            # and no SID redirection is required (this is the structural fix
            # for the Resolve-HkcuRoot New-PSDrive scope fragility).
            $importReady = Convert-RegFileToTargetHive `
                -SrcRegPath $blPath `
                -SourcePrefix $sourcePrefix `
                -TargetPrefix 'HKEY_CURRENT_USER'
            $perProfile.hiveRewrite = if ($sourcePrefix -eq 'HKEY_CURRENT_USER') { 'none' }
                                      else { "$sourcePrefix -> HKEY_CURRENT_USER" }

            # Persist the import-ready .reg into the handoff _data\ folder
            # (UTF-16LE, matching reg.exe export encoding).
            $safe          = ($profName -replace '[^\w\-]', '_')
            $importRegName = "profile_$safe.import.reg"
            $importRegDest = Join-Path $handoffDataDir $importRegName
            try {
                $readyText = [System.IO.File]::ReadAllText($importReady, [System.Text.Encoding]::Unicode)
                [System.IO.File]::WriteAllText($importRegDest, $readyText, [System.Text.Encoding]::Unicode)
                $perProfile.importReg = $importRegName
                $autoProfiles += [ordered]@{ profileName = $profName; importReg = $importRegName }
                Show-Success "  [$profName] import-ready .reg -> _data\$importRegName ($($perProfile.hiveRewrite))"
            } catch {
                $msg = "Auto-restore: failed to write import-ready .reg for '$profName': $($_.Exception.Message)"
                $warnings += $msg; Show-Warning "  $msg"
                $manualProfiles += $profName
            }

            # Cleanup temp .reg files (BL-transformed + hive-rewritten).
            foreach ($tmp in @($blPath, $importReady)) {
                if ($tmp -ne $regPath -and (Test-Path -LiteralPath $tmp)) {
                    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                }
            }

            $strategyBDetails += $perProfile
        }

        if ($autoProfiles.Count -gt 0) { $batchGenerated = $true }
    }
}

# ----------------------------------------------------------
# Stage 4 (v0.32.0): emit the auto-restore batch into the handoff folder
#   02_outlook_アカウント情報\
#     Restore-Outlook.bat        operator double-clicks (AS TARGET USER)
#     _data\
#       Restore-Outlook.ps1      reg import + verify (ASCII-only)
#       _restore_config.json     target/source profile + version + auto list
#       manifest.json            copy of the section manifest (account data)
#       profile_<name>.import.reg
# Strategy A files (README.txt / _account_settings.txt / RESTORE_INSTRUCTIONS.txt)
# are written by Stage 5 / Stage 5.5 below regardless.
# ----------------------------------------------------------
if ($batchGenerated -and $null -ne $handoffDataDir) {
    # (a) copy the section manifest into _data\ (the batch reads it for
    #     account/PST data + per-account verify).
    try {
        Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $handoffDataDir 'manifest.json') -Force -ErrorAction Stop
    } catch {
        $warnings += "Auto-restore: failed to copy manifest into _data: $($_.Exception.Message)"
        Show-Warning "  $($warnings[-1])"
    }

    # (b) _restore_config.json: target/source profiles + outlook version +
    #     auto/manual profile lists. The batch keys off this.
    $cfg = [ordered]@{
        schemaVersion         = 1
        sourceUserProfile     = $sourceUserProfile
        targetUserProfile     = $targetUserProfilePath
        outlookVersion        = if (-not [string]::IsNullOrWhiteSpace($tgtRegVer)) { $tgtRegVer } else { '16.0' }
        crossVersion          = [bool]$isCrossVersion
        crossVersionDirection = $crossVersionDirection
        autoProfiles          = @($autoProfiles)
        manualProfiles        = @($manualProfiles)
    }
    try {
        $cfgJson = $cfg | ConvertTo-Json -Depth 8
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText((Join-Path $handoffDataDir '_restore_config.json'), $cfgJson, $utf8Bom)
    } catch {
        $warnings += "Auto-restore: failed to write _restore_config.json: $($_.Exception.Message)"
        Show-Warning "  $($warnings[-1])"
    }

    # (c) Restore-Outlook.ps1 (ASCII-only here-string, written with UTF-8 BOM).
    #     ASCII-only because restore.ps1 may be persisted without a BOM and
    #     PS5.1 would then ANSI-mis-decode any Japanese in this here-string
    #     (CLAUDE.md rule 5). Japanese guidance lives in README.txt
    #     (New-OutlookHandoffReadme, common.ps1) + _account_settings.txt.
    $restorePs1 = @'
# ============================================================
# Fabriq Outlook Restore - Restore-Outlook.ps1
#
# Launched by Restore-Outlook.bat (parent folder). Imports the
# pre-baked Outlook profile registry export(s) into the CURRENT
# user's HKCU, then verifies each POP3 account.
#
# IMPORTANT: run while logged on AS THE MIGRATION TARGET USER.
#   Do NOT run as administrator - the registry import targets the
#   CURRENT user's HKCU, so running as a different (admin) account
#   would write the accounts into the wrong profile.
#
# Does NOT require administrator privileges. IMAP-containing
# profiles are NOT auto-restored (set them up manually via the
# Outlook account wizard; see _account_settings.txt).
# ============================================================

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$baseDir    = $PSScriptRoot                  # _data\
$handoffDir = Split-Path -Parent $baseDir    # 02_outlook_account folder
$reportPath = Join-Path $handoffDir '_RestoreOutlookReport.txt'

$reportLines = New-Object System.Collections.ArrayList
function Write-Line {
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host $Message -ForegroundColor $Color
    [void]$reportLines.Add($Message)
}
function Save-Report {
    try {
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($reportPath, ($reportLines -join "`r`n"), $utf8Bom)
    } catch {}
}

Clear-Host
Write-Line ""
Write-Line "============================================================" Cyan
Write-Line "  Fabriq Outlook Restore" Cyan
Write-Line "============================================================" Cyan
Write-Line ""

# Admin footgun guard: import targets the CURRENT user's HKCU.
try {
    $pr = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    if ($pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Line "  [WARN] This window is running with administrator privileges." Yellow
        Write-Line "         The registry import targets the CURRENT user's HKCU." Yellow
        Write-Line "         If this is NOT the migration target user, the accounts" Yellow
        Write-Line "         will land in the wrong profile." Yellow
        Write-Line ""
        $ans = Read-Host "  Continue anyway? (y/N)"
        if ($ans -notmatch '^[Yy]$') {
            Write-Line "  Aborted by user." Yellow
            Save-Report
            Read-Host "  Press Enter to close"
            exit 1
        }
    }
} catch {}

# Load manifest + config.
$manifestPath = Join-Path $baseDir 'manifest.json'
$configPath   = Join-Path $baseDir '_restore_config.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    Write-Line "  [FATAL] manifest.json not found: $manifestPath" Red
    Save-Report; Read-Host "  Press Enter to close"; exit 1
}
if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Line "  [FATAL] _restore_config.json not found: $configPath" Red
    Save-Report; Read-Host "  Press Enter to close"; exit 1
}
try { $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json }
catch { Write-Line "  [FATAL] manifest parse: $($_.Exception.Message)" Red; Save-Report; Read-Host "  Press Enter to close"; exit 1 }
try { $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json }
catch { Write-Line "  [FATAL] config parse: $($_.Exception.Message)" Red; Save-Report; Read-Host "  Press Enter to close"; exit 1 }

$ver            = if (-not [string]::IsNullOrWhiteSpace($config.outlookVersion)) { "$($config.outlookVersion)" } else { '16.0' }
$autoProfiles   = @($config.autoProfiles)
$manualProfiles = @($config.manualProfiles)

Write-Line "  Source PC      : $($manifest.computerName)  (captured: $($manifest.collectedAt))"
Write-Line "  Auto profiles  : $($autoProfiles.Count)"
Write-Line "  Manual (IMAP)  : $($manualProfiles.Count)"
Write-Line ""

if ($autoProfiles.Count -eq 0) {
    Write-Line "  No POP-only profiles to auto-restore." Yellow
    Write-Line "  Set up your account(s) manually via Outlook (File > Add Account)." Yellow
    Write-Line "  See _account_settings.txt for server / port / PST details." Yellow
    Write-Line ""
    Save-Report; Read-Host "  Press Enter to close"; exit 0
}

# Preflight: close Outlook so reg import is picked up cleanly on next launch.
$ol = @(Get-Process -Name OUTLOOK -ErrorAction SilentlyContinue)
if ($ol.Count -gt 0) {
    Write-Line "  Outlook is running. Closing it before importing..." Yellow
    foreach ($p in $ol) { try { $null = $p.CloseMainWindow() } catch {} }
    Start-Sleep -Seconds 3
    $ol = @(Get-Process -Name OUTLOOK -ErrorAction SilentlyContinue)
    foreach ($p in $ol) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; Write-Line "    force-closed PID $($p.Id)" DarkGray } catch {}
    }
    Start-Sleep -Seconds 1
}

# PST presence advisory (PSTs were placed by the restore run).
$pstWarn = 0
$srcProf = "$($config.sourceUserProfile)"
$dstProf = "$($config.targetUserProfile)"
foreach ($prof in @($manifest.items.profiles)) {
    if (@($autoProfiles | Where-Object { $_.profileName -eq $prof.name }).Count -eq 0) { continue }
    foreach ($acct in @($prof.accounts)) {
        if ("$($acct.type)" -ne 'pop3') { continue }
        if (-not $acct.pst -or [string]::IsNullOrWhiteSpace($acct.pst.sourcePath)) { continue }
        $src = "$($acct.pst.sourcePath)"
        $rebased = $src
        if (-not [string]::IsNullOrWhiteSpace($srcProf) -and $src.Length -ge $srcProf.Length -and `
            $src.Substring(0, $srcProf.Length) -ieq $srcProf) {
            $rebased = ($dstProf.TrimEnd('\','/')) + $src.Substring($srcProf.Length)
        }
        $byEmail = Join-Path (Split-Path -Path $rebased -Parent) ("$($acct.email).pst")
        if (-not (Test-Path -LiteralPath $rebased) -and -not (Test-Path -LiteralPath $byEmail)) {
            Write-Line "  [WARN] PST not found for $($acct.email): $rebased" Yellow
            $pstWarn++
        }
    }
}
if ($pstWarn -gt 0) {
    Write-Line "  $pstWarn PST file(s) not at the expected target path." Yellow
    Write-Line "  Outlook will prompt for the data file on first launch if needed." Yellow
    Write-Line ""
}

# Import + verify, per auto profile.
$importOk = 0; $importFail = 0; $verifyOk = 0; $verifyNg = 0
foreach ($ap in $autoProfiles) {
    $profName = "$($ap.profileName)"
    $regName  = "$($ap.importReg)"
    $regPath  = Join-Path $baseDir $regName
    Write-Line "  ----- Profile: $profName -----" Cyan
    if (-not (Test-Path -LiteralPath $regPath)) {
        Write-Line "    [FAIL] import .reg missing: $regPath" Red; $importFail++; continue
    }
    $tmpOut = [System.IO.Path]::GetTempFileName()
    $tmpErr = [System.IO.Path]::GetTempFileName()
    $ok = $false
    try {
        $proc = Start-Process -FilePath 'reg.exe' -ArgumentList @('import', $regPath) `
            -NoNewWindow -Wait -PassThru -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
        if ($proc.ExitCode -eq 0) { Write-Line "    [OK] registry imported" Green; $importOk++; $ok = $true }
        else {
            $err = if (Test-Path -LiteralPath $tmpErr) { (Get-Content -LiteralPath $tmpErr -Raw) } else { '' }
            Write-Line "    [FAIL] reg import exit=$($proc.ExitCode): $err" Red; $importFail++
        }
    } catch {
        Write-Line "    [FAIL] reg import error: $($_.Exception.Message)" Red; $importFail++
    } finally {
        Remove-Item -LiteralPath $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
    }
    if (-not $ok) { continue }

    $prof = @($manifest.items.profiles | Where-Object { $_.name -eq $profName }) | Select-Object -First 1
    if ($null -ne $prof) {
        foreach ($acct in @($prof.accounts)) {
            if ("$($acct.type)" -ne 'pop3') { continue }
            $key = "HKCU:\Software\Microsoft\Office\$ver\Outlook\Profiles\$profName\9375CFF0413111d3B88A00104B2A6676\$($acct.subKey)"
            $expected = "$($acct.pop3.server)"
            if (-not (Test-Path -LiteralPath $key)) {
                Write-Line "      [verify] $($acct.email): subkey not found" Yellow; $verifyNg++; continue
            }
            try {
                $rk = Get-Item -LiteralPath $key -ErrorAction Stop
                $raw = $rk.GetValue('POP3 Server', $null)
                $got = if ($raw -is [byte[]]) { [System.Text.Encoding]::Unicode.GetString([byte[]]$raw).TrimEnd([char]0) } else { [string]$raw }
                if ($got -eq $expected) { Write-Line "      [verify] $($acct.email): OK" Green; $verifyOk++ }
                else { Write-Line "      [verify] $($acct.email): server mismatch (expected '$expected', got '$got')" Yellow; $verifyNg++ }
            } catch {
                Write-Line "      [verify] $($acct.email): $($_.Exception.Message)" Yellow; $verifyNg++
            }
        }
    }
}
Write-Line ""

if ($manualProfiles.Count -gt 0) {
    Write-Line "  ----- Manual setup required (IMAP) -----" Cyan
    foreach ($mp in $manualProfiles) { Write-Line "    - $mp" Yellow }
    Write-Line "    These profiles contain IMAP accounts and were not auto-restored." Yellow
    Write-Line "    Set them up via Outlook (File > Add Account); see _account_settings.txt." Yellow
    Write-Line ""
}

Write-Line "============================================================" Cyan
Write-Line "  Done.  import OK=$importOk fail=$importFail  /  verify OK=$verifyOk NG=$verifyNg" Cyan
Write-Line "============================================================" Cyan
Write-Line ""
Write-Line "  NEXT: finish setup via Control Panel > Mail (not by just launching Outlook):"
Write-Line "    1. Control Panel > Mail (Microsoft Outlook) > Show Profiles: open it, then close."
Write-Line "       (otherwise Outlook asks which profile to use at every launch)"
Write-Line "    2. E-mail Accounts: for each account choose Change, enter the PASSWORD ONLY, finish."
Write-Line "       (passwords cannot be migrated across PCs / DPAPI)"
Write-Line "    3. Launch Outlook. If migrated rules error on run, reset them in"
Write-Line "       Rules > Manage Rules: uncheck all + Apply, re-check all + Apply, then Run Rules once."
Write-Line "       (or use the 'clear rules' shortcut in this folder to wipe them, if not needed)"
Write-Line "    4. Run Send/Receive and confirm mail arrives."
Write-Line "  Server / port / PST details are in _account_settings.txt."
Write-Line ""
Save-Report
Read-Host "  Press Enter to close"
'@
    $restorePs1Path = Join-Path $handoffDataDir 'Restore-Outlook.ps1'
    try {
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($restorePs1Path, $restorePs1, $utf8Bom)
        Show-Success "Auto-restore: Restore-Outlook.ps1 emitted to _data\"
    } catch {
        $warnings += "Restore-Outlook.ps1 emit failed: $($_.Exception.Message)"
        Show-Warning "  $($warnings[-1])"
    }

    # (d) Restore-Outlook.bat (ASCII, no BOM). Run AS TARGET USER, no UAC.
    #     Passes no path arg (the .ps1 derives root from $PSScriptRoot) to
    #     dodge the %~dp0 trailing-backslash quote-escape trap.
    $restoreBat = @'
@echo off
title Fabriq Outlook Restore
chcp 65001 > nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0_data\Restore-Outlook.ps1" %*
'@
    $restoreBatPath = Join-Path $operatorHandoffSubdir 'Restore-Outlook.bat'
    try {
        $asciiNoBom = New-Object System.Text.ASCIIEncoding
        [System.IO.File]::WriteAllText($restoreBatPath, $restoreBat, $asciiNoBom)
        Show-Success "Auto-restore: Restore-Outlook.bat emitted"
    } catch {
        $warnings += "Restore-Outlook.bat emit failed: $($_.Exception.Message)"
        Show-Warning "  $($warnings[-1])"
    }

    # (e) README.txt - Japanese operator guide, composed in common.ps1
    #     (BOM-tagged) and written with UTF-8 BOM (CLAUDE.md rule 5).
    $outlookReadmePath = Join-Path $operatorHandoffSubdir 'README.txt'
    try {
        $readmeText = New-OutlookHandoffReadme `
            -Manifest $manifest `
            -AutoProfiles @($autoProfiles | ForEach-Object { $_.profileName }) `
            -ManualProfiles @($manualProfiles)
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($outlookReadmePath, $readmeText, $utf8Bom)
        Show-Success "Auto-restore: README.txt emitted"
    } catch {
        $warnings += "Outlook README.txt emit failed: $($_.Exception.Message)"
        Show-Warning "  $($warnings[-1])"
    }
}

# v0.32.0: the legacy in-engine Strategy B import loop (reg.exe import +
# per-account verify against Resolve-HkcuRoot's HKCU/HKU hive) was REMOVED.
# Its work now happens (a) at restore time as the pre-bake above
# (Convert-RegFileToStrategyBLight -> hive rewrite to HKEY_CURRENT_USER ->
# import-ready .reg in the handoff _data\) and (b) on the target PC inside
# the generated Restore-Outlook.ps1 (reg import + POP3 Server verify, run AS
# the target user so no SID redirection is needed). See CHANGELOG v0.32.0.

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
            -OutlookExePath        $targetInstall.OutlookExePath `
            -DestinationDir        $operatorHandoffSubdir
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
# Stage 5: operator communication (v0.32.0: batch-aware)
# ----------------------------------------------------------
# Always write RESTORE_INSTRUCTIONS.txt (Strategy A reference; also the
# fallback for IMAP / manual profiles). The completion popup then differs
# by whether the auto-restore batch was generated (POP-only profiles) or
# not (opt-out / no POP-only profiles / handoff OFF).
$instructionsPath = $null
if ($null -ne $operatorHandoffSubdir) {
    if (-not (Test-Path -LiteralPath $operatorHandoffSubdir)) {
        try {
            $null = New-Item -ItemType Directory -Path $operatorHandoffSubdir -Force -ErrorAction Stop
        } catch {
            $warnings += "Could not create operator handoff subdir '$operatorHandoffSubdir' (falling back to legacy path): $($_.Exception.Message)"
            Show-Warning ("Operator handoff subdir creation failed; falling back to legacy: " + $_.Exception.Message)
        }
    }
    $instructionsPath = if (Test-Path -LiteralPath $operatorHandoffSubdir) {
        Join-Path $operatorHandoffSubdir 'RESTORE_INSTRUCTIONS.txt'
    } else {
        Join-Path $sectionDir 'RESTORE_INSTRUCTIONS.txt'
    }
} else {
    $instructionsPath = Join-Path $sectionDir 'RESTORE_INSTRUCTIONS.txt'
}
try {
    $instructionsText = New-OutlookAccountInfoText `
        -Manifest $manifest `
        -TargetUserProfilePath $targetUserProfilePath `
        -PlannedAccounts $plannedAccounts `
        -ResultsByAccount $resultsByAccount `
        -SecretsByKey $secretsByKey
    $instructionsText | Out-File -FilePath $instructionsPath -Encoding UTF8 -Force
    Show-Info "Wrote instruction file: $instructionsPath"
} catch {
    $warnings += "Failed to write instructions file: $($_.Exception.Message)"
    Show-Error "Failed to write instructions file: $($_.Exception.Message)"
}

try {
    if ($batchGenerated) {
        # ---- Stage 5a (v0.32.0): auto-restore batch placed in handoff ----
        $autoCount   = $autoProfiles.Count
        $manualCount = $manualProfiles.Count
        $popupTitle  = if ($manualCount -gt 0) {
            'Outlook - 自動復元バッチを配置 (一部 IMAP は手動)'
        } else {
            'Outlook - 自動復元バッチを配置しました'
        }
        $popupBody = "POP アカウントの自動復元バッチを操作者用フォルダに配置しました ($autoCount プロファイル)。`r`n`r`n" +
                     "*** 操作手順 ***`r`n" +
                     "  1. 移行先 (新 PC) に【復元対象ユーザ】でログイン (管理者では実行しない)。`r`n" +
                     "  2. 02_outlook_アカウント情報\Restore-Outlook.bat をダブルクリック。`r`n" +
                     "  3. コントロールパネル →「メール」→「プロファイルの表示」を開いて閉じる。`r`n" +
                     "     (これをしないと起動時に毎回プロファイル選択を求められます)`r`n" +
                     "  4. 「電子メール アカウント」→ 各アカウントの「変更」でパスワードのみ入力し完了。`r`n" +
                     "     (DPAPI 制約でパスワードは PC を跨いで移行できません)`r`n" +
                     "  5. Outlook 起動。仕分けルールでエラーが出る場合はルールを全 OFF→適用→`r`n" +
                     "     全 ON→適用→手動で1回実行、でリセット (不要なら「仕分けルールをクリア」`r`n" +
                     "     ショートカットで一括クリアも可)。`r`n" +
                     "  6. 送受信で受信を確認。`r`n`r`n" +
                     "PST ファイル・メール履歴・連絡先は保持されます。`r`n" +
                     "サーバ / ポート / PST パスは同フォルダの _account_settings.txt に記載しています。"
        if ($manualCount -gt 0) {
            $popupBody += "`r`n`r`n*** IMAP を含むため手動セットアップが必要なプロファイル ***`r`n" +
                          ($manualProfiles -join ', ') + "`r`n" +
                          "上記は Restore-Outlook.bat では自動復元されません。Outlook の`r`n" +
                          "[ファイル > アカウント追加] から手動で設定してください。"
        }
        if ($isCrossVersion) {
            $popupBody += "`r`n`r`n*** 異バージョン復元 ($crossVersionDirection) ***`r`n" +
                          "初回起動時に追加の手動クリーンアップが必要な場合があります。`r`n" +
                          "詳細は _account_settings.txt を参照してください。"
        }
        if ($null -ne $shortcutResult -and $shortcutResult.Success) {
            $popupBody += "`r`n`r`n*** Outlook の初回起動 ***`r`n" +
                          "Desktop の [Outlook を初回起動 (仕分けルールをクリア).lnk] から`r`n" +
                          "起動すると、移行された仕分けルールをクリアします (必要時のみ)。"
        }
        # v0.32.0: handoff モデルでは section 自前のモーダルを出さず、リストアを
        # スムーズに流す (printer / credentials / system_evidence と同方針)。案内は
        # 配置済みの README.txt + Restore-Outlook.ps1 実行時 console + 下記 progress
        # log に集約。handoff OFF (Desktop 集約フォルダが無い legacy 経路) のときだけ、
        # 唯一の明確な案内手段として従来通り popup を出す (ここを消すと退行)。
        if ($null -eq $operatorHandoffSubdir) {
            Show-CompletionPopup -Title $popupTitle -Body $popupBody -Status 'Success'
        } else {
            Show-Info ("Outlook: auto-restore batch placed -> $operatorHandoffSubdir " +
                       "(run Restore-Outlook.bat as the target user; see README.txt). " +
                       "auto=$autoCount manual=$manualCount")
            if ($manualCount -gt 0) {
                Show-Warning ("Outlook: $manualCount IMAP profile(s) need manual setup: " +
                              ($manualProfiles -join ', '))
            }
        }
    } else {
        # ---- Stage 5b: no auto-restore batch (opt-out / no POP-only / handoff OFF) ----
        # Strategy A operator manual setup. PST files are already placed.
        $popupTitle = 'Outlook POP/IMAP - PST 配置完了 (手動セットアップ)'
        $settingsCallout = if ($null -ne $operatorHandoffSubdir) {
            "同じフォルダに _account_settings.txt (同内容) も配置されています。"
        } else {
            "各 PST 配置先のフォルダにも _account_settings.txt が併設されています。"
        }
        $popupBody = "PST ファイルは移行先パスに配置済みです。$($plannedAccounts.Count) 件のアカウントを" +
                     "Outlook で手動で追加してください。`r`n`r`n" +
                     "手順:`r`n" +
                     "  1. Outlook を起動 > ファイル > アカウント追加`r`n" +
                     "  2. 各メールアドレスを入力 (autodiscover が大半の設定を自動補完)`r`n" +
                     "  3. データファイルを求められたら、配置済みの <email>.pst を選択`r`n" +
                     "  4. パスワードは初回送受信時に入力`r`n`r`n" +
                     "詳細手順書 (アカウントごとのサーバ設定・PST パスを記載):`r`n$instructionsPath`r`n`r`n" +
                     $settingsCallout
        if ($null -ne $shortcutResult -and $shortcutResult.Success) {
            $popupBody += "`r`n`r`n*** 重要: Outlook の初回起動 ***`r`n" +
                          "アカウント追加が済んだら、Desktop の`r`n" +
                          "[Outlook を初回起動 (仕分けルールをクリア).lnk] から起動してください。"
        }
        # v0.32.0: same policy - popup only on the handoff-OFF legacy path.
        if ($null -eq $operatorHandoffSubdir) {
            Show-CompletionPopup -Title $popupTitle -Body $popupBody -Status 'Success'
        } else {
            Show-Info ("Outlook: PST placed; manual setup required. See " +
                       "$operatorHandoffSubdir\RESTORE_INSTRUCTIONS.txt / _account_settings.txt")
        }
    }
} catch { }

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
    if ($null -ne $operatorHandoffSubdir) {
        # v0.25.0: handoff mode - write a single _account_settings.txt at
        # the handoff subdir. ProfileFilter is intentionally omitted, so
        # the file contains every account in every profile. Realistic
        # environments have 1 Outlook profile, so the resulting file is
        # identical in scope to the legacy per-profile copies. Multi-
        # profile environments (officially unsupported) get a single
        # consolidated view rather than scattered per-PST copies.
        # Subdir was mkdir'd by Stage 5b, but re-check defensively in
        # case Stage 5b path resolution was taken on the legacy branch.
        if (-not (Test-Path -LiteralPath $operatorHandoffSubdir)) {
            try {
                $null = New-Item -ItemType Directory -Path $operatorHandoffSubdir -Force -ErrorAction Stop
            } catch {
                $warnings += "Could not create handoff subdir for _account_settings.txt: $($_.Exception.Message)"
            }
        }
        if (Test-Path -LiteralPath $operatorHandoffSubdir) {
            $settingsPath = Join-Path $operatorHandoffSubdir '_account_settings.txt'
            $settingsText = New-OutlookAccountInfoText `
                -Manifest $manifest `
                -TargetUserProfilePath $targetUserProfilePath `
                -PlannedAccounts $plannedAccounts `
                -ResultsByAccount $resultsByAccount `
                -SecretsByKey $secretsByKey
            $settingsText | Out-File -FilePath $settingsPath -Encoding UTF8 -Force
            $targetSettingsWritten += $settingsPath
            Show-Info "Wrote consolidated settings file: $settingsPath"
        }
    } else {
        # Legacy: per-profile + per-PST-folder copies (v0.24.5 behaviour).
        # The leading underscore sorts the file above the PST in Explorer.
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
    }
} catch {
    $warnings += "Failed to write target settings file(s): $($_.Exception.Message)"
    Show-Warning "Failed to write target settings file(s): $($_.Exception.Message)"
}

$sw.Stop()

# v0.32.0: status no longer reflects an in-engine import (import is deferred
# to the operator-run batch). It reflects PST placement (Stage 2) success.
$status = if ($failCount -gt 0 -and $successCount -eq 0) {
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
        # v0.32.0: 'B (handoff batch)' = a Restore-Outlook.bat was generated for
        # POP-only profiles; otherwise Strategy A (operator manual setup).
        strategy               = if ($batchGenerated) { 'B (handoff batch)' }
                                 elseif (-not $attemptStrategyB) { 'A (operator manual, opt-out)' }
                                 else { 'A (no auto-restorable profiles)' }
        batchGenerated         = [bool]$batchGenerated
        autoProfileCount       = @($autoProfiles).Count
        autoProfiles           = @($autoProfiles | ForEach-Object { $_.profileName })
        manualProfileCount     = @($manualProfiles).Count
        manualProfiles         = @($manualProfiles)
        instructionsFile       = $instructionsPath
        targetSettingsFiles    = @($targetSettingsWritten)
        handoffSubdir          = $operatorHandoffSubdir
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
    ExternalOutputDir    = if ($batchGenerated) { $operatorHandoffSubdir } else { $null }
    ExternalManifestPath = $null
    AccountResults       = @($resultsByAccount)
    StrategyBDetails     = @($strategyBDetails)
}
