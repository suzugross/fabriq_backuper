# ============================================================
# Fabriq BackUper - Credentials Section PoC
# Test 02: schtasks /IT spawn identity
#
# Purpose:
#   Verify that we can run a child PowerShell process AS a
#   specified target user from an admin context, without
#   knowing the target user's password, by using
#     schtasks.exe /create ... /ru <TargetUser> /it
#   ("/IT" = Interactive Token, run only when user is logged
#   on, no password required).
#
#   The child writes its own identity ($env:USERNAME) to a
#   JSON file in %ProgramData%\FabriqBackUper\poc\. The parent
#   reads it back and prints the comparison.
#
# Expected outcome (when target user is logged on):
#   Parent: <admin user>
#   Child : <target user>
#   ... showing that the child genuinely ran in target's token.
#
# Failure modes documented in output:
#   - Target user not logged on => /IT cannot fire => timeout
#   - GPO restricts schtasks usage => /create fails
#   - AppLocker / WDAC blocks PowerShell.exe spawn => /run starts
#     but child silently dies, => timeout
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass `
#     -File dev\credentials_poc\02_spawn_test.ps1 `
#     -TargetUser "DOMAIN\yuki"  # or ".\localuser"
# ============================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$TargetUser,

    [int]$TimeoutSec = 30
)

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------
# IPC dir under ProgramData (admin + target user both readable)
# ----------------------------------------------------------
$ipcDir = Join-Path $env:ProgramData 'FabriqBackUper\poc'
if (-not (Test-Path $ipcDir)) {
    New-Item -ItemType Directory -Path $ipcDir -Force | Out-Null
}

$stamp       = (Get-Date).ToString('yyyyMMdd_HHmmss_fff')
$childScript = Join-Path $ipcDir "spawn_child_$stamp.ps1"
$outputJson  = Join-Path $ipcDir "spawn_child_$stamp.json"

# ----------------------------------------------------------
# Child script - dumps own identity to JSON
# ----------------------------------------------------------
$childBody = @'
param([string]$OutputPath)
$payload = [PSCustomObject]@{
    timestamp   = (Get-Date).ToString('o')
    userDomain  = $env:USERDOMAIN
    userName    = $env:USERNAME
    userProfile = $env:USERPROFILE
    sessionName = $env:SESSIONNAME
    whoAmI      = (whoami).Trim()
    psVersion   = $PSVersionTable.PSVersion.ToString()
}
$payload | ConvertTo-Json -Depth 3 | Set-Content -Path $OutputPath -Encoding UTF8
'@

# Write child script as UTF-8 with BOM (PS5.1 convention)
$bom   = [byte[]](0xEF, 0xBB, 0xBF)
$bytes = $bom + [System.Text.Encoding]::UTF8.GetBytes($childBody)
[System.IO.File]::WriteAllBytes($childScript, $bytes)

# ----------------------------------------------------------
# Schedule + run + wait + delete via ScheduledTasks cmdlets
# (cleaner than schtasks.exe argument escaping)
# ----------------------------------------------------------
$taskName = "FabriqBackUper_PoC_Spawn_$stamp"

Write-Host ('=' * 64) -ForegroundColor Cyan
Write-Host ("Parent identity : {0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)
Write-Host ("Target user     : {0}" -f $TargetUser)
Write-Host ("Task name       : {0}" -f $taskName)
Write-Host ("Child script    : {0}" -f $childScript)
Write-Host ("Output JSON     : {0}" -f $outputJson)
Write-Host ('=' * 64) -ForegroundColor Cyan
Write-Host ''

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}" "{1}"' -f $childScript, $outputJson)

# Dummy trigger required by Register-ScheduledTask; we'll fire via Start-ScheduledTask
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddYears(1)

# LogonType=Interactive corresponds to "/IT" - no password required, runs only when logged on
$principal = New-ScheduledTaskPrincipal -UserId $TargetUser -LogonType Interactive -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 2)

try {
    Register-ScheduledTask -TaskName $taskName `
        -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Force | Out-Null
    Write-Host "Task registered." -ForegroundColor Green
} catch {
    Write-Host ("Register-ScheduledTask FAILED: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Remove-Item $childScript -ErrorAction SilentlyContinue
    exit 1
}

try {
    Start-ScheduledTask -TaskName $taskName
    Write-Host "Task started." -ForegroundColor Green
} catch {
    Write-Host ("Start-ScheduledTask FAILED: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item $childScript -ErrorAction SilentlyContinue
    exit 1
}

# ----------------------------------------------------------
# Poll for output JSON
# ----------------------------------------------------------
Write-Host ("Waiting up to {0}s for child output..." -f $TimeoutSec)
$deadline = (Get-Date).AddSeconds($TimeoutSec)
while (-not (Test-Path $outputJson) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 300
}

if (Test-Path $outputJson) {
    Write-Host "Output received." -ForegroundColor Green
    Write-Host ''
    Write-Host ('-' * 64) -ForegroundColor Cyan
    $payload = Get-Content $outputJson -Raw | ConvertFrom-Json
    Write-Host ("Child identity  : {0}\{1}" -f $payload.userDomain, $payload.userName) -ForegroundColor Green
    Write-Host ("Child profile   : {0}" -f $payload.userProfile)
    Write-Host ("Child session   : {0}" -f $payload.sessionName)
    Write-Host ("Child whoami    : {0}" -f $payload.whoAmI)
    Write-Host ("Child PS ver    : {0}" -f $payload.psVersion)
    Write-Host ('-' * 64) -ForegroundColor Cyan

    $parentId = "$env:USERDOMAIN\$env:USERNAME"
    $childId  = "$($payload.userDomain)\$($payload.userName)"
    Write-Host ''
    if ($parentId -ieq $childId) {
        Write-Host "Note: child identity == parent identity (target user was the same)." -ForegroundColor Yellow
    } else {
        Write-Host "SUCCESS: child ran under target user token (different from parent)." -ForegroundColor Green
    }
} else {
    Write-Host "TIMEOUT - child did not produce output." -ForegroundColor Red
    Write-Host ''
    Write-Host "Diagnostics:" -ForegroundColor Yellow
    try {
        $info = Get-ScheduledTask -TaskName $taskName | Get-ScheduledTaskInfo
        Write-Host ("  LastTaskResult : 0x{0:X}" -f $info.LastTaskResult)
        Write-Host ("  LastRunTime    : {0}" -f $info.LastRunTime)
        Write-Host ("  NumberOfMissed : {0}" -f $info.NumberOfMissedRuns)
    } catch {
        Write-Host ("  (could not query task: {0})" -f $_.Exception.Message)
    }
    Write-Host ''
    Write-Host "Possible causes:" -ForegroundColor Yellow
    Write-Host ("  - Target user '{0}' is not currently logged on (required for LogonType=Interactive)." -f $TargetUser)
    Write-Host ("  - ExecutionPolicy enforced by GPO blocks the -ExecutionPolicy Bypass override.")
    Write-Host ("  - AppLocker / WDAC blocks powershell.exe in the target user session.")
    Write-Host ("  - %ProgramData%\FabriqBackUper\poc\ is not writable by the target user.")
}

# ----------------------------------------------------------
# Cleanup
# ----------------------------------------------------------
Write-Host ''
Write-Host "Cleaning up..."
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item $childScript -ErrorAction SilentlyContinue
Remove-Item $outputJson  -ErrorAction SilentlyContinue
Write-Host "PoC 02 complete." -ForegroundColor Cyan
