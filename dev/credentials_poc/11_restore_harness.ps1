# ============================================================
# Fabriq BackUper - Credentials Section Restore Harness
#
# Invokes backuper/lib/sections/credentials/restore.ps1 against
# the output of 10_section_harness.ps1 (or any previous run that
# left $env:TEMP\fbu_creds_poc\<ts>\sections\credentials\
# populated). Deploys the operator payload into a TEST Documents
# location (NOT the real one) under $env:TEMP\fbu_creds_restore\.
#
# Run AFTER 10_section_harness.ps1 (which produces the source
# manifest + CSV that restore.ps1 reads).
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass `
#     -File dev\credentials_poc\11_restore_harness.ps1
# ============================================================

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$repoRoot = Resolve-Path (Join-Path $here '..\..')
$commonPath    = Join-Path $repoRoot 'backuper\common.ps1'
$sectionScript = Join-Path $repoRoot 'backuper\lib\sections\credentials\restore.ps1'

. $commonPath

# Locate most recent backup output from 10_section_harness
$pocBackupRoot = Join-Path $env:TEMP 'fbu_creds_poc'
if (-not (Test-Path $pocBackupRoot)) {
    Show-Error "No prior backup output found at $pocBackupRoot. Run 10_section_harness.ps1 first."
    exit 1
}
$latestBackup = Get-ChildItem $pocBackupRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
if (-not $latestBackup) {
    Show-Error "No timestamped backup dirs under $pocBackupRoot. Run 10_section_harness.ps1 first."
    exit 1
}
$aggregateBackupDir = $latestBackup.FullName

# Fake target user profile dir (we will NOT write to the real user's Documents)
$fakeProfile = Join-Path $env:TEMP 'fbu_creds_restore_target'
$null = New-Item -ItemType Directory -Path $fakeProfile -Force
$null = New-Item -ItemType Directory -Path (Join-Path $fakeProfile 'Documents') -Force

Show-Separator
Show-Info ("Restore harness")
Show-Info ("  AggregateBackupDir    : {0}" -f $aggregateBackupDir)
Show-Info ("  Fake TargetUserProfile: {0}" -f $fakeProfile)
Show-Separator

$result = & $sectionScript `
    -BackuperRoot (Join-Path $repoRoot 'backuper') `
    -FabriqRoot   'C:\fabriq-not-needed-for-this-section' `
    -OldPcName    $env:COMPUTERNAME `
    -AggregateBackupDir $aggregateBackupDir `
    -SectionParams @{ TargetUserProfilePath = $fakeProfile }

Show-Separator
Show-Info ("Result.Status                : {0}" -f $result.Status)
Show-Info ("Result.ElapsedMs             : {0}" -f $result.ElapsedMs)
Show-Info ("Result.InternalSectionDir    : {0}" -f $result.InternalSectionDir)
Show-Info ("Result.InternalManifestPath  : {0}" -f $result.InternalManifestPath)
Show-Info ("Result.Summary:")
$result.Summary.GetEnumerator() | ForEach-Object {
    Show-Info ("    {0,-22}= {1}" -f $_.Key, $_.Value)
}

if ($result.Warnings -and $result.Warnings.Count -gt 0) {
    Show-Warning "Warnings:"
    foreach ($w in $result.Warnings) { Show-Warning ("  - {0}" -f $w) }
}

# List deployed files
$deployDir = $result.Summary.deployDir
if ($deployDir -and (Test-Path $deployDir)) {
    Show-Separator
    Show-Info ("Deployed contents of {0}:" -f $deployDir)
    Get-ChildItem $deployDir | ForEach-Object {
        Write-Host ("    {0,-32}  {1,8} bytes" -f $_.Name, $_.Length)
    }
}

Show-Separator
Show-Success "Restore harness complete."
