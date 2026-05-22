# ============================================================
# FabriqBackUper Section: credentials / backup (v0.19.0 initial)
#
# Enumerates the TARGET USER's Windows Credential Manager vault
# (Generic / Domain* types) via Win32 CredEnumerate and emits:
#   - manifest.json  (fabriq-credentials-backup schemaVersion=1)
#   - _credentials_list.csv  (UTF-8 BOM + CRLF, operator-readable)
#
# Password blobs (CredentialBlob bytes) are intentionally NOT
# captured. Only metadata: target / type / userName / persist /
# comment / lastWritten / blobSize. Re-registration on the new PC
# requires the operator to re-enter each password.
#
# Target user determination:
#   - Resolve-HkcuRoot returns the SID of the currently logged-on
#     user when admin context != interactive user (Redirected=true).
#     The SID is translated to NTAccount form (DOMAIN\user) and
#     used as the schtasks /RU target.
#   - When admin context == interactive user (Redirected=false),
#     the target IS the current process user; dump_creds.ps1 is
#     invoked as a direct child process (no scheduled task needed).
#
# DPAPI per-user constraint:
#   - Credential blobs are decrypted by CredEnumerate using the
#     calling process user's DPAPI master key. An admin cannot
#     read a different user's vault.
#   - When admin != target, this section spawns dump_creds.ps1
#     as the target user via Register-ScheduledTask with
#     LogonType=Interactive ("/IT"): runs only when the target
#     is logged on, no password required.
#
# Failure mode (target user not logged on):
#   - schtasks /IT cannot fire => 30s poll timeout =>
#     targetUserDumpMethod='unavailable', credentialCount=0,
#     Status=Failed. Honest report; no silent data loss.
#
# SectionParams (hashtable, all optional):
#   SourceUserProfilePath : metadata only, mirrors other sections.
#                           Recorded in manifest for traceability.
#
# Web Credentials (Windows.Security.Credentials.PasswordVault):
#   NOT collected in this phase (v0.19.0). webCredentialCount is
#   always 0. Future v0.20+ may add WinRT-based collection.
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
$sourceUserProfilePath = $null
if ($SectionParams.ContainsKey('SourceUserProfilePath') -and `
    -not [string]::IsNullOrWhiteSpace($SectionParams['SourceUserProfilePath'])) {
    $sourceUserProfilePath = "$($SectionParams['SourceUserProfilePath'])"
}

# ----------------------------------------------------------
# Prerequisites
# ----------------------------------------------------------
if (-not (Test-AdminPrivilege)) {
    return [PSCustomObject]@{
        Status               = 'Failed'
        ElapsedMs            = [int]$sw.ElapsedMilliseconds
        Summary              = [ordered]@{}
        Warnings             = @('Administrator privileges required')
        ExternalOutputDir    = $null
        ExternalManifestPath = $null
        InternalSectionDir   = $null
        InternalManifestPath = $null
    }
}

# ----------------------------------------------------------
# Section output dir
# ----------------------------------------------------------
$sectionDir = Join-Path $AggregateBackupDir 'sections\credentials'
try {
    $null = New-Item -ItemType Directory -Path $sectionDir -Force -ErrorAction Stop
} catch {
    return [PSCustomObject]@{
        Status               = 'Failed'
        ElapsedMs            = [int]$sw.ElapsedMilliseconds
        Summary              = [ordered]@{}
        Warnings             = @("Could not create section dir: $($_.Exception.Message)")
        ExternalOutputDir    = $null
        ExternalManifestPath = $null
        InternalSectionDir   = $null
        InternalManifestPath = $null
    }
}

# ----------------------------------------------------------
# Resolve target user
# ----------------------------------------------------------
$adminUser  = "$env:USERDOMAIN\$env:USERNAME"
$targetUser = $adminUser
$targetSid  = $null
$dumpMethod = 'self'

$hkcuInfo = Resolve-HkcuRoot
if ($null -ne $hkcuInfo -and $hkcuInfo.Redirected -and `
    -not [string]::IsNullOrWhiteSpace($hkcuInfo.SID)) {
    $targetSid = $hkcuInfo.SID
    try {
        $sidObj    = New-Object System.Security.Principal.SecurityIdentifier($targetSid)
        $ntAccount = $sidObj.Translate([System.Security.Principal.NTAccount])
        $targetUser = $ntAccount.Value
        $dumpMethod = 'schtasks-it'
        Show-Info "credentials: target user = $targetUser (cross-user, will spawn via schtasks /IT)"
    } catch {
        $warnings += "Could not resolve target SID $targetSid to NTAccount: $($_.Exception.Message); falling back to self"
        $targetUser = $adminUser
        $dumpMethod = 'self'
    }
} else {
    Show-Info "credentials: target user = $adminUser (admin == interactive user, direct dump)"
}

# ----------------------------------------------------------
# IPC paths (ProgramData is readable by both admin and any logged-on user)
# ----------------------------------------------------------
$ipcDir = Join-Path $env:ProgramData 'FabriqBackUper\ipc'
if (-not (Test-Path $ipcDir)) {
    try {
        New-Item -ItemType Directory -Path $ipcDir -Force -ErrorAction Stop | Out-Null
    } catch {
        return [PSCustomObject]@{
            Status               = 'Failed'
            ElapsedMs            = [int]$sw.ElapsedMilliseconds
            Summary              = [ordered]@{ adminUser=$adminUser; targetUser=$targetUser }
            Warnings             = @("Could not create IPC dir $ipcDir : $($_.Exception.Message)")
            ExternalOutputDir    = $null
            ExternalManifestPath = $null
            InternalSectionDir   = $sectionDir
            InternalManifestPath = $null
        }
    }
}
$stamp         = (Get-Date).ToString('yyyyMMdd_HHmmss_fff')
$ipcOutputJson = Join-Path $ipcDir "creds_$stamp.json"

$dumpScriptPath = Join-Path $PSScriptRoot 'dump_creds.ps1'
if (-not (Test-Path $dumpScriptPath)) {
    return [PSCustomObject]@{
        Status               = 'Failed'
        ElapsedMs            = [int]$sw.ElapsedMilliseconds
        Summary              = [ordered]@{ adminUser=$adminUser; targetUser=$targetUser }
        Warnings             = @("dump_creds.ps1 not found at $dumpScriptPath")
        ExternalOutputDir    = $null
        ExternalManifestPath = $null
        InternalSectionDir   = $sectionDir
        InternalManifestPath = $null
    }
}

# ----------------------------------------------------------
# Invoke dump_creds.ps1 - self path
# ----------------------------------------------------------
$rawJson = $null

if ($dumpMethod -eq 'self') {
    $procArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $dumpScriptPath,
        '-OutputPath', $ipcOutputJson
    )
    try {
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $procArgs `
            -Wait -WindowStyle Hidden -PassThru -ErrorAction Stop
        if ($proc.ExitCode -ne 0) {
            $warnings += "dump_creds.ps1 (self) exited with code $($proc.ExitCode)"
        }
    } catch {
        $warnings += "Failed to launch dump_creds.ps1 (self): $($_.Exception.Message)"
    }
    if (Test-Path $ipcOutputJson) {
        try { $rawJson = Get-Content $ipcOutputJson -Raw -ErrorAction Stop } catch {
            $warnings += "Failed to read IPC JSON: $($_.Exception.Message)"
        }
    }
}

# ----------------------------------------------------------
# Invoke dump_creds.ps1 - schtasks /IT path
# ----------------------------------------------------------
if ($dumpMethod -eq 'schtasks-it') {
    $taskName = "FabriqBackUper_CredDump_$stamp"
    $taskRegistered = $false
    try {
        $argStr = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -OutputPath "{1}"' `
            -f $dumpScriptPath, $ipcOutputJson
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argStr
        # Dummy trigger required by Register-ScheduledTask; we fire via Start-ScheduledTask
        $trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddYears(1)
        $principal = New-ScheduledTaskPrincipal -UserId $targetUser `
                        -LogonType Interactive -RunLevel Limited
        $settings  = New-ScheduledTaskSettingsSet `
                        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                        -ExecutionTimeLimit (New-TimeSpan -Minutes 2)

        Register-ScheduledTask -TaskName $taskName `
            -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
            -Force -ErrorAction Stop | Out-Null
        $taskRegistered = $true

        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop

        # Poll for JSON (30s)
        $deadline = (Get-Date).AddSeconds(30)
        while (-not (Test-Path $ipcOutputJson) -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 300
        }

        if (Test-Path $ipcOutputJson) {
            $rawJson = Get-Content $ipcOutputJson -Raw -ErrorAction Stop
            Show-Success "credentials: dump_creds.ps1 produced output as $targetUser via schtasks /IT"
        } else {
            $warnings += "Target user '$targetUser' did not produce output within 30s (likely not logged on, GPO restriction, or AppLocker)"
            $dumpMethod = 'unavailable'
        }
    } catch {
        $warnings += "schtasks /IT spawn failed: $($_.Exception.Message)"
        $dumpMethod = 'unavailable'
    } finally {
        if ($taskRegistered) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
}

# Clean up IPC tempfile after reading
if (Test-Path $ipcOutputJson) {
    Remove-Item $ipcOutputJson -Force -ErrorAction SilentlyContinue
}

# ----------------------------------------------------------
# Parse child JSON
# ----------------------------------------------------------
$apiSuccess    = $false
$apiLastError  = -1
$childIdentity = $null
$childCreds    = @()

if ($rawJson) {
    try {
        $payload       = $rawJson | ConvertFrom-Json -ErrorAction Stop
        $childIdentity = "$($payload.userDomain)\$($payload.userName)"
        $apiSuccess    = [bool]$payload.apiSuccess
        $apiLastError  = [int]$payload.apiLastError
        if ($null -ne $payload.credentials) {
            $childCreds = @($payload.credentials)
        }
        # Honest identity check
        if ($dumpMethod -eq 'schtasks-it' -and $childIdentity -ine $targetUser) {
            $warnings += "Child identity ($childIdentity) does not match target ($targetUser); spawn returned wrong user's vault"
        }
    } catch {
        $warnings += "Failed to parse dump_creds.ps1 output JSON: $($_.Exception.Message)"
    }
}

# ----------------------------------------------------------
# Filter out OS-managed "system noise" credentials (v0.19.2)
#
# These targets are auto-generated by Windows whenever a Microsoft
# account / device-SSO infrastructure runs. They:
#   - have BlobSize=0 (no real password to back up)
#   - regenerate themselves on next Microsoft Account sign-in / OS
#     boot, so restoring them is pointless
#   - clutter the operator-facing CSV with non-actionable rows
# Filter at backup time so they never reach the restore payload.
#
# Conservative list of EXACT target matches only. Extend here if
# more well-known noise patterns surface in the field.
# ----------------------------------------------------------
function Test-IsSystemNoiseCredential {
    param([string]$Target)
    switch ($Target) {
        'MicrosoftAccount:target=SSO_POP_Device'    { return $true }
        'WindowsLive:target=virtualapp/didlogical'  { return $true }
    }
    return $false
}

$filteredCreds   = New-Object System.Collections.Generic.List[object]
$systemNoiseList = New-Object System.Collections.Generic.List[object]
foreach ($e in $childCreds) {
    if (Test-IsSystemNoiseCredential -Target ([string]$e.target)) {
        $systemNoiseList.Add($e) | Out-Null
    } else {
        $filteredCreds.Add($e) | Out-Null
    }
}
$systemNoiseFilteredCount = $systemNoiseList.Count
if ($systemNoiseFilteredCount -gt 0) {
    Show-Info ("credentials: filtered {0} OS-managed system entries (SSO_POP_Device / virtualapp/didlogical)" -f `
        $systemNoiseFilteredCount)
}

# ----------------------------------------------------------
# Apply restoreHint heuristic per entry
#
# Heuristic targets well-known token-bearing Generic creds whose
# blobs are NOT a password (so re-entry won't work) and cert-based
# creds (need cert export, not in scope).
# ----------------------------------------------------------
$enrichedCreds = @(
    foreach ($e in $filteredCreds) {
        $hint   = 'cred-write'
        $target = [string]$e.target
        $blob   = [int]$e.blobSize

        if ($e.type -eq 'DomainCertificate' -or $e.type -eq 'GenericCertificate') {
            $hint = 'manual'
        } elseif ($blob -eq 0) {
            $hint = 'manual'
        } elseif ($target -match '^MicrosoftAccount:'                -or `
                  $target -match '^WindowsLive:'                     -or `
                  $target -match '^LegacyGeneric:target=DriveFS_'    -or `
                  $target -match '^LegacyGeneric:target=OneDrive'    -or `
                  $target -match '^OneDrive'                         -or `
                  $target -match '^Office16_Data:'                   -or `
                  $target -match '^MicrosoftOffice16_') {
            $hint = 'manual'
        }

        [PSCustomObject][ordered]@{
            store       = 'WindowsVault'
            type        = $e.type
            target      = $e.target
            userName    = $e.userName
            persist     = $e.persist
            comment     = $e.comment
            lastWritten = $e.lastWritten
            blobSize    = $blob
            restoreHint = $hint
        }
    }
)

$credentialCount = $enrichedCreds.Count
$manualHintCount = @($enrichedCreds | Where-Object { $_.restoreHint -eq 'manual' }).Count

# ----------------------------------------------------------
# Write manifest.json
# ----------------------------------------------------------
$manifest = [ordered]@{
    schemaVersion           = 1
    manifestType            = 'fabriq-credentials-backup'
    collectedAt             = (Get-Date).ToString('o')
    host                    = $OldPcName
    sourceUserProfilePath   = $sourceUserProfilePath
    adminUser               = $adminUser
    targetUser              = $targetUser
    targetUserSid           = $targetSid
    targetUserDumpMethod    = $dumpMethod
    targetUserChildIdentity = $childIdentity
    apiSuccess              = $apiSuccess
    apiLastError            = $apiLastError
    credentialCount         = $credentialCount
    manualHintCount         = $manualHintCount
    systemNoiseFilteredCount = $systemNoiseFilteredCount
    webCredentialCount      = 0
    credentials             = @($enrichedCreds | ForEach-Object {
                                  [ordered]@{
                                      store       = $_.store
                                      type        = $_.type
                                      target      = $_.target
                                      userName    = $_.userName
                                      persist     = $_.persist
                                      comment     = $_.comment
                                      lastWritten = $_.lastWritten
                                      blobSize    = $_.blobSize
                                      restoreHint = $_.restoreHint
                                  }
                              })
    warnings                = $warnings
}

$manifestPath = Join-Path $sectionDir 'manifest.json'
$manifest | ConvertTo-Json -Depth 8 | Out-File -FilePath $manifestPath -Encoding UTF8 -Force

# ----------------------------------------------------------
# Write _credentials_list.csv (UTF-8 BOM + CRLF, operator-visible)
# ----------------------------------------------------------
$csvPath = Join-Path $sectionDir '_credentials_list.csv'

$csvLines = @('Store,Type,Target,UserName,Persist,Comment,LastWritten,BlobSize,RestoreHint')
foreach ($e in $enrichedCreds) {
    $row = [PSCustomObject][ordered]@{
        Store       = $e.store
        Type        = $e.type
        Target      = $e.target
        UserName    = $e.userName
        Persist     = $e.persist
        Comment     = $e.comment
        LastWritten = $e.lastWritten
        BlobSize    = $e.blobSize
        RestoreHint = $e.restoreHint
    }
    # ConvertTo-Csv produces 2 lines (header + 1 row); we already have a header.
    $csvRow = ($row | ConvertTo-Csv -NoTypeInformation | Select-Object -Last 1)
    $csvLines += $csvRow
}
$csvText = ($csvLines -join "`r`n") + "`r`n"
$bomBytes = [byte[]](0xEF, 0xBB, 0xBF)
$csvBytes = $bomBytes + [System.Text.Encoding]::UTF8.GetBytes($csvText)
[System.IO.File]::WriteAllBytes($csvPath, $csvBytes)

# ----------------------------------------------------------
# Decide Status
# ----------------------------------------------------------
$status = 'Success'
if ($dumpMethod -eq 'unavailable') {
    $status = 'Failed'
} elseif (-not $apiSuccess) {
    $status = 'Failed'
} elseif ($warnings.Count -gt 0) {
    $status = 'Partial'
}

Show-Info ("credentials: count={0} (manual hint: {1}, system-noise filtered: {2}) method={3} status={4}" -f `
    $credentialCount, $manualHintCount, $systemNoiseFilteredCount, $dumpMethod, $status)

# ----------------------------------------------------------
# Return result
# ----------------------------------------------------------
return [PSCustomObject]@{
    Status               = $status
    ElapsedMs            = [int]$sw.ElapsedMilliseconds
    Summary              = [ordered]@{
        adminUser                = $adminUser
        targetUser               = $targetUser
        targetUserDumpMethod     = $dumpMethod
        targetUserChildIdentity  = $childIdentity
        credentialCount          = $credentialCount
        manualHintCount          = $manualHintCount
        systemNoiseFilteredCount = $systemNoiseFilteredCount
        webCredentialCount       = 0
        csvPath                  = $csvPath
    }
    Warnings             = $warnings
    ExternalOutputDir    = $null
    ExternalManifestPath = $null
    InternalSectionDir   = $sectionDir
    InternalManifestPath = $manifestPath
}
