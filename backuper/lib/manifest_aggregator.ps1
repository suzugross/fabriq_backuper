# ============================================================
# FabriqBackUper - Aggregate Manifest Generator
# Produces the top-level manifest.json
# (fabriq-backuper-snapshot, schemaVersion=1) by combining
# per-section results.
# ============================================================

function ConvertTo-SectionManifestEntry {
    # Builds one aggregate-manifest "sections" entry from a section result.
    # Shared by New-AggregateManifest (full backup) and Merge-AggregateManifest
    # (v0.56.0 retry) so the section-entry shape stays identical in both paths.
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)]$Result
    )
    $hasInternal = ($Result.PSObject.Properties.Name -contains 'InternalManifestPath') -and `
                   (-not [string]::IsNullOrWhiteSpace($Result.InternalManifestPath))
    $internalRel = if ($hasInternal) { "sections/$Key/manifest.json" } else { $null }
    return [ordered]@{
        enabled              = $true
        status               = $Result.Status
        elapsedMs            = [int]$Result.ElapsedMs
        manifestPath         = $internalRel
        externalOutputDir    = $Result.ExternalOutputDir
        externalManifestPath = $Result.ExternalManifestPath
        summary              = $Result.Summary
        warnings             = @($Result.Warnings)
    }
}

function New-AggregateManifest {
    param(
        [Parameter(Mandatory = $true)][string]$OldPcName,
        [Parameter(Mandatory = $true)][string]$BackuperVersion,
        [Parameter(Mandatory = $true)][string]$FabriqKernelVersion,
        [Parameter(Mandatory = $true)][hashtable]$SectionResults,
        # NOTE: Warnings is intentionally non-Mandatory with default @().
        # PowerShell rejects empty collections when bound to a Mandatory
        # array parameter, which is the typical case for a clean backup.
        [array]$Warnings = @()
    )

    $hwUid = $null
    try {
        $hwUid = (Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop |
                  Select-Object -First 1).UUID
    } catch { }

    $osArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
        'arm64'
    } elseif ([Environment]::Is64BitOperatingSystem) {
        'amd64'
    } else {
        'x86'
    }

    # Build sections object preserving stable key order
    $sectionsOrdered = [ordered]@{}
    $sectionCount   = 0
    $successCount   = 0
    $partialCount   = 0
    $failedCount    = 0
    $skippedCount   = 0
    $totalBytes     = 0

    foreach ($key in @($SectionResults.Keys | Sort-Object)) {
        $r = $SectionResults[$key]
        $sectionCount++
        switch ($r.Status) {
            'Success'  { $successCount++ }
            'Partial'  { $partialCount++ }
            'Failed'   { $failedCount++ }
            'Skipped'  { $skippedCount++ }
        }
        # v0.69.4: shape-agnostic read (mirror Merge-AggregateManifest). $r.Summary is
        # an [ordered] dict for which .PSObject.Properties does NOT surface keys, so the
        # old "-contains 'totalBytes'" guard was always false and summary.totalBytes was
        # left 0 (the per-section entries were fine; only the rolled-up total was wrong).
        $sumObj = $r.Summary
        $tbVal = $null
        if ($sumObj -is [System.Collections.IDictionary]) {
            $tbVal = $sumObj['totalBytes']
        } elseif ($null -ne $sumObj) {
            $tbProp = $sumObj.PSObject.Properties['totalBytes']
            if ($tbProp) { $tbVal = $tbProp.Value }
        }
        if ($null -ne $tbVal) { $totalBytes += [long]$tbVal }

        # Phase 2.2.1: internalized sections expose InternalManifestPath
        # (absolute path to sections/<name>/manifest.json). Legacy wrapper
        # sections expose ExternalOutputDir + ExternalManifestPath. The shared
        # builder records both (internal as a portable relative path).
        $sectionsOrdered[$key] = ConvertTo-SectionManifestEntry -Key $key -Result $r
    }

    $manifest = [ordered]@{
        schemaVersion        = 1
        manifestType         = "fabriq-backuper-snapshot"
        backuperVersion      = $BackuperVersion
        fabriqKernelVersion  = $FabriqKernelVersion
        collectedAt          = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
        oldPcName            = $OldPcName
        computerName         = $env:COMPUTERNAME
        hardwareUniqueId     = $hwUid
        osVersion            = [System.Environment]::OSVersion.Version.ToString()
        osArch               = $osArch
        sections             = $sectionsOrdered
        summary              = [ordered]@{
            sectionCount  = $sectionCount
            successCount  = $successCount
            partialCount  = $partialCount
            failedCount   = $failedCount
            skippedCount  = $skippedCount
            totalBytes    = [long]$totalBytes
        }
        warnings             = @($Warnings)
    }

    return $manifest
}

function Save-AggregateManifest {
    param(
        [Parameter(Mandatory = $true)][string]$OutputDir,
        [Parameter(Mandatory = $true)][object]$Manifest
    )

    $manifestPath = Join-Path $OutputDir "manifest.json"
    $Manifest | ConvertTo-Json -Depth 10 | Out-File -FilePath $manifestPath -Encoding UTF8 -Force
    return $manifestPath
}

function Merge-AggregateManifest {
    # v0.56.0 (t-0003): merge a RETRY run's section results into an EXISTING
    # aggregate manifest so a partially-failed backup can be COMPLETED in place
    # (same aggregate dir, same collectedAt) by re-running only the failed
    # sections/entries. The successful sections from the original run are kept.
    # Returns the merged manifest object, or $null if the existing manifest can't
    # be read (the caller then falls back to New-AggregateManifest).
    param(
        [Parameter(Mandatory = $true)][string]$ExistingManifestPath,
        [Parameter(Mandatory = $true)][hashtable]$RetriedSectionResults,
        [array]$Warnings = @()
    )
    if (-not (Test-Path -LiteralPath $ExistingManifestPath)) { return $null }
    try {
        $existing = (Get-Content -LiteralPath $ExistingManifestPath -Raw -Encoding UTF8) | ConvertFrom-Json
    } catch { return $null }
    if ($null -eq $existing -or $null -eq $existing.sections) { return $null }

    # Overlay the retried sections onto the existing ones (preserve existing key
    # order; append any genuinely new section keys).
    $mergedSections = [ordered]@{}
    foreach ($prop in $existing.sections.PSObject.Properties) {
        $mergedSections[$prop.Name] = $prop.Value
    }
    foreach ($key in $RetriedSectionResults.Keys) {
        $newEntry = ConvertTo-SectionManifestEntry -Key $key -Result $RetriedSectionResults[$key]
        $existingEntry = $mergedSections[$key]
        # A retry that SKIPPED a section (e.g. nothing selected for it this run)
        # must never DOWNGRADE the section's existing result: keep the prior status
        # (Success/Partial/Failed) rather than masking it as Skipped. Without this,
        # re-running with a section/entry deselected would drop its prior result.
        if ($null -ne $existingEntry -and "$($newEntry.status)" -eq 'Skipped') {
            continue
        }
        $mergedSections[$key] = $newEntry
    }

    # Recompute the summary over ALL merged sections. Section entries can be
    # PSCustomObject (from the existing JSON) or [ordered] (just rebuilt), so read
    # status / summary.totalBytes in a shape-agnostic way.
    $sectionCount = 0; $successCount = 0; $partialCount = 0; $failedCount = 0; $skippedCount = 0
    [long]$totalBytes = 0
    foreach ($k in $mergedSections.Keys) {
        $sec = $mergedSections[$k]
        $sectionCount++
        switch ("$($sec.status)") {
            'Success' { $successCount++ }
            'Partial' { $partialCount++ }
            'Failed'  { $failedCount++ }
            'Skipped' { $skippedCount++ }
        }
        $sumObj = $sec.summary
        $tbVal = $null
        if ($sumObj -is [System.Collections.IDictionary]) {
            $tbVal = $sumObj['totalBytes']
        } elseif ($null -ne $sumObj) {
            $tbProp = $sumObj.PSObject.Properties['totalBytes']
            if ($tbProp) { $tbVal = $tbProp.Value }
        }
        if ($null -ne $tbVal) { $totalBytes += [long]$tbVal }
    }

    # Rebuild the manifest preserving existing top-level fields, replacing only
    # sections + summary, merging warnings, and stamping the retry time.
    $out = [ordered]@{}
    foreach ($prop in $existing.PSObject.Properties) {
        switch ($prop.Name) {
            'sections' { $out['sections'] = $mergedSections }
            'summary'  {
                $out['summary'] = [ordered]@{
                    sectionCount = $sectionCount
                    successCount = $successCount
                    partialCount = $partialCount
                    failedCount  = $failedCount
                    skippedCount = $skippedCount
                    totalBytes   = [long]$totalBytes
                }
            }
            'warnings' { $out['warnings'] = @(@($prop.Value) + @($Warnings)) }
            default    { $out[$prop.Name] = $prop.Value }
        }
    }
    if (-not $out.Contains('sections')) { $out['sections'] = $mergedSections }
    if (-not $out.Contains('summary')) {
        $out['summary'] = [ordered]@{
            sectionCount = $sectionCount; successCount = $successCount
            partialCount = $partialCount; failedCount = $failedCount
            skippedCount = $skippedCount; totalBytes = [long]$totalBytes
        }
    }
    $out['lastRetriedAt'] = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
    return $out
}
