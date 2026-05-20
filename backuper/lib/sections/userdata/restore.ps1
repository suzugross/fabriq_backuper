# ============================================================
# FabriqBackUper Section: userdata / restore (Phase 2.3, internalized)
#
# Reads $AggregateBackupDir/sections/userdata/manifest.json
# (fabriq-userdata-backup schemaVersion=1) and replays each entry
# back to its resolvedPath via robocopy.
#
# SectionParams (hashtable, all optional):
#   IncludeEntries        : array of SourcePath strings to restore
#                           (null/empty = all entries in manifest, except 'Skipped')
#   TargetUserProfilePath : profile path to resolve %USERPROFILE% /
#                           %APPDATA% / %LOCALAPPDATA% / %USERNAME% against
#                           on the restore target (null/empty = use current
#                           process env vars). Phase 2.7.
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

$includeEntries = $null
if ($SectionParams.ContainsKey('IncludeEntries') -and `
    $null -ne $SectionParams['IncludeEntries'] -and `
    @($SectionParams['IncludeEntries']).Count -gt 0) {
    $includeEntries = @($SectionParams['IncludeEntries'])
}

$targetUserProfilePath = $null
if ($SectionParams.ContainsKey('TargetUserProfilePath') -and `
    -not [string]::IsNullOrWhiteSpace($SectionParams['TargetUserProfilePath'])) {
    $targetUserProfilePath = "$($SectionParams['TargetUserProfilePath'])"
}

# ----------------------------------------------------------
# Prereq + manifest validation
# ----------------------------------------------------------
if (-not (Test-AdminPrivilege)) {
    return [PSCustomObject]@{
        Status = 'Failed'; ElapsedMs = [int]$sw.ElapsedMilliseconds
        Summary = [ordered]@{}; Warnings = @('Administrator privileges required')
    }
}
$robocopyExe = Get-Command robocopy.exe -ErrorAction SilentlyContinue
if ($null -eq $robocopyExe) {
    return [PSCustomObject]@{
        Status = 'Failed'; ElapsedMs = [int]$sw.ElapsedMilliseconds
        Summary = [ordered]@{}; Warnings = @('robocopy.exe not found')
    }
}

$sectionDir = Join-Path $AggregateBackupDir 'sections\userdata'
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
if ($manifest.manifestType -ne 'fabriq-userdata-backup') {
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
# Build restore plan
# ----------------------------------------------------------
$allEntries = @($manifest.items.entries)
$plannedEntries = @($allEntries | Where-Object {
    $_.status -ne 'Skipped' -and -not [string]::IsNullOrWhiteSpace($_.backupSubpath)
})
if ($null -ne $includeEntries) {
    $plannedEntries = @($plannedEntries | Where-Object { $_.sourcePath -in $includeEntries })
}

if ($plannedEntries.Count -eq 0) {
    return [PSCustomObject]@{
        Status = 'Skipped'; ElapsedMs = [int]$sw.ElapsedMilliseconds
        Summary = [ordered]@{ note = 'no restorable entries' }
        Warnings = @($warnings)
    }
}

Show-Info "Restoring $($plannedEntries.Count) entry(ies)"

# Phase 2.7.8 / 2.7.9: hand the planned list to the Progress View
# checklist. Direct call (no Get-Command gate); try/catch handles the
# console-only / no-GUI fallback.
try {
    $uiEntries = foreach ($pe in $plannedEntries) {
        @{ Id = "$($pe.id)"; Label = "$($pe.sourcePath)" }
    }
    Initialize-ProgressEntries -Entries @($uiEntries)
} catch { }

# ----------------------------------------------------------
# Execute
# ----------------------------------------------------------
$successCount = 0; $skipCount = 0; $failCount = 0

foreach ($pe in $plannedEntries) {
    try { Set-EntryStatus -Id "$($pe.id)" -Status 'InProgress' } catch { }
    Show-Info "[$($pe.id)] $($pe.resolvedPath)"
    $srcDataDir = Join-Path $sectionDir $pe.backupSubpath
    if (-not (Test-Path $srcDataDir)) {
        Show-Error "  Backup data folder missing: $srcDataDir"
        $warnings += "Missing data folder for entry $($pe.id)"
        $failCount++
        try { Set-EntryStatus -Id "$($pe.id)" -Status 'Failed' } catch { }
        continue
    }

    # Phase 2.4 / 2.7: re-expand the manifest's sourcePath against the
    # restore target's user context (selected user > current process env
    # vars > manifest resolvedPath). This lets cross-user migration
    # (backup-user != restore-user) map %USERPROFILE% etc. to the right
    # profile directory, including under admin elevation where the
    # process owner differs from the chosen logged-on user.
    $targetPath = $null
    if ($pe.sourcePath -match '%\w+%') {
        if (-not [string]::IsNullOrWhiteSpace($targetUserProfilePath) -and `
            (Get-Command Expand-PathWithUser -ErrorAction SilentlyContinue)) {
            $targetPath = Expand-PathWithUser -Path $pe.sourcePath -UserProfilePath $targetUserProfilePath
        } else {
            $targetPath = [Environment]::ExpandEnvironmentVariables($pe.sourcePath)
        }
    } else {
        $targetPath = $pe.sourcePath
    }
    if ([string]::IsNullOrWhiteSpace($targetPath)) {
        $targetPath = $pe.resolvedPath  # final fallback
    }
    Show-Info "  target: $targetPath  (source: $($pe.sourcePath))"

    $isDir      = [bool]$pe.isDirectory
    $onConflict = if ([string]::IsNullOrWhiteSpace($pe.onConflict)) { 'skip' } else { $pe.onConflict.ToLower() }
    $includeAcl = [bool]$pe.includeAcl
    $proceed = $true
    # Phase 2.7.8: tracks the reason proceed got flipped to false so the
    # UI checklist can distinguish "skipped" vs "failed" for this entry.
    $proceedReason = 'Failed'

    if ($isDir) {
        if (Test-Path -LiteralPath $targetPath -PathType Container) {
            switch ($onConflict) {
                'skip' { Show-Skip "  exists (skip)"; $skipCount++; $proceed = $false; $proceedReason = 'Skipped' }
                'overwrite' { Show-Info "  exists (overwrite)" }
                'rename' {
                    $renamed = "$targetPath.bak_$(Get-Date -Format yyyyMMdd_HHmmss)"
                    try {
                        Rename-Item -LiteralPath $targetPath -NewName (Split-Path $renamed -Leaf) -ErrorAction Stop
                        Show-Info "  renamed existing -> $(Split-Path $renamed -Leaf)"
                    } catch {
                        $warnings += "Rename failed for $targetPath"; $failCount++; $proceed = $false
                    }
                }
                default { $warnings += "Unknown OnConflict for $($pe.id)"; $failCount++; $proceed = $false }
            }
        } elseif (Test-Path -LiteralPath $targetPath -PathType Leaf) {
            $warnings += "Type mismatch (file vs dir) for $($pe.id)"; $failCount++; $proceed = $false
        }
    } else {
        if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
            switch ($onConflict) {
                'skip' { Show-Skip "  exists (skip)"; $skipCount++; $proceed = $false; $proceedReason = 'Skipped' }
                'overwrite' { Show-Info "  exists (overwrite)" }
                'rename' {
                    $renamed = "$targetPath.bak_$(Get-Date -Format yyyyMMdd_HHmmss)"
                    try {
                        Rename-Item -LiteralPath $targetPath -NewName (Split-Path $renamed -Leaf) -ErrorAction Stop
                        Show-Info "  renamed existing -> $(Split-Path $renamed -Leaf)"
                    } catch {
                        $warnings += "Rename failed for $targetPath"; $failCount++; $proceed = $false
                    }
                }
                default { $warnings += "Unknown OnConflict for $($pe.id)"; $failCount++; $proceed = $false }
            }
        }
    }

    if (-not $proceed) {
        try { Set-EntryStatus -Id "$($pe.id)" -Status $proceedReason } catch { }
        continue
    }

    if ($isDir) {
        if (-not (Test-Path -LiteralPath $targetPath)) {
            try { $null = New-Item -ItemType Directory -Path $targetPath -Force -ErrorAction Stop }
            catch {
                $warnings += "Target dir create failed: $targetPath"; $failCount++
                try { Set-EntryStatus -Id "$($pe.id)" -Status 'Failed' } catch { }
                continue
            }
        }
    } else {
        $parent = Split-Path -Path $targetPath -Parent
        if (-not (Test-Path -LiteralPath $parent)) {
            try { $null = New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop }
            catch {
                $warnings += "Target parent create failed: $parent"; $failCount++
                try { Set-EntryStatus -Id "$($pe.id)" -Status 'Failed' } catch { }
                continue
            }
        }
    }

    $copyFlag = if ($includeAcl) { '/COPYALL' } else { '/COPY:DAT' }
    if ($isDir) {
        # /XJD on restore is a belt-and-suspenders measure: if the backup
        # was taken before the v0.7.3 fix and still contains
        # Documents\My Pictures content, /XJD here prevents robocopy from
        # writing through the target-side junction to the real Pictures.
        # New v0.7.3+ backups have no such content; /XJD is a no-op for them.
        # /MT:16 = same threading bump as backup side (Phase 2.7.6).
        $rcArgs = @($srcDataDir, $targetPath, '/E', '/XJD', $copyFlag, '/B', '/MT:16', '/R:1', '/W:1', '/NP')
    } else {
        $fileName = Split-Path -Path $targetPath -Leaf
        $targetDir = Split-Path -Path $targetPath -Parent
        $rcArgs = @($srcDataDir, $targetDir, $fileName, $copyFlag, '/B', '/R:1', '/W:1', '/NP', '/NDL', '/NS', '/NC')
    }
    try { Add-ProgressLog "  [$($pe.id)] robocopy $srcDataDir -> $targetPath" } catch { }
    # Phase 2.7.4 / 2.7.9: stream robocopy output line-by-line so the user
    # sees restore progress in real time. Direct Add-ProgressLog call
    # (no Get-Command gate) — see backup.ps1 for the same rationale.
    $rcLine = 0
    & robocopy.exe @rcArgs 2>&1 | ForEach-Object {
        $line = "$_"
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            try { Add-ProgressLog "    $($line.TrimEnd())" } catch { }
            $rcLine++
            if (($rcLine % 8) -eq 0 -and `
                ([System.Windows.Forms.Application] -as [type])) {
                [System.Windows.Forms.Application]::DoEvents()
            }
        }
    }
    $rcExit = $LASTEXITCODE
    $entryUiStatus = 'Done'
    if ($rcExit -ge 8) {
        Show-Error "  robocopy fail (exit $rcExit)"
        $warnings += "robocopy exit $rcExit for $($pe.id)"; $failCount++
        $entryUiStatus = 'Failed'
    } elseif ($rcExit -ge 4) {
        Show-Warning "  robocopy mismatch (exit $rcExit)"
        $warnings += "robocopy mismatch (exit $rcExit) for $($pe.id)"; $successCount++
        $entryUiStatus = 'Partial'
    } else {
        Show-Success "  restored (exit $rcExit)"
        $successCount++
    }
    try { Set-EntryStatus -Id "$($pe.id)" -Status $entryUiStatus } catch { }
}

$sw.Stop()
$status = if ($failCount -gt 0 -and $successCount -eq 0) { 'Failed' }
          elseif ($failCount -gt 0) { 'Partial' }
          else { 'Success' }

return [PSCustomObject]@{
    Status   = $status
    ElapsedMs = [int]$sw.ElapsedMilliseconds
    Summary  = [ordered]@{
        entrySuccess = $successCount
        entrySkip    = $skipCount
        entryFail    = $failCount
    }
    Warnings = $warnings
}
