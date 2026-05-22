# ============================================================
# Fabriq BackUper - Credentials Section Test Harness
#
# Exercises backuper/lib/sections/credentials/backup.ps1
# outside of the full engine, with a synthetic AggregateBackupDir
# under E:\tmp\ and SourceUserProfilePath = current user.
#
# Prerequisites:
#   - Must run elevated (Administrator). The section returns
#     Status=Failed for non-admin processes.
#
# Output:
#   - $env:TEMP\fbu_creds_poc\<timestamp>\sections\credentials\
#       manifest.json
#       _credentials_list.csv
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass `
#     -File dev\credentials_poc\10_section_harness.ps1
# ============================================================

$ErrorActionPreference = 'Stop'

# Resolve paths
$here = $PSScriptRoot
$repoRoot = Resolve-Path (Join-Path $here '..\..')
$commonPath = Join-Path $repoRoot 'backuper\common.ps1'
$sectionScript = Join-Path $repoRoot 'backuper\lib\sections\credentials\backup.ps1'

if (-not (Test-Path $commonPath))    { throw "common.ps1 not found: $commonPath" }
if (-not (Test-Path $sectionScript)) { throw "credentials/backup.ps1 not found: $sectionScript" }

. $commonPath

# Synthetic aggregate dir
$timestamp = (Get-Date).ToString('yyyy_MM_dd_HHmmss')
$aggregateBackupDir = Join-Path $env:TEMP "fbu_creds_poc\$timestamp"
$null = New-Item -ItemType Directory -Path $aggregateBackupDir -Force

Show-Separator
Show-Info ("Section harness: invoking credentials/backup.ps1")
Show-Info ("  BackuperRoot       : {0}" -f (Join-Path $repoRoot 'backuper'))
Show-Info ("  AggregateBackupDir : {0}" -f $aggregateBackupDir)
Show-Info ("  OldPcName          : {0}" -f $env:COMPUTERNAME)
Show-Separator

# Invoke section
$result = & $sectionScript `
    -BackuperRoot (Join-Path $repoRoot 'backuper') `
    -FabriqRoot   'C:\fabriq-not-needed-for-this-section' `
    -OldPcName    $env:COMPUTERNAME `
    -AggregateBackupDir $aggregateBackupDir `
    -SectionParams @{ SourceUserProfilePath = $env:USERPROFILE }

# Print result summary
Show-Separator
Show-Info ("Result.Status               : {0}" -f $result.Status)
Show-Info ("Result.ElapsedMs            : {0}" -f $result.ElapsedMs)
Show-Info ("Result.InternalSectionDir   : {0}" -f $result.InternalSectionDir)
Show-Info ("Result.InternalManifestPath : {0}" -f $result.InternalManifestPath)
Show-Info ("Result.Summary :")
$result.Summary.GetEnumerator() | ForEach-Object {
    Show-Info ("    {0,-26}= {1}" -f $_.Key, $_.Value)
}
if ($result.Warnings -and $result.Warnings.Count -gt 0) {
    Show-Warning "Warnings:"
    foreach ($w in $result.Warnings) { Show-Warning ("  - {0}" -f $w) }
}

# Show first few CSV lines if produced
if ($result.Summary.csvPath -and (Test-Path $result.Summary.csvPath)) {
    Show-Separator
    Show-Info ("CSV preview ({0}):" -f $result.Summary.csvPath)
    Get-Content $result.Summary.csvPath -Encoding UTF8 | Select-Object -First 8 | ForEach-Object {
        Write-Host ("    {0}" -f $_)
    }
}

Show-Separator
Show-Success "Section harness complete."
