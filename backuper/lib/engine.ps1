# ============================================================
# FabriqBackUper - Engine (Orchestrator)
# Drives section backup/restore in sequence, collects results,
# writes the aggregate manifest.
# ============================================================

function Get-RegisteredSections {
    param([Parameter(Mandatory = $true)][string]$BackuperRoot)
    $csvPath = Join-Path $BackuperRoot 'data\sections.csv'
    if (-not (Test-Path $csvPath)) {
        Show-Error "sections.csv not found: $csvPath"
        return @()
    }
    $sections = Import-Csv -Path $csvPath
    return @($sections)
}

function Invoke-SectionScript {
    param(
        [Parameter(Mandatory = $true)][string]$SectionName,
        [Parameter(Mandatory = $true)][string]$ScriptName,
        [Parameter(Mandatory = $true)][string]$BackuperRoot,
        [Parameter(Mandatory = $true)][string]$FabriqRoot,
        [Parameter(Mandatory = $true)][string]$OldPcName,
        [Parameter(Mandatory = $true)][string]$AggregateBackupDir,
        [hashtable]$SectionParams = @{}
    )

    $scriptPath = Join-Path $BackuperRoot "lib\sections\$SectionName\$ScriptName"
    if (-not (Test-Path $scriptPath)) {
        Show-Error "Section script not found: $scriptPath"
        return [PSCustomObject]@{
            Status = 'Failed'
            ElapsedMs = 0
            Summary = [ordered]@{}
            Warnings = @("Script not found: $scriptPath")
            ExternalOutputDir = $null
            ExternalManifestPath = $null
        }
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " Section: $SectionName  ($ScriptName)" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $result = $null
    try {
        # Set environment so the wrapped module gets the same OldPCname
        $env:SELECTED_OLD_PCNAME = $OldPcName

        $result = & $scriptPath `
            -BackuperRoot $BackuperRoot `
            -FabriqRoot   $FabriqRoot `
            -OldPcName    $OldPcName `
            -AggregateBackupDir $AggregateBackupDir `
            -SectionParams $SectionParams
    }
    catch {
        Show-Error "Section '$SectionName' threw: $($_.Exception.Message)"
        $sw.Stop()
        return [PSCustomObject]@{
            Status = 'Failed'
            ElapsedMs = [int]$sw.ElapsedMilliseconds
            Summary = [ordered]@{}
            Warnings = @("Exception: $($_.Exception.Message)")
            ExternalOutputDir = $null
            ExternalManifestPath = $null
        }
    }
    $sw.Stop()

    if ($null -eq $result) {
        return [PSCustomObject]@{
            Status = 'Failed'
            ElapsedMs = [int]$sw.ElapsedMilliseconds
            Summary = [ordered]@{}
            Warnings = @("Section returned null")
            ExternalOutputDir = $null
            ExternalManifestPath = $null
        }
    }

    # Normalize fields the engine expects
    return [PSCustomObject]@{
        Status               = if ($result.Status)               { $result.Status }               else { 'Success' }
        ElapsedMs            = if ($result.ElapsedMs)             { [int]$result.ElapsedMs }       else { [int]$sw.ElapsedMilliseconds }
        Summary              = if ($result.Summary)               { $result.Summary }              else { [ordered]@{} }
        Warnings             = if ($result.Warnings)              { @($result.Warnings) }          else { @() }
        ExternalOutputDir    = if ($result.ExternalOutputDir)     { $result.ExternalOutputDir }    else { $null }
        ExternalManifestPath = if ($result.ExternalManifestPath)  { $result.ExternalManifestPath } else { $null }
    }
}

# ============================================================
# UI-agnostic core orchestrators (Phase 2.1+).
# These take pre-selected parameters and run the backup / restore
# without prompting the user. The GUI (or the legacy console
# orchestrator below) is responsible for collecting selections.
# ============================================================

function Set-SelectedHostEnvVars {
    param([Parameter(Mandatory = $true)]$SelectedHost)
    $env:SELECTED_OLD_PCNAME = $SelectedHost.OldPCname
    foreach ($field in @('NewPCname','EthIp','EthSubnet','EthGateway','Dns1','Dns2','KanriNo')) {
        if ($SelectedHost.PSObject.Properties.Name -contains $field) {
            $val = $SelectedHost.$field
            $envName = "SELECTED_$($field.ToUpper())"
            if ($field -eq 'NewPCname')  { $envName = 'SELECTED_NEW_PCNAME' }
            if ($field -eq 'EthIp')      { $envName = 'SELECTED_ETH_IP' }
            if ($field -eq 'EthSubnet')  { $envName = 'SELECTED_ETH_SUBNET' }
            if ($field -eq 'EthGateway') { $envName = 'SELECTED_ETH_GATEWAY' }
            if ($field -eq 'Dns1')       { $envName = 'SELECTED_DNS1' }
            if ($field -eq 'Dns2')       { $envName = 'SELECTED_DNS2' }
            if ($field -eq 'KanriNo')    { $envName = 'SELECTED_KANRI_NO' }
            if (-not [string]::IsNullOrWhiteSpace($val)) {
                Set-Item -Path "Env:$envName" -Value $val
            }
        }
    }
}

function Get-BackupTimestamps {
    # v0.27.0: now returns objects with Name + FullPath + Source so the
    # restore UI can resolve a chosen timestamp to its actual aggregate
    # directory (which may live on the local disk, a local SMB share, or
    # a UNC mount). Multi-root search is driven by AdditionalRoots so the
    # migration_profile (backuper.backupRootUnc / share.localPath) can
    # contribute candidates without the engine knowing about the profile.
    #
    # Search roots (in priority order, highest first):
    #   1. Local : <BackuperRoot>\Backup\<OldPcName>             (Source='Local')
    #   2..N    : <each AdditionalRoot>\<OldPcName>              (Source='ShareLocal' for local-style paths,
    #                                                              Source='UNC' for paths starting with \\)
    #
    # Same Name (= same timestamp folder name) across multiple roots is
    # de-duplicated by keeping the FIRST occurrence (= highest-priority root).
    # Within a single Name, results are ordered by Name descending so the
    # newest timestamp is on top.
    param(
        [Parameter(Mandatory = $true)][string]$BackuperRoot,
        [Parameter(Mandatory = $true)][string]$OldPcName,
        [string[]]$AdditionalRoots = @()
    )

    function Get-RootSource {
        param([string]$RootPath)
        if ([string]::IsNullOrWhiteSpace($RootPath)) { return 'Unknown' }
        if ($RootPath -match '^\\\\') { return 'UNC' }
        return 'ShareLocal'
    }

    $rootsOrdered = @()
    $rootsOrdered += @{ Root = (Join-Path $BackuperRoot 'Backup'); Source = 'Local' }
    foreach ($ar in $AdditionalRoots) {
        if (-not [string]::IsNullOrWhiteSpace($ar)) {
            $rootsOrdered += @{ Root = $ar; Source = (Get-RootSource $ar) }
        }
    }

    $seen = @{}
    $entries = @()
    foreach ($rootInfo in $rootsOrdered) {
        $hostBackupRoot = Join-Path $rootInfo.Root $OldPcName
        if (-not (Test-Path -LiteralPath $hostBackupRoot)) { continue }
        try {
            $dirs = @(Get-ChildItem -LiteralPath $hostBackupRoot -Directory -ErrorAction SilentlyContinue)
        } catch {
            continue
        }
        foreach ($d in $dirs) {
            if ($seen.ContainsKey($d.Name)) { continue }
            $seen[$d.Name] = $true
            $entries += [PSCustomObject]@{
                Name     = $d.Name
                FullPath = $d.FullName
                Source   = $rootInfo.Source
            }
        }
    }

    return @($entries | Sort-Object -Property @{Expression='Name'; Descending=$true})
}

function Invoke-BackuperBackupCore {
    param(
        [Parameter(Mandatory = $true)]$SelectedHost,
        [Parameter(Mandatory = $true)][array]$PickedSections,
        [Parameter(Mandatory = $true)][string]$BackuperRoot,
        [Parameter(Mandatory = $true)][string]$FabriqRoot,
        [Parameter(Mandatory = $true)][string]$BackuperVersion,
        # SectionParams: dict keyed by section name -> hashtable of section-
        # specific parameters. Sections that don't recognize their key just
        # receive an empty hashtable.
        [hashtable]$SectionParamsBySection = @{},
        # Phase 2.4: backup destination root. If empty/null, defaults to
        # $BackuperRoot\Backup. Can be UNC (e.g. \\server\share\backups).
        # Caller is responsible for UNC credential prep before invoking.
        [string]$DestinationRoot = $null,
        # v0.56.0 (t-0003): when set to an EXISTING aggregate dir, this is a RETRY
        # run -- re-run only the (failed) PickedSections INTO that dir and MERGE
        # the results into its existing manifest, instead of creating a new
        # timestamped dir. Null/empty = normal full backup (new timestamp dir).
        [string]$RetryIntoAggregateDir = $null
    )

    Set-SelectedHostEnvVars -SelectedHost $SelectedHost

    $timestamp = Get-Date -Format "yyyy_MM_dd_HHmmss"
    $rootDir = if ([string]::IsNullOrWhiteSpace($DestinationRoot)) {
        Join-Path $BackuperRoot 'Backup'
    } else {
        $DestinationRoot
    }
    # v0.56.0 (t-0003): retry mode reuses the original aggregate dir (keeping its
    # timestamp) so the merged result stays ONE backup; normal mode creates a new
    # timestamped dir.
    $isRetry = (-not [string]::IsNullOrWhiteSpace($RetryIntoAggregateDir)) -and `
               (Test-Path -LiteralPath $RetryIntoAggregateDir)
    if ($isRetry) {
        $aggregateDir = $RetryIntoAggregateDir
    }
    else {
        $aggregateDir = Join-Path (Join-Path $rootDir $SelectedHost.OldPCname) $timestamp
        try {
            $null = New-Item -ItemType Directory -Path $aggregateDir -Force -ErrorAction Stop
        }
        catch {
            return [PSCustomObject]@{
                Status = 'Failed'
                Message = "Failed to create aggregate dir: $($_.Exception.Message)"
                AggregateDir = $null
                SectionResults = @{}
                ManifestPath = $null
            }
        }
    }

    # v0.34.0: best-effort cleanup marker so this backup tree can later be
    # bulk-deleted from the Cleanup view. (It is also recognisable via its
    # manifest.json, but the marker carries placedByHost / newPcName.)
    # v0.56.0: skip on retry -- the marker already exists from the original run.
    if (-not $isRetry) {
        $null = New-CleanupMarker -Dir $aggregateDir -ArtifactKind 'backup-tree' `
            -OldPcName $SelectedHost.OldPCname `
            -NewPcName $(if ($SelectedHost.PSObject.Properties.Name -contains 'NewPCname') { "$($SelectedHost.NewPCname)" } else { '' }) `
            -BackuperVersion $BackuperVersion
    }

    $sectionResults = @{}
    foreach ($s in $PickedSections) {
        $params = if ($SectionParamsBySection.ContainsKey($s.SectionName)) {
            $SectionParamsBySection[$s.SectionName]
        } else { @{} }
        $r = Invoke-SectionScript `
            -SectionName $s.SectionName `
            -ScriptName  'backup.ps1' `
            -BackuperRoot $BackuperRoot `
            -FabriqRoot   $FabriqRoot `
            -OldPcName    $SelectedHost.OldPCname `
            -AggregateBackupDir $aggregateDir `
            -SectionParams $params
        $sectionResults[$s.SectionName] = $r
    }

    $kernelVerFile = Join-Path $FabriqRoot 'kernel\KERNEL_VERSION'
    $kernelVer = if (Test-Path $kernelVerFile) { (Get-Content $kernelVerFile -Raw).Trim() } else { 'unknown' }

    # v0.56.0 (t-0003): on retry, MERGE the retried sections into the existing
    # manifest (keeps the original run's successful sections/entries). On a normal
    # run -- or a retry whose existing manifest is unreadable -- build fresh.
    $manifest = $null
    $retryAggMergeFailed = $false
    if ($isRetry) {
        $existingManifestPath = Join-Path $aggregateDir 'manifest.json'
        $manifest = Merge-AggregateManifest `
            -ExistingManifestPath $existingManifestPath `
            -RetriedSectionResults $sectionResults `
            -Warnings @()
        # On retry, a null merge result means the existing aggregate manifest was
        # unreadable. Do NOT rebuild from the retried sections only (that would
        # drop the original run's other sections); preserve the existing file and
        # fail loudly so the operator investigates.
        if ($null -eq $manifest) { $retryAggMergeFailed = $true }
    }
    if ($null -eq $manifest -and -not $retryAggMergeFailed) {
        $manifest = New-AggregateManifest `
            -OldPcName $SelectedHost.OldPCname `
            -BackuperVersion $BackuperVersion `
            -FabriqKernelVersion $kernelVer `
            -SectionResults $sectionResults `
            -Warnings @()
    }
    if ($retryAggMergeFailed) {
        $manifestPath = Join-Path $aggregateDir 'manifest.json'
    }
    else {
        $manifestPath = Save-AggregateManifest -OutputDir $aggregateDir -Manifest $manifest
    }

    # Execution log
    $logPath = Join-Path $aggregateDir "_execution_log.txt"
    $logLines = @(
        "Fabriq BackUper Execution Log",
        "================================",
        "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "OldPCname: $($SelectedHost.OldPCname)",
        "Computer : $env:COMPUTERNAME",
        "Mode     : Backup",
        ""
    )
    foreach ($key in $sectionResults.Keys) {
        $r = $sectionResults[$key]
        $logLines += "[$key]"
        $logLines += "  Status    : $($r.Status)"
        $logLines += "  ElapsedMs : $($r.ElapsedMs)"
        $logLines += "  External  : $($r.ExternalOutputDir)"
        if ($r.Warnings -and @($r.Warnings).Count -gt 0) {
            $logLines += "  Warnings  :"
            foreach ($w in @($r.Warnings)) { $logLines += "    - $w" }
        }
        $logLines += ""
    }
    # v0.56.0: on retry, append (keep the original run's log) instead of overwrite.
    if ($isRetry -and (Test-Path -LiteralPath $logPath)) {
        @("", "==== RETRY $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ====") + $logLines |
            Add-Content -Path $logPath -Encoding UTF8
    }
    else {
        $logLines | Out-File -FilePath $logPath -Encoding UTF8 -Force
    }

    # v0.56.0: derive overall from the (possibly merged) manifest summary so a
    # retry that fills in the last failures correctly flips Partial/Failed ->
    # Success over the WHOLE backup, not just the retried sections.
    $overall = 'Success'
    $sumFailed = 0; $sumPartial = 0
    try { $sumFailed  = [int]$manifest.summary.failedCount }  catch { }
    try { $sumPartial = [int]$manifest.summary.partialCount } catch { }
    if ($sumPartial -gt 0) { $overall = 'Partial' }
    if ($sumFailed  -gt 0) { $overall = 'Failed' }
    # v0.56.0: an unreadable existing manifest on retry is a hard failure (the
    # merged manifest was not written; see $retryAggMergeFailed).
    if ($retryAggMergeFailed) { $overall = 'Failed' }

    # v0.41.0 (P1): drop a passive backup-completion flag at the destination
    # ROOT (in the local operation model this is the target's shared
    # <BackuperRoot>\Backup) so the restore side (P2) can poll for it and
    # auto-select this backup. Best-effort; only on a non-Failed backup. No
    # consumer yet -- this is the producing half of the local-mode handshake.
    if ($overall -ne 'Failed') {
        # v0.56.0: use the aggregate dir's own timestamp leaf so a retry updates
        # the flag for the ORIGINAL backup instead of minting a new timestamp.
        $flagTimestamp = Split-Path -Leaf $aggregateDir
        $null = New-BackupCompleteFlag `
            -RootDir $rootDir `
            -OldPcName $SelectedHost.OldPCname `
            -NewPcName $(if ($SelectedHost.PSObject.Properties.Name -contains 'NewPCname') { "$($SelectedHost.NewPCname)" } else { '' }) `
            -Timestamp $flagTimestamp `
            -Status $overall `
            -BackuperVersion $BackuperVersion
    }

    return [PSCustomObject]@{
        Status         = $overall
        Message        = "Backup written to $aggregateDir"
        AggregateDir   = $aggregateDir
        SectionResults = $sectionResults
        ManifestPath   = $manifestPath
    }
}

function Invoke-BackuperRestoreCore {
    # v0.27.0: ExplicitAggregateDir is now the ONLY way the restore UI
    # passes a target backup directory. The old PickedTimestamp parameter
    # has been removed; the UI resolves a chosen timestamp to a full path
    # via Get-BackupTimestamps (multi-root) and forwards that path here.
    # This eliminates the hard-coded "<BackuperRoot>\Backup\..." assumption
    # and lets a single restore session pick from local / share / UNC roots
    # uniformly.
    param(
        [Parameter(Mandatory = $true)]$SelectedHost,
        [Parameter(Mandatory = $true)][array]$PickedSections,
        [Parameter(Mandatory = $true)][string]$BackuperRoot,
        [Parameter(Mandatory = $true)][string]$FabriqRoot,
        [hashtable]$SectionParamsBySection = @{},
        # Explicit backup folder path (local / UNC). The UI always supplies
        # this in v0.27.0+ (the multi-root combo or Browse dialog has
        # already resolved it). The engine just validates and uses it.
        [Parameter(Mandatory = $true)][string]$ExplicitAggregateDir
    )

    Set-SelectedHostEnvVars -SelectedHost $SelectedHost

    $aggregateDir = $ExplicitAggregateDir
    if (-not (Test-Path $aggregateDir)) {
        return [PSCustomObject]@{
            Status = 'Failed'
            Message = "Aggregate backup directory not found: $aggregateDir"
            AggregateDir = $aggregateDir
            SectionResults = @{}
        }
    }

    $sectionResults = @{}
    foreach ($s in $PickedSections) {
        $params = if ($SectionParamsBySection.ContainsKey($s.SectionName)) {
            $SectionParamsBySection[$s.SectionName]
        } else { @{} }
        $r = Invoke-SectionScript `
            -SectionName $s.SectionName `
            -ScriptName  'restore.ps1' `
            -BackuperRoot $BackuperRoot `
            -FabriqRoot   $FabriqRoot `
            -OldPcName    $SelectedHost.OldPCname `
            -AggregateBackupDir $aggregateDir `
            -SectionParams $params
        $sectionResults[$s.SectionName] = $r
    }

    $overall = 'Success'
    foreach ($r in $sectionResults.Values) {
        if ($r.Status -eq 'Failed')  { $overall = 'Failed'; break }
        if ($r.Status -eq 'Partial') { $overall = 'Partial' }
    }

    return [PSCustomObject]@{
        Status         = $overall
        Message        = "Restore from $aggregateDir"
        AggregateDir   = $aggregateDir
        SectionResults = $sectionResults
    }
}

# ============================================================
# Legacy console orchestrator (kept for reference / fallback).
# Phase 2.1 default flow is GUI via lib/ui/main_form.ps1.
# ============================================================
function Invoke-BackuperEngine {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Backup','Restore')]
        [string]$Mode
    )

    # ----------------------------------------
    # 1. Load hostlist + select host
    # ----------------------------------------
    $hosts = Get-FabriqHostlist -FabriqRoot $script:FabriqRoot
    if ($null -eq $hosts -or $hosts.Count -eq 0) {
        Show-Error "No hosts available."
        return
    }

    $selectedHost = Select-HostFromList -Hosts $hosts
    if ($null -eq $selectedHost) {
        Show-Info "Host selection cancelled."
        return
    }
    $env:SELECTED_OLD_PCNAME = $selectedHost.OldPCname

    # Also set SELECTED_NEW_PCNAME and other fields if present, so the
    # wrapped modules pick them up (they read $env:SELECTED_NEW_PCNAME
    # for some operations).
    foreach ($field in @('NewPCname','EthIp','EthSubnet','EthGateway','Dns1','Dns2','KanriNo')) {
        if ($selectedHost.PSObject.Properties.Name -contains $field) {
            $val = $selectedHost.$field
            $envName = "SELECTED_$($field.ToUpper())"
            if ($field -eq 'NewPCname')   { $envName = 'SELECTED_NEW_PCNAME' }
            if ($field -eq 'EthIp')       { $envName = 'SELECTED_ETH_IP' }
            if ($field -eq 'EthSubnet')   { $envName = 'SELECTED_ETH_SUBNET' }
            if ($field -eq 'EthGateway')  { $envName = 'SELECTED_ETH_GATEWAY' }
            if ($field -eq 'Dns1')        { $envName = 'SELECTED_DNS1' }
            if ($field -eq 'Dns2')        { $envName = 'SELECTED_DNS2' }
            if ($field -eq 'KanriNo')     { $envName = 'SELECTED_KANRI_NO' }
            if (-not [string]::IsNullOrWhiteSpace($val)) {
                Set-Item -Path "Env:$envName" -Value $val
            }
        }
    }

    # ----------------------------------------
    # 2. Load section registry + selection
    # ----------------------------------------
    $allSections = Get-RegisteredSections -BackuperRoot $script:FabriqBackuperRoot
    if ($allSections.Count -eq 0) {
        Show-Error "No sections registered in data/sections.csv"
        return
    }
    $picked = Show-SectionSelector -AllSections $allSections
    if ($picked.Count -eq 0) {
        Show-Info "No sections selected."
        return
    }

    # ----------------------------------------
    # 3. Prepare aggregate backup directory
    # ----------------------------------------
    $timestamp = Get-Date -Format "yyyy_MM_dd_HHmmss"
    $aggregateDir = Join-Path (Join-Path (Join-Path $script:FabriqBackuperRoot 'Backup') $selectedHost.OldPCname) $timestamp

    if ($Mode -eq 'Backup') {
        try {
            $null = New-Item -ItemType Directory -Path $aggregateDir -Force -ErrorAction Stop
        }
        catch {
            Show-Error "Failed to create aggregate dir: $($_.Exception.Message)"
            return
        }
    } else {
        # Restore: scan existing backups for this OldPCname
        $hostBackupRoot = Join-Path (Join-Path $script:FabriqBackuperRoot 'Backup') $selectedHost.OldPCname
        if (-not (Test-Path $hostBackupRoot)) {
            Show-Error "No backups found under: $hostBackupRoot"
            return
        }
        $timestamps = @(Get-ChildItem -Path $hostBackupRoot -Directory -ErrorAction SilentlyContinue |
                        Sort-Object Name -Descending | ForEach-Object { $_.Name })
        if ($timestamps.Count -eq 0) {
            Show-Error "No timestamp folders under: $hostBackupRoot"
            return
        }
        $picked_ts = Show-BackupTimestampSelector -Timestamps $timestamps
        if ($null -eq $picked_ts) {
            Show-Info "Restore cancelled."
            return
        }
        $aggregateDir = Join-Path $hostBackupRoot $picked_ts
    }

    # ----------------------------------------
    # 4. Confirm
    # ----------------------------------------
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host " $Mode Plan" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "  Mode             : $Mode" -ForegroundColor White
    Write-Host "  OldPCname        : $($selectedHost.OldPCname)" -ForegroundColor White
    Write-Host "  Aggregate dir    : $aggregateDir" -ForegroundColor White
    Write-Host "  Sections         : $(@($picked | ForEach-Object { $_.SectionName }) -join ', ')" -ForegroundColor White
    Write-Host "========================================" -ForegroundColor Yellow

    if (-not (Show-ConfirmPrompt -Message "Proceed with $Mode")) {
        Show-Info "Cancelled."
        return
    }

    # ----------------------------------------
    # 5. Execute sections
    # ----------------------------------------
    $sectionResults = @{}
    $aggregateWarnings = @()
    $scriptName = if ($Mode -eq 'Backup') { 'backup.ps1' } else { 'restore.ps1' }

    foreach ($s in $picked) {
        $r = Invoke-SectionScript `
            -SectionName $s.SectionName `
            -ScriptName  $scriptName `
            -BackuperRoot $script:FabriqBackuperRoot `
            -FabriqRoot   $script:FabriqRoot `
            -OldPcName    $selectedHost.OldPCname `
            -AggregateBackupDir $aggregateDir
        $sectionResults[$s.SectionName] = $r
    }

    # ----------------------------------------
    # 6. Aggregate manifest + execution log (Backup only)
    # ----------------------------------------
    if ($Mode -eq 'Backup') {
        $kernelVerFile = Join-Path $script:FabriqRoot 'kernel\KERNEL_VERSION'
        $kernelVer = if (Test-Path $kernelVerFile) { (Get-Content $kernelVerFile -Raw).Trim() } else { 'unknown' }

        $manifest = New-AggregateManifest `
            -OldPcName $selectedHost.OldPCname `
            -BackuperVersion $script:BackuperVersion `
            -FabriqKernelVersion $kernelVer `
            -SectionResults $sectionResults `
            -Warnings $aggregateWarnings
        $manifestPath = Save-AggregateManifest -OutputDir $aggregateDir -Manifest $manifest
        Show-Success "Aggregate manifest written: $manifestPath"

        # Execution log
        $logPath = Join-Path $aggregateDir "_execution_log.txt"
        $logLines = @()
        $logLines += "Fabriq BackUper Execution Log"
        $logLines += "================================"
        $logLines += "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        $logLines += "OldPCname: $($selectedHost.OldPCname)"
        $logLines += "Computer : $env:COMPUTERNAME"
        $logLines += "Mode     : $Mode"
        $logLines += ""
        foreach ($key in $sectionResults.Keys) {
            $r = $sectionResults[$key]
            $logLines += "[$key]"
            $logLines += "  Status    : $($r.Status)"
            $logLines += "  ElapsedMs : $($r.ElapsedMs)"
            $logLines += "  External  : $($r.ExternalOutputDir)"
            if ($r.Warnings -and @($r.Warnings).Count -gt 0) {
                $logLines += "  Warnings  :"
                foreach ($w in @($r.Warnings)) {
                    $logLines += "    - $w"
                }
            }
            $logLines += ""
        }
        $logLines | Out-File -FilePath $logPath -Encoding UTF8 -Force
    }

    # ----------------------------------------
    # 7. Result summary
    # ----------------------------------------
    Write-Host ""
    Show-Separator
    Write-Host " $Mode Results" -ForegroundColor Cyan
    Show-Separator
    foreach ($key in $sectionResults.Keys) {
        $r = $sectionResults[$key]
        $color = switch ($r.Status) {
            'Success' { 'Green' }
            'Partial' { 'Yellow' }
            'Failed'  { 'Red' }
            'Skipped' { 'DarkGray' }
            default   { 'White' }
        }
        Write-Host ("  {0,-12} {1,-8}  ({2} ms)" -f $key, $r.Status, $r.ElapsedMs) -ForegroundColor $color
    }
    Show-Separator
    Write-Host ""
    Read-Host "Press Enter to return to main menu"
}
