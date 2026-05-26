# ============================================================
# FabriqBackUper Section: system_evidence / backup (Phase 2)
#
# Captures source-PC configuration evidence so operator can manually
# re-create network / installed apps / Wi-Fi / etc. on the target PC.
# Output format follows fabriq's modules/standard/evidence_config
# (schemaVersion=1, fabriq-evidence-manifest) so external consumers
# stay compatible.
#
# Implements (Phase 2 + Phase 3):
#   - Step 0: lan-prep rollback snapshot harvest -> _OriginalNetworkConfig.{json,txt}
#   - §01: System Basic Info
#   - §06: Network Settings (CSV)
#   - §07: Printers / Ports List (CSV)
#   - §10: PC Serial Number (multi-source)
#   - §11: Installed Software (Desktop via HKLM + HKU\<source-sid>, Store via Get-AppxPackage)
#   - §16: Wi-Fi Profiles (without PSK - key=clear is intentionally NOT used)
#   - §27: Environment Variables (Machine + User scopes, CSV)
#
# SectionParams (hashtable, all optional):
#   SourceUserProfilePath : profile path of the source user. Phase 3
#                           uses this to resolve HKU SID for per-user
#                           uninstall scan.
#   MigrationProfile      : the loaded migration_profile.json object.
#                           If non-null and rollback.snapshotPath
#                           resolves, the snapshot is harvested in
#                           Step 0 to record the pre-lan-prep IP/Gw/DNS
#                           (since §06 captures the temporary lan-prep
#                           IP otherwise).
#
# Implementation notes:
#   - The Out-Log / Start-EvidenceSection / Close-EvidenceSection
#     helpers below are vendored from fabriq's evidence_config 1.7.0
#     so the manifest schema and the per-section split-file pattern
#     are bit-identical to fabriq's output. Per-file Write-Host inside
#     Out-Log is intentional (this is the per-evidence log layer, not
#     the backuper master console) and tracks the upstream pattern;
#     CLAUDE.md rule 2 still applies to the surrounding backuper code
#     which uses Show-Info / Show-Error / Show-Success.
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
# Resolve SectionParams
# ----------------------------------------------------------
# SourceUserProfilePath is used by §11 (per-user HKU\<sid>\Uninstall
# scan) for source-user-side installed-software enumeration. The
# resolution to HKU is done by Resolve-HkcuRoot at scan time.
$sourceUserProfilePath = $null
if ($SectionParams.ContainsKey('SourceUserProfilePath') -and `
    -not [string]::IsNullOrWhiteSpace($SectionParams['SourceUserProfilePath'])) {
    $sourceUserProfilePath = "$($SectionParams['SourceUserProfilePath'])"
}
$migrationProfile = $null
if ($SectionParams.ContainsKey('MigrationProfile')) {
    $migrationProfile = $SectionParams['MigrationProfile']
}

# ----------------------------------------------------------
# Prepare section output directory
# ----------------------------------------------------------
$sectionDir = Join-Path $AggregateBackupDir 'sections\system_evidence'
try {
    $null = New-Item -ItemType Directory -Path $sectionDir -Force -ErrorAction Stop
} catch {
    return [PSCustomObject]@{
        Status               = 'Failed'
        ElapsedMs            = [int]$sw.ElapsedMilliseconds
        Summary              = [ordered]@{}
        Warnings             = @("Failed to create section dir: $($_.Exception.Message)")
        ExternalOutputDir    = $null
        ExternalManifestPath = $null
        InternalSectionDir   = $sectionDir
        InternalManifestPath = $null
    }
}

Show-Info "system_evidence: section dir = $sectionDir"

# Source PC name for log filenames. Uses local hostname since this
# code runs on the source PC; OldPcName from engine is the same value
# under normal flow (session_form picks the current host).
$pcName = $env:COMPUTERNAME
$masterLogFile = Join-Path $sectionDir "_ALL_${pcName}_Log.txt"

# ============================================================
# Vendored helpers from fabriq/modules/standard/evidence_config/
# evidence_config.ps1 (v1.7.0). Schema is shared so the manifest
# stays consumable by fabriq_evidence_manager etc.
# ============================================================

$script:CurrentSplitFile = $null
$script:CurrentSectionId = $null
$script:CurrentSectionTitle = $null
$script:CurrentSectionFiles = @()
$script:CurrentSectionStopwatch = $null
$script:ManifestSections = @()

function Out-Log {
    param([string]$Text, [ConsoleColor]$Color = 'White')
    # Console + master log + per-section split file (3-way fan-out, fabriq 1.7.0 pattern).
    Write-Host $Text -ForegroundColor $Color
    $Text | Out-File -FilePath $masterLogFile -Append -Encoding UTF8
    if (-not [string]::IsNullOrEmpty($script:CurrentSplitFile)) {
        $splitPath = Join-Path $sectionDir $script:CurrentSplitFile
        $Text | Out-File -FilePath $splitPath -Append -Encoding UTF8
    }
}

function Start-EvidenceSection {
    param([string]$Id, [string]$Title, [string]$FileName)
    $script:CurrentSectionId = $Id
    $script:CurrentSectionTitle = $Title
    $script:CurrentSectionFiles = @()
    if (-not [string]::IsNullOrEmpty($FileName)) {
        $script:CurrentSectionFiles += $FileName
        $script:CurrentSplitFile = $FileName
    } else {
        $script:CurrentSplitFile = $null
    }
    $script:CurrentSectionStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Out-Log ""
    Out-Log "========================================" -Color Cyan
    Out-Log "$Title" -Color Cyan
    Out-Log "========================================" -Color Cyan
}

function Add-EvidenceSectionFile {
    param([string]$FileName)
    if ([string]::IsNullOrEmpty($FileName)) { return }
    if ($null -eq $script:CurrentSectionFiles) {
        $script:CurrentSectionFiles = @($FileName)
        return
    }
    if ($script:CurrentSectionFiles -notcontains $FileName) {
        $script:CurrentSectionFiles += $FileName
    }
}

function Close-EvidenceSection {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Success','Skipped','Failed','Partial')]
        [string]$Status,
        [string]$Reason = $null
    )
    if ($null -ne $script:CurrentSectionStopwatch) {
        $script:CurrentSectionStopwatch.Stop()
        $elapsed = [int]$script:CurrentSectionStopwatch.ElapsedMilliseconds
    } else {
        $elapsed = 0
    }
    $files = if ($Status -eq 'Failed') { @() } else { @($script:CurrentSectionFiles) }
    $script:ManifestSections += [PSCustomObject]@{
        id        = $script:CurrentSectionId
        title     = $script:CurrentSectionTitle
        files     = @($files)
        status    = $Status
        reason    = $Reason
        elapsedMs = $elapsed
    }
    $script:CurrentSectionId = $null
    $script:CurrentSectionTitle = $null
    $script:CurrentSectionFiles = @()
    $script:CurrentSectionStopwatch = $null
    $script:CurrentSplitFile = $null
}

# ============================================================
# Master log preamble
# ============================================================
$collectedAt = Get-Date
$now = $collectedAt.ToString("yyyy/MM/dd HH:mm:ss.ff")
Out-Log "==== Evidence Log (system_evidence v0.26.0) ====" -Color Cyan
Out-Log "Date: $now"
Out-Log "Computer: $pcName"
Out-Log "Save Location: $sectionDir"

# ============================================================
# Step 0: lan-prep rollback snapshot harvest
# ============================================================
# When the operator drove the migration through Fabriq_LanPrep.exe,
# the source PC's network config was rewritten to a temporary IP
# (e.g. 192.168.250.10/24) before this backup ran. §06 captures
# that temporary IP, which is not the value the operator needs to
# re-create on the target PC. The lan-prep rollback snapshot,
# written by Prepare-LanMigration.ps1 at $migrationProfile.rollback.
# snapshotPath, holds the pre-rewrite IP/Gateway/DNS and is harvested
# here verbatim.
#
# Absence (USB-only / direct-LAN / no profile) is normal and is
# recorded as a Skipped step, NOT as a section failure.
$snapshotHarvested = $false
$snapshotPath = $null
$originalNetwork = $null
try {
    if ($null -ne $migrationProfile -and `
        $null -ne $migrationProfile.rollback -and `
        -not [string]::IsNullOrWhiteSpace($migrationProfile.rollback.snapshotPath)) {
        $snapshotPath = $migrationProfile.rollback.snapshotPath
        if (Test-Path -LiteralPath $snapshotPath) {
            $snapshotJson = Get-Content -LiteralPath $snapshotPath -Raw -Encoding UTF8
            $snap = $snapshotJson | ConvertFrom-Json

            # Write JSON copy alongside section dir (raw passthrough).
            $jsonOut = Join-Path $sectionDir '_OriginalNetworkConfig.json'
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($jsonOut, $snapshotJson, $utf8NoBom)

            # Human-readable summary. ASCII-only by design - this backup.ps1
            # file is produced via Write tool which emits UTF-8 without BOM,
            # so PS5.1 would decode literal non-ASCII bytes as CP932 and
            # mojibake the output (CLAUDE.md project rule 5). Operator-facing
            # Japanese commentary is generated in restore.ps1 (Phase 4)
            # where the source file is BOM-tagged.
            $txtLines = @(
                "============================================================",
                "Source PC Original Network Configuration (pre-lan-prep)",
                "============================================================",
                "",
                "  Captured At     : $($snap.capturedAt)",
                "  Role            : $($snap.role)",
                "  Interface Alias : $($snap.interfaceAlias)",
                "  DHCP Enabled    : $($snap.dhcpEnabled)",
                ""
            )
            if ($snap.ipAddresses -and $snap.ipAddresses.Count -gt 0) {
                $txtLines += "  Static IPv4 Addresses:"
                foreach ($a in $snap.ipAddresses) {
                    $txtLines += ("    {0} / {1}" -f $a.address, $a.prefixLength)
                }
            } else {
                $txtLines += "  Static IPv4 Addresses: (none -> DHCP)"
            }
            $txtLines += ""
            $gw = if ([string]::IsNullOrWhiteSpace($snap.defaultGateway)) { '(none)' } else { $snap.defaultGateway }
            $txtLines += "  Default Gateway : $gw"
            $dns = if ($snap.dnsServers -and $snap.dnsServers.Count -gt 0) { $snap.dnsServers -join ', ' } else { '(none)' }
            $txtLines += "  DNS Servers     : $dns"
            $nc = if ([string]::IsNullOrWhiteSpace($snap.networkCategory)) { '(unknown)' } else { $snap.networkCategory }
            $txtLines += "  NetworkCategory : $nc"
            $txtLines += ""
            $txtLines += "Source: $snapshotPath"
            $txtLines += "============================================================"
            $txtLines += ""
            $txtLines += "NOTE: This is the operator-visible network configuration as of the"
            $txtLines += "      lan-prep snapshot capture, BEFORE the temporary migration IP"
            $txtLines += "      was applied. Use these values when re-creating network"
            $txtLines += "      settings on the target PC. The CURRENT (temporary) values are"
            $txtLines += "      recorded separately in 06_NetworkConfig.csv."

            $txtOut = Join-Path $sectionDir '_OriginalNetworkConfig.txt'
            $utf8Bom = New-Object System.Text.UTF8Encoding($true)
            [System.IO.File]::WriteAllText($txtOut, ($txtLines -join "`r`n"), $utf8Bom)

            $originalNetwork = $snap
            $snapshotHarvested = $true
            Show-Success "system_evidence: lan-prep snapshot harvested from $snapshotPath"
            Out-Log "Original network config harvested: $snapshotPath" -Color Green
        } else {
            Show-Info "system_evidence: snapshotPath specified in profile but file not present ($snapshotPath); skipping snapshot harvest"
            Out-Log "snapshotPath specified but file not present: $snapshotPath" -Color DarkYellow
        }
    } else {
        Show-Info "system_evidence: no MigrationProfile / rollback.snapshotPath; skipping snapshot harvest"
        Out-Log "No migration profile snapshot harvest (this is normal for USB-only backups)"
    }
}
catch {
    $warnings += "Step 0 (snapshot harvest) error: $($_.Exception.Message)"
    Show-Warning "system_evidence: snapshot harvest error: $($_.Exception.Message)"
    Out-Log "[WARN] snapshot harvest error: $($_.Exception.Message)" -Color Yellow
}

# ============================================================
# §01 System Basic Info  (vendored from fabriq evidence_config 1.7.0)
# ============================================================
Start-EvidenceSection -Id "01" -Title "System Basic Info" -FileName "01_SystemInfo.txt"
$secStatus = 'Success'
$secReason = $null
try {
    Out-Log "Hostname:       $env:COMPUTERNAME"

    $os = Get-CimInstance Win32_OperatingSystem
    Out-Log "OS Name:        $($os.Caption)"
    Out-Log "Version:        $($os.Version) (Build: $($os.BuildNumber))"

    $cpu = Get-CimInstance Win32_Processor
    Out-Log "CPU:            $($cpu.Name)"

    $mem = Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum
    $memGB = [Math]::Round($mem.Sum / 1GB, 1)
    Out-Log "Memory:         $memGB GB"

    $tz = Get-TimeZone
    Out-Log "TimeZone:       $($tz.Id) (UTC$( if ($tz.BaseUtcOffset.TotalHours -ge 0) {'+'} )$($tz.BaseUtcOffset.TotalHours))"

    $culture = Get-Culture
    Out-Log "Locale:         $($culture.Name) ($($culture.DisplayName))"
}
catch {
    Out-Log "[ERROR] Failed to get basic info: $_" -Color Red
    $secStatus = 'Failed'
    $secReason = "$($_.Exception.Message)"
}
Close-EvidenceSection -Status $secStatus -Reason $secReason

# ============================================================
# §06 Network Settings (CSV)
# ============================================================
# Captures the CURRENT IP/DNS state, which under lan-prep is the
# temporary migration IP. Compare with _OriginalNetworkConfig.json
# (Step 0 above) for the pre-lan-prep values.
Start-EvidenceSection -Id "06" -Title "Network Settings (CSV)" -FileName $null
$secStatus = 'Success'
$secReason = $null
try {
    $netConfigs = Get-NetIPConfiguration | Where-Object { $_.IPv4Address -ne $null }
    $networkRows = @()

    foreach ($nc in $netConfigs) {
        # Filter out APIPA / link-local addresses (169.254.x.x)
        $validIPs = @($nc.IPv4Address.IPAddress | Where-Object { $_ -notmatch '^169\.254\.' })
        if ($validIPs.Count -eq 0) { continue }

        # Subnet Mask: PrefixLength -> dotted-decimal conversion
        $subnet = ""
        $ipEntry = Get-NetIPAddress -InterfaceIndex $nc.InterfaceIndex `
                   -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                   Where-Object { $_.PrefixOrigin -ne "WellKnown" -and $_.IPAddress -notmatch '^169\.254\.' } |
                   Select-Object -First 1
        if ($ipEntry) {
            $prefixLen = $ipEntry.PrefixLength
            $maskInt = if ($prefixLen -gt 0) {
                [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $prefixLen))
            } else { [uint32]0 }
            $subnet = "{0}.{1}.{2}.{3}" -f `
                (($maskInt -shr 24) -band 0xFF),
                (($maskInt -shr 16) -band 0xFF),
                (($maskInt -shr 8) -band 0xFF),
                ($maskInt -band 0xFF)
        }

        $networkRows += [PSCustomObject]@{
            Interface      = $nc.InterfaceAlias
            IPv4Address    = ($validIPs -join ', ')
            SubnetMask     = $subnet
            DefaultGateway = $nc.IPv4DefaultGateway.NextHop
            DNSServers     = ($nc.DNSServer.ServerAddresses -join ', ')
        }
    }

    $outNetwork = Join-Path $sectionDir "06_NetworkConfig.csv"
    $networkRows | Export-Csv -Path $outNetwork -NoTypeInformation -Encoding UTF8
    Add-EvidenceSectionFile "06_NetworkConfig.csv"

    Out-Log "Network interfaces: $($networkRows.Count) entries -> 06_NetworkConfig.csv"
    if ($snapshotHarvested) {
        Out-Log "(Note: these values may reflect the temporary lan-prep IP. See _OriginalNetworkConfig.txt for the pre-lan-prep values.)"
    }
}
catch {
    Out-Log "[ERROR] Failed to get network settings: $_" -Color Red
    $secStatus = 'Failed'
    $secReason = "$($_.Exception.Message)"
}
Close-EvidenceSection -Status $secStatus -Reason $secReason

# ============================================================
# §07 Printers / Ports List (CSV)
# ============================================================
Start-EvidenceSection -Id "07" -Title "Printers / Ports List (CSV)" -FileName $null
$secStatus = 'Success'
$secReason = $null
try {
    $printers = Get-Printer -ErrorAction SilentlyContinue
    if ($printers) {
        $printerRows = $printers | Select-Object Name, DriverName, PortName, Shared, PrinterStatus |
            Sort-Object Name

        $outPrinters = Join-Path $sectionDir "07_Printers.csv"
        $printerRows | Export-Csv -Path $outPrinters -NoTypeInformation -Encoding UTF8
        Add-EvidenceSectionFile "07_Printers.csv"

        Out-Log "Printers: $(@($printerRows).Count) entries -> 07_Printers.csv"
    } else {
        Out-Log "(No printers installed)"
        $secStatus = 'Skipped'
        $secReason = 'No printers installed'
    }
}
catch {
    Out-Log "[ERROR] Failed to get printer info: $_" -Color Red
    $secStatus = 'Failed'
    $secReason = "$($_.Exception.Message)"
}
Close-EvidenceSection -Status $secStatus -Reason $secReason

# ============================================================
# §10 PC Serial Number (multi-source)
# ============================================================
# Query every reasonable SMBIOS / registry source independently,
# then pick a canonical value by priority. Every source is
# recorded (even rejected) so post-facto audit can determine
# which field held the SN on the device. See fabriq evidence_config
# 1.7.0 for the motivation (mixed OEM SMBIOS Type 0 / Type 1 fields).
Start-EvidenceSection -Id "10" -Title "PC Serial Number" -FileName "10_SerialNumber.txt"
$secStatus = 'Success'
$secReason = $null

function Test-SerialValid {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return @{ Valid = $false; Reason = 'empty' } }
    $trimmed = $Value.Trim()
    $invalidExact = @(
        'None','N/A','INVALID',
        'To be filled by O.E.M.',
        'Default string',
        'System Serial Number','Chassis Serial Number',
        'Not Applicable','Not Specified','OEM'
    )
    foreach ($bad in $invalidExact) {
        if ($trimmed -ieq $bad) { return @{ Valid = $false; Reason = "`"$bad`"" } }
    }
    if ($trimmed -match '^0+$')        { return @{ Valid = $false; Reason = 'all-zero' } }
    if ($trimmed -match '^[\.\-\s]+$') { return @{ Valid = $false; Reason = 'dummy-chars-only' } }
    return @{ Valid = $true; Reason = $null }
}

function New-SerialSourceRow {
    param(
        [string]$Label,
        [bool]$IsCanonicalCandidate,
        [scriptblock]$Getter
    )
    $row = [PSCustomObject]@{
        Label                = $Label
        Value                = ''
        Tag                  = ''
        Valid                = $false
        IsCanonicalCandidate = $IsCanonicalCandidate
    }
    try {
        $raw  = & $Getter
        $text = if ($null -eq $raw) { '' } else { [string]$raw }
        $row.Value = $text
        $check     = Test-SerialValid -Value $text
        $row.Valid = $check.Valid
        $row.Tag   = if ($check.Valid) { 'VALID' } else { "INVALID: $($check.Reason)" }
    }
    catch {
        $reason = ($_.Exception.Message -replace '\s+', ' ').Trim()
        if ($reason.Length -gt 80) { $reason = $reason.Substring(0, 80) + '...' }
        $row.Tag = "QUERY FAILED: $reason"
    }
    return $row
}

try {
    $sources = @()
    $sources += New-SerialSourceRow -Label 'Win32_BIOS.SerialNumber' -IsCanonicalCandidate $true -Getter {
        (Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SerialNumber
    }
    $sources += New-SerialSourceRow -Label 'Win32_ComputerSystemProduct.IdentifyingNumber' -IsCanonicalCandidate $true -Getter {
        (Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop).IdentifyingNumber
    }
    $sources += New-SerialSourceRow -Label 'Win32_SystemEnclosure.SerialNumber' -IsCanonicalCandidate $true -Getter {
        $enc = Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction Stop
        if ($enc -is [array]) {
            ($enc | ForEach-Object { $_.SerialNumber } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -First 1)
        } else {
            $enc.SerialNumber
        }
    }
    $sources += New-SerialSourceRow -Label 'Win32_BaseBoard.SerialNumber' -IsCanonicalCandidate $false -Getter {
        (Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction Stop).SerialNumber
    }
    $sources += New-SerialSourceRow -Label 'Registry SystemSerialNumber' -IsCanonicalCandidate $true -Getter {
        $regPath = 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS'
        (Get-ItemProperty -Path $regPath -Name SystemSerialNumber -ErrorAction Stop).SystemSerialNumber
    }

    # Reference ID (UUID) - record-only, not a serial.
    $uuidRow = [PSCustomObject]@{ Label = 'Win32_ComputerSystemProduct.UUID'; Value = ''; Tag = '' }
    try {
        $uuidVal       = (Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop).UUID
        $uuidRow.Value = if ($null -eq $uuidVal) { '' } else { [string]$uuidVal }
        $uuidRow.Tag   = if ([string]::IsNullOrWhiteSpace($uuidRow.Value)) { 'EMPTY' } else { 'CAPTURED' }
    }
    catch {
        $reason = ($_.Exception.Message -replace '\s+', ' ').Trim()
        if ($reason.Length -gt 80) { $reason = $reason.Substring(0, 80) + '...' }
        $uuidRow.Tag = "QUERY FAILED: $reason"
    }

    # Pick canonical by priority order.
    $canonical       = $null
    $canonicalSource = $null
    foreach ($s in $sources) {
        if ($s.IsCanonicalCandidate -and $s.Valid) {
            $canonical       = $s.Value.Trim()
            $canonicalSource = $s.Label
            break
        }
    }

    Out-Log "---- Canonical Serial Number ----"
    if ($null -eq $canonical) {
        Out-Log "(Unretrievable)" -Color Red
        Out-Log "(Source: none - all canonical candidates were invalid or failed)"
    } else {
        Out-Log $canonical
        Out-Log "(Source: $canonicalSource)"
    }
    Out-Log ""

    $allLabels  = @($sources | ForEach-Object { $_.Label }) + @($uuidRow.Label)
    $labelWidth = ($allLabels | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    $allValues  = @($sources | ForEach-Object { if ([string]::IsNullOrEmpty($_.Value)) { '(empty)' } else { $_.Value.Trim() } }) +
                  @( if ([string]::IsNullOrEmpty($uuidRow.Value)) { '(empty)' } else { $uuidRow.Value.Trim() } )
    $valueWidth = [Math]::Max(20, (($allValues | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum))

    Out-Log "---- All Sources ----"
    foreach ($s in $sources) {
        $displayValue = if ([string]::IsNullOrEmpty($s.Value)) { '(empty)' } else { $s.Value.Trim() }
        $tag = $s.Tag
        if ($s.Valid) {
            if ($null -ne $canonical -and $displayValue -eq $canonical) {
                $tag = 'VALID, MATCH'
            } elseif ($s.IsCanonicalCandidate) {
                $tag = 'VALID, DIFFERENT'
            } else {
                $tag = 'VALID, DIFFERENT (record-only)'
            }
        }
        $line = $s.Label.PadRight($labelWidth) + "  : " + $displayValue.PadRight($valueWidth) + "  [$tag]"
        Out-Log $line
    }
    Out-Log ""

    Out-Log "---- Reference ID ----"
    $refDisplay = if ([string]::IsNullOrEmpty($uuidRow.Value)) { '(empty)' } else { $uuidRow.Value.Trim() }
    $refLine    = $uuidRow.Label.PadRight($labelWidth) + "  : " + $refDisplay.PadRight($valueWidth) + "  [$($uuidRow.Tag)]"
    Out-Log $refLine
    Out-Log ""

    Out-Log "---- Selection Policy ----"
    Out-Log "Priority: Win32_BIOS.SerialNumber -> Win32_ComputerSystemProduct.IdentifyingNumber"
    Out-Log "       -> Win32_SystemEnclosure.SerialNumber -> Registry SystemSerialNumber"
    Out-Log "Win32_BaseBoard.SerialNumber is record-only (motherboard SN, not PC SN)."
    Out-Log "Win32_ComputerSystemProduct.UUID is reference ID only (not a serial number)."
    Out-Log 'Rejected values: empty / "Default string" / "To be filled by O.E.M." /'
    Out-Log '                 "None" / "N/A" / "INVALID" / "System Serial Number" /'
    Out-Log '                 "Chassis Serial Number" / "Not Applicable" / "Not Specified" /'
    Out-Log '                 "OEM" / all-zero / dots-hyphens-whitespace-only'

    if ($null -eq $canonical) {
        $secStatus = 'Failed'
        $secReason = 'No valid serial number source found (all canonical candidates rejected)'
    }
}
catch {
    Out-Log "[ERROR] Failed to collect serial number sources: $_" -Color Red
    $secStatus = 'Failed'
    $secReason = "$($_.Exception.Message)"
}
Close-EvidenceSection -Status $secStatus -Reason $secReason

# ============================================================
# §11 Installed Software (Desktop + Store)
# ============================================================
# Desktop apps come from 4 registry roots:
#   - HKLM\SOFTWARE\...\Uninstall                (machine-wide x64)
#   - HKLM\SOFTWARE\WOW6432Node\...\Uninstall    (machine-wide x86 on x64 OS)
#   - HKU:\<source-sid>\SOFTWARE\...\Uninstall   (source-user per-user install)
#   - HKU:\<source-sid>\SOFTWARE\WOW6432Node\... (source-user x86 per-user)
# The HKU paths catch installs that target users do "Just me" rather than
# "All users". Without the HKU sweep, under cross-user admin elevation the
# admin's HKCU is captured instead (wrong user). Resolve-HkcuRoot picks
# either HKCU: (= current user) or HKU:\<SID> based on logged-on user
# context.
#
# Store apps use Get-AppxPackage. Under cross-user admin elevation this
# enumerates the admin's Appx packages, NOT the source user's. This is the
# operator-accepted "manager-recommended apps" compromise; per-user
# enumeration via Get-AppxPackage -User <name> needs ApplicationPackages
# Discovery service + more permissions and is intentionally not attempted.
Start-EvidenceSection -Id "11" -Title "Installed Software List (CSV)" -FileName $null
$secStatus = 'Success'
$secReason = $null
try {
    # 11a. Desktop Apps (registry)
    $desktopPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $hkcuInfo = $null
    try {
        $hkcuInfo = Resolve-HkcuRoot
    } catch {
        Out-Log "  [WARN] Resolve-HkcuRoot failed; per-user uninstall paths skipped: $($_.Exception.Message)" -Color Yellow
    }
    $perUserScanLabel = '(none)'
    if ($null -ne $hkcuInfo -and -not [string]::IsNullOrWhiteSpace($hkcuInfo.PsDrivePath)) {
        $desktopPaths += "$($hkcuInfo.PsDrivePath)\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
        $desktopPaths += "$($hkcuInfo.PsDrivePath)\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        $perUserScanLabel = $hkcuInfo.Label
    }
    Out-Log "  Per-user scan target: $perUserScanLabel"
    if (-not [string]::IsNullOrWhiteSpace($sourceUserProfilePath)) {
        Out-Log "  SourceUserProfilePath (informational): $sourceUserProfilePath"
    }

    $desktop = Get-ItemProperty $desktopPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName } |
        Select-Object @{N='Name';E={$_.DisplayName}},
                      @{N='Version';E={$_.DisplayVersion}},
                      Publisher,
                      InstallDate,
                      @{N='Scope';E={
                          $p = $_.PSPath
                          if     ($p -match 'HKEY_LOCAL_MACHINE\\SOFTWARE\\WOW6432Node') { 'Machine (x86)' }
                          elseif ($p -match 'HKEY_LOCAL_MACHINE')                       { 'Machine (x64)' }
                          elseif ($p -match 'HKEY_USERS\\.*\\SOFTWARE\\WOW6432Node')    { 'User (x86)' }
                          elseif ($p -match 'HKEY_USERS')                               { 'User (x64)' }
                          else                                                          { 'Unknown' }
                      }} |
        Sort-Object Name

    $outDesktop = Join-Path $sectionDir "11_DesktopApps.csv"
    $desktop | Export-Csv -Path $outDesktop -NoTypeInformation -Encoding UTF8
    Add-EvidenceSectionFile "11_DesktopApps.csv"

    Out-Log "Desktop apps: $(@($desktop).Count) items -> 11_DesktopApps.csv"

    # 11b. Store / UWP Apps (current admin's view)
    $store = Get-AppxPackage |
        Select-Object @{N='Name';E={$_.Name}},
                      @{N='Version';E={$_.Version}},
                      @{N='Publisher';E={$_.PublisherId}} |
        Sort-Object Name

    $outStore = Join-Path $sectionDir "11_StoreApps.csv"
    $store | Export-Csv -Path $outStore -NoTypeInformation -Encoding UTF8
    Add-EvidenceSectionFile "11_StoreApps.csv"

    Out-Log "Store apps: $(@($store).Count) items -> 11_StoreApps.csv"
    Out-Log "  (Store apps reflect the current admin context, not necessarily the source user.)"
}
catch {
    Out-Log "[ERROR] Failed to get software list: $_" -Color Red
    $secStatus = 'Failed'
    $secReason = "$($_.Exception.Message)"
}
Close-EvidenceSection -Status $secStatus -Reason $secReason

# ============================================================
# §16 Wi-Fi Profiles  (without PSK)
# ============================================================
# Strategy:
#   1. netsh wlan show profiles                 -> profile names
#   2. netsh wlan show profile name="<name>"    -> per-profile details
#                                                  (NO key=clear -> PSK NOT shown)
#
# Encoding note: netsh emits OEM/CP932 bytes on Japanese Windows. Setting
# [Console]::OutputEncoding to UTF-8 and prefixing the cmd line with
# `chcp 65001 >nul` (same trick fabriq evidence_config 1.7.0 uses) coaxes
# netsh into emitting UTF-8 so the captured strings round-trip cleanly.
#
# We only capture metadata that's safe to publish: SSID name,
# Authentication, Cipher, Connection mode, Connection type, Network type.
# Key Content / Security key are deliberately not requested (operator
# policy: "Wi-Fi password is NOT captured").
Start-EvidenceSection -Id "16" -Title "WiFi Profiles" -FileName "16_WiFiProfiles.txt"
$secStatus = 'Success'
$secReason = $null
try {
    Out-Log "Wi-Fi profile capture: PSK / key content is NOT captured (operator policy)."
    Out-Log ""

    $prevEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $listOutput = & cmd /c "chcp 65001 >nul && netsh wlan show profiles" 2>&1
    }
    finally {
        [Console]::OutputEncoding = $prevEncoding
    }

    # Parse "    All User Profile     : <name>" and
    # "    User Profile          : <name>" lines.
    $profileNames = @()
    foreach ($line in $listOutput) {
        $s = "$line"
        if ($s -match '(?:All User Profile|User Profile)\s*:\s*(.+?)\s*$') {
            $name = $Matches[1].Trim()
            if (-not [string]::IsNullOrWhiteSpace($name) -and ($profileNames -notcontains $name)) {
                $profileNames += $name
            }
        }
    }

    if ($profileNames.Count -eq 0) {
        Out-Log "No Wi-Fi profiles found (this PC may have no WLAN adapter or no saved networks)."
        $secStatus = 'Skipped'
        $secReason = 'No Wi-Fi profiles registered on this PC'
    }
    else {
        Out-Log "Found $($profileNames.Count) Wi-Fi profile(s):"
        foreach ($name in $profileNames) {
            Out-Log "  - $name"
        }
        Out-Log ""
        Out-Log "============================================================"

        # Field whitelist for per-profile output: anything mentioning
        # 'key' / 'password' / 'PSK' is filtered out as a defence-in-depth
        # measure (even though we never pass key=clear, future netsh
        # versions might leak hints).
        $denyFieldRegex = '(?i)(key content|security key|password|psk)'

        foreach ($name in $profileNames) {
            Out-Log ""
            Out-Log "Profile: $name"
            Out-Log "------------------------------------------------------------"

            $prevEnc2 = [Console]::OutputEncoding
            $detailOutput = $null
            try {
                [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
                # Use double-quoted profile name to handle spaces.
                $cmd = 'chcp 65001 >nul && netsh wlan show profile name="' + $name + '"'
                $detailOutput = & cmd /c $cmd 2>&1
            }
            finally {
                [Console]::OutputEncoding = $prevEnc2
            }

            foreach ($dline in $detailOutput) {
                $ds = "$dline"
                # Drop key-bearing lines defensively, even though we did
                # not request key=clear.
                if ($ds -match $denyFieldRegex) { continue }
                Out-Log "  $ds"
            }
        }
    }
}
catch {
    Out-Log "[ERROR] Failed to get Wi-Fi profiles: $_" -Color Red
    $secStatus = 'Failed'
    $secReason = "$($_.Exception.Message)"
}
Close-EvidenceSection -Status $secStatus -Reason $secReason

# ============================================================
# §27 Environment Variables (Machine + User scopes, CSV)
# ============================================================
Start-EvidenceSection -Id "27" -Title "Environment Variables (CSV)" -FileName $null
$secStatus = 'Success'
$secReason = $null
try {
    $envRows = @()
    foreach ($scope in 'Machine','User') {
        try {
            $vars = [System.Environment]::GetEnvironmentVariables($scope)
            foreach ($key in $vars.Keys) {
                $envRows += [PSCustomObject]@{
                    Scope = $scope
                    Name  = $key
                    Value = $vars[$key]
                }
            }
            Out-Log "  $scope scope: $($vars.Count) variables"
        }
        catch {
            Out-Log "  [WARN] Could not enumerate $scope scope: $_" -Color Yellow
        }
    }

    $envRows = $envRows | Sort-Object Scope, Name
    $outEnv = Join-Path $sectionDir "27_EnvironmentVariables.csv"
    $envRows | Export-Csv -Path $outEnv -NoTypeInformation -Encoding UTF8
    Add-EvidenceSectionFile "27_EnvironmentVariables.csv"

    Out-Log "Environment variables: $($envRows.Count) entries -> 27_EnvironmentVariables.csv"
}
catch {
    Out-Log "[ERROR] Failed to enumerate environment variables: $_" -Color Red
    $secStatus = 'Failed'
    $secReason = "$($_.Exception.Message)"
}
Close-EvidenceSection -Status $secStatus -Reason $secReason

# ============================================================
# Write section manifest (fabriq-system-evidence-backup schemaVersion=1)
# ============================================================
# Schema combines fabriq's per-section sections[] array (so existing
# fabriq evidence consumers can read it) with backuper-specific
# extensions for the lan-prep snapshot harvest result.

$sectionsArr  = @($script:ManifestSections)
$successCount = @($sectionsArr | Where-Object { $_.status -eq 'Success' }).Count
$skippedCount = @($sectionsArr | Where-Object { $_.status -eq 'Skipped' }).Count
$failedCount  = @($sectionsArr | Where-Object { $_.status -eq 'Failed'  }).Count
$partialCount = @($sectionsArr | Where-Object { $_.status -eq 'Partial' }).Count

$manifest = [ordered]@{
    schemaVersion         = 1
    manifestType          = 'fabriq-system-evidence-backup'
    backuperVersion       = if ($script:BackuperVersion) { $script:BackuperVersion } else { 'unknown' }
    evidenceConfigOrigin  = 'vendored from fabriq evidence_config 1.7.0 (subset)'
    collectedAt           = $collectedAt.ToString("yyyy-MM-ddTHH:mm:sszzz")
    computerName          = $pcName
    oldPcName             = $OldPcName
    lanPrepSnapshot       = [ordered]@{
        harvested        = $snapshotHarvested
        snapshotPath     = $snapshotPath
        originalNetwork  = $originalNetwork
    }
    sections              = $sectionsArr
    summary               = [ordered]@{
        sectionCount = $sectionsArr.Count
        successCount = $successCount
        skippedCount = $skippedCount
        failedCount  = $failedCount
        partialCount = $partialCount
    }
    pendingPhases         = @(
        'Phase 4 will copy backup artifacts to the operator handoff folder on restore'
    )
}

$manifestPath = Join-Path $sectionDir 'manifest.json'
$json = $manifest | ConvertTo-Json -Depth 8
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($manifestPath, $json, $utf8NoBom)

Show-Success "system_evidence: manifest written to $manifestPath"

$sw.Stop()

# ============================================================
# Compute return status for the engine
# ============================================================
# Aggregate the evidence section statuses into one Backuper section
# status:
#   - any Failed -> Partial (we still produced some files)
#   - all Success+Skipped, but no actual data sections -> Partial
#   - everything Success or intrinsic Skip -> Success
$overallStatus = if ($failedCount -gt 0 -or $partialCount -gt 0) {
    'Partial'
} else {
    'Success'
}

$summary = [ordered]@{
    sectionCount       = $sectionsArr.Count
    successCount       = $successCount
    skippedCount       = $skippedCount
    failedCount        = $failedCount
    partialCount       = $partialCount
    snapshotHarvested  = $snapshotHarvested
    snapshotPath       = $snapshotPath
}

return [PSCustomObject]@{
    Status               = $overallStatus
    ElapsedMs            = [int]$sw.ElapsedMilliseconds
    Summary              = $summary
    Warnings             = $warnings
    ExternalOutputDir    = $null
    ExternalManifestPath = $null
    InternalSectionDir   = $sectionDir
    InternalManifestPath = $manifestPath
}
