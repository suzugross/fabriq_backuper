# ============================================================
# FabriqBackUper Section: printer / restore (Phase 2.2.1, internalized)
#
# Reads $AggregateBackupDir/sections/printer/manifest.json
# (fabriq-printer-backup schemaVersion=1) and replays it.
#
# SectionParams (hashtable, all optional):
#   IncludePrinters       : array of printer names to restore; null/empty = all in manifest
#   StrictOsVersion       : bool (default $false)
#   ReuseInboxDrivers     : bool (default $true)
#   OnConflict            : 'skip'|'replace' (default 'skip')
#   RestoreDefaultPrinter : bool (default $true)
#   SkipVirtualPrinters   : bool (default $true)
#   RestoreHardwareConfig : bool (default $true)
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

# v0.29.0: SectionParams.
#   IncludePrinters       : optional string[] -- printer-grid selection
#                           from restore_view. Empty/null = all printers.
#   OperatorHandoffSubdir : <handoff>\04_プリンタ. Required (handoff is the
#                           sole restore path from v0.29.0; if missing the
#                           section returns Skipped). restore_view always
#                           provides this when the operator handoff folder
#                           checkbox is ON; turning the checkbox OFF means
#                           the printer install simply does not happen,
#                           consistent with credentials / outlook_pop.
$includePrinters = $null
if ($SectionParams.ContainsKey('IncludePrinters') -and `
    $null -ne $SectionParams['IncludePrinters'] -and `
    @($SectionParams['IncludePrinters']).Count -gt 0) {
    $includePrinters = @($SectionParams['IncludePrinters'])
}
$handoffSubdir = $null
if ($SectionParams.ContainsKey('OperatorHandoffSubdir') -and `
    -not [string]::IsNullOrWhiteSpace($SectionParams['OperatorHandoffSubdir'])) {
    $handoffSubdir = "$($SectionParams['OperatorHandoffSubdir'])"
    Show-Info "printer: OperatorHandoffSubdir = $handoffSubdir"
}

# v0.29.0 Phase 5: handoff-only restore path. If the handoff folder is
# disabled (checkbox OFF in restore_view), there is no operator-facing
# target for the printer payload, so the section returns Skipped without
# touching the local system. This matches the credentials / outlook_pop
# / system_evidence pattern: turning the handoff checkbox OFF means the
# operator handles all artifacts manually.
if ([string]::IsNullOrWhiteSpace($handoffSubdir)) {
    Show-Skip "printer: handoff folder disabled, restore skipped (printers will NOT be installed)"
    return [PSCustomObject]@{
        Status               = 'Skipped'
        ElapsedMs            = [int]$sw.ElapsedMilliseconds
        Summary              = [ordered]@{
            reason = 'Operator handoff folder feature is disabled'
        }
        Warnings             = @()
        ExternalOutputDir    = $null
        ExternalManifestPath = $null
    }
}

# ----------------------------------------------------------
# Prerequisites
# ----------------------------------------------------------
if (-not (Test-AdminPrivilege)) {
    return [PSCustomObject]@{
        Status = 'Failed'; ElapsedMs = [int]$sw.ElapsedMilliseconds
        Summary = [ordered]@{}; Warnings = @('Administrator privileges required')
    }
}

$sectionDir = Join-Path $AggregateBackupDir 'sections\printer'
$manifestPath = Join-Path $sectionDir 'manifest.json'
if (-not (Test-Path $manifestPath)) {
    return [PSCustomObject]@{
        Status = 'Failed'; ElapsedMs = [int]$sw.ElapsedMilliseconds
        Summary = [ordered]@{}; Warnings = @("manifest.json not found at: $manifestPath")
    }
}

$manifest = $null
try { $manifest = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json }
catch {
    return [PSCustomObject]@{
        Status = 'Failed'; ElapsedMs = [int]$sw.ElapsedMilliseconds
        Summary = [ordered]@{}; Warnings = @("manifest.json parse error: $($_.Exception.Message)")
    }
}
if ($manifest.manifestType -ne 'fabriq-printer-backup') {
    return [PSCustomObject]@{
        Status = 'Failed'; ElapsedMs = [int]$sw.ElapsedMilliseconds
        Summary = [ordered]@{}; Warnings = @("Unexpected manifestType: $($manifest.manifestType)")
    }
}
if ([int]$manifest.schemaVersion -ne 1) {
    return [PSCustomObject]@{
        Status = 'Failed'; ElapsedMs = [int]$sw.ElapsedMilliseconds
        Summary = [ordered]@{}; Warnings = @("Unsupported schemaVersion: $($manifest.schemaVersion)")
    }
}

# ----------------------------------------------------------
# v0.29.0 Phase 2: deploy backup section dir into the operator handoff
# folder so Phase 3-4 (Install-Printers.ps1 + Install-Printers.bat +
# README.txt + _printer_settings.txt) have a self-contained payload to
# drive.
#
# v0.29.0 Phase 5a: deploy into a "_data" subdirectory rather than the
# handoff root, so the operator sees only the small operator-facing
# fileset (Install-Printers.bat / README.txt / _printer_settings.txt)
# when they open 04_プリンタ\. The full payload (manifest.json,
# drivers/, printsettings/, Install-Printers.ps1, etc.) lives under
# _data\ which the operator does not need to touch. Install-Printers.bat
# references _data\Install-Printers.ps1 by relative path so the layout
# is self-contained.
$handoffDataDir = Join-Path $handoffSubdir '_data'
$handoffDeployedFiles = 0
$handoffDeployBytes   = 0L
if ($handoffSubdir) {
    try {
        if (-not (Test-Path -LiteralPath $handoffSubdir)) {
            $null = New-Item -ItemType Directory -Path $handoffSubdir -Force -ErrorAction Stop
        }
        if (-not (Test-Path -LiteralPath $handoffDataDir)) {
            $null = New-Item -ItemType Directory -Path $handoffDataDir -Force -ErrorAction Stop
        }
        # Copy every file/dir under sections/printer/ into the handoff
        # _data subdir. Using -Recurse + wildcard so the destination
        # keeps the same internal layout under _data\ (manifest.json at
        # _data root, drivers/, etc.) -- Install-Printers.ps1 resolves
        # all its sub-paths relative to $PSScriptRoot, which becomes
        # _data\ once we put the script there.
        Show-Info "printer: deploying section payload to $handoffDataDir"
        Copy-Item -Path (Join-Path $sectionDir '*') -Destination $handoffDataDir -Recurse -Force -ErrorAction Stop
        $deployed = @(Get-ChildItem -LiteralPath $handoffDataDir -Recurse -File -ErrorAction SilentlyContinue)
        $handoffDeployedFiles = $deployed.Count
        $handoffDeployBytes   = ($deployed | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        if ($null -eq $handoffDeployBytes) { $handoffDeployBytes = 0L }
        Show-Success ("printer: handoff payload deployed ({0} files, {1:N1} MB)" -f $handoffDeployedFiles, ($handoffDeployBytes / 1MB))
    } catch {
        $msg = "Handoff Copy failed: $($_.Exception.Message)"
        $warnings += $msg
        Show-Warning "printer: $msg"
    }

    # v0.29.0 Phase 3: emit Install-Printers.ps1 alongside the copied
    # payload. The script faithfully mirrors the legacy auto-install
    # path's Phase A-E (driver install / port create / printer add /
    # Spooler restart + HKLM hwconfig + HKCU DEVMODE / default printer)
    # so the operator gets identical results from running 登録.bat as
    # they would from the in-engine auto-install. Resolve-HkcuRoot is
    # inlined because the batch is a standalone script and cannot
    # dot-source backuper/common.ps1.
    #
    # Encoding: this restore.ps1 file is BOM-tagged so the here-string
    # below can carry Japanese console messages safely. We write the
    # output with UTF8Encoding($true) so PS5.1 in the operator's
    # admin-elevated session decodes it correctly.
    # ASCII-only here-string (CLAUDE.md rule 5): this restore.ps1 has
    # been observed without a UTF-8 BOM on operator machines. Any
    # Japanese inside this here-string would be ANSI-mis-decoded by
    # PS5.1 and the resulting Install-Printers.ps1 would carry mojibake.
    # All operator-visible messages are therefore plain English. The
    # README.txt and _printer_settings.txt next to this script provide
    # the same information in Japanese.
    $installPs1 = @'
# ============================================================
# Fabriq Printer Restore - Install-Printers.ps1
#
# Launched by Install-Printers.bat (in the parent folder) via UAC
# elevation. Reads the source PC manifest.json from the same _data
# folder and replays Phase A-E (driver / port / printer / DEVMODE /
# default printer).
#
# Requirements:
#   * Run while logged on as the restore-target user. DEVMODE is a
#     per-user HKCU setting; the script auto-redirects to HKU\<SID>
#     when running under cross-user admin elevation, but running as
#     the target user is the safest path.
#   * Internet access lets Windows Update auto-fill missing inbox
#     drivers if needed.
# ============================================================

$ErrorActionPreference = 'Continue'

# Force console output to UTF-8 so Japanese printer names render
# correctly in Write-Host even when the host console codepage is
# CP932. PS5.1's internal strings are UTF-16, but Write-Host
# encodes via [Console]::OutputEncoding before writing -- setting
# this to UTF-8 keeps non-ASCII characters intact end-to-end.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# ----------------------------------------------------------
# A0: Self-Elevate (UAC)
# ----------------------------------------------------------
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ""
    Write-Host "  Administrator privileges required. Relaunching via UAC..." -ForegroundColor Yellow
    Start-Process -FilePath PowerShell.exe -Verb RunAs `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

# ----------------------------------------------------------
# A1: Banner + Prerequisites
# ----------------------------------------------------------
Clear-Host
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "    Fabriq Printer Restore" -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host ""

try {
    $spooler = Get-Service -Name Spooler -ErrorAction Stop
    if ($spooler.Status -ne 'Running') {
        Write-Host "  [FATAL] Print Spooler service is not running (Status=$($spooler.Status))." -ForegroundColor Red
        Write-Host "          Start the Spooler service via services.msc and try again." -ForegroundColor Red
        Read-Host "  Press Enter to close"
        exit 1
    }
} catch {
    Write-Host "  [FATAL] Spooler check failed: $($_.Exception.Message)" -ForegroundColor Red
    Read-Host "  Press Enter to close"
    exit 1
}

# ----------------------------------------------------------
# A2: manifest.json
# ----------------------------------------------------------
$baseDir      = $PSScriptRoot
$manifestPath = Join-Path $baseDir 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    Write-Host "  [FATAL] manifest.json not found: $manifestPath" -ForegroundColor Red
    Read-Host "  Press Enter to close"
    exit 1
}
try {
    # -Encoding UTF8 ensures Japanese printer names decode correctly
    # regardless of whether the manifest carries a BOM. PS5.1's default
    # Get-Content falls back to ANSI (CP932 on JP locales) for BOM-less
    # files, which would mojibake non-ASCII printer names.
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Host "  [FATAL] manifest.json parse failed: $($_.Exception.Message)" -ForegroundColor Red
    Read-Host "  Press Enter to close"
    exit 1
}
if ($manifest.manifestType -ne 'fabriq-printer-backup') {
    Write-Host "  [FATAL] Unexpected manifestType: $($manifest.manifestType)" -ForegroundColor Red
    Read-Host "  Press Enter to close"
    exit 1
}

Write-Host "  manifest   : $manifestPath"
Write-Host "  Source PC  : $($manifest.computerName)  (captured: $($manifest.collectedAt))"
Write-Host "  Counts     : $($manifest.counts.printer) printer(s) / $($manifest.counts.port) port(s) / $($manifest.counts.driverRegistered) driver(s)"
Write-Host ""

$warnings    = @()
$successList = @()
$failureList = @()
$skipList    = @()

# ----------------------------------------------------------
# Phase A: Driver install (pnputil + Add-PrinterDriver)
# ----------------------------------------------------------
Write-Host "  ----- Phase A: Driver install -----" -ForegroundColor Cyan
$drivers = @($manifest.items.drivers)
foreach ($drv in $drivers) {
    $name = $drv.driverName
    try {
        if ($drv.isInboxDriver) {
            Write-Host "    [INBOX] $name  ... " -NoNewline
            Add-PrinterDriver -Name $name -ErrorAction Stop
            Write-Host "OK" -ForegroundColor Green
        } else {
            $driverDir = Join-Path $baseDir $drv.backupFolder
            if (-not (Test-Path -LiteralPath $driverDir)) {
                throw "driver folder not found: $driverDir"
            }
            $infFile = Get-ChildItem -LiteralPath $driverDir -Filter *.inf -File -ErrorAction Stop | Select-Object -First 1
            if (-not $infFile) { throw "inf not found in $driverDir" }
            Write-Host "    [OEM]   $name  ($($infFile.Name))  ... " -NoNewline
            $pnputilOut = & pnputil.exe /add-driver $infFile.FullName /install 2>&1
            if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 259) {
                # 259 = ERROR_NO_MORE_ITEMS (driver already in store)
                Write-Host "pnputil exit=$LASTEXITCODE" -ForegroundColor Yellow
                $warnings += "pnputil $name exit=$LASTEXITCODE : $pnputilOut"
            }
            Add-PrinterDriver -Name $name -ErrorAction Stop
            Write-Host "OK" -ForegroundColor Green
        }
    } catch {
        Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red
        $warnings += "driver '$name': $($_.Exception.Message)"
    }
}
Write-Host ""

# ----------------------------------------------------------
# Phase B: Port creation (+ WSD rescue map)
# ----------------------------------------------------------
Write-Host "  ----- Phase B: Port creation -----" -ForegroundColor Cyan
$portRewriteMap = @{}
$ports = @($manifest.items.ports)
foreach ($port in $ports) {
    $pname = $port.name
    if (Get-PrinterPort -Name $pname -ErrorAction SilentlyContinue) {
        Write-Host "    [SKIP]  $pname (exists)"
        continue
    }
    try {
        switch -Regex ($port.portType) {
            '^TCPIP$' {
                $addArgs = @{
                    Name               = $pname
                    PrinterHostAddress = $port.printerHostAddress
                }
                if ($port.portNumber)  { $addArgs['PortNumber']    = [int]$port.portNumber }
                if ($port.snmpEnabled) { $addArgs['SNMP']          = 1; $addArgs['SNMPCommunity'] = $port.snmpCommunity }
                Add-PrinterPort @addArgs -ErrorAction Stop
                $hostInfo = "$($port.printerHostAddress) port $($port.portNumber)"
                Write-Host "    [TCPIP] $pname -> $hostInfo" -ForegroundColor Green
            }
            '^LPR$' {
                Add-PrinterPort -Name $pname -LprHostAddress $port.lprHostName `
                    -LprQueueName $port.lprQueueName -ErrorAction Stop
                Write-Host "    [LPR]   $pname -> $($port.lprHostName) queue=$($port.lprQueueName)" -ForegroundColor Green
            }
            '^WSD$' {
                if (-not [string]::IsNullOrWhiteSpace($port.wsdResolvedHost)) {
                    $newName = "IP_$($port.wsdResolvedHost)"
                    if (-not (Get-PrinterPort -Name $newName -ErrorAction SilentlyContinue)) {
                        Add-PrinterPort -Name $newName -PrinterHostAddress $port.wsdResolvedHost `
                            -PortNumber 9100 -ErrorAction Stop
                    }
                    $portRewriteMap[$pname] = $newName
                    Write-Host "    [WSD->TCPIP] $pname -> $newName  (host=$($port.wsdResolvedHost) port 9100)" -ForegroundColor Green
                } else {
                    Write-Host "    [WSD]   $pname (no wsdResolvedHost; manual re-add required)" -ForegroundColor Yellow
                    $warnings += "WSD port '$pname' has no wsdResolvedHost; needs manual re-add"
                }
            }
            '^Local$' {
                Write-Host "    [LOCAL] $pname (Spooler internal, skipped)"
            }
            default {
                Write-Host "    [Other] $pname (type=$($port.portType), skipped)" -ForegroundColor Yellow
                $warnings += "port '$pname' has unsupported type $($port.portType)"
            }
        }
    } catch {
        Write-Host "    [FAIL]  $pname : $($_.Exception.Message)" -ForegroundColor Red
        $warnings += "port '$pname': $($_.Exception.Message)"
    }
}
Write-Host ""

# ----------------------------------------------------------
# Phase C: Printer add + Properties
# ----------------------------------------------------------
Write-Host "  ----- Phase C: Printer add -----" -ForegroundColor Cyan
$printers = @($manifest.items.printers)
$restoredPrinterNames = @()
foreach ($p in $printers) {
    $pname = $p.name
    if (Get-Printer -Name $pname -ErrorAction SilentlyContinue) {
        Write-Host "    [SKIP] $pname (exists)"
        $skipList += $pname
        continue
    }
    $effectivePort = if ($portRewriteMap.ContainsKey($p.portName)) {
        $portRewriteMap[$p.portName]
    } else { $p.portName }

    try {
        $addArgs = @{
            Name       = $pname
            DriverName = $p.driverName
            PortName   = $effectivePort
        }
        if ($p.shared -and -not [string]::IsNullOrWhiteSpace($p.shareName)) {
            $addArgs['Shared']    = $true
            $addArgs['ShareName'] = $p.shareName
        }
        if (-not [string]::IsNullOrWhiteSpace($p.comment))  { $addArgs['Comment']  = $p.comment }
        if (-not [string]::IsNullOrWhiteSpace($p.location)) { $addArgs['Location'] = $p.location }
        if ($p.published) { $addArgs['Published'] = $true }
        Add-Printer @addArgs -ErrorAction Stop
        $portLabel = "port=$effectivePort driver=$($p.driverName)"
        Write-Host "    [OK] $pname  ($portLabel)" -ForegroundColor Green
        $successList += $pname
        $restoredPrinterNames += $pname
    } catch {
        Write-Host "    [FAIL] $pname : $($_.Exception.Message)" -ForegroundColor Red
        $failureList += $pname
        $warnings += "printer '$pname' add: $($_.Exception.Message)"
        continue
    }

    # properties
    if (-not [string]::IsNullOrWhiteSpace($p.propertiesFile)) {
        $propPath = Join-Path $baseDir $p.propertiesFile
        if (Test-Path -LiteralPath $propPath) {
            try {
                $props = Get-Content -LiteralPath $propPath -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($prop in @($props)) {
                    if ($null -eq $prop) { continue }
                    if ([string]::IsNullOrWhiteSpace($prop.PropertyName)) { continue }
                    try {
                        Set-PrinterProperty -PrinterName $pname `
                            -PropertyName $prop.PropertyName -Value $prop.Value -ErrorAction Stop
                    } catch { }
                }
            } catch { }
        }
    }
}
Write-Host ""

# ----------------------------------------------------------
# Phase D: Spooler restart + HKLM hwconfig + HKCU DEVMODE
# ----------------------------------------------------------
$anyHwConfig = @($printers | Where-Object { -not [string]::IsNullOrWhiteSpace($_.hwConfigFile) }).Count -gt 0
$anyDevMode  = @($printers | Where-Object { -not [string]::IsNullOrWhiteSpace($_.devModeFile)  }).Count -gt 0

if ($anyHwConfig -or $anyDevMode) {
    Write-Host "  ----- Phase D: Settings (DEVMODE / hwconfig) -----" -ForegroundColor Cyan
    Write-Host "    Restarting Spooler..."
    try {
        Restart-Service -Name Spooler -Force -ErrorAction Stop
        Start-Sleep -Seconds 2
        Write-Host "    Spooler restarted OK" -ForegroundColor Green
    } catch {
        Write-Host "    Spooler restart failed: $($_.Exception.Message)" -ForegroundColor Yellow
        $warnings += "Spooler restart: $($_.Exception.Message)"
    }
}

# Resolve-HkcuRoot inline: prefer the interactive logged-on user's HKU
# hive when running under cross-user admin elevation (mirrors backuper/
# common.ps1 Resolve-HkcuRoot). Falls back to HKCU: when current user
# is the interactive user.
function Get-HandoffHkcuRoot {
    $currentSid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
    $loggedSid  = $null
    try {
        $explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop |
                    Select-Object -First 1
        if ($explorer) {
            $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner -ErrorAction Stop
            if ($owner.User -and $owner.Domain) {
                $nt = New-Object Security.Principal.NTAccount($owner.Domain, $owner.User)
                $loggedSid = ($nt.Translate([Security.Principal.SecurityIdentifier])).Value
            }
        }
    } catch {}
    if ($loggedSid -and $loggedSid -ne $currentSid) {
        if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
            try {
                $null = New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -Scope Global -ErrorAction Stop
            } catch { return @{ PsDrivePath = 'HKCU:'; Redirected = $false; SID = $currentSid } }
        }
        if (Test-Path "HKU:\$loggedSid") {
            return @{ PsDrivePath = "HKU:\$loggedSid"; Redirected = $true; SID = $loggedSid }
        }
    }
    return @{ PsDrivePath = 'HKCU:'; Redirected = $false; SID = $currentSid }
}

$hkcuInfo   = Get-HandoffHkcuRoot
$devModeKey = "$($hkcuInfo.PsDrivePath)\Printers\DevModePerUser"
if ($hkcuInfo.Redirected) {
    Write-Host "    DEVMODE target: $($hkcuInfo.PsDrivePath) (SID=$($hkcuInfo.SID))"
}

foreach ($p in $printers) {
    $pname = $p.name
    if ($pname -notin $restoredPrinterNames -and -not (Get-Printer -Name $pname -ErrorAction SilentlyContinue)) {
        continue
    }
    # HKLM hwconfig
    if (-not [string]::IsNullOrWhiteSpace($p.hwConfigFile)) {
        $hwConfigPath = Join-Path $baseDir $p.hwConfigFile
        if (Test-Path -LiteralPath $hwConfigPath) {
            $hwRegPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Printers\$pname\PrinterDriverData"
            try {
                $hwDump = Get-Content -LiteralPath $hwConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if (-not (Test-Path $hwRegPath)) { $null = New-Item -Path $hwRegPath -Force -ErrorAction Stop }
                $restoredValues = 0
                foreach ($prop in $hwDump.PSObject.Properties) {
                    $vname = $prop.Name; $info = $prop.Value
                    if ($null -eq $info -or [string]::IsNullOrWhiteSpace($info.Type)) { continue }
                    try {
                        $decoded = switch ($info.Type) {
                            'Binary'       { if ($null -ne $info.Data) { [Convert]::FromBase64String([string]$info.Data) } else { [byte[]]@() } }
                            'String'       { [string]$info.Data }
                            'ExpandString' { [string]$info.Data }
                            'MultiString'  { @($info.Data) }
                            'DWord'        { [int]$info.Data }
                            'QWord'        { [long]$info.Data }
                            default        { [string]$info.Data }
                        }
                        $null = New-ItemProperty -Path $hwRegPath -Name $vname -Value $decoded -PropertyType $info.Type -Force -ErrorAction Stop
                        $restoredValues++
                    } catch {
                        $warnings += "hwconfig '$vname' on '$pname': $($_.Exception.Message)"
                    }
                }
                if ($restoredValues -gt 0) {
                    Write-Host "    [hwconfig] $pname : $restoredValues values" -ForegroundColor Green
                }
            } catch {
                $warnings += "hwconfig '$pname': $($_.Exception.Message)"
            }
        }
    }
    # HKCU DEVMODE
    if (-not [string]::IsNullOrWhiteSpace($p.devModeFile)) {
        $devModePath = Join-Path $baseDir $p.devModeFile
        if (Test-Path -LiteralPath $devModePath) {
            try {
                $b64 = (Get-Content -LiteralPath $devModePath -Raw -ErrorAction Stop).Trim()
                if (-not [string]::IsNullOrWhiteSpace($b64)) {
                    $blob = [Convert]::FromBase64String($b64)
                    if (-not (Test-Path $devModeKey)) { $null = New-Item -Path $devModeKey -Force -ErrorAction Stop }
                    $null = New-ItemProperty -Path $devModeKey -Name $pname -Value $blob -PropertyType Binary -Force -ErrorAction Stop
                    Write-Host "    [DEVMODE]  $pname" -ForegroundColor Green
                }
            } catch {
                $warnings += "DEVMODE '$pname': $($_.Exception.Message)"
            }
        }
    }
}
Write-Host ""

# ----------------------------------------------------------
# Phase E: Default printer
# ----------------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($manifest.defaultPrinter)) {
    $defName = $manifest.defaultPrinter
    Write-Host "  ----- Phase E: Default printer -----" -ForegroundColor Cyan
    if (Get-Printer -Name $defName -ErrorAction SilentlyContinue) {
        try {
            (New-Object -ComObject WScript.Network).SetDefaultPrinter($defName)
            Write-Host "    [OK] Default printer: $defName" -ForegroundColor Green
        } catch {
            Write-Host "    [WARN] Default printer set failed: $($_.Exception.Message)" -ForegroundColor Yellow
            $warnings += "default printer '$defName': $($_.Exception.Message)"
        }
    } else {
        Write-Host "    [SKIP] Default printer '$defName' is not installed" -ForegroundColor Yellow
    }
    Write-Host ""
}

# ----------------------------------------------------------
# Summary
# ----------------------------------------------------------
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "    Done" -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "    Success : $($successList.Count)"
foreach ($n in $successList) { Write-Host "        - $n" -ForegroundColor Green }
if ($skipList.Count -gt 0) {
    Write-Host "    Skipped : $($skipList.Count) (already exist)"
    foreach ($n in $skipList) { Write-Host "        - $n" -ForegroundColor DarkGray }
}
if ($failureList.Count -gt 0) {
    Write-Host "    FAIL    : $($failureList.Count)" -ForegroundColor Red
    foreach ($n in $failureList) { Write-Host "        - $n" -ForegroundColor Red }
    Write-Host ""
    Write-Host "    >>> Manually re-add any failed printers: <<<" -ForegroundColor Yellow
    Write-Host "        Control Panel -> Devices and Printers -> Add a printer" -ForegroundColor Yellow
    Write-Host "        IP and driver info is in _printer_settings.txt." -ForegroundColor Yellow
}
if ($warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "    Warnings: $($warnings.Count)" -ForegroundColor Yellow
    foreach ($w in $warnings) { Write-Host "        - $w" -ForegroundColor DarkYellow }
}
Write-Host ""
Read-Host "  Press Enter to close"
'@

    # v0.29.0 Phase 5a: Install-Printers.ps1 lives under _data\ so it is
    # not visible alongside the operator-facing files in 04_プリンタ\.
    # All sub-paths it resolves (manifest.json / drivers/ / printsettings/)
    # are relative to $PSScriptRoot, which now equals _data\, so no
    # internal path change is needed in the here-string above.
    $installPs1Path = Join-Path $handoffDataDir 'Install-Printers.ps1'
    try {
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($installPs1Path, $installPs1, $utf8Bom)
        Show-Success "printer: Install-Printers.ps1 emitted to $installPs1Path"
    } catch {
        $msg = "Install-Printers.ps1 emit failed: $($_.Exception.Message)"
        $warnings += $msg
        Show-Warning "printer: $msg"
    }

    # v0.29.0 Phase 4: Install-Printers.bat + README.txt +
    # _printer_settings.txt. All string literals in this block are
    # ASCII-only so this restore.ps1 can be saved without a UTF-8 BOM
    # without triggering PS5.1 ANSI mis-decoding (CLAUDE.md rule 5).
    # Operator-facing messages are in plain English that Japanese
    # readers can scan; that matches the KeepAwake utility pattern.

    # Install-Printers.bat: cmd -> powershell wrapper. Self-elevate is
    # done inside the .ps1 so the batch is just title + invoke.
    # v0.29.0 Phase 5a: invoke the .ps1 from _data\ relative to the bat.
    $registerBat = @'
@echo off
title Fabriq Printer Restore
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0_data\Install-Printers.ps1"
'@
    $registerBatPath = Join-Path $handoffSubdir 'Install-Printers.bat'
    try {
        $asciiNoBom = New-Object System.Text.ASCIIEncoding
        [System.IO.File]::WriteAllText($registerBatPath, $registerBat, $asciiNoBom)
        Show-Success "printer: Install-Printers.bat emitted"
    } catch {
        $warnings += "Install-Printers.bat emit failed: $($_.Exception.Message)"
        Show-Warning "printer: Install-Printers.bat emit failed: $($_.Exception.Message)"
    }

    # README.txt and _printer_settings.txt content is composed in
    # backuper/common.ps1 (BOM-tagged UTF-8) by New-PrinterHandoffReadme
    # and New-PrinterSettingsText. Keeping the Japanese literals out of
    # this file is intentional: this restore.ps1 has been observed
    # without a UTF-8 BOM on operator machines, and PS5.1 would then
    # ANSI-decode embedded Japanese into mojibake. By only forwarding
    # the resulting strings to WriteAllText we preserve handoff Japanese
    # content while keeping this file ASCII-only.
    $readmePath = Join-Path $handoffSubdir 'README.txt'
    try {
        $readmeText = New-PrinterHandoffReadme -Manifest $manifest
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($readmePath, $readmeText, $utf8Bom)
        Show-Success "printer: README.txt emitted"
    } catch {
        $warnings += "README.txt emit failed: $($_.Exception.Message)"
        Show-Warning "printer: README.txt emit failed: $($_.Exception.Message)"
    }

    $settingsPath = Join-Path $handoffSubdir '_printer_settings.txt'
    try {
        $settingsText = New-PrinterSettingsText -Manifest $manifest
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($settingsPath, $settingsText, $utf8Bom)
        Show-Success "printer: _printer_settings.txt emitted ($($manifest.counts.printer) printers summarized)"
    } catch {
        $warnings += "_printer_settings.txt emit failed: $($_.Exception.Message)"
        Show-Warning "printer: _printer_settings.txt emit failed: $($_.Exception.Message)"
    }
}

# ----------------------------------------------------------
# v0.29.0 Phase 5: handoff manifest filter
# ----------------------------------------------------------
# restore_view's printer grid lets operator deselect printers. The
# legacy auto-install path applied this via $includePrinters; now that
# Install-Printers.bat reads handoff/04_プリンタ/_data/manifest.json
# verbatim (Phase 5a moved the payload into _data\), rewrite that
# manifest to contain only the selected printers (and their referenced
# ports / drivers). The original sections/printer/manifest.json stays
# untouched, so the full source-PC inventory is still recoverable.
if ($null -ne $includePrinters -and $includePrinters.Count -gt 0) {
    $handoffManifestPath = Join-Path $handoffDataDir 'manifest.json'
    if (Test-Path -LiteralPath $handoffManifestPath) {
        try {
            # Force UTF-8 read so Japanese printer names round-trip cleanly
            # (the source manifest is BOM-tagged UTF-8 from backup.ps1, but
            # we explicit the encoding for safety in case the Copy or upstream
            # tooling ever strips the BOM).
            $h = Get-Content -LiteralPath $handoffManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $h.items.printers = @($h.items.printers | Where-Object { $_.name -in $includePrinters })
            $remainPortNames   = @($h.items.printers | ForEach-Object { $_.portName }   | Sort-Object -Unique)
            $remainDriverNames = @($h.items.printers | ForEach-Object { $_.driverName } | Sort-Object -Unique)
            $h.items.ports   = @($h.items.ports   | Where-Object { $_.name -in $remainPortNames })
            $h.items.drivers = @($h.items.drivers | Where-Object { $_.driverName -in $remainDriverNames })
            $h.counts.printer          = @($h.items.printers).Count
            $h.counts.port             = @($h.items.ports).Count
            $h.counts.driverRegistered = @($h.items.drivers).Count
            $json = $h | ConvertTo-Json -Depth 12
            # Write with UTF-8 BOM so PS5.1's default Get-Content (which
            # otherwise falls back to ANSI/CP932 when reading a BOM-less
            # file) decodes Japanese printer names correctly when
            # Install-Printers.ps1 reads this manifest back.
            $utf8Bom = New-Object System.Text.UTF8Encoding($true)
            [System.IO.File]::WriteAllText($handoffManifestPath, $json, $utf8Bom)
            Show-Info "printer: handoff manifest filtered to $($h.counts.printer) printer(s) per IncludePrinters"
        } catch {
            $warnings += "handoff manifest filter failed: $($_.Exception.Message)"
            Show-Warning "printer: handoff manifest filter failed: $($_.Exception.Message)"
        }
    }
}

# ----------------------------------------------------------
# Final return: handoff-only path
# ----------------------------------------------------------
$sw.Stop()

$handoffManifestPath = Join-Path $handoffDataDir 'manifest.json'
$status = if ($warnings.Count -gt 0) { 'Partial' } else { 'Success' }

return [PSCustomObject]@{
    Status               = $status
    ElapsedMs            = [int]$sw.ElapsedMilliseconds
    Summary              = [ordered]@{
        handoffSubdir         = $handoffSubdir
        backupSectionDir      = $sectionDir
        handoffDeployedFiles  = $handoffDeployedFiles
        handoffDeployBytes    = $handoffDeployBytes
        sourcePrinterCount    = $manifest.counts.printer
        includePrintersCount  = if ($null -ne $includePrinters) { @($includePrinters).Count } else { $null }
        defaultPrinter        = $manifest.defaultPrinter
    }
    Warnings             = $warnings
    ExternalOutputDir    = $handoffSubdir
    ExternalManifestPath = $handoffManifestPath
    InternalSectionDir   = $null
    InternalManifestPath = $null
}
