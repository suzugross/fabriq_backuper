# ============================================================
# FabriqBackUper - Phase 1 Console UI
# Simple console-based menus. Phase 3 will replace with WinForms.
# ============================================================

function Show-MainMenu {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " Fabriq BackUper - Main Menu" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  [1] Backup"   -ForegroundColor White
    Write-Host "  [2] Restore"  -ForegroundColor White
    Write-Host "  [Q] Quit"     -ForegroundColor DarkGray
    Write-Host ""

    while ($true) {
        $sel = Read-Host "Enter choice"
        switch -Regex ($sel) {
            '^1$'        { return 'Backup' }
            '^2$'        { return 'Restore' }
            '^[Qq]$'     { return 'Quit' }
            '^$'         { return 'Quit' }
            default      { Show-Error "Invalid choice: $sel" }
        }
    }
}

function Show-SectionSelector {
    param(
        [Parameter(Mandatory = $true)][array]$AllSections
    )

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host " Select sections to process" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "  Enter section numbers separated by comma (e.g. 1,2)" -ForegroundColor DarkGray
    Write-Host "  or 'A' for all enabled, '0' to cancel." -ForegroundColor DarkGray
    Write-Host ""

    for ($i = 0; $i -lt $AllSections.Count; $i++) {
        $s = $AllSections[$i]
        $enabledTag = if ($s.Enabled -eq "1") { "[ON ]" } else { "[off]" }
        $color = if ($s.Enabled -eq "1") { 'White' } else { 'DarkGray' }
        Write-Host ("  [{0,2}] {1} {2,-10} {3}" -f ($i + 1), $enabledTag, $s.SectionName, $s.DisplayName) -ForegroundColor $color
        if ($s.Description) {
            Write-Host ("        {0}" -f $s.Description) -ForegroundColor DarkGray
        }
    }
    Write-Host ""

    while ($true) {
        $sel = Read-Host "Sections"
        if ($sel -eq '0' -or [string]::IsNullOrWhiteSpace($sel)) {
            return @()
        }
        if ($sel -match '^[Aa]$') {
            return @($AllSections | Where-Object { $_.Enabled -eq "1" })
        }
        $picks = @()
        $invalid = $false
        foreach ($tok in $sel.Split(',')) {
            $t = $tok.Trim()
            if ([string]::IsNullOrWhiteSpace($t)) { continue }
            $n = 0
            if (-not [int]::TryParse($t, [ref]$n) -or $n -lt 1 -or $n -gt $AllSections.Count) {
                Show-Error "Invalid: '$t'"
                $invalid = $true
                break
            }
            $picks += $AllSections[$n - 1]
        }
        if (-not $invalid -and $picks.Count -gt 0) {
            return $picks
        }
        if (-not $invalid -and $picks.Count -eq 0) {
            Show-Error "No sections selected."
        }
    }
}

function Show-BackupTimestampSelector {
    param(
        [Parameter(Mandatory = $true)][array]$Timestamps
    )

    if ($Timestamps.Count -eq 0) {
        return $null
    }
    if ($Timestamps.Count -eq 1) {
        Show-Info "Only one backup available: $($Timestamps[0])"
        return $Timestamps[0]
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host " Select backup timestamp" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Yellow
    for ($i = 0; $i -lt $Timestamps.Count; $i++) {
        $marker = if ($i -eq 0) { "  (latest)" } else { "" }
        Write-Host ("  [{0,2}] {1}{2}" -f ($i + 1), $Timestamps[$i], $marker) -ForegroundColor White
    }
    Write-Host "  [ 0] Cancel" -ForegroundColor DarkGray
    Write-Host ""

    while ($true) {
        $sel = Read-Host "Enter number (default: 1 = latest)"
        if ([string]::IsNullOrWhiteSpace($sel)) {
            return $Timestamps[0]
        }
        if ($sel -eq '0') {
            return $null
        }
        $n = 0
        if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $Timestamps.Count) {
            return $Timestamps[$n - 1]
        }
        Show-Error "Invalid: $sel"
    }
}

function Show-ConfirmPrompt {
    param([string]$Message = "Proceed?")
    Write-Host ""
    while ($true) {
        $sel = Read-Host "$Message (Y/N)"
        switch -Regex ($sel) {
            '^[Yy]$' { return $true }
            '^[Nn]$' { return $false }
            default  { }
        }
    }
}
