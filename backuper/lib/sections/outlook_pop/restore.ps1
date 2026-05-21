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
    # Phase 2.10.3 / extended in Phase 2.12.0 for cross-version + IMAP.
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
    #     Gated on cross-version (Phase 2.12.1 hotfix). The drop creates
    #     dangling MAPIUID references in surviving subkeys (IMAP account
    #     "Service UID", MAPI section provider 0a0d02..., other service
    #     definitions). Outlook 365 importing a 2013 (15.0) reg goes
    #     through a lenient "schema migration" path that tolerates these,
    #     but Outlook 365 importing its own (16.0) reg validates strictly
    #     and fails to open the profile ("cannot open this folder set").
    #
    #     For same-version restore, leave OST service-def subkeys intact;
    #     Outlook's normal IMAP cross-PC behaviour (OST auto-recreate on
    #     first sync) handles the missing file case. T4 path rewrites
    #     keep the subkey content internally consistent with the target
    #     user's directory layout.
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
    # binary path values when same-version). ----
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

    # ---- Main pass: T2/T3/T4 inline, T5 section drop (cross-ver),
    # T6 binary EntryID strip in OST subkey (same-ver) ----
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
            # T5: drop entire section when cross-version
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
               else { 'T5 OST-drop=0 (skipped: same-version)' }
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

function New-OutlookAccountInfoText {
    # Build a human-readable account-info text used by:
    #   (a) Strategy A fallback -> aggregate/sections/outlook_pop/
    #       RESTORE_INSTRUCTIONS.txt (engineer / operator)
    #   (b) Always-on target-folder copy -> <target_user>\Documents\
    #       <localized_outlook_files>\_account_settings.txt (operator
    #       safety net, travels with the PST file)
    #
    # Content: source/target metadata, per-account email + PST file +
    # POP3/SMTP server settings, and a manual setup procedure that an
    # operator can follow if automatic restore ever has to be redone
    # by hand. Body is in Japanese because the file is read by on-site
    # operators (UI policy applies to operator-facing artifacts).
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$TargetUserProfilePath,
        [Parameter(Mandatory = $true)]$PlannedAccounts,
        [Parameter(Mandatory = $true)]$ResultsByAccount,
        [bool]$StrategyBAttempted = $false,
        [bool]$StrategyBSucceeded = $false,
        [string]$ProfileFilter = $null,
        [bool]$IsCrossVersion = $false,
        [string]$CrossVersionDirection = $null,
        [bool]$ImapPresent = $false
    )

    # Optional per-profile filter: when writing the target-folder copy
    # we want only the accounts whose PST sits in that profile's folder.
    $effectiveResults = $ResultsByAccount
    if (-not [string]::IsNullOrWhiteSpace($ProfileFilter)) {
        $effectiveResults = @($ResultsByAccount | Where-Object { $_.profile -eq $ProfileFilter })
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('========================================') | Out-Null
    if ($StrategyBSucceeded) {
        $lines.Add(' Outlook POP アカウント設定 (自動復元済み)') | Out-Null
    } else {
        $lines.Add(' Outlook POP アカウント復元 - 手動セットアップが必要') | Out-Null
    }
    $lines.Add('========================================') | Out-Null
    $lines.Add('') | Out-Null

    if ($StrategyBAttempted -and -not $StrategyBSucceeded) {
        $lines.Add('注意: Strategy B (レジストリ自動インポート) を試行しましたが') | Out-Null
        $lines.Add('完全な検証ができませんでした。手動ウィザードによるセットアップにフォールバックします。') | Out-Null
        $lines.Add('詳細は実行サマリのセクション警告を参照してください。') | Out-Null
        $lines.Add('') | Out-Null
    }
    if ($StrategyBSucceeded) {
        $lines.Add('本ファイルはアカウントと PST のマッピング、および全サーバ設定の参照コピーです。') | Out-Null
        $lines.Add('自動復元は成功しており、Outlook アカウントを最初から手動で再構成する場合に') | Out-Null
        $lines.Add('のみ本設定が必要となります。') | Out-Null
        $lines.Add('') | Out-Null
    }

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
            $lines.Add('  ** 手動セットアップに必要な情報が揃っていません **') | Out-Null
            $lines.Add("  理由: $($r.reason)") | Out-Null
            $lines.Add('') | Out-Null
            continue
        }

        $isImap = ("$($acct.type)" -eq 'imap')

        $lines.Add('') | Out-Null
        $lines.Add('  ウィザード入力項目 (表示名 / メール / サーバ設定):') | Out-Null
        $lines.Add("    表示名            : $($acct.displayName)") | Out-Null
        $lines.Add("    メールアドレス    : $($acct.email)") | Out-Null
        $lines.Add("    アカウント種別    : $(if ($isImap) { 'IMAP' } else { 'POP' })") | Out-Null
        $lines.Add('') | Out-Null

        if ($isImap) {
            $lines.Add('  受信サーバ (IMAP):') | Out-Null
            $lines.Add("    サーバ            : $($acct.imap.server)") | Out-Null
            $lines.Add("    ポート            : $($acct.imap.port)") | Out-Null
            $imapSsl = if ($acct.imap.useSSL -eq 1) { 'はい (必須)' } else { 'いいえ' }
            $lines.Add("    SSL/TLS           : $imapSsl") | Out-Null
            $lines.Add("    ユーザ名          : $($acct.imap.userName)") | Out-Null
            if (-not [string]::IsNullOrWhiteSpace("$($acct.imap.folderPath)")) {
                $lines.Add("    ルートフォルダパス: $($acct.imap.folderPath)") | Out-Null
            }
        } else {
            $lines.Add('  受信サーバ (POP3):') | Out-Null
            $lines.Add("    サーバ            : $($acct.pop3.server)") | Out-Null
            $lines.Add("    ポート            : $($acct.pop3.port)") | Out-Null
            $popSsl = if ($acct.pop3.useSSL -eq 1) { 'はい (必須)' } else { 'いいえ' }
            $lines.Add("    SSL/TLS           : $popSsl") | Out-Null
            $lines.Add("    ユーザ名          : $($acct.pop3.userName)") | Out-Null
        }
        $lines.Add('') | Out-Null

        $lines.Add('  送信サーバ (SMTP):') | Out-Null
        $lines.Add("    サーバ            : $($acct.smtp.server)") | Out-Null
        $lines.Add("    ポート            : $($acct.smtp.port)") | Out-Null
        $smtpSsl = if ($acct.smtp.useSSL -eq 1) { 'はい (必須)' } else { 'いいえ' }
        $lines.Add("    SSL/TLS           : $smtpSsl") | Out-Null
        $smtpAuth = if ($acct.smtp.useAuth -eq 1) { 'はい (必須)' } else { 'いいえ' }
        $lines.Add("    認証              : $smtpAuth") | Out-Null
        $sameAsLabel = if ($isImap) { '(IMAP と同じ)' } else { '(POP3 と同じ)' }
        $smtpUser = if ($acct.smtp.userName) { $acct.smtp.userName } else { $sameAsLabel }
        $lines.Add("    SMTP ユーザ名     : $smtpUser") | Out-Null
        $lines.Add('') | Out-Null

        if ($isImap) {
            $lines.Add('  ローカルデータファイル (OST):') | Out-Null
            $lines.Add('    移行されません。OST はマシン単位の DPAPI で暗号化されており') | Out-Null
            $lines.Add('    PC 間で持ち運べません。初回 IMAP 同期時に Outlook が既定の') | Out-Null
            $lines.Add('    場所に新しい OST を作成し、IMAP サーバから全フォルダを') | Out-Null
            $lines.Add('    再ダウンロードします。') | Out-Null
        } else {
            $lines.Add('  既存データファイル (PST):') | Out-Null
            $lines.Add("    $($r.targetPstPath)") | Out-Null
        }
        $lines.Add('') | Out-Null
    }

    $lines.Add('----------------------------------------') | Out-Null
    $lines.Add(' 手動セットアップ手順 (必要な場合のみ):') | Out-Null
    $lines.Add('----------------------------------------') | Out-Null
    $lines.Add('  1. Outlook を起動') | Out-Null
    $lines.Add('  2. ファイル > アカウント追加') | Out-Null
    $lines.Add('  3. "詳細オプション" を展開し "自分で自分のアカウントを手動で設定"') | Out-Null
    $lines.Add('     にチェックを入れる (POP アカウントの場合は必須。チェックしないと') | Out-Null
    $lines.Add('     Outlook が IMAP に自動判定してしまう。IMAP の場合も明示的な制御の') | Out-Null
    $lines.Add('     ため推奨。)') | Out-Null
    $lines.Add('  4. 上記のメールアドレスを入力し "接続" をクリック') | Out-Null
    $lines.Add('  5. 上のアカウントセクションに記載された "アカウント種別"') | Out-Null
    $lines.Add('     (POP または IMAP) と一致する種別を選択') | Out-Null
    $lines.Add('  6. 上記のサーバ設定をそのまま入力。IMAP の場合は') | Out-Null
    $lines.Add('     ルートフォルダパスも記載があれば設定。') | Out-Null
    $lines.Add('  7. POP のみ: データファイルを尋ねられたら "既存の Outlook データ') | Out-Null
    $lines.Add('     ファイル" を選択し、記載された PST パスを参照。') | Out-Null
    $lines.Add('     IMAP: データファイル選択ステップなし (OST は自動作成)。') | Out-Null
    $lines.Add('  8. ウィザードを完了') | Out-Null
    $lines.Add('  9. 初回送受信時に Outlook がパスワードを尋ねたら入力') | Out-Null
    $lines.Add('     (DPAPI 制約によりパスワードは PC を跨いで配信不能)') | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add(' POP のみ: メールアドレスが PST のファイル名と一致していれば') | Out-Null
    $lines.Add(' (本ツールでは <email>.pst にリネーム済みなので一致するはず)、') | Out-Null
    $lines.Add(' Outlook が既存 PST を自動でアタッチし、過去のメール/フォルダ/') | Out-Null
    $lines.Add(' 連絡先がすべて表示されます。') | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add(' IMAP のみ: Outlook が AppData\Local\Microsoft\Outlook\ 配下に') | Out-Null
    $lines.Add(' 新しい OST を作成し、初回同期時にサーバから全フォルダを') | Out-Null
    $lines.Add(' 再ダウンロードします (大きなメールボックスでは時間がかかります)。') | Out-Null
    $lines.Add('') | Out-Null

    if ($IsCrossVersion) {
        # CrossVersionDirection is an internal enum string (e.g. "2013->2016+",
        # "365->2019") used as-is in the section label for cross-reference
        # against the run log.
        $dirLabel = if ($CrossVersionDirection) { " ($CrossVersionDirection)" } else { '' }
        $lines.Add('========================================') | Out-Null
        $lines.Add(" 異バージョン復元時のクリーンアップ手順$dirLabel") | Out-Null
        $lines.Add('========================================') | Out-Null
        $lines.Add('') | Out-Null
        $lines.Add(' 移行元と移行先の Outlook がメジャーバージョン違いです') | Out-Null
        $lines.Add(' (例: 2013 -> 2016/2019/365)。Outlook の初回起動時に') | Out-Null
        $lines.Add(' 操作者の対応が必要なプロンプトがいくつか表示されます。') | Out-Null
        $lines.Add(' これらは Microsoft の挙動でレジストリでは抑制できません。') | Out-Null
        $lines.Add('') | Out-Null
        $lines.Add(' A. "IMAP 検索フォルダ" の警告ポップアップ (1回限り)') | Out-Null
        $lines.Add('    旧 IMAP 検索フォルダが新 OST に適用できない旨が表示されます。') | Out-Null
        $lines.Add('    OK で閉じれば再表示されません。') | Out-Null
        $lines.Add('') | Out-Null
        $lines.Add(' B. 空の "Outlook.pst" が自動作成される') | Out-Null
        $lines.Add('    異バージョン reg-import ではプロファイルに "既定の配信ストア"') | Out-Null
        $lines.Add('    ポインタが含まれないため、Outlook が空の Outlook.pst を新規作成し') | Out-Null
        $lines.Add('    既定として利用します。移行した PST に再バインドする手順:') | Out-Null
        $lines.Add('      1. ファイル > アカウント設定 > アカウント設定') | Out-Null
        $lines.Add('         > データファイル タブ') | Out-Null
        $lines.Add('      2. 移行した PST') | Out-Null
        $lines.Add('         (Outlook ファイル フォルダ配下の <email>.pst) を選択し') | Out-Null
        $lines.Add('         "既定に設定" をクリック') | Out-Null
        $lines.Add('      3. Outlook を完全に終了し、再起動') | Out-Null
        $lines.Add('      4. 同じデータファイル タブで Outlook.pst を選択し') | Out-Null
        $lines.Add('         "削除" をクリック') | Out-Null
        $lines.Add('      5. メール タブで POP アカウントを選択し') | Out-Null
        $lines.Add('         "フォルダの変更" をクリック、移行した PST の受信トレイを') | Out-Null
        $lines.Add('         選択して OK') | Out-Null
        $lines.Add('') | Out-Null
        $lines.Add(' C. パスワード入力') | Out-Null
        $lines.Add('    初回送受信時に POP / IMAP のパスワードを入力 (DPAPI 制約により') | Out-Null
        $lines.Add('    パスワードは PC を跨いで持ち運べないため、必ず手入力が必要)。') | Out-Null
        $lines.Add('') | Out-Null
        $lines.Add(' 上記手順の完了後は、以降の起動と送受信が通常通り動作します。') | Out-Null
        $lines.Add('') | Out-Null
    }

    # Same-version IMAP-present: POP delivery target sometimes auto-binds
    # to the IMAP OST instead of the migrated PST after Strategy B-light
    # strips Delivery Store EntryID. Cross-version cleanup section already
    # covers the same fix step (under "B. Outlook.pst cleanup"), so this
    # section is suppressed when IsCrossVersion is true to avoid redundancy.
    if ($ImapPresent -and -not $IsCrossVersion) {
        $lines.Add('========================================') | Out-Null
        $lines.Add(' POP の配信先確認 (IMAP 共存プロファイル)') | Out-Null
        $lines.Add('========================================') | Out-Null
        $lines.Add('') | Out-Null
        $lines.Add(' 移行元プロファイルには上記の POP アカウントに加えて') | Out-Null
        $lines.Add(' IMAP アカウントが含まれていました。Strategy B-light が') | Out-Null
        $lines.Add(' 明示的な POP 配信バインド (Delivery Store EntryID) を除去するため、') | Out-Null
        $lines.Add(' 移行先 PC の Outlook はプロファイル内の利用可能なメッセージストアから') | Out-Null
        $lines.Add(' 配信先を自動選択します。移行した PST と再作成された IMAP OST が') | Out-Null
        $lines.Add(' 共存している場合、Outlook が PST ではなく OST を選んでしまい、') | Out-Null
        $lines.Add(' 新着 POP メールが IMAP フォルダに落ちることがあります。') | Out-Null
        $lines.Add('') | Out-Null
        $lines.Add(' 確認と修正手順:') | Out-Null
        $lines.Add('   1. ファイル > アカウント設定 > アカウント設定 > メール タブ') | Out-Null
        $lines.Add('   2. 各 POP アカウントを選択') | Out-Null
        $lines.Add('   3. 下部の "選択したアカウントは新しいメッセージを次の場所に') | Out-Null
        $lines.Add('      配信します:" の表記を確認') | Out-Null
        $lines.Add('   4. 配信先が IMAP OST (またはその他誤った場所) であれば') | Out-Null
        $lines.Add('      "フォルダの変更" をクリックし、移行した PST') | Out-Null
        $lines.Add('      (Outlook ファイル フォルダ配下の <email>.pst) の受信トレイを') | Out-Null
        $lines.Add('      選択して OK') | Out-Null
        $lines.Add('') | Out-Null
        $lines.Add(' これは 1 回限りの修正で、以降の起動でもバインドが維持されます。') | Out-Null
        $lines.Add('') | Out-Null
    }

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

# ----------------------------------------------------------
# Phase 2.12.3 / 2.13.0: detect IMAP presence in source profile.
# Primary path (Phase 2.13.0+ backup): manifest.items.profiles[].accounts[]
# now includes IMAP entries with type='imap', alongside counts.imapAccount.
# Legacy path (pre-2.13.0 backup): IMAP was skipped from enumeration but
# counted in counts.imapAccountSkipped; still consulted for backward
# compatibility so older backups continue to trigger the operator note.
# ----------------------------------------------------------
$imapPresent = $false
$imapEnumerated = @()
foreach ($prof in @($manifest.items.profiles)) {
    foreach ($acct in @($prof.accounts)) {
        if ("$($acct.type)" -eq 'imap') { $imapEnumerated += $acct }
    }
}
if ($imapEnumerated.Count -gt 0) {
    $imapPresent = $true
    Show-Info ("Source profile contains IMAP account(s) enumerated in manifest (count=$($imapEnumerated.Count))")
} elseif ($manifest.counts -and `
          $null -ne $manifest.counts.imapAccountSkipped -and `
          [int]$manifest.counts.imapAccountSkipped -gt 0) {
    $imapPresent = $true
    Show-Info ("Source profile contains IMAP account(s) (legacy schema, skipped count=$($manifest.counts.imapAccountSkipped))")
}

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
        profile       = $profileName
        accountSubKey = $a.subKey
        accountType   = "$($a.type)"
        email         = $a.email
        status        = 'Failed'
        reason        = $null
        targetPstPath = $null
        verifyResult  = $null
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

if ($regExports.Count -gt 0 -and $successCount -gt 0) {
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

        $allProfilesVerified = $true
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

            # Phase 2.10.3 / extended in Phase 2.12.0: apply B-light pre-processing.
            # The 5 transforms inside cover: POP+IMAP binding strip (T2/T3),
            # user-path rewrite (T4), OST service-def drop (T5), and -- only
            # when version args differ -- cross-version path rewrite (T1).
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

            # Per-account verify (Phase 2.13.0: dispatch on account type)
            $profileAccounts = @($plannedAccounts | Where-Object { $_.ProfileName -eq $profName })
            foreach ($pa in $profileAccounts) {
                $a = $pa.Account
                $expectedServer = if ("$($a.type)" -eq 'imap') { "$($a.imap.server)" }
                                  else { "$($a.pop3.server)" }
                $serverValueName = if ("$($a.type)" -eq 'imap') { 'IMAP Server' }
                                   else { 'POP3 Server' }
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
                    $allProfilesVerified = $false
                }
            }

            $strategyBDetails += $perProfile
        }

        if ($allProfilesVerified) {
            $strategyBSucceeded = $true
            Show-Success 'Strategy B: all profiles imported and verified'
        } else {
            Show-Warning 'Strategy B: at least one profile/account failed - falling back to Strategy A'
        }
    }
}

# ----------------------------------------------------------
# Stage 5: operator communication
# ----------------------------------------------------------
$instructionsPath = $null

if ($strategyBSucceeded) {
    # ---- Stage 5a: Strategy B success popup ----
    $emails = ($resultsByAccount | Where-Object { $_.verifyResult -eq 'verified' } |
               ForEach-Object { $_.email }) -join ', '
    $popCount  = @($plannedAccounts | Where-Object { "$($_.Account.type)" -ne 'imap' }).Count
    $imapCount = @($plannedAccounts | Where-Object { "$($_.Account.type)" -eq 'imap' }).Count
    $countLabel = if ($imapCount -gt 0) { "POP=$popCount  IMAP=$imapCount" } else { "POP3 $popCount 件" }
    $popupTitle = 'Outlook POP/IMAP - 復元完了'
    $popupBody  = "$countLabel のアカウントを自動復元しました:`r`n  $emails`r`n`r`n" +
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
    } elseif ($imapPresent) {
        $popupBody += "`r`n`r`n*** 移行元プロファイルに IMAP アカウントが存在 ***`r`n" +
                      "初回起動後、各 POP アカウントの配信先を確認してください:`r`n" +
                      "  ファイル > アカウント設定 > メール タブ > POP アカウントを選択`r`n" +
                      "  -> 下部に '新しいメッセージを次の場所に配信します' と表示`r`n" +
                      "  配信先が移行した PST ではなく IMAP OST を指していた場合、`r`n" +
                      "  'フォルダの変更' をクリックして PST の受信トレイを選択してください。`r`n" +
                      "詳細な手順は _account_settings.txt の 'POP の配信先確認' セクションを`r`n" +
                      "参照してください。"
    }
    try {
        Show-CompletionPopup -Title $popupTitle -Body $popupBody -Status 'Success'
    } catch { }
} else {
    # ---- Stage 5b: Strategy A fallback - RESTORE_INSTRUCTIONS.txt ----
    $instructionsPath = Join-Path $sectionDir 'RESTORE_INSTRUCTIONS.txt'
    try {
        $instructionsText = New-OutlookAccountInfoText `
            -Manifest $manifest `
            -TargetUserProfilePath $targetUserProfilePath `
            -PlannedAccounts $plannedAccounts `
            -ResultsByAccount $resultsByAccount `
            -StrategyBAttempted $strategyBAttempted `
            -StrategyBSucceeded $false `
            -IsCrossVersion $isCrossVersion `
            -CrossVersionDirection $crossVersionDirection `
            -ImapPresent $imapPresent
        $instructionsText | Out-File -FilePath $instructionsPath -Encoding UTF8 -Force
        Show-Info "Wrote instruction file: $instructionsPath"
    } catch {
        $warnings += "Failed to write instructions file: $($_.Exception.Message)"
        Show-Error "Failed to write instructions file: $($_.Exception.Message)"
    }

    try {
        $popupBody = "$($plannedAccounts.Count) 件の Outlook アカウント (POP / IMAP) で手動セットアップが必要です。`r`n`r`n" +
                     "PST ファイルは移行先パスに配置済みです。操作者が一致するメールアドレスでアカウントを" +
                     "追加すると、Outlook のウィザードが自動で PST をアタッチします。`r`n`r`n" +
                     "手順書を開いて手順に従ってください:`r`n$instructionsPath"
        Show-CompletionPopup -Title 'Outlook POP - 手動セットアップが必要' -Body $popupBody -Status 'Partial'
    } catch { }

    try {
        Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$instructionsPath`"" -ErrorAction Stop | Out-Null
    } catch { }
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
        $settingsText = New-OutlookAccountInfoText `
            -Manifest $manifest `
            -TargetUserProfilePath $targetUserProfilePath `
            -PlannedAccounts $plannedAccounts `
            -ResultsByAccount $resultsByAccount `
            -StrategyBAttempted $strategyBAttempted `
            -StrategyBSucceeded $strategyBSucceeded `
            -ProfileFilter $profName `
            -IsCrossVersion $isCrossVersion `
            -CrossVersionDirection $crossVersionDirection `
            -ImapPresent $imapPresent
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
    }
    Warnings             = $warnings
    ExternalOutputDir    = $null
    ExternalManifestPath = $null
    AccountResults       = @($resultsByAccount)
    StrategyBDetails     = @($strategyBDetails)
}
