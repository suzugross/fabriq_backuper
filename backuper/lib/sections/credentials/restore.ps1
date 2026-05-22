# ============================================================
# FabriqBackUper Section: credentials / restore (v0.19.0 initial)
#
# Deploys an operator-runnable credential re-registration payload
# to the target user's Documents folder:
#
#   <TargetUserProfilePath>\Documents\
#     FabriqCredentialsBackup_<oldHost>_<timestamp>\
#       credentials_list.csv         (copied from the backup)
#       register_credentials.ps1     (operator-facing PS1)
#       登録.bat                      (ASCII wrapper that launches
#                                     PS1 with -ExecutionPolicy Bypass)
#       README.txt                   (operator instructions, JP)
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
    return [PSCustomObject]@{
        Status               = 'Failed'
        ElapsedMs            = [int]$sw.ElapsedMilliseconds
        Summary              = [ordered]@{}
        Warnings             = @("Source manifest.json not found: $srcManifest")
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

foreach ($p in @($payloadPs1, $payloadBat, $payloadReadme)) {
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
# ----------------------------------------------------------
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
# Copy payload + CSV
# ----------------------------------------------------------
$copied = @()
try {
    Copy-Item -LiteralPath $srcCsv      -Destination (Join-Path $deployDir 'credentials_list.csv') -Force -ErrorAction Stop
    $copied += 'credentials_list.csv'

    Copy-Item -LiteralPath $payloadPs1  -Destination (Join-Path $deployDir 'register_credentials.ps1') -Force -ErrorAction Stop
    $copied += 'register_credentials.ps1'

    Copy-Item -LiteralPath $payloadBat  -Destination (Join-Path $deployDir '登録.bat') -Force -ErrorAction Stop
    $copied += '登録.bat'

    Copy-Item -LiteralPath $payloadReadme -Destination (Join-Path $deployDir 'README.txt') -Force -ErrorAction Stop
    $copied += 'README.txt'
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
if ($copied.Count -lt 4) {
    $status = 'Partial'
}
if ($copied.Count -eq 0) {
    $status = 'Failed'
}

Show-Info ("credentials/restore: deployed {0} files to {1} (status: {2})" -f $copied.Count, $deployDir, $status)
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
    }
    Warnings             = $warnings
    ExternalOutputDir    = $null
    ExternalManifestPath = $null
    InternalSectionDir   = $sectionDir
    InternalManifestPath = $deployManifestPath
}
