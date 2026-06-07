# ============================================================
# FabriqBackUper Section: system_evidence / restore (Phase 4)
#
# Restore-time role: the section never re-collects evidence on the
# target PC (operator policy: "no second sampling"). Instead, it
# deploys the source-PC artifacts captured at backup time into the
# operator handoff folder so the operator can browse the source PC's
# configuration while manually re-creating settings on the target
# PC.
#
# Deploy target:
#   <TargetUserDesktop>\<yyyy_MM_dd>_<OldPCname>_BK\03_移行元PC情報\
#   (forwarded via SectionParams['OperatorHandoffSubdir'])
#
# Files copied (everything from the backup section dir EXCEPT the
# backuper-internal manifest.json, which is not operator-facing):
#   - _ALL_<src>_Log.txt
#   - _OriginalNetworkConfig.{json,txt}    (if lan-prep snapshot was harvested)
#   - 01_SystemInfo.txt
#   - 06_NetworkConfig.csv
#   - 07_Printers.csv                       (if printers existed)
#   - 10_SerialNumber.txt
#   (11_DesktopApps.csv / 11_StoreApps.csv MOVED to the 'application' section, t-0009 P2;
#    old backups still carry them here and are copied for compatibility.)
#   - 16_WiFiProfiles.txt
#   - 27_EnvironmentVariables.csv
#
# The operator-facing Japanese README that explains the whole
# handoff folder lives at <handoffRoot>\README.txt and is written
# by restore_view.ps1's Invoke-RestoreStart (commit 3090f5c +
# Phase 1 of v0.26.0). This section does NOT duplicate that README.
#
# Skip semantics:
#   - OperatorHandoffSubdir empty/unset -> Skipped (handoff checkbox OFF)
#   - backup section dir missing       -> Skipped (older backup w/o system_evidence)
#   - copy errors per file             -> warning, continue, final status=Partial
#
# CLAUDE.md project rule 5: this file is written by the Write tool
# which emits UTF-8 without BOM. Therefore all string literals are
# kept ASCII-only; Japanese operator-facing copy lives in
# restore_view.ps1 (BOM-tagged) and the section dir's data files.
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

# Early exit: handoff folder feature is off.
if ([string]::IsNullOrWhiteSpace($handoffSubdir)) {
    Show-Skip "system_evidence: OperatorHandoffSubdir not provided (handoff checkbox OFF); restore skipped."
    $sw.Stop()
    return [PSCustomObject]@{
        Status               = 'Skipped'
        ElapsedMs            = [int]$sw.ElapsedMilliseconds
        Summary              = [ordered]@{
            reason          = 'Operator handoff folder feature is disabled'
            handoffSubdir   = $null
            filesCopied     = 0
        }
        Warnings             = @()
        ExternalOutputDir    = $null
        ExternalManifestPath = $null
        InternalSectionDir   = $null
        InternalManifestPath = $null
    }
}

# ----------------------------------------------------------
# Locate the backup-side section dir
# ----------------------------------------------------------
# AggregateBackupDir is the timestamped backup root (e.g.
# \\target\FabriqMigration\OLD-PC-01\2026_05_24_223333). The
# system_evidence section's payload sits at sections\system_evidence
# under that root.
$backupSectionDir = Join-Path $AggregateBackupDir 'sections\system_evidence'
if (-not (Test-Path -LiteralPath $backupSectionDir)) {
    Show-Skip "system_evidence: backup section dir not present ($backupSectionDir); restore skipped (older backup?)."
    $sw.Stop()
    return [PSCustomObject]@{
        Status               = 'Skipped'
        ElapsedMs            = [int]$sw.ElapsedMilliseconds
        Summary              = [ordered]@{
            reason            = 'Backup section dir not present (likely a pre-v0.26.0 backup)'
            handoffSubdir     = $handoffSubdir
            backupSectionDir  = $backupSectionDir
            filesCopied       = 0
        }
        Warnings             = @()
        ExternalOutputDir    = $null
        ExternalManifestPath = $null
        InternalSectionDir   = $null
        InternalManifestPath = $null
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
    Show-Error "system_evidence: failed to create handoff subdir: $($_.Exception.Message)"
    $sw.Stop()
    return [PSCustomObject]@{
        Status               = 'Failed'
        ElapsedMs            = [int]$sw.ElapsedMilliseconds
        Summary              = [ordered]@{
            reason         = "Failed to create handoff subdir: $($_.Exception.Message)"
            handoffSubdir  = $handoffSubdir
            filesCopied    = 0
        }
        Warnings             = @("mkdir failed: $($_.Exception.Message)")
        ExternalOutputDir    = $null
        ExternalManifestPath = $null
        InternalSectionDir   = $null
        InternalManifestPath = $null
    }
}

Show-Info "system_evidence: deploying to $handoffSubdir"

# ----------------------------------------------------------
# Copy files (everything except manifest.json)
# ----------------------------------------------------------
# manifest.json is the backuper-internal section manifest and is
# not operator-facing. The handoff folder's own README at
# <handoffRoot>\README.txt is written by restore_view.ps1 (Phase 1)
# and explains the role of 03_移行元PC情報 to the operator.
$filesCopied  = @()
$filesSkipped = @()
$copyErrors   = @()

$sourceFiles = @()
try {
    $sourceFiles = @(Get-ChildItem -LiteralPath $backupSectionDir -File -ErrorAction Stop)
} catch {
    $warnings += "Failed to enumerate backup section dir: $($_.Exception.Message)"
    Show-Warning "system_evidence: failed to enumerate $backupSectionDir : $($_.Exception.Message)"
}

foreach ($srcFile in $sourceFiles) {
    if ($srcFile.Name -ieq 'manifest.json') {
        $filesSkipped += $srcFile.Name
        continue
    }
    $destPath = Join-Path $handoffSubdir $srcFile.Name
    try {
        Copy-Item -LiteralPath $srcFile.FullName -Destination $destPath -Force -ErrorAction Stop
        $filesCopied += $srcFile.Name
    } catch {
        $msg = "Copy failed for $($srcFile.Name): $($_.Exception.Message)"
        $copyErrors += $msg
        $warnings   += $msg
        Show-Warning "system_evidence: $msg"
    }
}

Show-Success "system_evidence: copied $($filesCopied.Count) file(s) to handoff subdir"
if ($filesSkipped.Count -gt 0) {
    Show-Info "system_evidence: skipped (internal/non-operator files): $($filesSkipped -join ', ')"
}

# ----------------------------------------------------------
# Write restore manifest (fabriq-system-evidence-restore v1)
# ----------------------------------------------------------
$restoreManifest = [ordered]@{
    schemaVersion    = 1
    manifestType     = 'fabriq-system-evidence-restore'
    deployedAt       = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    deployedTo       = $handoffSubdir
    backupSectionDir = $backupSectionDir
    filesCopied      = $filesCopied
    filesSkipped     = $filesSkipped
    copyErrors       = $copyErrors
    summary          = [ordered]@{
        copiedCount  = $filesCopied.Count
        skippedCount = $filesSkipped.Count
        errorCount   = $copyErrors.Count
    }
}

$restoreManifestPath = Join-Path $handoffSubdir '_restore_manifest.json'
try {
    $json = $restoreManifest | ConvertTo-Json -Depth 6
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($restoreManifestPath, $json, $utf8NoBom)
} catch {
    $warnings += "Failed to write _restore_manifest.json: $($_.Exception.Message)"
    Show-Warning "system_evidence: failed to write _restore_manifest.json: $($_.Exception.Message)"
    $restoreManifestPath = $null
}

# ----------------------------------------------------------
# Determine final section status
# ----------------------------------------------------------
$status = if ($copyErrors.Count -gt 0) {
    if ($filesCopied.Count -gt 0) { 'Partial' } else { 'Failed' }
} elseif ($filesCopied.Count -eq 0) {
    # Source dir existed but contained nothing copyable (only manifest.json).
    'Skipped'
} else {
    'Success'
}

$sw.Stop()

$summary = [ordered]@{
    handoffSubdir     = $handoffSubdir
    backupSectionDir  = $backupSectionDir
    copiedCount       = $filesCopied.Count
    skippedCount      = $filesSkipped.Count
    errorCount        = $copyErrors.Count
    filesCopied       = $filesCopied
}

return [PSCustomObject]@{
    Status               = $status
    ElapsedMs            = [int]$sw.ElapsedMilliseconds
    Summary              = $summary
    Warnings             = $warnings
    ExternalOutputDir    = $handoffSubdir
    ExternalManifestPath = $restoreManifestPath
    InternalSectionDir   = $null
    InternalManifestPath = $null
}
