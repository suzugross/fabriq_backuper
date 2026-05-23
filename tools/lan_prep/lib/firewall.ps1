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
