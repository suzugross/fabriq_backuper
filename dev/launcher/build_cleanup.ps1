# ========================================
# Fabriq Cleanup Launcher Build Script (v0.54.0)
# ========================================
# Compiles Launcher_Cleanup.cs into Fabriq_Cleanup.exe using csc.exe.
# Produces the final binary at the repo root: ..\..\Fabriq_Cleanup.exe
# (i.e. E:\fabriq_backuper\Fabriq_Cleanup.exe).
#
# Mirrors build_lanprep.ps1 exactly except for the source / manifest
# / output file names, so all launchers share the same toolchain.
# ========================================

[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot   = Resolve-Path (Join-Path $scriptDir '..\..')
$commonPath = Join-Path $repoRoot 'backuper\common.ps1'

if (-not (Test-Path $commonPath)) {
    Write-Host "[ERROR] backuper\common.ps1 not found at: $commonPath" -ForegroundColor Red
    exit 1
}
. $commonPath

Show-Separator
Write-Host "  Fabriq Cleanup Launcher Build" -ForegroundColor Cyan
Show-Separator

Show-Info "Locating csc.exe (.NET Framework compiler)..."
$cscCandidates = @(
    'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe',
    'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe'
)
$csc = $cscCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $csc) {
    Show-Error ".NET Framework 4.x csc.exe was not found."
    exit 1
}
Show-Success "csc.exe: $csc"

$iconPath = Join-Path $scriptDir 'fabriq.ico'
if (-not (Test-Path $iconPath)) {
    Show-Warning "fabriq.ico not found; building without an icon."
    $iconPath = $null
}

$sourceCs  = Join-Path $scriptDir 'Launcher_Cleanup.cs'
$manifest  = Join-Path $scriptDir 'app_cleanup.manifest'
$outputExe = Join-Path $repoRoot  'Fabriq_Cleanup.exe'

foreach ($required in @($sourceCs, $manifest)) {
    if (-not (Test-Path $required)) {
        Show-Error "Required file missing: $required"
        exit 1
    }
}

$running = Get-Process -Name 'Fabriq_Cleanup' -ErrorAction SilentlyContinue
if ($running) {
    Show-Warning "Fabriq_Cleanup.exe is currently running. Terminate it before rebuild."
    if (-not $Force) {
        Show-Error "Build aborted. Re-run with -Force to ignore (not recommended)."
        exit 1
    }
}

Show-Info "Compiling Launcher_Cleanup.cs -> Fabriq_Cleanup.exe ..."

$cscArgs = @(
    '/target:winexe',
    '/platform:anycpu',
    '/optimize+',
    '/nologo',
    "/win32manifest:$manifest",
    "/out:$outputExe"
)
if ($iconPath) {
    $cscArgs += "/win32icon:$iconPath"
}
$cscArgs += $sourceCs

$proc = Start-Process -FilePath $csc -ArgumentList $cscArgs `
    -NoNewWindow -Wait -PassThru `
    -WorkingDirectory $scriptDir

if ($proc.ExitCode -ne 0) {
    Show-Error "csc.exe failed with exit code $($proc.ExitCode)"
    exit $proc.ExitCode
}
if (-not (Test-Path $outputExe)) {
    Show-Error "Build reported success but output is missing: $outputExe"
    exit 1
}

Show-Success "Build succeeded."
$info = Get-Item $outputExe
Show-Info "Output    : $($info.FullName)"
Show-Info "Size      : $([math]::Round($info.Length / 1KB, 2)) KB"
Show-Info "Product   : $($info.VersionInfo.ProductName)"
Show-Info "Version   : $($info.VersionInfo.ProductVersion)"

Show-Separator
Write-Host "  Done" -ForegroundColor Cyan
Show-Separator
exit 0
