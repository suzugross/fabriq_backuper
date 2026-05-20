# ============================================================
# Fabriq BackUper - Entry Script
# Backup/Restore satellite over Fabriq main (auto-discovered).
# Comments are English-only per project policy.
# ============================================================

# Self-spawn guard. When invoked in-process (e.g. via & $appPath),
# re-launch in an isolated powershell.exe subprocess and return.
# This keeps PSReadLine key handlers, env-var mutations, and
# global-scope state confined to the child process.
#
# -NoNewWindow makes the child reuse the parent's console window so
# we don't end up with two visible conhost windows when launched from
# Fabriq_BackUper.exe (the C# launcher already creates one fresh
# console via UseShellExecute = true). Process isolation is preserved;
# only the console window is shared.
if (-not $env:FABRIQ_BACKUPER_SUBPROCESS) {
    $env:FABRIQ_BACKUPER_SUBPROCESS = '1'
    try {
        $self = $PSCommandPath
        Start-Process powershell.exe `
            -ArgumentList @(
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-File', "`"$self`""
            ) `
            -Wait `
            -NoNewWindow
    } finally {
        Remove-Item Env:FABRIQ_BACKUPER_SUBPROCESS -ErrorAction SilentlyContinue
    }
    return
}

# --- The following runs only inside the isolated subprocess. ---

$ErrorActionPreference = 'Stop'

# Resolve repo paths.
$script:BackuperRoot = $PSScriptRoot
$script:BackuperLib  = Join-Path $PSScriptRoot 'backuper'

# Locate main.ps1 (Stage 3 fills this; in Stage 2 skeleton it may be absent).
$mainScript = Join-Path $script:BackuperLib 'main.ps1'
if (-not (Test-Path -LiteralPath $mainScript)) {
    Write-Host ""                                                          -ForegroundColor Red
    Write-Host "[FATAL] backuper/main.ps1 was not found."                   -ForegroundColor Red
    Write-Host "        Expected at: $mainScript"                           -ForegroundColor Red
    Write-Host "        This is a Stage 2 skeleton; Stage 3 copies the"     -ForegroundColor DarkGray
    Write-Host "        real main.ps1 from the original apps/fabriq_backuper/ tree." -ForegroundColor DarkGray
    Write-Host ""
    Read-Host "Press Enter to exit"
    return
}

# Delegate everything else to backuper/main.ps1.
. $mainScript
