# ============================================================
# FabriqBackUper Section: userdata / backup (Phase 2.3, internalized)
#
# Independent userdata backup engine. Reads entries from
# apps/fabriq_backuper/data/userdata_list.csv (FabriqBackUper-owned)
# and copies each enabled entry to
# $AggregateBackupDir/sections/userdata/entries/<NN>/data/ via robocopy.
# Writes manifest.json (fabriq-userdata-backup schemaVersion=1).
#
# SectionParams (hashtable, all optional):
#   IncludeEntries        : array of SourcePath strings to include
#                           (null/empty = use CSV Enabled column as-is)
#   SourceUserProfilePath : profile path to resolve %USERPROFILE% /
#                           %APPDATA% / %LOCALAPPDATA% / %USERNAME% against
#                           (null/empty = use current process env vars,
#                            which under admin elevation may differ from
#                            the logged-on interactive user — see Phase 2.7)
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
$includeEntries = $null
if ($SectionParams.ContainsKey('IncludeEntries') -and `
    $null -ne $SectionParams['IncludeEntries'] -and `
    @($SectionParams['IncludeEntries']).Count -gt 0) {
    $includeEntries = @($SectionParams['IncludeEntries'])
}

$sourceUserProfilePath = $null
if ($SectionParams.ContainsKey('SourceUserProfilePath') -and `
    -not [string]::IsNullOrWhiteSpace($SectionParams['SourceUserProfilePath'])) {
    $sourceUserProfilePath = "$($SectionParams['SourceUserProfilePath'])"
}

# v0.56.0 (t-0003): retry-merge mode. When RetryMerge is set, this run folds its
# (failed-entry) results INTO the existing section manifest instead of replacing
# it, and uses the caller-supplied original ids (RetryEntryIds: sourcePath -> id)
# so each retried entry overwrites its ORIGINAL entries/<id>/data dir. This keeps
# the backup a single complete tree (successful entries from the first run stay).
$retryMerge = ($SectionParams.ContainsKey('RetryMerge') -and $SectionParams['RetryMerge'])
$retryEntryIds = @{}
if ($SectionParams.ContainsKey('RetryEntryIds') -and $SectionParams['RetryEntryIds'] -is [hashtable]) {
    $retryEntryIds = $SectionParams['RetryEntryIds']
}

# ----------------------------------------------------------
# Load CSV (FabriqBackUper-owned)
# ----------------------------------------------------------
$csvPath = Join-Path $BackuperRoot 'data\userdata_list.csv'
if (-not (Test-Path $csvPath)) {
    return [PSCustomObject]@{
        Status               = 'Failed'
        ElapsedMs            = [int]$sw.ElapsedMilliseconds
        Summary              = [ordered]@{}
        Warnings             = @("userdata_list.csv not found: $csvPath")
        ExternalOutputDir    = $null
        ExternalManifestPath = $null
    }
}

# Use Import-ModuleCsv for ENC: auto-decrypt (no harm if values are plain)
$allEntries = Import-ModuleCsv -Path $csvPath `
    -RequiredColumns @('Enabled','SourcePath','Recurse','ExcludePattern','OnConflict','IncludeAcl')

if ($null -eq $allEntries) {
    return [PSCustomObject]@{
        Status               = 'Failed'
        ElapsedMs            = [int]$sw.ElapsedMilliseconds
        Summary              = [ordered]@{}
        Warnings             = @("Failed to read userdata_list.csv")
        ExternalOutputDir    = $null
        ExternalManifestPath = $null
    }
}
$allEntries = @($allEntries)

# Apply filter: IncludeEntries override > CSV Enabled
$entries = if ($null -ne $includeEntries) {
    @($allEntries | Where-Object { $_.SourcePath -in $includeEntries })
} else {
    @($allEntries | Where-Object { $_.Enabled -eq '1' })
}

if ($entries.Count -eq 0) {
    return [PSCustomObject]@{
        Status               = 'Skipped'
        ElapsedMs            = [int]$sw.ElapsedMilliseconds
        Summary              = [ordered]@{ entryCount = 0; note = 'no entries selected or enabled' }
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
$robocopyExe = Get-Command robocopy.exe -ErrorAction SilentlyContinue
if ($null -eq $robocopyExe) {
    return [PSCustomObject]@{
        Status = 'Failed'; ElapsedMs = [int]$sw.ElapsedMilliseconds
        Summary = [ordered]@{}; Warnings = @('robocopy.exe not found')
    }
}

# ----------------------------------------------------------
# Section output dir
# ----------------------------------------------------------
$sectionDir = Join-Path $AggregateBackupDir 'sections\userdata'
try {
    $null = New-Item -ItemType Directory -Path $sectionDir -Force -ErrorAction Stop
    $null = New-Item -ItemType Directory -Path (Join-Path $sectionDir 'entries') -Force -ErrorAction Stop
} catch {
    return [PSCustomObject]@{
        Status = 'Failed'; ElapsedMs = [int]$sw.ElapsedMilliseconds
        Summary = [ordered]@{}; Warnings = @("Failed to create section output dir: $($_.Exception.Message)")
    }
}

Show-Info "Section output: $sectionDir"
Show-Info "Processing $($entries.Count) entry(ies) (from $($allEntries.Count) total)"

# ----------------------------------------------------------
# Helpers
# ----------------------------------------------------------
function Resolve-EntryPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    # Prefer user-aware expansion when a source profile path was supplied
    # (Phase 2.7), so admin-elevated runs map %USERPROFILE%/%APPDATA% etc.
    # to the chosen logged-on user instead of the elevating admin.
    $expanded = $null
    if (-not [string]::IsNullOrWhiteSpace($sourceUserProfilePath) -and `
        (Get-Command Expand-PathWithUser -ErrorAction SilentlyContinue)) {
        $expanded = Expand-PathWithUser -Path $Path.Trim() -UserProfilePath $sourceUserProfilePath
    } else {
        $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    }
    if ([string]::IsNullOrWhiteSpace($expanded)) { return $null }
    return $expanded
}
function ConvertFrom-ExcludePattern {
    param([string]$Raw)
    $result = @{ Files = @(); Dirs = @() }
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $result }
    foreach ($tok in $Raw.Split(';')) {
        $t = $tok.Trim()
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        if ($t.EndsWith('/') -or $t.EndsWith('\')) {
            $result.Dirs += $t.TrimEnd('/', '\')
        } else {
            $result.Files += $t
        }
    }
    return $result
}

# ----------------------------------------------------------
# Build entry plan
# ----------------------------------------------------------
$planned = @()
$entryIndex = 0
# v0.56.0 (t-0003): retry-merge id allocation. Entries present in the ORIGINAL
# backup reuse their original id (RetryEntryIds: sourcePath -> id) so they
# overwrite their own entries/<id>/data dir. Entries NOT in the map (added since
# the original backup, or otherwise unknown) get a FRESH id beyond every existing
# id -- they must NEVER fall back to a positional id, which could collide with and
# WIPE a successful sibling's dir (adversarial review finding).
$retryNextFreeId = 1
if ($retryMerge) {
    # Fresh-id floor = beyond every existing id, taken from BOTH the caller's id
    # map AND the entry dirs already on disk. Scanning the on-disk dirs makes this
    # robust even if the map is empty (prior manifest unreadable): a new/unmapped
    # entry then still gets an id beyond every existing entries/<id> dir, so it can
    # never reuse (and wipe) a sibling's dir.
    $maxId = 0
    foreach ($v in $retryEntryIds.Values) {
        $iv = 0
        if ([int]::TryParse("$v", [ref]$iv) -and $iv -gt $maxId) { $maxId = $iv }
    }
    $entriesRoot = Join-Path $sectionDir 'entries'
    if (Test-Path -LiteralPath $entriesRoot) {
        foreach ($d in @(Get-ChildItem -LiteralPath $entriesRoot -Directory -ErrorAction SilentlyContinue)) {
            $iv = 0
            if ([int]::TryParse($d.Name, [ref]$iv) -and $iv -gt $maxId) { $maxId = $iv }
        }
    }
    $retryNextFreeId = $maxId + 1
}
foreach ($e in $entries) {
    $entryIndex++
    if ($retryMerge) {
        if ($retryEntryIds.ContainsKey($e.SourcePath)) {
            $entryId = "$($retryEntryIds[$e.SourcePath])"
        } else {
            $entryId = "{0:D2}" -f $retryNextFreeId
            $retryNextFreeId++
        }
    } else {
        $entryId = "{0:D2}" -f $entryIndex
    }
    $resolved = Resolve-EntryPath -Path $e.SourcePath
    $existsAsDir  = $false
    $existsAsFile = $false
    if (-not [string]::IsNullOrWhiteSpace($resolved)) {
        $existsAsDir  = (Test-Path -LiteralPath $resolved -PathType Container)
        $existsAsFile = (Test-Path -LiteralPath $resolved -PathType Leaf)
    }
    $planned += [PSCustomObject]@{
        Index          = $entryIndex
        Id             = $entryId
        SourcePath     = $e.SourcePath
        ResolvedPath   = $resolved
        ExistsAsDir    = $existsAsDir
        ExistsAsFile   = $existsAsFile
        Recurse        = ($e.Recurse -eq '1')
        ExcludePattern = if ($null -ne $e.ExcludePattern) { $e.ExcludePattern.Trim() } else { '' }
        OnConflict     = if ([string]::IsNullOrWhiteSpace($e.OnConflict)) { 'skip' } else { $e.OnConflict.Trim().ToLower() }
        IncludeAcl     = ($e.IncludeAcl -eq '1')
        Description    = if ($null -ne $e.Description) { $e.Description } else { '' }
    }
}

# ----------------------------------------------------------
# Phase 2.7.8: hand the planned list to the Progress View
# checklist so operators can track per-entry completion.
# Phase 2.7.9: Get-Command gate was unreliable when section is
# invoked via `& $scriptPath` — dynamic scope chain works for
# DIRECT function calls (Test-AdminPrivilege etc.) but
# Get-Command lookup may not surface parent-scope functions.
# Wrap the call in try/catch so console-only invocation still
# degrades gracefully.
# ----------------------------------------------------------
try {
    $uiEntries = foreach ($p in $planned) {
        $label = if (-not [string]::IsNullOrWhiteSpace($p.Description)) {
            "$($p.Description)  ($($p.SourcePath))"
        } else {
            "$($p.SourcePath)"
        }
        @{ Id = $p.Id; Label = $label }
    }
    Initialize-ProgressEntries -Entries @($uiEntries)
} catch { }

# ----------------------------------------------------------
# Execute backup
# ----------------------------------------------------------
$manifestEntries = @()
$successCount = 0; $skipCount = 0; $failCount = 0

foreach ($p in $planned) {
    try { Set-EntryStatus -Id $p.Id -Status 'InProgress' } catch { }
    $entryDir = Join-Path (Join-Path $sectionDir 'entries') $p.Id
    $dataDir  = Join-Path $entryDir 'data'
    $logFile  = Join-Path $entryDir 'entry_log.txt'
    $status   = 'Success'
    $reason   = $null
    $rcExit   = $null
    $fileCount = 0; $dirCount = 0; $byteCount = 0

    Show-Info "[$($p.Id)] $($p.ResolvedPath)"

    if (-not $p.ExistsAsDir -and -not $p.ExistsAsFile) {
        Show-Skip "  Source path does not exist"
        $warnings += "Missing source: $($p.ResolvedPath)"
        $status = 'Skipped'; $reason = 'Source path not found'
        $skipCount++
        $manifestEntries += [PSCustomObject]@{
            id              = $p.Id
            sourcePath      = $p.SourcePath
            resolvedPath    = $p.ResolvedPath
            isDirectory     = $false
            recurse         = $p.Recurse
            excludePattern  = $p.ExcludePattern
            onConflict      = $p.OnConflict
            includeAcl      = $p.IncludeAcl
            fileCount       = 0
            dirCount        = 0
            byteCount       = 0
            backupSubpath   = $null
            robocopyExitCode = $null
            status          = $status
            reason          = $reason
        }
        try { Set-EntryStatus -Id $p.Id -Status 'Skipped' } catch { }
        continue
    }

    try {
        # v0.56.0: on retry, wipe the re-processed entry's data first so its
        # backup exactly matches the source (robocopy here is additive, not /MIR,
        # so stale partial files from the failed first run could otherwise linger).
        if ($retryMerge -and (Test-Path -LiteralPath $dataDir)) {
            Remove-Item -LiteralPath $dataDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $null = New-Item -ItemType Directory -Path $dataDir -Force -ErrorAction Stop
    } catch {
        $warnings += "Entry $($p.Id) dir creation failed: $($_.Exception.Message)"
        $failCount++
        # v0.56.0: record a Failed manifest entry (mirroring the missing-source
        # branch) so the manifest-driven status computation sees this failure --
        # without it a dir-creation failure would be invisible and the section
        # mis-reported as Success.
        $manifestEntries += [PSCustomObject]@{
            id              = $p.Id
            sourcePath      = $p.SourcePath
            resolvedPath    = $p.ResolvedPath
            isDirectory     = [bool]$p.ExistsAsDir
            recurse         = $p.Recurse
            excludePattern  = $p.ExcludePattern
            onConflict      = $p.OnConflict
            includeAcl      = $p.IncludeAcl
            fileCount       = 0
            dirCount        = 0
            byteCount       = 0
            backupSubpath   = $null
            robocopyExitCode = $null
            status          = 'Failed'
            reason          = 'dir creation failed'
        }
        try { Set-EntryStatus -Id $p.Id -Status 'Failed' } catch { }
        continue
    }

    $excludes = ConvertFrom-ExcludePattern -Raw $p.ExcludePattern
    $copyFlag = if ($p.IncludeAcl) { '/COPYALL' } else { '/COPY:DAT' }

    if ($p.ExistsAsDir) {
        # /XJD: eXclude Junction Directories. The XP-era compatibility
        # junctions inside the user profile (Documents\My Pictures ->
        # Pictures, Documents\My Music -> Music, Documents\My Videos ->
        # Videos, AppData\Local\Application Data -> AppData\Local etc.)
        # would otherwise be FOLLOWED by robocopy /E, leaking sibling
        # folder contents into the wrong backup subpath. On restore, the
        # same target-side junctions would silently re-route those files
        # to the real Pictures / Music / Videos, producing the
        # "Pictures shows up in Documents but ends up in Pictures on
        # restore" phenomenon. /XJD makes the recursion respect the
        # logical folder boundaries instead of NTFS reparse points.
        # /MT:16 = 16-thread copy. Robocopy default is /MT:8; bumping to 16
        # gives 10-20% throughput improvement for many-small-file workloads
        # (AppData / browser caches in user profiles) on SSD or UNC
        # destinations. Conservative vs /MT:32 to avoid HDD seek-storm on
        # spinning-disk targets.
        if ($p.Recurse) {
            $rcArgs = @($p.ResolvedPath, $dataDir, '/E', '/XJD', $copyFlag, '/B', '/MT:16', '/R:1', '/W:1', '/NP')
        } else {
            $rcArgs = @($p.ResolvedPath, $dataDir, '/LEV:1', '/XJD', $copyFlag, '/B', '/MT:16', '/R:1', '/W:1', '/NP')
        }
        if ($excludes.Files.Count -gt 0) { $rcArgs += '/XF'; $rcArgs += $excludes.Files }
        if ($excludes.Dirs.Count -gt 0)  { $rcArgs += '/XD'; $rcArgs += $excludes.Dirs }
    } else {
        $parentDir = Split-Path -Path $p.ResolvedPath -Parent
        $fileName  = Split-Path -Path $p.ResolvedPath -Leaf
        $rcArgs = @($parentDir, $dataDir, $fileName, $copyFlag, '/B', '/R:1', '/W:1', '/NP', '/NDL', '/NS', '/NC')
    }

    Show-Info "  robocopy ..."
    try { Add-ProgressLog "  [$($p.Id)] robocopy $($p.ResolvedPath) -> $dataDir" } catch { }
    # Phase 2.7.4: stream robocopy stdout/stderr line-by-line. Each line is
    # (a) appended to entry_log.txt (preserves existing artifact) and
    # (b) forwarded to the Progress View log with periodic DoEvents() so the
    # WinForms message pump can render incremental updates. Without this the
    # whole backup ran silently on the UI thread until completion.
    # Phase 2.7.9: removed the Get-Command Add-ProgressLog gate — it was
    # silently no-op'ing in the section's `&`-invoked scope. Direct call
    # works via PowerShell's dynamic-scope function lookup (same as
    # Test-AdminPrivilege / Show-Info above); try/catch keeps the
    # console-only / no-GUI fallback path safe.
    $logStream = [System.IO.StreamWriter]::new($logFile, $false, [System.Text.Encoding]::UTF8)
    try {
        $rcLine = 0
        & robocopy.exe @rcArgs 2>&1 | ForEach-Object {
            $line = "$_"
            $logStream.WriteLine($line)
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                try { Add-ProgressLog "    $($line.TrimEnd())" } catch { }
                $rcLine++
                if (($rcLine % 8) -eq 0 -and `
                    ([System.Windows.Forms.Application] -as [type])) {
                    [System.Windows.Forms.Application]::DoEvents()
                }
            }
        }
    } finally {
        $logStream.Close()
    }
    $rcExit = $LASTEXITCODE

    if ($rcExit -ge 8) {
        Show-Error "  robocopy failures (exit $rcExit)"
        $warnings += "robocopy exit $rcExit for entry $($p.Id)"
        $status = 'Failed'; $reason = "robocopy exit $rcExit"
        $failCount++
    } elseif ($rcExit -ge 4) {
        Show-Warning "  robocopy mismatches (exit $rcExit)"
        $warnings += "robocopy mismatch (exit $rcExit) for entry $($p.Id)"
        $status = 'Partial'; $reason = "robocopy mismatch"
        $successCount++
    } else {
        Show-Success "  copied (exit $rcExit)"
        $successCount++
    }

    $copied = @(Get-ChildItem -Path $dataDir -Recurse -ErrorAction SilentlyContinue)
    $fileCount = @($copied | Where-Object { -not $_.PSIsContainer }).Count
    $dirCount  = @($copied | Where-Object { $_.PSIsContainer }).Count
    $byteSum   = ($copied | Where-Object { -not $_.PSIsContainer } |
                  Measure-Object -Property Length -Sum).Sum
    if ($null -ne $byteSum) { $byteCount = [long]$byteSum }

    $manifestEntries += [PSCustomObject]@{
        id              = $p.Id
        sourcePath      = $p.SourcePath
        resolvedPath    = $p.ResolvedPath
        isDirectory     = [bool]$p.ExistsAsDir
        recurse         = $p.Recurse
        excludePattern  = $p.ExcludePattern
        onConflict      = $p.OnConflict
        includeAcl      = $p.IncludeAcl
        fileCount       = $fileCount
        dirCount        = $dirCount
        byteCount       = $byteCount
        backupSubpath   = "entries/$($p.Id)/data"
        robocopyExitCode = $rcExit
        status          = $status
        reason          = $reason
    }

    $uiStatus = switch ($status) {
        'Success' { 'Done' }
        'Failed'  { 'Failed' }
        'Partial' { 'Partial' }
        'Skipped' { 'Skipped' }
        default   { 'Done' }
    }
    try { Set-EntryStatus -Id $p.Id -Status $uiStatus } catch { }
}

# ----------------------------------------------------------
# v0.56.0 (t-0003): retry-merge -- fold the just-processed (retried) entries into
# the ORIGINAL run's manifest entries so the section manifest stays COMPLETE
# (successful entries from the first run are kept; retried entries replace their
# old records by id). The counts / status / Summary below are then computed over
# the merged set. id is stable across runs (caller passes the original ids), so
# matching/overwriting by id is correct.
# ----------------------------------------------------------
$retryMergeAbort = $false
if ($retryMerge) {
    $existingManifestPath = Join-Path $sectionDir 'manifest.json'
    if (Test-Path -LiteralPath $existingManifestPath) {
        try {
            $existingUd = (Get-Content -LiteralPath $existingManifestPath -Raw -Encoding UTF8) | ConvertFrom-Json
            $existingEntries = @()
            if ($existingUd -and $existingUd.items -and $existingUd.items.entries) {
                $existingEntries = @($existingUd.items.entries)
            }
            $retriedIds = @{}
            foreach ($me in $manifestEntries) { $retriedIds["$($me.id)"] = $true }
            $kept = @($existingEntries | Where-Object { -not $retriedIds.ContainsKey("$($_.id)") })
            $manifestEntries = @(@(@($kept) + @($manifestEntries)) | Sort-Object { [int]("$($_.id)") })
            Show-Info "Retry-merge: kept $($kept.Count) existing + $($retriedIds.Count) retried = $($manifestEntries.Count) entry(ies)"
        } catch {
            # The existing manifest is present but unreadable. Do NOT overwrite it
            # with a retried-only manifest (that would drop the previously-
            # successful entries' records, so restore would skip their preserved
            # data). Abort the manifest write below + mark the section Failed.
            $retryMergeAbort = $true
            Show-Error "Retry-merge: existing userdata manifest unreadable; preserving it and marking the section Failed for manual review: $($_.Exception.Message)"
        }
    }
}

# ----------------------------------------------------------
# Build manifest (fabriq-userdata-backup schemaVersion=1)
# ----------------------------------------------------------
$hwUid = $null
try { $hwUid = (Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop |
                Select-Object -First 1).UUID } catch { }
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

$totalFiles = ($manifestEntries | Measure-Object -Property fileCount -Sum).Sum; if ($null -eq $totalFiles) { $totalFiles = 0 }
$totalDirs  = ($manifestEntries | Measure-Object -Property dirCount  -Sum).Sum; if ($null -eq $totalDirs)  { $totalDirs  = 0 }
$totalBytes = ($manifestEntries | Measure-Object -Property byteCount -Sum).Sum; if ($null -eq $totalBytes) { $totalBytes = 0 }
$missingCount = @($manifestEntries | Where-Object { $_.status -eq 'Skipped' -and $_.reason -eq 'Source path not found' }).Count

$sourceUserName = $null
if (-not [string]::IsNullOrWhiteSpace($sourceUserProfilePath)) {
    try { $sourceUserName = Split-Path $sourceUserProfilePath -Leaf } catch { }
}

$manifest = [ordered]@{
    schemaVersion       = 1
    manifestType        = "fabriq-userdata-backup"
    backupVersion       = $moduleVersion
    fabriqKernelVersion = $kernelVersion
    collectedAt         = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
    computerName        = $OldPcName
    hardwareUniqueId    = $hwUid
    osVersion           = $osVersion
    osArch              = $osArch
    sourceUser          = [ordered]@{
        profilePath = $sourceUserProfilePath
        userName    = $sourceUserName
    }
    counts              = [ordered]@{
        entry          = $manifestEntries.Count
        file           = [long]$totalFiles
        dir            = [long]$totalDirs
        missingSource  = $missingCount
    }
    sizes               = [ordered]@{ totalBytes = [long]$totalBytes }
    items               = [ordered]@{ entries = @($manifestEntries) }
    warnings            = @($warnings)
}

$manifestPath = Join-Path $sectionDir 'manifest.json'
# v0.56.0: on a retry whose existing manifest was unreadable, do NOT overwrite it
# (preserve the original records; see $retryMergeAbort above).
if (-not $retryMergeAbort) {
    $manifest | ConvertTo-Json -Depth 8 | Out-File -FilePath $manifestPath -Encoding UTF8 -Force
}

$sw.Stop()

# v0.56.0: compute status over the (possibly merged) entry set via each entry's
# status field, so a retry that fills the last failures flips the section to
# Success even though THIS run only processed the previously-failed entries.
$mFail = @($manifestEntries | Where-Object { "$($_.status)" -eq 'Failed' }).Count
$mOk   = @($manifestEntries | Where-Object { "$($_.status)" -eq 'Success' -or "$($_.status)" -eq 'Partial' }).Count
$status = if ($mFail -gt 0 -and $mOk -eq 0) { 'Failed' }
          elseif ($mFail -gt 0) { 'Partial' }
          else { 'Success' }
# v0.56.0: a retry that couldn't safely merge its manifest is a hard failure.
if ($retryMergeAbort) { $status = 'Failed' }

return [PSCustomObject]@{
    Status               = $status
    ElapsedMs            = [int]$sw.ElapsedMilliseconds
    Summary              = [ordered]@{
        entryCount = $manifestEntries.Count
        fileCount  = [long]$totalFiles
        dirCount   = [long]$totalDirs
        totalBytes = [long]$totalBytes
    }
    Warnings             = $warnings
    ExternalOutputDir    = $null
    ExternalManifestPath = $null
    InternalSectionDir   = $sectionDir
    InternalManifestPath = $manifestPath
}
