# ============================================================
# FabriqBackUper - Aggregate Manifest Generator
# Produces the top-level manifest.json
# (fabriq-backuper-snapshot, schemaVersion=1) by combining
# per-section results.
# ============================================================

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
        if ($r.Summary -and $r.Summary.PSObject.Properties.Name -contains 'totalBytes') {
            $totalBytes += [long]$r.Summary.totalBytes
        }

        # Phase 2.2.1: internalized sections expose InternalManifestPath
        # (absolute path to sections/<name>/manifest.json). Legacy wrapper
        # sections expose ExternalOutputDir + ExternalManifestPath. We
        # record both, with internal as a portable relative path.
        $hasInternal = ($r.PSObject.Properties.Name -contains 'InternalManifestPath') -and `
                       (-not [string]::IsNullOrWhiteSpace($r.InternalManifestPath))
        $internalRel = if ($hasInternal) { "sections/$key/manifest.json" } else { $null }

        $sectionsOrdered[$key] = [ordered]@{
            enabled              = $true
            status               = $r.Status
            elapsedMs            = [int]$r.ElapsedMs
            manifestPath         = $internalRel
            externalOutputDir    = $r.ExternalOutputDir
            externalManifestPath = $r.ExternalManifestPath
            summary              = $r.Summary
            warnings             = @($r.Warnings)
        }
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
