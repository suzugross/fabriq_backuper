# ============================================================
# FabriqBackUper Section: application / backup (t-0009 P2)
#
# Captures the source PC's installed-application inventory. Relocated from
# the system_evidence section's former "11" sub-step so app data lives in
# its own dedicated section (handoff subdir 05_application info) separate
# from PC info (03).
#
#   - 11_DesktopApps.csv : HKLM (x64 + WOW6432Node) + the source user's
#                          per-user Uninstall hive (Resolve-HkcuRoot).
#   - 11_StoreApps.csv   : Get-AppxPackage (current context).
#   - manifest.json      : fabriq-application-backup, schemaVersion=1.
#
# Enumeration uses the shared common.ps1 readers (Get-InstalledDesktopApp /
# Get-InstalledStoreApp) so the backup, the legacy Check-AppMigration.bat,
# and the viewer's live new-PC query (P3) all agree on the same logic.
#
# CLAUDE.md rule 5: written by the Write tool (UTF-8 without BOM) so all
# string literals are ASCII-only; operator-facing Japanese lives in the
# handoff README (restore_view.ps1) and the viewer (BOM-tagged).
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
# Prepare section output directory
# ----------------------------------------------------------
$sectionDir = Join-Path $AggregateBackupDir 'sections\application'
try {
    $null = New-Item -ItemType Directory -Path $sectionDir -Force -ErrorAction Stop
} catch {
    return [PSCustomObject]@{
        Status               = 'Failed'
        ElapsedMs            = [int]$sw.ElapsedMilliseconds
        Summary              = [ordered]@{}
        Warnings             = @("Failed to create section dir: $($_.Exception.Message)")
        ExternalOutputDir    = $null
        ExternalManifestPath = $null
        InternalSectionDir   = $sectionDir
        InternalManifestPath = $null
    }
}
Show-Info "application: section dir = $sectionDir"

# ----------------------------------------------------------
# Resolve the source user's per-user Uninstall hive
# ----------------------------------------------------------
# HKU:\<sid> under cross-user admin elevation, else HKCU: (current user).
# Same approach the former system_evidence 11 used so per-user "Just me"
# installs are captured for the source user, not the elevated admin.
$perUserRoot = $null
try {
    $hkcuInfo = Resolve-HkcuRoot
    if ($null -ne $hkcuInfo -and -not [string]::IsNullOrWhiteSpace($hkcuInfo.PsDrivePath)) {
        $perUserRoot = $hkcuInfo.PsDrivePath
        Show-Info "application: per-user scan target = $($hkcuInfo.Label)"
    } else {
        Show-Info "application: per-user scan target = (none)"
    }
} catch {
    $warnings += "Resolve-HkcuRoot failed; per-user uninstall paths skipped: $($_.Exception.Message)"
    Show-Warning "application: Resolve-HkcuRoot failed; per-user uninstall paths skipped"
}

$status       = 'Success'
$desktopCount = 0
$storeCount   = 0

# ----------------------------------------------------------
# Desktop apps (registry)
# ----------------------------------------------------------
try {
    $desktop = @(Get-InstalledDesktopApp -PerUserUninstallRoot $perUserRoot)
    $desktopCount = $desktop.Count
    $outDesktop = Join-Path $sectionDir '11_DesktopApps.csv'
    $desktop | Export-Csv -Path $outDesktop -NoTypeInformation -Encoding UTF8
    Show-Success "application: Desktop apps $desktopCount -> 11_DesktopApps.csv"
} catch {
    $status = 'Partial'
    $warnings += "Desktop app enumeration failed: $($_.Exception.Message)"
    Show-Warning "application: Desktop app enumeration failed: $($_.Exception.Message)"
}

# ----------------------------------------------------------
# Store / UWP apps (current context)
# ----------------------------------------------------------
try {
    $store = @(Get-InstalledStoreApp)
    $storeCount = $store.Count
    $outStore = Join-Path $sectionDir '11_StoreApps.csv'
    $store | Export-Csv -Path $outStore -NoTypeInformation -Encoding UTF8
    Show-Success "application: Store apps $storeCount -> 11_StoreApps.csv"
} catch {
    $status = 'Partial'
    $warnings += "Store app enumeration failed: $($_.Exception.Message)"
    Show-Warning "application: Store app enumeration failed: $($_.Exception.Message)"
}

# ----------------------------------------------------------
# Section manifest
# ----------------------------------------------------------
$totalBytes = 0
try {
    $totalBytes = [long]((Get-ChildItem -LiteralPath $sectionDir -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum)
} catch {}

$manifest = [ordered]@{
    schemaVersion = 1
    manifestType  = 'fabriq-application-backup'
    collectedAt   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    oldPcName     = $OldPcName
    computerName  = $env:COMPUTERNAME
    perUserScan   = $(if ([string]::IsNullOrWhiteSpace($perUserRoot)) { '(none)' } else { $perUserRoot })
    files         = @('11_DesktopApps.csv', '11_StoreApps.csv')
    summary       = [ordered]@{
        desktopCount = $desktopCount
        storeCount   = $storeCount
        totalBytes   = [long]$totalBytes
    }
}
$manifestPath = Join-Path $sectionDir 'manifest.json'
try {
    $json = $manifest | ConvertTo-Json -Depth 6
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($manifestPath, $json, $utf8NoBom)
} catch {
    $warnings += "Failed to write manifest.json: $($_.Exception.Message)"
    Show-Warning "application: failed to write manifest.json: $($_.Exception.Message)"
    $manifestPath = $null
}

$sw.Stop()
return [PSCustomObject]@{
    Status               = $status
    ElapsedMs            = [int]$sw.ElapsedMilliseconds
    Summary              = [ordered]@{
        desktopCount = $desktopCount
        storeCount   = $storeCount
        totalBytes   = [long]$totalBytes
    }
    Warnings             = $warnings
    ExternalOutputDir    = $null
    ExternalManifestPath = $null
    InternalSectionDir   = $sectionDir
    InternalManifestPath = $manifestPath
}
