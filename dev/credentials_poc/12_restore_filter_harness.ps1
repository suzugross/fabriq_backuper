# ============================================================
# Fabriq BackUper - Credentials Restore Filter Harness (v0.20.0)
#
# Verifies that credentials/restore.ps1's IncludeTargets
# SectionParam correctly filters the deployed CSV.
#
# Pre-requisite: 10_section_harness.ps1 has been run at least
# once, leaving a backup under %TEMP%\fbu_creds_poc\<ts>\
# sections\credentials\.
#
# Test scenarios:
#   1) No filter        => deployed CSV has all source rows
#   2) Subset filter    => deployed CSV has only specified Targets
#   3) Empty array      => deployed CSV has 0 rows (header only)
#   4) Non-matching     => same as empty (0 rows)
# ============================================================

$ErrorActionPreference = 'Stop'

$here          = $PSScriptRoot
$repoRoot      = Resolve-Path (Join-Path $here '..\..')
$commonPath    = Join-Path $repoRoot 'backuper\common.ps1'
$sectionScript = Join-Path $repoRoot 'backuper\lib\sections\credentials\restore.ps1'
. $commonPath

$pocBackupRoot = Join-Path $env:TEMP 'fbu_creds_poc'
$latestBackup = Get-ChildItem $pocBackupRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
if (-not $latestBackup) {
    Show-Error "Run 10_section_harness.ps1 first."
    exit 1
}
$aggregateBackupDir = $latestBackup.FullName

# Read source CSV to know what targets exist
$srcCsv = Join-Path $aggregateBackupDir 'sections\credentials\_credentials_list.csv'
$srcRows = @(Import-Csv -LiteralPath $srcCsv -Encoding UTF8)
Show-Info ("Source CSV row count: {0}" -f $srcRows.Count)
Show-Info "Source Target list:"
foreach ($r in $srcRows) { Write-Host ('    {0}' -f $r.Target) }
Write-Host ''

function Invoke-OneCase {
    param([string]$Name, $IncludeTargets, [int]$ExpectedRows)
    $tgtProfile = Join-Path $env:TEMP ("fbu_creds_restore_filter_{0}" -f $Name)
    if (Test-Path $tgtProfile) { Remove-Item $tgtProfile -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $tgtProfile -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $tgtProfile 'Documents') -Force

    Show-Separator
    Show-Info ("--- Case: {0} (expected rows: {1}) ---" -f $Name, $ExpectedRows)

    $params = @{ TargetUserProfilePath = $tgtProfile }
    if ($null -ne $IncludeTargets) { $params['IncludeTargets'] = $IncludeTargets }

    $result = & $sectionScript `
        -BackuperRoot (Join-Path $repoRoot 'backuper') `
        -FabriqRoot   'C:\fabriq-not-needed' `
        -OldPcName    $env:COMPUTERNAME `
        -AggregateBackupDir $aggregateBackupDir `
        -SectionParams $params

    Show-Info ("Status                : {0}" -f $result.Status)
    Show-Info ("deployedFileCount     : {0}" -f $result.Summary.deployedFileCount)
    Show-Info ("sourceCsvRowCount     : {0}" -f $result.Summary.sourceCsvRowCount)
    Show-Info ("deployedCsvRowCount   : {0}" -f $result.Summary.deployedCsvRowCount)
    Show-Info ("includeTargetsApplied : {0}" -f $result.Summary.includeTargetsApplied)

    # Read the deployed CSV and verify row count
    $deployCsv = Join-Path $result.Summary.deployDir 'credentials_list.csv'
    if (Test-Path $deployCsv) {
        $deployRows = @(Import-Csv -LiteralPath $deployCsv -Encoding UTF8)
        Show-Info ("Actual deployed rows  : {0}" -f $deployRows.Count)
        foreach ($r in $deployRows) { Write-Host ('      {0}' -f $r.Target) }
        if ($deployRows.Count -eq $ExpectedRows) {
            Show-Success ("PASS: row count matches expected ({0})" -f $ExpectedRows)
        } else {
            Show-Error ("FAIL: expected {0} rows, got {1}" -f $ExpectedRows, $deployRows.Count)
        }
    } else {
        Show-Error "Deployed CSV not found"
    }
}

# Case 1: No filter (IncludeTargets = $null) -> all rows
Invoke-OneCase -Name 'no_filter' -IncludeTargets $null -ExpectedRows $srcRows.Count

# Case 2: Subset (first Target only)
if ($srcRows.Count -ge 1) {
    Invoke-OneCase -Name 'subset_one' -IncludeTargets @($srcRows[0].Target) -ExpectedRows 1
}

# Case 3: Empty array -> zero rows
Invoke-OneCase -Name 'empty_array' -IncludeTargets @() -ExpectedRows 0

# Case 4: Non-matching target -> zero rows
Invoke-OneCase -Name 'no_match' -IncludeTargets @('Domain:target=does-not-exist-12345') -ExpectedRows 0

Show-Separator
Show-Success "Filter harness complete."
