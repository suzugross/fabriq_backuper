# ============================================================
# Fabriq LAN-Prep - Firewall helpers
# Enables the built-in "File and Printer Sharing" rule group.
# Best-effort: failures are warned but not fatal.
# ============================================================

function Enable-FileAndPrinterSharingRule {
    [CmdletBinding()]
    param()

    $count = 0
    foreach ($group in @('File and Printer Sharing', 'ファイルとプリンターの共有')) {
        try {
            $rules = Get-NetFirewallRule -DisplayGroup $group -ErrorAction SilentlyContinue
            foreach ($rule in $rules) {
                if ($rule.Enabled -eq 'False') {
                    Enable-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
                    $count++
                }
            }
        } catch {
            # Locale group name not present - skip.
        }
    }

    if ($count -gt 0) {
        Write-Host "[ok] enabled $count firewall rule(s) for File and Printer Sharing" -ForegroundColor Green
    }
    else {
        Write-Host "[skip] File and Printer Sharing rules already enabled (or not found)" -ForegroundColor DarkGray
    }
}

# v0.71.1 (t-0004 P3): capture / restore the "File and Printer Sharing" firewall group
# state so Revert returns this PC to its pre-LAN-Prep firewall posture (Prepare enables
# the group for share access; without this it stayed ON after revert).
function Get-FileAndPrinterSharingState {
    # Returns $true if any "File and Printer Sharing" firewall rule is currently enabled.
    $enabled = $false
    foreach ($group in @('File and Printer Sharing', 'ファイルとプリンターの共有')) {
        try {
            $rules = Get-NetFirewallRule -DisplayGroup $group -ErrorAction SilentlyContinue
            foreach ($rule in $rules) { if ($rule.Enabled -eq 'True') { $enabled = $true } }
        }
        catch { }
    }
    return $enabled
}

function Set-FileAndPrinterSharingState {
    # Revert: enable/disable the "File and Printer Sharing" firewall group to a captured
    # state. $Enabled=$false disables the group (back to the pre-LAN-Prep posture).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][bool]$Enabled)
    $count = 0
    foreach ($group in @('File and Printer Sharing', 'ファイルとプリンターの共有')) {
        try {
            $rules = Get-NetFirewallRule -DisplayGroup $group -ErrorAction SilentlyContinue
            foreach ($rule in $rules) {
                if ($Enabled -and $rule.Enabled -eq 'False') {
                    Enable-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
                    $count++
                }
                elseif ((-not $Enabled) -and $rule.Enabled -eq 'True') {
                    Disable-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
                    $count++
                }
            }
        }
        catch { }
    }
    $state = if ($Enabled) { 'enabled' } else { 'disabled' }
    if ($count -gt 0) { Write-Host "[ok] restored $count File and Printer Sharing firewall rule(s) ($state)" -ForegroundColor Green }
    else { Write-Host "[skip] File and Printer Sharing firewall already in the desired state" -ForegroundColor DarkGray }
}
