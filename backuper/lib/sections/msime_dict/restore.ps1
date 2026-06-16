# ============================================================
# FabriqBackUper Section: msime_dict / restore (v0.22.0 initial)
#
# Restores the Microsoft IME user dictionary captured by
# msime_dict/backup.ps1 into the target user's profile:
#
#   <TargetUserProfilePath>\AppData\Roaming\Microsoft\IME\15.0
#     \IMEJP\UserDict\imjp15cu.dic
#     \IMEJP\UserDict\imjp15cu.dic_bak
#
# Lock handling:
#   - The target user's ctfmon.exe (text-services framework) may
#     hold imjp15cu.dic open. We look up ctfmon processes owned by
#     the target user's SID and Stop-Process them before copying.
#   - ctfmon auto-restarts on the next user logon, and the dict
#     reload requires a logoff/logon cycle anyway, so we don't
#     explicitly re-spawn it from this section.
#   - SID resolution maps TargetUserProfilePath -> SID via the
#     ProfileList registry. If that fails (rare) we skip the kill
#     step rather than killing every ctfmon (which would freeze
#     the admin's IME too).
#
# Overwrite policy:
#   - Existing target imjp15cu.dic is overwritten unconditionally
#     per the agreed kitting-time semantics (operator wants the
#     source PC's dictionary, full stop). No backup is kept.
#
# SectionParams (hashtable, all optional):
#   TargetUserProfilePath : profile path of the user receiving the
#                           dictionary. Resolved by restore_view's
#                           target-user ComboBox. Falls back to
#                           $env:USERPROFILE when absent.
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
# Resolve target user profile path
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
# Source paths
# ----------------------------------------------------------
$srcSectionDir = Join-Path $AggregateBackupDir 'sections\msime_dict'
$srcManifest   = Join-Path $srcSectionDir 'manifest.json'
$srcPayloadDir = Join-Path $srcSectionDir 'payload'

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
                ($aggDoc.sections.PSObject.Properties.Name -contains 'msime_dict') -and `
                ("$($aggDoc.sections.msime_dict.status)" -ne 'Skipped')) { $wasBackedUp = $true }
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
        InternalSectionDir   = $srcSectionDir
        InternalManifestPath = $null
    }
}
if (-not (Test-Path $srcPayloadDir)) {
    return [PSCustomObject]@{
        Status               = 'Failed'
        ElapsedMs            = [int]$sw.ElapsedMilliseconds
        Summary              = [ordered]@{}
        Warnings             = @("Source payload dir not found: $srcPayloadDir")
        ExternalOutputDir    = $null
        ExternalManifestPath = $null
        InternalSectionDir   = $srcSectionDir
        InternalManifestPath = $null
    }
}

$srcManifestObj = $null
try {
    $srcManifestObj = Get-Content -Path $srcManifest -Raw | ConvertFrom-Json -ErrorAction Stop
} catch {
    return [PSCustomObject]@{
        Status               = 'Failed'
        ElapsedMs            = [int]$sw.ElapsedMilliseconds
        Summary              = [ordered]@{}
        Warnings             = @("Failed to parse source manifest.json: $($_.Exception.Message)")
        ExternalOutputDir    = $null
        ExternalManifestPath = $null
        InternalSectionDir   = $srcSectionDir
        InternalManifestPath = $null
    }
}

# ----------------------------------------------------------
# Target UserDict directory
# ----------------------------------------------------------
$targetUserDictDir = Join-Path $targetUserProfilePath 'AppData\Roaming\Microsoft\IME\15.0\IMEJP\UserDict'
if (-not (Test-Path $targetUserDictDir)) {
    try {
        $null = New-Item -ItemType Directory -Path $targetUserDictDir -Force -ErrorAction Stop
        Show-Info "msime_dict: created target UserDict dir $targetUserDictDir"
    } catch {
        return [PSCustomObject]@{
            Status               = 'Failed'
            ElapsedMs            = [int]$sw.ElapsedMilliseconds
            Summary              = [ordered]@{}
            Warnings             = @("Could not create target UserDict dir: $($_.Exception.Message)")
            ExternalOutputDir    = $null
            ExternalManifestPath = $null
            InternalSectionDir   = $srcSectionDir
            InternalManifestPath = $null
        }
    }
}

# ----------------------------------------------------------
# Map TargetUserProfilePath -> SID via HKLM ProfileList
# ----------------------------------------------------------
$targetSid = $null
try {
    $profileListKeys = @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction Stop)
    foreach ($key in $profileListKeys) {
        $imgPath = $null
        try {
            $imgPath = (Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop).ProfileImagePath
        } catch { continue }
        if (-not [string]::IsNullOrWhiteSpace($imgPath) -and `
            [string]::Equals($imgPath, $targetUserProfilePath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $targetSid = Split-Path $key.PSPath -Leaf
            break
        }
    }
} catch {
    $warnings += "ProfileList enumeration failed: $($_.Exception.Message)"
}

if ($null -eq $targetSid) {
    Show-Warning "msime_dict: could not resolve SID for $targetUserProfilePath; skipping ctfmon stop step"
}

# ----------------------------------------------------------
# Stop ctfmon.exe owned by the target user (best-effort)
# ----------------------------------------------------------
$ctfmonStopped     = $false
$ctfmonPidsStopped = @()
if ($null -ne $targetSid) {
    try {
        $cimProcs = @(Get-CimInstance Win32_Process -Filter "Name='ctfmon.exe'" -ErrorAction Stop)
        foreach ($p in $cimProcs) {
            $ownerSid = $null
            try {
                $ownRes = Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop
                if ($ownRes.ReturnValue -eq 0) { $ownerSid = $ownRes.Sid }
            } catch {
                # Older CIM/WMI may expose GetOwnerSid differently; skip
                # this process rather than risk killing the wrong user's.
                continue
            }
            if ($ownerSid -eq $targetSid) {
                try {
                    Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
                    $ctfmonStopped = $true
                    $ctfmonPidsStopped += [int]$p.ProcessId
                    Show-Info ("msime_dict: stopped ctfmon.exe PID={0} (target SID match)" -f $p.ProcessId)
                } catch {
                    $warnings += "Stop-Process ctfmon PID=$($p.ProcessId) failed: $($_.Exception.Message)"
                }
            }
        }
    } catch {
        $warnings += "ctfmon CIM enumeration failed: $($_.Exception.Message)"
    }
}

# Brief delay so the file handle is fully released before we copy
if ($ctfmonStopped) {
    Start-Sleep -Milliseconds 500
}

# ----------------------------------------------------------
# Deploy payload -> target UserDict
# ----------------------------------------------------------
$deployed   = New-Object System.Collections.Generic.List[object]
$totalBytes = 0L

foreach ($entry in @($srcManifestObj.files)) {
    if (-not $entry.copySucceeded) {
        # Source PC didn't have this file or capture failed; skip silently
        continue
    }
    $name    = [string]$entry.fileName
    $srcFile = Join-Path $srcPayloadDir $name
    $dstFile = Join-Path $targetUserDictDir $name

    if (-not (Test-Path -LiteralPath $srcFile)) {
        $warnings += "Payload file missing despite manifest claim: $srcFile"
        $deployed.Add([PSCustomObject][ordered]@{
            fileName   = $name
            targetPath = $dstFile
            bytes      = 0
            deployed   = $false
            error      = 'payload file missing'
        }) | Out-Null
        continue
    }

    try {
        Copy-Item -LiteralPath $srcFile -Destination $dstFile -Force -ErrorAction Stop
        $bytes = (Get-Item -LiteralPath $dstFile).Length
        $totalBytes += $bytes
        Show-Success ("msime_dict: deployed {0} -> {1} ({2} bytes)" -f $name, $dstFile, $bytes)
        $deployed.Add([PSCustomObject][ordered]@{
            fileName   = $name
            targetPath = $dstFile
            bytes      = $bytes
            deployed   = $true
            error      = $null
        }) | Out-Null
    } catch {
        $warnings += "Failed to copy ${name}: $($_.Exception.Message)"
        $deployed.Add([PSCustomObject][ordered]@{
            fileName   = $name
            targetPath = $dstFile
            bytes      = 0
            deployed   = $false
            error      = $_.Exception.Message
        }) | Out-Null
    }
}

$deployedCount = @($deployed | Where-Object { $_.deployed }).Count

# ----------------------------------------------------------
# Write restore manifest
# ----------------------------------------------------------
$restoreManifestPath = Join-Path $srcSectionDir 'restore_manifest.json'
$restoreManifest = [ordered]@{
    schemaVersion         = 1
    manifestType          = 'fabriq-msime-dict-restore'
    restoredAt            = (Get-Date).ToString('o')
    sourceHost            = $OldPcName
    targetUserProfilePath = $targetUserProfilePath
    targetUserSid         = $targetSid
    targetUserDictDir     = $targetUserDictDir
    ctfmonStopped         = $ctfmonStopped
    ctfmonPidsStopped     = @($ctfmonPidsStopped)
    deployed              = @($deployed | ForEach-Object {
        [ordered]@{
            fileName   = $_.fileName
            targetPath = $_.targetPath
            bytes      = $_.bytes
            deployed   = $_.deployed
            error      = $_.error
        }
    })
    deployedCount         = $deployedCount
    totalBytes            = $totalBytes
    warnings              = $warnings
}
try {
    $restoreManifest | ConvertTo-Json -Depth 6 | Out-File -FilePath $restoreManifestPath -Encoding UTF8 -Force
} catch {
    $warnings += "Could not write restore_manifest.json: $($_.Exception.Message)"
}

# ----------------------------------------------------------
# Decide Status (primary file = imjp15cu.dic)
# ----------------------------------------------------------
$primaryDeployed = $deployed | Where-Object {
    $_.fileName -eq 'imjp15cu.dic' -and $_.deployed
}
$status = if (-not $primaryDeployed) {
    'Failed'
} elseif ($warnings.Count -gt 0) {
    'Partial'
} else {
    'Success'
}

Show-Info ("msime_dict/restore: deployed={0} bytes={1} status={2}" -f `
    $deployedCount, $totalBytes, $status)
Show-Info "msime_dict/restore: target user must re-login for IME to reload the dictionary."

return [PSCustomObject]@{
    Status               = $status
    ElapsedMs            = [int]$sw.ElapsedMilliseconds
    Summary              = [ordered]@{
        targetUserProfilePath = $targetUserProfilePath
        targetUserSid         = $targetSid
        targetUserDictDir     = $targetUserDictDir
        ctfmonStopped         = $ctfmonStopped
        deployedCount         = $deployedCount
        totalBytes            = $totalBytes
    }
    Warnings             = $warnings
    ExternalOutputDir    = $null
    ExternalManifestPath = $null
    InternalSectionDir   = $srcSectionDir
    InternalManifestPath = $restoreManifestPath
}
