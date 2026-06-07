# ============================================================
# FabriqBackUper Section: application / restore (t-0009 P2)
#
# Deploys the source PC's installed-app inventory + the Check-AppMigration
# tooling into the operator handoff folder so the operator (and the Handoff
# Viewer's in-app cross-check) can compare apps. Never re-collects on the
# target ("no second sampling").
#
# Deploy target:
#   <handoffRoot>\05_application info\   (SectionParams['OperatorHandoffSubdir'])
#     11_DesktopApps.csv / 11_StoreApps.csv   (source inventory)
#     app_migration_list.csv / .sample.csv    (project cross-check list)
#     Check-AppMigration.bat                   (operator entry, ASCII)
#     _data\Check-AppMigration.ps1             (body, UTF-8 BOM)
#
# Backward compatibility (dual-location): the source inventory CSVs are read
# from sections\application (new backups) OR, if absent, sections\system_evidence
# (pre-v0.61 backups that stored apps under the former section 11). This keeps
# old backups fully restorable after the section move.
#
# Skip semantics:
#   - OperatorHandoffSubdir empty/unset -> Skipped (handoff checkbox OFF)
#
# CLAUDE.md rule 5: written by the Write tool (UTF-8 without BOM) so all
# string literals are ASCII-only; the handoff README (restore_view.ps1) and
# the data files carry the operator-facing Japanese.
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
$handoffSubdir = $null
if ($SectionParams.ContainsKey('OperatorHandoffSubdir') -and `
    -not [string]::IsNullOrWhiteSpace($SectionParams['OperatorHandoffSubdir'])) {
    $handoffSubdir = "$($SectionParams['OperatorHandoffSubdir'])"
}

if ([string]::IsNullOrWhiteSpace($handoffSubdir)) {
    Show-Skip "application: OperatorHandoffSubdir not provided (handoff checkbox OFF); restore skipped."
    $sw.Stop()
    return [PSCustomObject]@{
        Status               = 'Skipped'
        ElapsedMs            = [int]$sw.ElapsedMilliseconds
        Summary              = [ordered]@{ reason = 'Operator handoff folder feature is disabled'; filesCopied = 0 }
        Warnings             = @()
        ExternalOutputDir    = $null
        ExternalManifestPath = $null
        InternalSectionDir   = $null
        InternalManifestPath = $null
    }
}

# ----------------------------------------------------------
# Locate the source inventory CSVs (dual-location, backward compatible)
# ----------------------------------------------------------
$appDir = Join-Path $AggregateBackupDir 'sections\application'
$sysDir = Join-Path $AggregateBackupDir 'sections\system_evidence'
$srcDir       = $null
$fromLegacy   = $false
foreach ($cand in @($appDir, $sysDir)) {
    if ([string]::IsNullOrWhiteSpace($cand)) { continue }
    if ((Test-Path -LiteralPath (Join-Path $cand '11_DesktopApps.csv')) -or `
        (Test-Path -LiteralPath (Join-Path $cand '11_StoreApps.csv'))) {
        $srcDir = $cand
        $fromLegacy = ($cand -eq $sysDir)
        break
    }
}

# ----------------------------------------------------------
# Materialize handoff subdir
# ----------------------------------------------------------
try {
    if (-not (Test-Path -LiteralPath $handoffSubdir)) {
        $null = New-Item -ItemType Directory -Path $handoffSubdir -Force -ErrorAction Stop
    }
} catch {
    Show-Error "application: failed to create handoff subdir: $($_.Exception.Message)"
    $sw.Stop()
    return [PSCustomObject]@{
        Status               = 'Failed'
        ElapsedMs            = [int]$sw.ElapsedMilliseconds
        Summary              = [ordered]@{ reason = "Failed to create handoff subdir: $($_.Exception.Message)"; filesCopied = 0 }
        Warnings             = @("mkdir failed: $($_.Exception.Message)")
        ExternalOutputDir    = $null
        ExternalManifestPath = $null
        InternalSectionDir   = $null
        InternalManifestPath = $null
    }
}

Show-Info "application: deploying to $handoffSubdir"

# ----------------------------------------------------------
# Copy the source inventory CSVs
# ----------------------------------------------------------
$filesCopied = @()
$copyErrors  = @()
if ($null -ne $srcDir) {
    if ($fromLegacy) {
        Show-Info "application: source inventory taken from legacy system_evidence location (pre-v0.61 backup)"
    }
    foreach ($csvName in @('11_DesktopApps.csv', '11_StoreApps.csv')) {
        $srcCsv = Join-Path $srcDir $csvName
        if (-not (Test-Path -LiteralPath $srcCsv)) { continue }
        try {
            Copy-Item -LiteralPath $srcCsv -Destination (Join-Path $handoffSubdir $csvName) -Force -ErrorAction Stop
            $filesCopied += $csvName
        } catch {
            $msg = "Copy failed for $csvName : $($_.Exception.Message)"
            $copyErrors += $msg; $warnings += $msg
            Show-Warning "application: $msg"
        }
    }
    Show-Success "application: copied $($filesCopied.Count) inventory CSV(s) to handoff subdir"
} else {
    $warnings += "No app inventory CSV (11_DesktopApps.csv / 11_StoreApps.csv) found under sections\application or sections\system_evidence."
    Show-Warning "application: no source inventory CSV found in backup; deploying the cross-check tool only."
}

# ----------------------------------------------------------
# Deploy Check-AppMigration tool (moved from system_evidence)
# ----------------------------------------------------------
# Best-effort: failures warn but never flip the section to Failed.
$appMigDeployed = $false
$appMigListCopied = $false
$appMigSampleCopied = $false
try {
    $repoListPath   = Join-Path $BackuperRoot 'data\app_migration_list.csv'
    $repoSamplePath = Join-Path $BackuperRoot 'data\app_migration_list.sample.csv'
    $dataDir        = Join-Path $handoffSubdir '_data'
    if (-not (Test-Path -LiteralPath $dataDir)) {
        $null = New-Item -ItemType Directory -Path $dataDir -Force -ErrorAction Stop
    }

    if (Test-Path -LiteralPath $repoListPath) {
        Copy-Item -LiteralPath $repoListPath -Destination (Join-Path $handoffSubdir 'app_migration_list.csv') -Force -ErrorAction Stop
        $appMigListCopied = $true
        Show-Info "application: copied app_migration_list.csv to handoff folder"
    } else {
        Show-Warning "application: $repoListPath not found; deploying sample only. Copy the sample and edit it before cross-checking."
        $warnings += "app_migration_list.csv missing from repo; only sample deployed"
    }

    if (Test-Path -LiteralPath $repoSamplePath) {
        Copy-Item -LiteralPath $repoSamplePath -Destination (Join-Path $handoffSubdir 'app_migration_list.sample.csv') -Force -ErrorAction Stop
        $appMigSampleCopied = $true
    } else {
        Show-Warning "application: $repoSamplePath not found; sample CSV will be absent from handoff folder"
        $warnings += "app_migration_list.sample.csv missing from repo"
    }

    $batBody = New-AppMigrationCheckBat
    $batPath = Join-Path $handoffSubdir 'Check-AppMigration.bat'
    $asciiEnc = New-Object System.Text.ASCIIEncoding
    [System.IO.File]::WriteAllText($batPath, $batBody, $asciiEnc)

    $psBody = New-AppMigrationCheckScript
    $psPath = Join-Path $dataDir 'Check-AppMigration.ps1'
    $utf8BomEnc = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($psPath, $psBody, $utf8BomEnc)

    $appMigDeployed = $true
    Show-Success "application: deployed Check-AppMigration.bat + _data\Check-AppMigration.ps1"
} catch {
    $msg = "Failed to deploy Check-AppMigration tool: $($_.Exception.Message)"
    $warnings += $msg
    Show-Warning "application: $msg"
}

# ----------------------------------------------------------
# Write restore manifest (fabriq-application-restore v1)
# ----------------------------------------------------------
$restoreManifest = [ordered]@{
    schemaVersion     = 1
    manifestType      = 'fabriq-application-restore'
    deployedAt        = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    deployedTo        = $handoffSubdir
    sourceDir         = $srcDir
    sourceFromLegacy  = $fromLegacy
    filesCopied       = $filesCopied
    copyErrors        = $copyErrors
    appMigrationCheck = [ordered]@{
        toolDeployed    = $appMigDeployed
        listCsvCopied   = $appMigListCopied
        sampleCsvCopied = $appMigSampleCopied
    }
    summary           = [ordered]@{
        copiedCount = $filesCopied.Count
        errorCount  = $copyErrors.Count
    }
}
$restoreManifestPath = Join-Path $handoffSubdir '_restore_manifest.json'
try {
    $json = $restoreManifest | ConvertTo-Json -Depth 6
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($restoreManifestPath, $json, $utf8NoBom)
} catch {
    $warnings += "Failed to write _restore_manifest.json: $($_.Exception.Message)"
    Show-Warning "application: failed to write _restore_manifest.json: $($_.Exception.Message)"
    $restoreManifestPath = $null
}

# ----------------------------------------------------------
# Final status
# ----------------------------------------------------------
$status = if ($copyErrors.Count -gt 0) {
    if ($filesCopied.Count -gt 0) { 'Partial' } else { 'Failed' }
} elseif ($filesCopied.Count -eq 0 -and -not $appMigDeployed) {
    'Skipped'
} else {
    'Success'
}

$sw.Stop()
return [PSCustomObject]@{
    Status               = $status
    ElapsedMs            = [int]$sw.ElapsedMilliseconds
    Summary              = [ordered]@{
        handoffSubdir = $handoffSubdir
        sourceDir     = $srcDir
        fromLegacy    = $fromLegacy
        copiedCount   = $filesCopied.Count
        errorCount    = $copyErrors.Count
        filesCopied   = $filesCopied
    }
    Warnings             = $warnings
    ExternalOutputDir    = $handoffSubdir
    ExternalManifestPath = $restoreManifestPath
    InternalSectionDir   = $null
    InternalManifestPath = $null
}
