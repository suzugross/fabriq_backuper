# ============================================================
# FabriqBackUper Section: msime_dict / backup (v0.22.0 initial)
#
# Captures the Microsoft IME user dictionary for the selected
# source user:
#   %APPDATA%\Microsoft\IME\15.0\IMEJP\UserDict\imjp15cu.dic
#   %APPDATA%\Microsoft\IME\15.0\IMEJP\UserDict\imjp15cu.dic_bak
#
# Design notes:
#   - The MSIME internal version (15.0) and the on-disk path are
#     fixed across Win10, Win11 23H2/24H2/25H2, and the "new" Win11
#     IME. Per ti-web.net / 1-notes.com / dynabook docs (confirmed
#     2026-05-23) the new Microsoft IME still reads/writes the same
#     imjp15cu.dic. So a flat file copy is portable across the
#     supported OS/IME matrix without any branching on OS or IME
#     version; the operator does not need to choose anything.
#   - The learning cache under %LOCALAPPDATA%\Microsoft\IME\15.0
#     \IMEJP\Cache\imjp15cache.dat is INTENTIONALLY excluded. The
#     cache can leave IME in an unstable state when restored to a
#     different machine; the trade-off is acceptable because the
#     dictionary (user-registered words) is the operator-visible
#     value while the cache (conversion bias) is rebuilt over time.
#   - The IMEJP process can hold a file lock on imjp15cu.dic.
#     We invoke robocopy with /B (backup mode) so the admin token
#     reads through the lock without needing to stop the IME on
#     the source side.
#
# SectionParams (hashtable, all optional):
#   SourceUserProfilePath : profile path of the user whose IME
#                           dictionary to capture. Resolved by the
#                           backup_view ComboBox. When absent we
#                           fall back to $env:USERPROFILE (= admin
#                           user, likely wrong under cross-user
#                           elevation; warn in that case).
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
# Resolve source user profile path
# ----------------------------------------------------------
$sourceUserProfilePath = $null
if ($SectionParams.ContainsKey('SourceUserProfilePath') -and `
    -not [string]::IsNullOrWhiteSpace($SectionParams['SourceUserProfilePath'])) {
    $sourceUserProfilePath = "$($SectionParams['SourceUserProfilePath'])"
}
if ([string]::IsNullOrWhiteSpace($sourceUserProfilePath)) {
    $sourceUserProfilePath = $env:USERPROFILE
    $warnings += "SourceUserProfilePath not provided; falling back to current process profile ($sourceUserProfilePath)"
}

# ----------------------------------------------------------
# Prepare section output directory
# ----------------------------------------------------------
$sectionDir = Join-Path $AggregateBackupDir 'sections\msime_dict'
$payloadDir = Join-Path $sectionDir 'payload'
try {
    $null = New-Item -ItemType Directory -Path $payloadDir -Force -ErrorAction Stop
} catch {
    return [PSCustomObject]@{
        Status               = 'Failed'
        ElapsedMs            = [int]$sw.ElapsedMilliseconds
        Summary              = [ordered]@{}
        Warnings             = @("Failed to create payload dir: $($_.Exception.Message)")
        ExternalOutputDir    = $null
        ExternalManifestPath = $null
        InternalSectionDir   = $sectionDir
        InternalManifestPath = $null
    }
}

Show-Info "Section output: $sectionDir"

# ----------------------------------------------------------
# Locate source UserDict directory (path is fixed across the
# entire Win10/11 + old/new IME matrix, see banner)
# ----------------------------------------------------------
$userDictDir = Join-Path $sourceUserProfilePath 'AppData\Roaming\Microsoft\IME\15.0\IMEJP\UserDict'
$userDictDirExists = Test-Path $userDictDir

$targetFiles = @(
    'imjp15cu.dic',
    'imjp15cu.dic_bak'
)

$captured   = New-Object System.Collections.Generic.List[object]
$totalBytes = 0L

if ($userDictDirExists) {
    Show-Info "msime_dict: UserDict dir found at $userDictDir"

    # robocopy /B with backup mode reads files even while IMEJP
    # holds the handle. /R:1 /W:1 keeps a stale lock from blocking
    # the run; the file list is passed as positional arguments
    # (source, dest, file1, file2, ...).
    $robocopyLog = Join-Path $sectionDir '_robocopy.log'

    $robocopyArgs = @($userDictDir, $payloadDir) + $targetFiles + @(
        '/B', '/R:1', '/W:1', '/NP', '/NJH', '/NJS', '/COPY:DT'
    )
    & robocopy.exe @robocopyArgs *>> $robocopyLog
    $robocopyExit = $LASTEXITCODE

    # robocopy exit codes: 0=no copy needed, 1=files copied,
    # 2/4/8/16=warnings or errors. >= 8 indicates failure.
    if ($robocopyExit -ge 8) {
        $warnings += "robocopy returned $robocopyExit (>=8 indicates failure); see _robocopy.log"
    }

    foreach ($name in $targetFiles) {
        $srcPath = Join-Path $userDictDir $name
        $dstPath = Join-Path $payloadDir $name

        $srcExists = Test-Path -LiteralPath $srcPath
        $srcInfo   = if ($srcExists) { Get-Item -LiteralPath $srcPath -ErrorAction SilentlyContinue } else { $null }
        $srcBytes  = if ($null -ne $srcInfo) { [long]$srcInfo.Length } else { 0L }
        $lwt       = if ($null -ne $srcInfo) { $srcInfo.LastWriteTime.ToString('o') } else { $null }

        $copyOk = Test-Path -LiteralPath $dstPath
        if ($srcExists -and -not $copyOk) {
            $warnings += "robocopy did not produce expected payload file: $dstPath"
        }
        if ($copyOk) {
            $totalBytes += (Get-Item -LiteralPath $dstPath).Length
        }

        $captured.Add([PSCustomObject][ordered]@{
            fileName      = $name
            sourcePath    = $srcPath
            exists        = $srcExists
            bytes         = $srcBytes
            lastWrite     = $lwt
            copySucceeded = $copyOk
        }) | Out-Null

        if (-not $srcExists) {
            Show-Skip "msime_dict: $name not present at source"
        }
    }
} else {
    Show-Skip "msime_dict: UserDict directory not present at $userDictDir"
    $warnings += "UserDict directory not found: $userDictDir"
}

$capturedCount = @($captured | Where-Object { $_.copySucceeded }).Count

# ----------------------------------------------------------
# Write manifest
# ----------------------------------------------------------
$manifest = [ordered]@{
    schemaVersion         = 1
    manifestType          = 'fabriq-msime-dict-backup'
    collectedAt           = (Get-Date).ToString('o')
    host                  = $OldPcName
    sourceUserProfilePath = $sourceUserProfilePath
    userDictDir           = $userDictDir
    userDictDirExists     = $userDictDirExists
    files                 = @($captured | ForEach-Object {
        [ordered]@{
            fileName      = $_.fileName
            sourcePath    = $_.sourcePath
            exists        = $_.exists
            bytes         = $_.bytes
            lastWrite     = $_.lastWrite
            copySucceeded = $_.copySucceeded
        }
    })
    capturedCount         = $capturedCount
    totalBytes            = $totalBytes
    warnings              = $warnings
}
$manifestPath = Join-Path $sectionDir 'manifest.json'
$manifest | ConvertTo-Json -Depth 6 | Out-File -FilePath $manifestPath -Encoding UTF8 -Force

# ----------------------------------------------------------
# Decide Status
#   - imjp15cu.dic captured  -> Success (Partial when warnings)
#   - dir absent             -> Skipped (source PC had no IME dict)
#   - dir present but failed -> Failed
# ----------------------------------------------------------
$primaryCaptured = $captured | Where-Object {
    $_.fileName -eq 'imjp15cu.dic' -and $_.copySucceeded
}
$status = if ($primaryCaptured) {
    if ($warnings.Count -gt 0) { 'Partial' } else { 'Success' }
} elseif (-not $userDictDirExists) {
    'Skipped'
} else {
    'Failed'
}

Show-Info ("msime_dict: captured={0} totalBytes={1} status={2}" -f `
    $capturedCount, $totalBytes, $status)

return [PSCustomObject]@{
    Status               = $status
    ElapsedMs            = [int]$sw.ElapsedMilliseconds
    Summary              = [ordered]@{
        sourceUserProfilePath = $sourceUserProfilePath
        userDictDir           = $userDictDir
        userDictDirExists     = $userDictDirExists
        capturedCount         = $capturedCount
        totalBytes            = $totalBytes
    }
    Warnings             = $warnings
    ExternalOutputDir    = $null
    ExternalManifestPath = $null
    InternalSectionDir   = $sectionDir
    InternalManifestPath = $manifestPath
}
