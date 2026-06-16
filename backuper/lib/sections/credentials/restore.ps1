# ============================================================
# FabriqBackUper Section: credentials / restore (v0.19.0 initial)
#
# Deploys an operator-runnable credential payload. v0.38.0: the folder FRONT
# shows mostly batches; all support files live in _data\.
#
#   <deploy root>\   (handoff 01_資格情報\, or legacy Documents\FabriqCredentialsBackup_<host>_<ts>\)
#     登録.bat                  (register-all; runs _data\register_credentials.ps1)
#     資格情報を表示.bat        (read-only viewer; runs _data\Show-Credentials.ps1)
#     _data\
#       credentials_list.csv      (from the backup; NO passwords)
#       register_credentials.ps1  (operator-facing PS1, CredWrite, -ExecutionPolicy Bypass)
#       Show-Credentials.ps1      (read-only WinForms list of the source-PC credentials)
#       README.txt                (operator instructions, JP)
#
# The actual re-registration into Windows Credential Manager
# happens later, when the operator double-clicks 登録.bat in their
# (= the target user's) session. This section script does NOT
# call CredWrite directly - it just stages the payload.
#
# Rationale (see backup.ps1 banner): DPAPI is per-user. The
# backuper itself runs as admin (possibly a different user from
# the target). CredWrite from the admin context would write into
# the WRONG user's vault. The operator runs the deployed
# 登録.bat as the target user, so CredWrite writes into the
# correct vault.
#
# SectionParams (hashtable, all optional):
#   TargetUserProfilePath : profile path of the user whose Documents
#                           to deploy into. Falls back to $env:USERPROFILE
#                           (= current admin user, likely wrong).
#   IncludeTargets        : array of Target strings (from the source CSV's
#                           "Target" column) to deploy. When provided, the
#                           deployed CSV only contains rows whose Target
#                           appears in this list. $null / empty / absent =
#                           include all rows (= v0.19.x behavior). v0.20.0+.
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
$targetUserProfilePath = $null
if ($SectionParams.ContainsKey('TargetUserProfilePath') -and `
    -not [string]::IsNullOrWhiteSpace($SectionParams['TargetUserProfilePath'])) {
    $targetUserProfilePath = "$($SectionParams['TargetUserProfilePath'])"
} else {
    $targetUserProfilePath = $env:USERPROFILE
    $warnings += "TargetUserProfilePath not provided; falling back to current process profile ($targetUserProfilePath)"
}

# v0.20.0: optional IncludeTargets filter. $null / absent = include all
# rows. If provided, only rows whose Target is in this set go into the
# deployed CSV.
$includeTargetSet = $null
if ($SectionParams.ContainsKey('IncludeTargets') -and `
    $null -ne $SectionParams['IncludeTargets']) {
    $includeArr = @($SectionParams['IncludeTargets'])
    # Treat empty array as "explicit zero" (operator wants nothing
    # deployed) rather than "include all". Distinguishes from $null.
    $includeTargetSet = New-Object System.Collections.Generic.HashSet[string]
    foreach ($t in $includeArr) { [void]$includeTargetSet.Add([string]$t) }
}

# v0.25.0: optional OperatorHandoffSubdir. When provided (non-empty),
# deploy directly into <Desktop>\<date>_<host>_BK\01_資格情報\ instead of
# <Documents>\FabriqCredentialsBackup_<host>_<ts>\. The parent date+host
# folder name already encodes the date, so no per-restore timestamp
# suffix is appended on the handoff path. Absent / null / empty = legacy
# Documents path (v0.24.5 compatible).
$operatorHandoffSubdir = if ($SectionParams.ContainsKey('OperatorHandoffSubdir') -and `
    -not [string]::IsNullOrWhiteSpace($SectionParams['OperatorHandoffSubdir'])) {
    "$($SectionParams['OperatorHandoffSubdir'])"
} else {
    $null
}

if (-not (Test-Path $targetUserProfilePath)) {
    return [PSCustomObject]@{
        Status               = 'Failed'
        ElapsedMs            = [int]$sw.ElapsedMilliseconds
        Summary              = [ordered]@{}
        Warnings             = @("Target user profile path does not exist: $targetUserProfilePath")
        ExternalOutputDir    = $null
        ExternalManifestPath = $null
        InternalSectionDir   = $null
        InternalManifestPath = $null
    }
}

# ----------------------------------------------------------
# Source paths in the aggregate backup
# ----------------------------------------------------------
$srcSectionDir = Join-Path $AggregateBackupDir 'sections\credentials'
$srcManifest   = Join-Path $srcSectionDir 'manifest.json'
$srcCsv        = Join-Path $srcSectionDir '_credentials_list.csv'

if (-not (Test-Path $srcManifest)) {
    # v0.73.2: a section de-selected at backup time is absent from the aggregate
    # manifest -> benign Skipped (not a failure). If the aggregate DOES list it but
    # the per-section manifest is gone, that is real corruption -> keep Failed.
    $wasBackedUp = $false
    $aggManifest = Join-Path $AggregateBackupDir 'manifest.json'
    if (Test-Path $aggManifest) {
        try {
            $aggDoc = Get-Content -Path $aggManifest -Raw | ConvertFrom-Json
            if ($null -ne $aggDoc.sections -and `
                ($aggDoc.sections.PSObject.Properties.Name -contains 'credentials') -and `
                ("$($aggDoc.sections.credentials.status)" -ne 'Skipped')) { $wasBackedUp = $true }
        } catch { $wasBackedUp = $true }   # unreadable aggregate -> conservative Failed
    }
    $st  = if ($wasBackedUp) { 'Failed' } else { 'Skipped' }
    $msg = if ($wasBackedUp) { "Source manifest.json not found though aggregate lists this section (possible transfer corruption): $srcManifest" }
           else { "section was not backed up (absent from aggregate manifest); nothing to restore" }
    return [PSCustomObject]@{
        Status               = $st
        ElapsedMs            = [int]$sw.ElapsedMilliseconds
        Summary              = [ordered]@{}
        Warnings             = @($msg)
        ExternalOutputDir    = $null
        ExternalManifestPath = $null
        InternalSectionDir   = $null
        InternalManifestPath = $null
    }
}

if (-not (Test-Path $srcCsv)) {
    return [PSCustomObject]@{
        Status               = 'Failed'
        ElapsedMs            = [int]$sw.ElapsedMilliseconds
        Summary              = [ordered]@{}
        Warnings             = @("Source _credentials_list.csv not found: $srcCsv")
        ExternalOutputDir    = $null
        ExternalManifestPath = $null
        InternalSectionDir   = $null
        InternalManifestPath = $null
    }
}

# Parse manifest to drive popup / summary content
$srcManifestObj = $null
try {
    $srcManifestObj = Get-Content -Path $srcManifest -Raw | ConvertFrom-Json -ErrorAction Stop
} catch {
    $warnings += "Could not parse source manifest.json: $($_.Exception.Message); proceeding with file deploy only"
}

# ----------------------------------------------------------
# Locate operator payload (next to this script)
# ----------------------------------------------------------
$payloadDir = Join-Path $PSScriptRoot 'operator_payload'
$payloadPs1 = Join-Path $payloadDir 'register_credentials.ps1'
$payloadBat = Join-Path $payloadDir '登録.bat'
$payloadReadme = Join-Path $payloadDir 'README.txt'
# v0.38.0: read-only viewer (lists the source-PC credentials) + its launcher.
$payloadViewer = Join-Path $payloadDir 'Show-Credentials.ps1'
$payloadViewerBat = Join-Path $payloadDir '資格情報を表示.bat'

foreach ($p in @($payloadPs1, $payloadBat, $payloadReadme, $payloadViewer, $payloadViewerBat)) {
    if (-not (Test-Path $p)) {
        return [PSCustomObject]@{
            Status               = 'Failed'
            ElapsedMs            = [int]$sw.ElapsedMilliseconds
            Summary              = [ordered]@{}
            Warnings             = @("Operator payload file missing: $p")
            ExternalOutputDir    = $null
            ExternalManifestPath = $null
            InternalSectionDir   = $null
            InternalManifestPath = $null
        }
    }
}

# ----------------------------------------------------------
# Determine deploy destination
# v0.25.0: Two-path resolution.
#   - OperatorHandoffSubdir provided -> deploy into the handoff subdir
#     directly (no timestamp suffix; parent <date>_<host>_BK already
#     encodes the date). New-Item -Force handles missing parents.
#   - Absent -> legacy Documents\FabriqCredentialsBackup_<host>_<ts>\
#     path (v0.19.x .. v0.24.5 behaviour). Documents dir is created
#     on demand for users whose profile lacks a Documents folder.
# ----------------------------------------------------------
if ($null -ne $operatorHandoffSubdir) {
    $deployDir = $operatorHandoffSubdir
} else {
    $documentsDir = Join-Path $targetUserProfilePath 'Documents'
    if (-not (Test-Path $documentsDir)) {
        try {
            $null = New-Item -ItemType Directory -Path $documentsDir -Force -ErrorAction Stop
        } catch {
            return [PSCustomObject]@{
                Status               = 'Failed'
                ElapsedMs            = [int]$sw.ElapsedMilliseconds
                Summary              = [ordered]@{}
                Warnings             = @("Could not create Documents dir at $documentsDir : $($_.Exception.Message)")
                ExternalOutputDir    = $null
                ExternalManifestPath = $null
                InternalSectionDir   = $null
                InternalManifestPath = $null
            }
        }
    }
    $stamp     = (Get-Date).ToString('yyyy_MM_dd_HHmmss')
    $deployDir = Join-Path $documentsDir ("FabriqCredentialsBackup_{0}_{1}" -f $OldPcName, $stamp)
}

try {
    $null = New-Item -ItemType Directory -Path $deployDir -Force -ErrorAction Stop
} catch {
    return [PSCustomObject]@{
        Status               = 'Failed'
        ElapsedMs            = [int]$sw.ElapsedMilliseconds
        Summary              = [ordered]@{}
        Warnings             = @("Could not create deploy dir at $deployDir : $($_.Exception.Message)")
        ExternalOutputDir    = $null
        ExternalManifestPath = $null
        InternalSectionDir   = $null
        InternalManifestPath = $null
    }
}

# ----------------------------------------------------------
# Deploy CSV (verbatim copy OR filtered by IncludeTargets) + payload
# ----------------------------------------------------------
$copied         = @()
$deployedCount  = 0
$srcRowCount    = 0
# v0.38.0: keep the folder FRONT mostly batches (登録.bat = register-all,
# 資格情報を表示.bat = the read-only viewer). All support files (CSV, the
# register/viewer .ps1, README) go into _data\, which the front batches
# reference via "%~dp0_data\".
$deployDataDir  = Join-Path $deployDir '_data'
$deployCsvPath  = Join-Path $deployDataDir 'credentials_list.csv'

try {
    if (-not (Test-Path -LiteralPath $deployDataDir)) {
        $null = New-Item -ItemType Directory -Path $deployDataDir -Force -ErrorAction Stop
    }

    if ($null -eq $includeTargetSet) {
        # v0.19.x behavior: copy source CSV verbatim
        Copy-Item -LiteralPath $srcCsv -Destination $deployCsvPath -Force -ErrorAction Stop
        # Count rows (Import-Csv returns rows excluding header)
        try { $srcRowCount = @(Import-Csv -LiteralPath $srcCsv -Encoding UTF8).Count } catch {}
        $deployedCount = $srcRowCount
    } else {
        # v0.20.0: filter rows by Target ∈ IncludeTargets
        $srcRows = @(Import-Csv -LiteralPath $srcCsv -Encoding UTF8)
        $srcRowCount = $srcRows.Count
        $kept = @($srcRows | Where-Object { $includeTargetSet.Contains([string]$_.Target) })
        $deployedCount = $kept.Count

        # Re-emit CSV with UTF-8 BOM + CRLF (mirror backup.ps1 format)
        $csvLines = @('Store,Type,Target,UserName,Persist,Comment,LastWritten,BlobSize,RestoreHint')
        foreach ($r in $kept) {
            $csvRow = ($r | Select-Object Store, Type, Target, UserName, Persist, Comment, LastWritten, BlobSize, RestoreHint |
                ConvertTo-Csv -NoTypeInformation | Select-Object -Last 1)
            $csvLines += $csvRow
        }
        $csvText  = ($csvLines -join "`r`n") + "`r`n"
        $bomBytes = [byte[]](0xEF, 0xBB, 0xBF)
        $csvBytes = $bomBytes + [System.Text.Encoding]::UTF8.GetBytes($csvText)
        [System.IO.File]::WriteAllBytes($deployCsvPath, $csvBytes)
    }
    $copied += '_data\credentials_list.csv'

    # --- support files -> _data\ ---
    Copy-Item -LiteralPath $payloadPs1    -Destination (Join-Path $deployDataDir 'register_credentials.ps1') -Force -ErrorAction Stop
    $copied += '_data\register_credentials.ps1'
    Copy-Item -LiteralPath $payloadViewer -Destination (Join-Path $deployDataDir 'Show-Credentials.ps1') -Force -ErrorAction Stop
    $copied += '_data\Show-Credentials.ps1'
    Copy-Item -LiteralPath $payloadReadme -Destination (Join-Path $deployDataDir 'README.txt') -Force -ErrorAction Stop
    $copied += '_data\README.txt'

    # --- launcher batches -> FRONT ---
    Copy-Item -LiteralPath $payloadBat       -Destination (Join-Path $deployDir '登録.bat') -Force -ErrorAction Stop
    $copied += '登録.bat'
    Copy-Item -LiteralPath $payloadViewerBat -Destination (Join-Path $deployDir '資格情報を表示.bat') -Force -ErrorAction Stop
    $copied += '資格情報を表示.bat'
} catch {
    $warnings += "File copy failed: $($_.Exception.Message)"
}

# ----------------------------------------------------------
# Write a per-deploy section manifest (for traceability /
# aggregate manifest indexing)
# ----------------------------------------------------------
$sectionDir = Join-Path $AggregateBackupDir 'sections\credentials'
$deployManifestPath = Join-Path $sectionDir 'restore_manifest.json'

$deployManifest = [ordered]@{
    schemaVersion         = 1
    manifestType          = 'fabriq-credentials-restore'
    restoredAt            = (Get-Date).ToString('o')
    sourceHost            = $OldPcName
    targetUserProfilePath = $targetUserProfilePath
    deployDir             = $deployDir
    deployedFiles         = $copied
    sourceCredentialCount = if ($srcManifestObj) { [int]$srcManifestObj.credentialCount } else { $null }
    sourceManualHintCount = if ($srcManifestObj) { [int]$srcManifestObj.manualHintCount } else { $null }
    sourceCsvRowCount     = $srcRowCount
    deployedCsvRowCount   = $deployedCount
    includeTargetsApplied = ($null -ne $includeTargetSet)
    warnings              = $warnings
}

try {
    $deployManifest | ConvertTo-Json -Depth 4 | Out-File -FilePath $deployManifestPath -Encoding UTF8 -Force
} catch {
    $warnings += "Could not write restore_manifest.json: $($_.Exception.Message)"
}

# ----------------------------------------------------------
# Decide Status
# ----------------------------------------------------------
$status = 'Success'
# v0.38.0: 6 files expected (_data\: csv + register.ps1 + viewer.ps1 + README;
# front: 登録.bat + 資格情報を表示.bat).
if ($copied.Count -lt 6) {
    $status = 'Partial'
}
if ($copied.Count -eq 0) {
    $status = 'Failed'
}

Show-Info ("credentials/restore: deployed {0} files to {1} (status: {2})" -f $copied.Count, $deployDir, $status)
if ($null -ne $includeTargetSet) {
    Show-Info ("credentials/restore: IncludeTargets filter applied - {0} of {1} rows kept in deployed CSV" -f `
        $deployedCount, $srcRowCount)
} elseif ($srcRowCount -gt 0) {
    Show-Info ("credentials/restore: deployed CSV contains all {0} rows (no IncludeTargets filter)" -f $srcRowCount)
}
if ($srcManifestObj) {
    Show-Info ("credentials/restore: source contained {0} credentials ({1} marked manual)" -f `
        $srcManifestObj.credentialCount, $srcManifestObj.manualHintCount)
}

# ----------------------------------------------------------
# Return
# ----------------------------------------------------------
return [PSCustomObject]@{
    Status               = $status
    ElapsedMs            = [int]$sw.ElapsedMilliseconds
    Summary              = [ordered]@{
        targetUserProfilePath = $targetUserProfilePath
        deployDir             = $deployDir
        deployedFileCount     = $copied.Count
        sourceCredentialCount = if ($srcManifestObj) { [int]$srcManifestObj.credentialCount } else { $null }
        sourceManualHintCount = if ($srcManifestObj) { [int]$srcManifestObj.manualHintCount } else { $null }
        sourceCsvRowCount     = $srcRowCount
        deployedCsvRowCount   = $deployedCount
        includeTargetsApplied = ($null -ne $includeTargetSet)
    }
    Warnings             = $warnings
    ExternalOutputDir    = $null
    ExternalManifestPath = $null
    InternalSectionDir   = $sectionDir
    InternalManifestPath = $deployManifestPath
}
