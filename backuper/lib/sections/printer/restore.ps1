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

function _Get-Param {
    param($Key, $Default)
    if ($SectionParams.ContainsKey($Key)) { return $SectionParams[$Key] }
    return $Default
}

$includePrinters       = $null
if ($SectionParams.ContainsKey('IncludePrinters') -and `
    $null -ne $SectionParams['IncludePrinters'] -and `
    @($SectionParams['IncludePrinters']).Count -gt 0) {
    $includePrinters = @($SectionParams['IncludePrinters'])
}
$strictOsVersion       = [bool](_Get-Param 'StrictOsVersion'       $false)
$reuseInboxDrivers     = [bool](_Get-Param 'ReuseInboxDrivers'     $true)
$onConflict            = [string](_Get-Param 'OnConflict'          'skip').ToLower()
$restoreDefaultPrinter = [bool](_Get-Param 'RestoreDefaultPrinter' $true)
$skipVirtualPrinters   = [bool](_Get-Param 'SkipVirtualPrinters'   $true)
$restoreHardwareConfig = [bool](_Get-Param 'RestoreHardwareConfig' $true)

if ($onConflict -ne 'skip' -and $onConflict -ne 'replace') { $onConflict = 'skip' }

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
# Compatibility check (osArch hard, osVersion soft)
# ----------------------------------------------------------
$targetArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' }
              elseif ([Environment]::Is64BitOperatingSystem) { 'amd64' }
              else { 'x86' }
if ($manifest.osArch -ne $targetArch) {
    return [PSCustomObject]@{
        Status = 'Failed'; ElapsedMs = [int]$sw.ElapsedMilliseconds
        Summary = [ordered]@{}; Warnings = @("Architecture mismatch: backup=$($manifest.osArch), target=$targetArch")
    }
}
$targetOsVersion = [System.Environment]::OSVersion.Version.ToString()
$osMatches = ($manifest.osVersion -eq $targetOsVersion)
if (-not $osMatches) {
    if ($strictOsVersion) {
        return [PSCustomObject]@{
            Status = 'Failed'; ElapsedMs = [int]$sw.ElapsedMilliseconds
            Summary = [ordered]@{}; Warnings = @("osVersion mismatch (strict): backup=$($manifest.osVersion), target=$targetOsVersion")
        }
    }
    $warnings += "osVersion mismatch: backup=$($manifest.osVersion), target=$targetOsVersion (permissive)"
}

# ----------------------------------------------------------
# Filters: RDP redirect + virtual + IncludePrinters
# ----------------------------------------------------------
$virtualDriverPatterns = @('Microsoft Print To PDF','Microsoft XPS Document Writer','Microsoft Shared Fax Driver','Microsoft OpenXPS Class Driver','OneNote')
$virtualPortPatterns   = @('PORTPROMPT:','XPSPort:','FAX:','nul:','SHRFAX:')

function Test-IsRdpRedirect {
    param($P)
    if ($P.driverName -eq 'Remote Desktop Easy Print') { return $true }
    if ($P.portName -match '^TS\d+$') { return $true }
    return $false
}
function Test-IsVirtualPrinter {
    param($P)
    foreach ($pat in $virtualDriverPatterns) { if ($P.driverName -like "*$pat*") { return $true } }
    foreach ($pat in $virtualPortPatterns)   { if ($P.portName -like "*$pat*")   { return $true } }
    if ($P.portName -like 'OneNote*') { return $true }
    return $false
}

$allPrinters = @($manifest.items.printers)
$plannedPrinters = @()
$skippedRdp = 0
$skippedVirtual = 0
$skippedFilter = 0
foreach ($p in $allPrinters) {
    if (Test-IsRdpRedirect -P $p) { $skippedRdp++; continue }
    if ($skipVirtualPrinters -and (Test-IsVirtualPrinter -P $p)) { $skippedVirtual++; continue }
    if ($null -ne $includePrinters -and ($p.name -notin $includePrinters)) { $skippedFilter++; continue }
    $plannedPrinters += $p
}

if ($plannedPrinters.Count -eq 0) {
    $sw.Stop()
    return [PSCustomObject]@{
        Status = 'Skipped'; ElapsedMs = [int]$sw.ElapsedMilliseconds
        Summary = [ordered]@{
            note='no printers to restore'
            skippedRdp=$skippedRdp; skippedVirtual=$skippedVirtual; skippedFilter=$skippedFilter
        }
        Warnings = @($warnings)
    }
}

Show-Info "Restoring $($plannedPrinters.Count) printer(s) (skipped: RDP=$skippedRdp, virtual=$skippedVirtual, filter=$skippedFilter)"

# v0.21.0: WSD-port rewrite map. Filled while building ports below
# (and via backward-compat IPv4 mining from printer.location for
# manifests produced by v0.20.x or earlier). After that loop, each
# planned printer's portName is rewritten via this map before Add-Printer.
$portNameRewrites = @{}
function Get-IPv4FromLocationCompat {
    param([string]$Location)
    if ([string]::IsNullOrWhiteSpace($Location)) { return $null }
    $m = [System.Text.RegularExpressions.Regex]::Match(
        $Location,
        '(?<!\d)((?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3})(?!\d)')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}
function Resolve-WsdHost {
    param($PortEntry, $PlannedPrinters)
    if ($PortEntry.PSObject.Properties.Name -contains 'wsdResolvedHost' -and `
        -not [string]::IsNullOrWhiteSpace($PortEntry.wsdResolvedHost)) {
        return [string]$PortEntry.wsdResolvedHost
    }
    # Backward-compat for manifests written by v0.20.x and earlier.
    $referringPrinter = @($PlannedPrinters | Where-Object { $_.portName -eq $PortEntry.name } | Select-Object -First 1)
    if ($referringPrinter.Count -gt 0) {
        return (Get-IPv4FromLocationCompat -Location $referringPrinter[0].location)
    }
    return $null
}

# Conflict snapshot
$existingPrinters = @{}
foreach ($e in @(Get-Printer -ErrorAction SilentlyContinue)) { $existingPrinters[$e.Name] = $e }
$existingPorts = @{}
foreach ($e in @(Get-PrinterPort -ErrorAction SilentlyContinue)) { $existingPorts[$e.Name] = $e }
$existingDriverNames = @{}
foreach ($e in @(Get-PrinterDriver -ErrorAction SilentlyContinue)) { $existingDriverNames[$e.Name] = $true }

$referencedPortNames = @($plannedPrinters | ForEach-Object { $_.portName } | Sort-Object -Unique)
$referencedDriverNames = @($plannedPrinters | ForEach-Object { $_.driverName } | Sort-Object -Unique)
$plannedPorts = @($manifest.items.ports | Where-Object { $_.name -in $referencedPortNames })
$plannedDrivers = @($manifest.items.drivers | Where-Object { $_.driverName -in $referencedDriverNames })

# ----------------------------------------------------------
# Phase A: Drivers
# ----------------------------------------------------------
$driverSuccess = 0; $driverSkip = 0; $driverFail = 0
$payloadGroups = @{}
foreach ($d in $plannedDrivers) {
    $key = if ($d.backupFolder) { $d.backupFolder } else { '__no_payload__' }
    if (-not $payloadGroups.ContainsKey($key)) { $payloadGroups[$key] = @() }
    $payloadGroups[$key] += $d
}

foreach ($key in @($payloadGroups.Keys)) {
    $drivers = $payloadGroups[$key]
    $firstDriver = $drivers[0]
    $useExisting = $false
    if ($key -eq '__no_payload__') { $useExisting = $true }
    elseif ($reuseInboxDrivers -and ($firstDriver.isInboxDriver -or $firstDriver.manufacturer -eq 'Microsoft')) {
        $useExisting = $true
    }

    $storeInfPath = $null
    if (-not $useExisting) {
        $payloadDir = Join-Path $sectionDir $firstDriver.backupFolder
        if (-not (Test-Path $payloadDir)) {
            $warnings += "Driver payload missing: $($firstDriver.backupFolder)"
            $useExisting = $true
        } else {
            $infFile = @(Get-ChildItem -Path $payloadDir -Filter *.inf -File -ErrorAction SilentlyContinue) | Select-Object -First 1
            if ($null -eq $infFile) {
                $warnings += "No .inf in $payloadDir"
                $useExisting = $true
            } else {
                $null = & pnputil /add-driver $infFile.FullName /install 2>&1
                $infBase = [System.IO.Path]::GetFileNameWithoutExtension($infFile.Name).ToLower()
                $repo = 'C:\Windows\System32\DriverStore\FileRepository'
                $storeDir = @(Get-ChildItem -Path $repo -Directory -Filter "${infBase}.inf_${targetArch}_*" -ErrorAction SilentlyContinue |
                              Sort-Object LastWriteTime -Descending) | Select-Object -First 1
                if ($null -eq $storeDir) {
                    $warnings += "DriverStore folder not found for $infBase"
                    $useExisting = $true
                } else {
                    $storeInfPath = Join-Path $storeDir.FullName $infFile.Name
                    if (-not (Test-Path $storeInfPath)) {
                        $warnings += "Store INF not found: $storeInfPath"
                        $useExisting = $true
                    }
                }
            }
        }
    }

    foreach ($d in $drivers) {
        if ($existingDriverNames.ContainsKey($d.driverName)) {
            Show-Skip "Driver already registered: $($d.driverName)"
            $driverSkip++
            continue
        }
        if ($useExisting) {
            try {
                Add-PrinterDriver -Name $d.driverName -ErrorAction Stop
                Show-Success "Driver registered (inbox): $($d.driverName)"
                $driverSuccess++
            } catch {
                $warnings += "Add-PrinterDriver inbox failed for '$($d.driverName)': $($_.Exception.Message)"
                $driverFail++
            }
            continue
        }
        try {
            Add-PrinterDriver -Name $d.driverName -InfPath $storeInfPath -ErrorAction Stop
            Show-Success "Driver registered: $($d.driverName)"
            $driverSuccess++
        } catch {
            $warnings += "Add-PrinterDriver failed for '$($d.driverName)': $($_.Exception.Message)"
            $driverFail++
        }
    }
}

# ----------------------------------------------------------
# Phase B: Ports
# ----------------------------------------------------------
$portSuccess = 0; $portSkip = 0; $portFail = 0
foreach ($port in $plannedPorts) {
    if ($existingPorts.ContainsKey($port.name)) {
        Show-Skip "Port exists: $($port.name)"; $portSkip++; continue
    }
    switch ($port.portType) {
        'TCPIP' {
            if ([string]::IsNullOrWhiteSpace($port.printerHostAddress)) { $warnings += "TCPIP port missing host: $($port.name)"; $portFail++; break }
            try {
                $p = @{ Name = $port.name; PrinterHostAddress = $port.printerHostAddress; ErrorAction = 'Stop' }
                if ($port.portNumber) { $p['PortNumber'] = [int]$port.portNumber }
                Add-PrinterPort @p
                Show-Success "TCPIP port: $($port.name)"; $portSuccess++
            } catch { $warnings += "TCPIP port failed $($port.name): $($_.Exception.Message)"; $portFail++ }
        }
        'LPR' {
            if ([string]::IsNullOrWhiteSpace($port.lprHostName)) { $warnings += "LPR port missing host: $($port.name)"; $portFail++; break }
            try {
                Add-PrinterPort -Name $port.name -LprHostName $port.lprHostName -LprQueueName $port.lprQueueName -ErrorAction Stop
                Show-Success "LPR port: $($port.name)"; $portSuccess++
            } catch { $warnings += "LPR port failed $($port.name): $($_.Exception.Message)"; $portFail++ }
        }
        'Local'   { $portSkip++ }
        'WSD'     {
            # v0.21.0: WSD ports cannot be re-created via Add-PrinterPort
            # (PnP-X / WS-Discovery is required, and the source UUID is
            # rarely reproducible on the target PC). Mine the IPv4 we
            # saved at backup time (wsdResolvedHost) - falling back to
            # the referring printer's Location URL for legacy manifests -
            # and create a TCP/IP standard port (RAW 9100) in its place.
            $wsdHost = Resolve-WsdHost -PortEntry $port -PlannedPrinters $plannedPrinters
            if ([string]::IsNullOrWhiteSpace($wsdHost)) {
                $warnings += "WSD port '$($port.name)': no IPv4 resolvable, port skipped (referring printers will fail)"
                $portSkip++
                break
            }
            $rewriteName = "IP_$wsdHost"
            if ($existingPorts.ContainsKey($rewriteName)) {
                Show-Skip "WSD->TCPIP rewrite target exists: $rewriteName (reusing for $($port.name))"
                $portNameRewrites[$port.name] = $rewriteName
                $portSkip++
                break
            }
            try {
                Add-PrinterPort -Name $rewriteName -PrinterHostAddress $wsdHost -PortNumber 9100 -ErrorAction Stop
                $portNameRewrites[$port.name] = $rewriteName
                Show-Success "WSD->TCPIP rewrite: '$($port.name)' -> '$rewriteName' (host=$wsdHost, port=9100)"
                $portSuccess++
            } catch {
                $warnings += "WSD->TCPIP rewrite failed for '$($port.name)' (host=$wsdHost): $($_.Exception.Message)"
                $portFail++
            }
        }
        'Bonjour' { $warnings += "Bonjour port skipped: $($port.name)"; $portSkip++ }
        default   { $warnings += "Unsupported port type '$($port.portType)': $($port.name)"; $portSkip++ }
    }
}

# ----------------------------------------------------------
# Phase C: Printers + Set-PrintConfiguration (PrintTicket + explicit fields)
# ----------------------------------------------------------
$printerSuccess = 0; $printerSkip = 0; $printerFail = 0
$restoredPrinterNames = @()
$settingsSuccess = 0; $settingsSkip = 0; $settingsFail = 0

foreach ($p in $plannedPrinters) {
    if ($existingPrinters.ContainsKey($p.name)) {
        if ($onConflict -eq 'skip') { Show-Skip "Printer exists (skip): $($p.name)"; $printerSkip++; continue }
        try { Remove-Printer -Name $p.name -ErrorAction Stop; Show-Info "Removed (replace): $($p.name)" }
        catch { $warnings += "Replace failed for $($p.name): $($_.Exception.Message)"; $printerFail++; continue }
    }
    # v0.21.0: apply WSD->TCPIP port-name rewrite to this printer's
    # portName. If the WSD port was successfully (or pre-existently)
    # rewritten in Phase B, use the new name; otherwise the original
    # name is kept and Add-Printer will fail honestly.
    $effectivePortName = if ($portNameRewrites.ContainsKey($p.portName)) {
        $portNameRewrites[$p.portName]
    } else { $p.portName }
    if ($effectivePortName -ne $p.portName) {
        Show-Info "Printer '$($p.name)': portName '$($p.portName)' -> '$effectivePortName' (WSD->TCPIP)"
    }

    try {
        Add-Printer -Name $p.name -DriverName $p.driverName -PortName $effectivePortName -ErrorAction Stop
        Show-Success "Printer: $($p.name)"
        $printerSuccess++
        $restoredPrinterNames += $p.name

        try {
            if ($p.shared -and -not [string]::IsNullOrWhiteSpace($p.shareName)) { Set-Printer -Name $p.name -Shared $true -ShareName $p.shareName -ErrorAction Stop }
            if (-not [string]::IsNullOrWhiteSpace($p.comment))  { Set-Printer -Name $p.name -Comment $p.comment -ErrorAction SilentlyContinue }
            if (-not [string]::IsNullOrWhiteSpace($p.location)) { Set-Printer -Name $p.name -Location $p.location -ErrorAction SilentlyContinue }
        } catch { $warnings += "Set-Printer attr failed for $($p.name): $($_.Exception.Message)" }
    } catch {
        $warnings += "Add-Printer failed for $($p.name): $($_.Exception.Message)"
        $printerFail++
        continue
    }

    # Apply PrintTicketXML + explicit fields (color etc.)
    if (-not [string]::IsNullOrWhiteSpace($p.printSettingsFile)) {
        $xmlPath = Join-Path $sectionDir $p.printSettingsFile
        if (Test-Path $xmlPath) {
            try {
                $cfgObj = Import-Clixml -Path $xmlPath -ErrorAction Stop
                if (-not [string]::IsNullOrWhiteSpace($cfgObj.PrintTicketXML)) {
                    Set-PrintConfiguration -PrinterName $p.name -PrintTicketXml $cfgObj.PrintTicketXML -ErrorAction Stop
                    $settingsSuccess++
                }
                foreach ($field in @('Color','Collate','DuplexingMode','PaperSize','PaperSource','PrintQuality')) {
                    $raw = $cfgObj.$field
                    if ($null -eq $raw -or "$raw" -eq '') { continue }
                    try {
                        $val = if ($field -in @('Color','Collate')) { [System.Convert]::ToBoolean($raw) } else { "$raw" }
                        $params = @{ PrinterName = $p.name; $field = $val; ErrorAction = 'Stop' }
                        Set-PrintConfiguration @params
                    } catch { $warnings += "Set-PrintConfiguration -$field failed for $($p.name): $($_.Exception.Message)" }
                }
            } catch { $warnings += "Set-PrintConfiguration failed for $($p.name): $($_.Exception.Message)"; $settingsFail++ }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($p.propertiesFile)) {
        $propPath = Join-Path $sectionDir $p.propertiesFile
        if (Test-Path $propPath) {
            try {
                $props = Get-Content -Path $propPath -Raw | ConvertFrom-Json
                foreach ($prop in @($props)) {
                    if ([string]::IsNullOrWhiteSpace($prop.PropertyName)) { continue }
                    try { Set-PrinterProperty -PrinterName $p.name -PropertyName $prop.PropertyName -Value $prop.Value -ErrorAction Stop } catch { }
                }
            } catch { }
        }
    }
}

# ----------------------------------------------------------
# Phase D: Spooler restart (if hw config will be restored)
# ----------------------------------------------------------
$hwConfigRestoredCount = 0
$anyHwConfigPlanned = $restoreHardwareConfig -and @($plannedPrinters | Where-Object { -not [string]::IsNullOrWhiteSpace($_.hwConfigFile) }).Count -gt 0
$anyDevModePlanned  = @($plannedPrinters | Where-Object { -not [string]::IsNullOrWhiteSpace($_.devModeFile) }).Count -gt 0

if ($anyHwConfigPlanned -or $anyDevModePlanned) {
    Show-Info "Restarting Spooler before HW config / DEVMODE writes..."
    try {
        Restart-Service -Name Spooler -Force -ErrorAction Stop
        Start-Sleep -Seconds 2
        Show-Success "Spooler restarted"
    } catch { $warnings += "Spooler restart failed: $($_.Exception.Message)" }
}

# Pass 2 (after Spooler restart): HKLM hwconfig + HKCU DevModePerUser
$hkcuInfo = Resolve-HkcuRoot
if ($hkcuInfo.Redirected) { Show-Info "Per-user DEVMODE target: $($hkcuInfo.Label) [SID=$($hkcuInfo.SID)]" }
$devModeKey = $hkcuInfo.PsDrivePath + '\Printers\DevModePerUser'

foreach ($p in $plannedPrinters) {
    if ($p.name -notin $restoredPrinterNames -and -not $existingPrinters.ContainsKey($p.name)) { continue }

    # HKLM PrinterDriverData
    if ($restoreHardwareConfig -and -not [string]::IsNullOrWhiteSpace($p.hwConfigFile)) {
        $hwConfigPath = Join-Path $sectionDir $p.hwConfigFile
        if (Test-Path $hwConfigPath) {
            $hwRegPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Printers\$($p.name)\PrinterDriverData"
            try {
                $hwDump = Get-Content -Path $hwConfigPath -Raw | ConvertFrom-Json
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
                    } catch { $warnings += "HwConfig value '$vname' on '$($p.name)' failed: $($_.Exception.Message)" }
                }
                if ($restoredValues -gt 0) {
                    Show-Success "HW config restored: $($p.name) ($restoredValues values)"
                    $hwConfigRestoredCount++
                }
            } catch { $warnings += "HwConfig restore failed for '$($p.name)': $($_.Exception.Message)" }
        }
    }

    # HKCU DevModePerUser
    if (-not [string]::IsNullOrWhiteSpace($p.devModeFile)) {
        $devModePath = Join-Path $sectionDir $p.devModeFile
        if (Test-Path $devModePath) {
            try {
                $b64 = (Get-Content -Path $devModePath -Raw -ErrorAction Stop).Trim()
                if (-not [string]::IsNullOrWhiteSpace($b64)) {
                    $blob = [Convert]::FromBase64String($b64)
                    if (-not (Test-Path $devModeKey)) { $null = New-Item -Path $devModeKey -Force -ErrorAction Stop }
                    $null = New-ItemProperty -Path $devModeKey -Name $p.name -Value $blob -PropertyType Binary -Force -ErrorAction Stop
                    Show-Success "DEVMODE restored: $($p.name)"
                }
            } catch { $warnings += "DEVMODE restore failed for '$($p.name)': $($_.Exception.Message)" }
        }
    }
}

# ----------------------------------------------------------
# Phase E: Default printer
# ----------------------------------------------------------
if ($restoreDefaultPrinter -and -not [string]::IsNullOrWhiteSpace($manifest.defaultPrinter)) {
    $defName = $manifest.defaultPrinter
    $wasPlanned = @($plannedPrinters | Where-Object { $_.name -eq $defName }).Count -gt 0
    if ($wasPlanned) {
        $defExists = $null -ne (Get-Printer -Name $defName -ErrorAction SilentlyContinue)
        if ($defExists) {
            try {
                $shell = New-Object -ComObject WScript.Network
                $shell.SetDefaultPrinter($defName)
                Show-Success "Default printer set: $defName"
            } catch { $warnings += "SetDefaultPrinter failed: $($_.Exception.Message)" }
        }
    }
}

$sw.Stop()

$status = 'Success'
if ($printerFail -gt 0 -or $driverFail -gt 0) { $status = 'Partial' }
if ($printerSuccess -eq 0 -and $printerFail -gt 0) { $status = 'Failed' }

return [PSCustomObject]@{
    Status   = $status
    ElapsedMs = [int]$sw.ElapsedMilliseconds
    Summary  = [ordered]@{
        driverSuccess = $driverSuccess; driverSkip = $driverSkip; driverFail = $driverFail
        portSuccess   = $portSuccess;   portSkip   = $portSkip;   portFail   = $portFail
        printerSuccess = $printerSuccess; printerSkip = $printerSkip; printerFail = $printerFail
        settingsSuccess = $settingsSuccess; settingsFail = $settingsFail
        hwConfigRestored = $hwConfigRestoredCount
        skippedRdp = $skippedRdp; skippedVirtual = $skippedVirtual; skippedFilter = $skippedFilter
        wsdRewrites = $portNameRewrites.Count
    }
    Warnings = $warnings
}
