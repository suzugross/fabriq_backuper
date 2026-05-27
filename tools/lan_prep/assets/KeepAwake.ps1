# ============================================================
# Fabriq KeepAwake - Sleep Suppression Utility
#
# Standalone PowerShell helper distributed alongside lan-prep into
# the FabriqMigration folder. While this script is running it
# prevents the PC from going to sleep or turning off the display
# via the Win32 SetThreadExecutionState API. Closing the window or
# pressing Ctrl+C releases the suppression immediately; on a hard
# crash the OS automatically releases the flag when the process
# exits, so there is no permanent state to clean up.
#
# Wiring (lan-prep adds these in Prepare-LanMigration.ps1):
#   1. After snapshot save: Copy KeepAwake.{bat,ps1} into the
#      FabriqMigration folder (= Split-Path -Parent $snapshotPath).
#   2. After Step 4: Start-Process KeepAwake.bat so the operator
#      does not have to remember to launch it.
#
# This script is intentionally ASCII-only because the Write tool
# saves new files without a UTF-8 BOM, and PS5.1 would mis-decode
# non-ASCII bytes as CP932 (CLAUDE.md project rule 5). Operator-
# facing messages use plain English that is easy for Japanese
# readers to scan at a glance.
# ============================================================

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class SleepSuppressor {
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);
    public const uint ES_CONTINUOUS       = 0x80000000;
    public const uint ES_SYSTEM_REQUIRED  = 0x00000001;
    public const uint ES_DISPLAY_REQUIRED = 0x00000002;
}
'@ -ErrorAction SilentlyContinue

try {
    [SleepSuppressor]::SetThreadExecutionState(
        [SleepSuppressor]::ES_CONTINUOUS  -bor
        [SleepSuppressor]::ES_SYSTEM_REQUIRED -bor
        [SleepSuppressor]::ES_DISPLAY_REQUIRED) | Out-Null

    Clear-Host
    Write-Host ""
    Write-Host "  =============================================" -ForegroundColor Cyan
    Write-Host "    Fabriq KeepAwake - Sleep Suppression Active" -ForegroundColor Cyan
    Write-Host "  =============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "    Sleep suppression is now active." -ForegroundColor White
    Write-Host "    This PC will NOT sleep while this window is open." -ForegroundColor White
    Write-Host ""
    Write-Host "    >>> Please start your backup or restore now. <<<" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    Started at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    When backup or restore is finished," -ForegroundColor White
    Write-Host "    close this window (X) or press Ctrl+C." -ForegroundColor White
    Write-Host ""

    # Idle loop: a 60-second Start-Sleep is long enough to be cheap on
    # CPU but short enough that closing the host process releases the
    # SetThreadExecutionState flag promptly (the OS releases on process
    # exit regardless, so the loop interval is mostly a cosmetic choice).
    while ($true) {
        Start-Sleep -Seconds 60
    }
}
finally {
    [SleepSuppressor]::SetThreadExecutionState(
        [SleepSuppressor]::ES_CONTINUOUS) | Out-Null
    Write-Host ""
    Write-Host "    Sleep suppression released." -ForegroundColor Yellow
    Write-Host ""
}
