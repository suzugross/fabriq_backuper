# ============================================================
# FabriqBackUper Section: printer / backup (Phase 2.2.1, internalized)
#
# Independent printer backup engine. Mirrors the manifest schema
# (fabriq-printer-backup schemaVersion=1) used by the legacy
# modules/extended/printer_backup/ but lives entirely within
# FabriqBackUper. No dependency on modules/.
#
# SectionParams (hashtable, all optional):
#   IncludePrinters       : array of printer Name strings; null/empty = all
#   IncludeDriverBinaries : bool (default $true) - pnputil /export-driver
#   IncludePrintSettings  : bool (default $true) - PrintConfiguration + DEVMODE
#   RestoreHardwareConfig : (unused on backup side; backup always captures)
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
$includePrinters = $null
if ($SectionParams.ContainsKey('IncludePrinters') -and `
    $null -ne $SectionParams['IncludePrinters'] -and `
    @($SectionParams['IncludePrinters']).Count -gt 0) {
    $includePrinters = @($SectionParams['IncludePrinters'])
}
$includeDriverBinaries = $true
if ($SectionParams.ContainsKey('IncludeDriverBinaries')) {
    $includeDriverBinaries = [bool]$SectionParams['IncludeDriverBinaries']
}
$includePrintSettings = $true
if ($SectionParams.ContainsKey('IncludePrintSettings')) {
    $includePrintSettings = [bool]$SectionParams['IncludePrintSettings']
}

# ----------------------------------------------------------
# Prerequisites
# ----------------------------------------------------------
if (-not (Test-AdminPrivilege)) {
    return [PSCustomObject]@{
        Status               = 'Failed'
        ElapsedMs            = [int]$sw.ElapsedMilliseconds
        Summary              = [ordered]@{}
        Warnings             = @('Administrator privileges required')
        ExternalOutputDir    = $null
        ExternalManifestPath = $null
    }
}
try {
    $spooler = Get-Service -Name Spooler -ErrorAction Stop
    if ($spooler.Status -ne 'Running') {
        return [PSCustomObject]@{
            Status               = 'Failed'
            ElapsedMs            = [int]$sw.ElapsedMilliseconds
            Summary              = [ordered]@{}
            Warnings             = @("Print Spooler not running (Status: $($spooler.Status))")
            ExternalOutputDir    = $null
            ExternalManifestPath = $null
        }
    }
} catch {
    return [PSCustomObject]@{
        Status               = 'Failed'
        ElapsedMs            = [int]$sw.ElapsedMilliseconds
        Summary              = [ordered]@{}
        Warnings             = @("Spooler check failed: $($_.Exception.Message)")
        ExternalOutputDir    = $null
        ExternalManifestPath = $null
    }
}

# ----------------------------------------------------------
# Prepare section output directory
# ----------------------------------------------------------
$sectionDir = Join-Path $AggregateBackupDir 'sections\printer'
try {
    $null = New-Item -ItemType Directory -Path $sectionDir -Force -ErrorAction Stop
}
catch {
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
# Enumerate printers / ports / drivers
# ----------------------------------------------------------
$allPrinters = @()
try { $allPrinters = @(Get-Printer -ErrorAction Stop) }
catch {
    return [PSCustomObject]@{
        Status               = 'Failed'
        ElapsedMs            = [int]$sw.ElapsedMilliseconds
        Summary              = [ordered]@{}
        Warnings             = @("Get-Printer failed: $($_.Exception.Message)")
        ExternalOutputDir    = $null
        ExternalManifestPath = $null
    }
}

# Apply IncludePrinters filter
$printers = if ($null -ne $includePrinters) {
    @($allPrinters | Where-Object { $_.Name -in $includePrinters })
} else {
    $allPrinters
}

if ($printers.Count -eq 0) {
    return [PSCustomObject]@{
        Status               = 'Skipped'
        ElapsedMs            = [int]$sw.ElapsedMilliseconds
        Summary              = [ordered]@{ printerCount = 0; note = 'no printers selected or found' }
        Warnings             = @()
        ExternalOutputDir    = $null
        ExternalManifestPath = $null
    }
}

Show-Info "Backing up $($printers.Count) printer(s) (selected from $($allPrinters.Count) total)"

$ports = @()
try { $ports = @(Get-PrinterPort -ErrorAction Stop) } catch { $warnings += "Get-PrinterPort failed: $_" }

$printerDrivers = @()
try { $printerDrivers = @(Get-PrinterDriver -ErrorAction Stop) } catch { $warnings += "Get-PrinterDriver failed: $_" }

$thirdPartyInfs = @()
try {
    $thirdPartyInfs = @(Get-WindowsDriver -Online -ErrorAction Stop |
                       Where-Object { $_.ClassName -eq 'Printer' })
} catch { $warnings += "Get-WindowsDriver failed: $_" }

# basename map for inbox/third-party discrimination
$basenameToOem = @{}
foreach ($wd in $thirdPartyInfs) {
    $orig = $wd.OriginalFileName
    if (-not [string]::IsNullOrWhiteSpace($orig)) {
        $bn = [System.IO.Path]::GetFileNameWithoutExtension($orig).ToLower()
        if (-not $basenameToOem.ContainsKey($bn)) {
            $basenameToOem[$bn] = $wd
        }
    }
}

# Filter drivers to only those used by SELECTED printers (so we don't
# export payloads for printers we're skipping).
$usedDriverNames = @($printers | ForEach-Object { $_.DriverName } | Sort-Object -Unique)
$relevantDrivers = @($printerDrivers | Where-Object { $_.Name -in $usedDriverNames })

# Drivers info + 3rd-party payload export plan
$driverInfoList = @()
$infPackagesToExport = @{}
foreach ($pd in $relevantDrivers) {
    $bn = if ($pd.InfPath) { [System.IO.Path]::GetFileNameWithoutExtension($pd.InfPath).ToLower() } else { $null }
    $isThird = ($null -ne $bn) -and $basenameToOem.ContainsKey($bn)
    $oemInf = $null
    if ($isThird) {
        $wd = $basenameToOem[$bn]
        $oemInf = $wd.Driver
        if ($includeDriverBinaries -and -not $infPackagesToExport.ContainsKey($oemInf)) {
            $infPackagesToExport[$oemInf] = $wd
        }
    }
    $driverInfoList += [PSCustomObject]@{
        DriverName    = $pd.Name
        Manufacturer  = $pd.Manufacturer
        DriverVersion = $pd.DriverVersion
        InfPath       = $pd.InfPath
        InfBaseName   = $bn
        OemInf        = $oemInf
        IsInboxDriver = -not $isThird
    }
}

# ----------------------------------------------------------
# Helpers (port from module)
# ----------------------------------------------------------
function Write-JsonArray {
    param([Parameter(Mandatory = $true)][string]$Path, $Data)
    $json = ConvertTo-Json -InputObject @($Data) -Depth 6
    $json | Out-File -FilePath $Path -Encoding UTF8 -Force
}
function Get-PortType {
    param($Port)
    $monitor = $Port.PortMonitor
    if ([string]::IsNullOrEmpty($monitor)) { return 'Other' }
    $m = $monitor.ToLower()
    if ($m -like 'tcpmon*')   { return 'TCPIP' }
    if ($m -like 'lprmon*' -or $m -like 'lpr*') { return 'LPR' }
    if ($m -like 'wsd*')      { return 'WSD' }
    if ($m -like 'localmon*' -or $m -like 'local*') { return 'Local' }
    if ($m -like '*bonjour*' -or $m -like '*mdns*') { return 'Bonjour' }
    return 'Other'
}
function Get-SafeFileName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return "unnamed" }
    return ($Name -replace '[^\w\-]', '_')
}

# ----------------------------------------------------------
# Write printers.json
# ----------------------------------------------------------
try {
    $printerRows = $printers | Select-Object Name, DriverName, PortName, Shared, ShareName, Comment, Location, Published, KeepPrintedJobs
    Write-JsonArray -Path (Join-Path $sectionDir 'printers.json') -Data $printerRows
    Show-Success "printers.json written"
} catch { $warnings += "Failed to write printers.json: $_" }

# Ports referenced by selected printers
$relevantPortNames = @($printers | ForEach-Object { $_.PortName } | Sort-Object -Unique)
$relevantPorts = @($ports | Where-Object { $_.Name -in $relevantPortNames })

try {
    $portRows = foreach ($p in $relevantPorts) {
        [PSCustomObject]@{
            Name               = $p.Name
            PortType           = Get-PortType -Port $p
            Description        = $p.Description
            PortMonitor        = $p.PortMonitor
            PrinterHostAddress = $p.PrinterHostAddress
            PortNumber         = $p.PortNumber
            LprHostName        = $p.LprHostName
            LprQueueName       = $p.LprQueueName
            SnmpEnabled        = [bool]$p.SnmpEnabled
            SnmpCommunity      = $p.SnmpCommunity
        }
    }
    Write-JsonArray -Path (Join-Path $sectionDir 'ports.json') -Data $portRows
    Show-Success "ports.json written"
    foreach ($w in @($portRows | Where-Object { $_.PortType -eq 'WSD' })) {
        $warnings += "WSD port '$($w.Name)': dynamic discovery dependent, restore not guaranteed"
    }
} catch { $warnings += "Failed to write ports.json: $_" }

try {
    Write-JsonArray -Path (Join-Path $sectionDir 'drivers_registered.json') -Data $driverInfoList
    Show-Success "drivers_registered.json written"
} catch { $warnings += "Failed to write drivers_registered.json: $_" }

try {
    $invRows = foreach ($wd in $thirdPartyInfs) {
        [PSCustomObject]@{
            Driver           = $wd.Driver
            OriginalFileName = $wd.OriginalFileName
            ClassName        = $wd.ClassName
            ProviderName     = $wd.ProviderName
            Date             = if ($wd.Date) { $wd.Date.ToString("o") } else { $null }
            Version          = $wd.Version
            Inbox            = [bool]$wd.Inbox
        }
    }
    Write-JsonArray -Path (Join-Path $sectionDir 'drivers_inf_inventory.json') -Data $invRows
    Show-Success "drivers_inf_inventory.json written"
} catch { $warnings += "Failed to write drivers_inf_inventory.json: $_" }

# ----------------------------------------------------------
# Per-printer print settings (PrintConfiguration / DEVMODE / hwconfig)
# ----------------------------------------------------------
$printSettingsRefs = @{}

if ($includePrintSettings) {
    Show-Info "Capturing per-printer print settings..."
    $settingsDir = Join-Path $sectionDir 'printsettings'
    $null = New-Item -ItemType Directory -Path $settingsDir -Force -ErrorAction SilentlyContinue

    # Resolve HKCU hive once (handles UAC redirect / SYSTEM context)
    $hkcuInfo = Resolve-HkcuRoot
    if ($hkcuInfo.Redirected) {
        Show-Info "Per-user DEVMODE source: $($hkcuInfo.Label) [SID=$($hkcuInfo.SID)]"
    }
    $devModeKey = $hkcuInfo.PsDrivePath + '\Printers\DevModePerUser'

    $usedNames = @{}

    foreach ($p in $printers) {
        $safe = Get-SafeFileName -Name $p.Name
        if ($usedNames.ContainsKey($safe)) {
            $usedNames[$safe]++
            $safe = "${safe}_$($usedNames[$safe])"
        } else {
            $usedNames[$safe] = 1
        }

        $xmlFile      = "printsettings/${safe}.xml"
        $propFile     = "printsettings/${safe}.properties.json"
        $devModeFile  = "printsettings/${safe}.devmode.b64"
        $hwConfigFile = "printsettings/${safe}.hwconfig.json"
        $xmlPath      = Join-Path $sectionDir $xmlFile
        $propPath     = Join-Path $sectionDir $propFile
        $devModePath  = Join-Path $sectionDir $devModeFile
        $hwConfigPath = Join-Path $sectionDir $hwConfigFile

        $xmlOk      = $false
        $propOk     = $false
        $devModeOk  = $false
        $hwConfigOk = $false

        try {
            $config = Get-PrintConfiguration -PrinterName $p.Name -ErrorAction Stop
            $config | Export-Clixml -Path $xmlPath -Force -ErrorAction Stop
            $xmlOk = $true
        } catch { $warnings += "PrintConfiguration capture failed for '$($p.Name)': $($_.Exception.Message)" }

        try {
            $props = Get-PrinterProperty -PrinterName $p.Name -ErrorAction Stop
            $propRows = $props | Select-Object PrinterName, PropertyName, Type, Value
            Write-JsonArray -Path $propPath -Data $propRows
            $propOk = $true
        } catch { $warnings += "PrinterProperty capture failed for '$($p.Name)': $($_.Exception.Message)" }

        # Per-user DEVMODE blob from HKCU
        try {
            if (Test-Path $devModeKey) {
                $itemProp = Get-ItemProperty -Path $devModeKey -Name $p.Name -ErrorAction SilentlyContinue
                if ($null -ne $itemProp) {
                    $blob = $itemProp.$($p.Name)
                    if ($null -ne $blob -and $blob -is [byte[]] -and $blob.Length -gt 0) {
                        $b64 = [Convert]::ToBase64String($blob)
                        $b64 | Out-File -FilePath $devModePath -Encoding ASCII -Force -ErrorAction Stop
                        $devModeOk = $true
                    }
                }
            }
        } catch { $warnings += "DEVMODE capture failed for '$($p.Name)': $($_.Exception.Message)" }

        # HKLM PrinterDriverData (installable options)
        try {
            $hwRegPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Printers\$($p.Name)\PrinterDriverData"
            if (Test-Path $hwRegPath) {
                $key = Get-Item -Path $hwRegPath -ErrorAction Stop
                $hwDump = [ordered]@{}
                foreach ($vname in $key.GetValueNames()) {
                    $vtype = $key.GetValueKind($vname).ToString()
                    $vdata = $key.GetValue($vname)
                    $encoded = switch ($vtype) {
                        'Binary'       { if ($null -ne $vdata) { [Convert]::ToBase64String([byte[]]$vdata) } else { $null } }
                        'String'       { [string]$vdata }
                        'ExpandString' { [string]$vdata }
                        'MultiString'  { @($vdata) }
                        'DWord'        { [int]$vdata }
                        'QWord'        { [long]$vdata }
                        default        { "$vdata" }
                    }
                    $hwDump[$vname] = [ordered]@{ Type = $vtype; Data = $encoded }
                }
                $hwDump | ConvertTo-Json -Depth 4 | Out-File -FilePath $hwConfigPath -Encoding UTF8 -Force
                $hwConfigOk = $true
            }
        } catch { $warnings += "HwConfig capture failed for '$($p.Name)': $($_.Exception.Message)" }

        $printSettingsRefs[$p.Name] = @{
            XmlFile      = if ($xmlOk)      { $xmlFile }      else { $null }
            PropFile     = if ($propOk)     { $propFile }     else { $null }
            DevModeFile  = if ($devModeOk)  { $devModeFile }  else { $null }
            HwConfigFile = if ($hwConfigOk) { $hwConfigFile } else { $null }
        }
    }

    Show-Success "Print settings captured for $($printSettingsRefs.Count) printer(s)"
}

# ----------------------------------------------------------
# Driver payload export
# ----------------------------------------------------------
$exportedDrivers = @{}
if ($includeDriverBinaries -and $infPackagesToExport.Count -gt 0) {
    Show-Info "Exporting driver packages with pnputil..."
    $driversDir = Join-Path $sectionDir 'drivers'
    $null = New-Item -ItemType Directory -Path $driversDir -Force -ErrorAction SilentlyContinue

    foreach ($oemInf in @($infPackagesToExport.Keys)) {
        $outDir = Join-Path $driversDir $oemInf
        try {
            $null = New-Item -ItemType Directory -Path $outDir -Force -ErrorAction Stop
        } catch {
            $warnings += "Driver dir creation failed for ${oemInf}: $($_.Exception.Message)"
            continue
        }
        Show-Info "  Exporting: $oemInf"
        $null = & pnputil /export-driver $oemInf $outDir 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            $size = (Get-ChildItem -Path $outDir -Recurse -File -ErrorAction SilentlyContinue |
                     Measure-Object -Property Length -Sum).Sum
            if ($null -eq $size) { $size = 0 }
            $exportedDrivers[$oemInf] = @{ Folder = "drivers/$oemInf"; SizeBytes = [long]$size }
            Show-Success "    Exported $oemInf ($([math]::Round($size/1MB,1)) MB)"
        } else {
            $warnings += "pnputil failed for ${oemInf} (exit ${exitCode})"
        }
    }
}

foreach ($d in $driverInfoList) {
    if ($d.IsInboxDriver) {
        $warnings += "Driver '$($d.DriverName)': inbox driver, payload not exported (Windows-supplied)"
    }
}

# ----------------------------------------------------------
# Default printer
# ----------------------------------------------------------
$defaultPrinter = $null
try {
    $defaultPrinter = (Get-CimInstance -ClassName Win32_Printer -Filter "Default=$true" -ErrorAction Stop |
                       Select-Object -First 1).Name
} catch { }

# ----------------------------------------------------------
# Build manifest (fabriq-printer-backup schemaVersion=1)
# ----------------------------------------------------------
$hwUid = $null
try {
    $hwUid = (Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop |
              Select-Object -First 1).UUID
} catch { }

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

$manifestPrinters = foreach ($p in $printers) {
    $ref = $printSettingsRefs[$p.Name]
    $matchedDriver = @($driverInfoList | Where-Object { $_.DriverName -eq $p.DriverName }) | Select-Object -First 1
    [PSCustomObject]@{
        name              = $p.Name
        driverName        = $p.DriverName
        portName          = $p.PortName
        shared            = [bool]$p.Shared
        shareName         = $p.ShareName
        comment           = $p.Comment
        location          = $p.Location
        published         = [bool]$p.Published
        isInboxDriver     = if ($matchedDriver) { [bool]$matchedDriver.IsInboxDriver } else { $false }
        printSettingsFile = if ($ref) { $ref.XmlFile      } else { $null }
        propertiesFile    = if ($ref) { $ref.PropFile     } else { $null }
        devModeFile       = if ($ref) { $ref.DevModeFile  } else { $null }
        hwConfigFile      = if ($ref) { $ref.HwConfigFile } else { $null }
    }
}
$manifestPorts = foreach ($p in $relevantPorts) {
    [PSCustomObject]@{
        name               = $p.Name
        portType           = Get-PortType -Port $p
        printerHostAddress = $p.PrinterHostAddress
        portNumber         = $p.PortNumber
        lprHostName        = $p.LprHostName
        lprQueueName       = $p.LprQueueName
        snmpEnabled        = [bool]$p.SnmpEnabled
        snmpCommunity      = $p.SnmpCommunity
        portMonitor        = $p.PortMonitor
    }
}
$manifestDrivers = foreach ($d in $driverInfoList) {
    $payload = if ($d.OemInf -and $exportedDrivers.ContainsKey($d.OemInf)) { $exportedDrivers[$d.OemInf] } else { $null }
    [PSCustomObject]@{
        driverName    = $d.DriverName
        manufacturer  = $d.Manufacturer
        driverVersion = $d.DriverVersion
        infBaseName   = $d.InfBaseName
        infOemFile    = $d.OemInf
        isInboxDriver = $d.IsInboxDriver
        backupFolder  = if ($payload) { $payload.Folder } else { $null }
    }
}

$driverBytes = 0
foreach ($v in $exportedDrivers.Values) { $driverBytes += $v.SizeBytes }

$manifest = [ordered]@{
    schemaVersion       = 1
    manifestType        = "fabriq-printer-backup"
    backupVersion       = $moduleVersion
    fabriqKernelVersion = $kernelVersion
    collectedAt         = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
    computerName        = $OldPcName
    hardwareUniqueId    = $hwUid
    osVersion           = $osVersion
    osArch              = $osArch
    defaultPrinter      = $defaultPrinter
    counts              = [ordered]@{
        printer          = @($manifestPrinters).Count
        port             = @($manifestPorts).Count
        driverRegistered = @($manifestDrivers).Count
        infPackage       = @($exportedDrivers.Keys).Count
    }
    sizes               = [ordered]@{
        totalBytes  = 0
        driverBytes = [long]$driverBytes
    }
    includes            = [ordered]@{
        driverBinaries = $includeDriverBinaries
        printSettings  = $includePrintSettings
    }
    items               = [ordered]@{
        printers = @($manifestPrinters)
        ports    = @($manifestPorts)
        drivers  = @($manifestDrivers)
    }
    warnings            = @($warnings)
}

$manifestPath = Join-Path $sectionDir 'manifest.json'
$manifest | ConvertTo-Json -Depth 8 | Out-File -FilePath $manifestPath -Encoding UTF8 -Force

# Patch totalBytes
$totalBytes = (Get-ChildItem -Path $sectionDir -Recurse -File -ErrorAction SilentlyContinue |
               Measure-Object -Property Length -Sum).Sum
if ($null -eq $totalBytes) { $totalBytes = 0 }
$manifest.sizes.totalBytes = [long]$totalBytes
$manifest | ConvertTo-Json -Depth 8 | Out-File -FilePath $manifestPath -Encoding UTF8 -Force

$sw.Stop()

$summary = [ordered]@{
    printerCount     = $printers.Count
    portCount        = $manifestPorts.Count
    driverRegistered = $manifestDrivers.Count
    infPackage       = $exportedDrivers.Count
    totalBytes       = [long]$totalBytes
}

# Status: Success unless any failures recorded as warnings
$status = if ($warnings.Count -gt 0) { 'Partial' } else { 'Success' }
# But if no manifest written or 0 printers, Failed/Skipped
if (-not (Test-Path $manifestPath)) { $status = 'Failed' }

return [PSCustomObject]@{
    Status               = $status
    ElapsedMs            = [int]$sw.ElapsedMilliseconds
    Summary              = $summary
    Warnings             = $warnings
    ExternalOutputDir    = $null
    ExternalManifestPath = $null
    InternalSectionDir   = $sectionDir
    InternalManifestPath = $manifestPath
}
