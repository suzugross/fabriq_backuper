# ============================================================
# Fabriq LAN-Prep - Remote Desktop helpers (t-0004 Phase 2)
# Enable Remote Desktop on THIS PC (fDenyTSConnections registry + the
# "Remote Desktop" firewall group), capture the prior state, and restore it
# on revert. Best-effort: failures are warned but never abort lan-prep.
# Console output is ASCII (project policy); the firewall display-group list
# includes the JA locale name, so this file is UTF-8 WITH BOM (rule 5).
# ============================================================

$script:RdpRegPath  = 'HKLM:\System\CurrentControlSet\Control\Terminal Server'
$script:RdpFwGroups = @('Remote Desktop', 'リモート デスクトップ')

function Get-RemoteDesktopState {
    # Pre-change capture. Returns @{ Enabled = <bool>; FirewallEnabled = <bool> }.
    $enabled = $false
    try {
        $v = (Get-ItemProperty -Path $script:RdpRegPath -Name 'fDenyTSConnections' -ErrorAction Stop).fDenyTSConnections
        $enabled = ([int]$v -eq 0)
    }
    catch { $enabled = $false }   # key absent/unreadable -> treat as disabled

    $fwEnabled = $false
    foreach ($group in $script:RdpFwGroups) {
        try {
            $rules = Get-NetFirewallRule -DisplayGroup $group -ErrorAction SilentlyContinue
            foreach ($rule in $rules) {
                if ($rule.Enabled -eq 'True') { $fwEnabled = $true }
            }
        }
        catch { }
    }
    return @{ Enabled = $enabled; FirewallEnabled = $fwEnabled }
}

function Enable-RemoteDesktopAccess {
    # Best-effort: allow RDP (registry) + enable its firewall group.
    try {
        Set-ItemProperty -Path $script:RdpRegPath -Name 'fDenyTSConnections' -Value 0 -Type DWord -ErrorAction Stop
        Write-Host "[ok] Remote Desktop enabled (fDenyTSConnections=0)" -ForegroundColor Green
    }
    catch {
        Write-Host "[warn] could not enable Remote Desktop (registry): $($_.Exception.Message)" -ForegroundColor Yellow
    }

    $count = 0
    foreach ($group in $script:RdpFwGroups) {
        try {
            $rules = Get-NetFirewallRule -DisplayGroup $group -ErrorAction SilentlyContinue
            foreach ($rule in $rules) {
                if ($rule.Enabled -eq 'False') {
                    Enable-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
                    $count++
                }
            }
        }
        catch { }
    }
    if ($count -gt 0) { Write-Host "[ok] enabled $count firewall rule(s) for Remote Desktop" -ForegroundColor Green }
    else { Write-Host "[skip] Remote Desktop firewall rules already enabled (or not found)" -ForegroundColor DarkGray }
}

function Set-RemoteDesktopState {
    # Revert: restore the RDP registry + firewall group to a captured state.
    #   $Enabled=$false  -> deny RDP (fDenyTSConnections=1)
    #   $FirewallEnabled=$false -> disable the Remote Desktop firewall group
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][bool]$Enabled,
        [Parameter(Mandatory = $true)][bool]$FirewallEnabled
    )
    try {
        $val = if ($Enabled) { 0 } else { 1 }
        Set-ItemProperty -Path $script:RdpRegPath -Name 'fDenyTSConnections' -Value $val -Type DWord -ErrorAction Stop
        Write-Host "[ok] Remote Desktop registry restored (fDenyTSConnections=$val)" -ForegroundColor Green
    }
    catch {
        Write-Host "[warn] could not restore Remote Desktop (registry): $($_.Exception.Message)" -ForegroundColor Yellow
    }

    $count = 0
    foreach ($group in $script:RdpFwGroups) {
        try {
            $rules = Get-NetFirewallRule -DisplayGroup $group -ErrorAction SilentlyContinue
            foreach ($rule in $rules) {
                if ($FirewallEnabled -and $rule.Enabled -eq 'False') {
                    Enable-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
                    $count++
                }
                elseif ((-not $FirewallEnabled) -and $rule.Enabled -eq 'True') {
                    Disable-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
                    $count++
                }
            }
        }
        catch { }
    }
    $state = if ($FirewallEnabled) { 'enabled' } else { 'disabled' }
    if ($count -gt 0) { Write-Host "[ok] restored $count Remote Desktop firewall rule(s) ($state)" -ForegroundColor Green }
    else { Write-Host "[skip] Remote Desktop firewall already in the desired state" -ForegroundColor DarkGray }
}
