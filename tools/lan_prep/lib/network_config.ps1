# ============================================================
# Fabriq LAN-Prep - Network configuration helpers
# Uses netsh (not NetTCPIP cmdlets like New-NetIPAddress) for
# applying IPv4 settings, because netsh can configure interfaces
# whose media is disconnected (typical during PC kitting before
# the LAN cable is connected). NetTCPIP cmdlets fail in that
# state with "Inaccessible boot device" or similar errors.
#
# Read-side helpers (Get-NetIPAddress / Get-NetIPInterface /
# Get-NetRoute / Get-DnsClientServerAddress) continue to use
# PowerShell cmdlets - enumeration works fine on disconnected
# interfaces.
# ============================================================

function ConvertTo-Ipv4Mask {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int]$PrefixLength)

    if ($PrefixLength -lt 0 -or $PrefixLength -gt 32) {
        throw "Invalid IPv4 prefix length: $PrefixLength"
    }
    $bits = ('1' * $PrefixLength) + ('0' * (32 - $PrefixLength))
    $octets = @()
    for ($i = 0; $i -lt 32; $i += 8) {
        $octets += [Convert]::ToInt32($bits.Substring($i, 8), 2)
    }
    return ($octets -join '.')
}

function Invoke-NetshIpv4 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$StepName,
        [switch]$AllowFailure
    )

    $stdoutFile = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath 'netsh.exe' `
                              -ArgumentList $Arguments `
                              -NoNewWindow `
                              -Wait `
                              -PassThru `
                              -RedirectStandardOutput $stdoutFile `
                              -RedirectStandardError  $stdoutFile
        $exit = $proc.ExitCode
        $out  = Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue
        if ($exit -ne 0) {
            $msg = "netsh failed during '$StepName' (exit=$exit): $($out -replace "\r?\n", ' | ')"
            if ($AllowFailure) {
                Write-Host "[warn] $msg" -ForegroundColor Yellow
            }
            else {
                throw $msg
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $stdoutFile -Force -ErrorAction SilentlyContinue
    }
}

function Set-MigrationNetworkConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Config)

    $alias      = $Config.interfaceAlias
    $newIp      = $Config.ipAddress
    $prefix     = [int]$Config.prefixLength
    $mask       = ConvertTo-Ipv4Mask -PrefixLength $prefix
    $gateway    = $Config.gateway
    $dnsServers = @($Config.dnsServers)

    # Adapter must exist; enumeration works on disconnected interfaces.
    $adapter = Get-NetAdapter -Name $alias -ErrorAction Stop
    Write-Host "[info] adapter '$alias' status=$($adapter.Status) media=$($adapter.MediaConnectState)" -ForegroundColor DarkGray
    if ($adapter.Status -eq 'Disabled') {
        Write-Host "[warn] adapter '$alias' is disabled; netsh may still write the config but it won't activate until enabled." -ForegroundColor Yellow
    }

    # Apply primary IPv4 address (replaces existing primary; clears DHCP).
    $setAddrArgs = @('interface', 'ipv4', 'set', 'address',
                     "name=$alias", 'source=static',
                     "address=$newIp", "mask=$mask")
    if (-not [string]::IsNullOrWhiteSpace($gateway)) {
        $setAddrArgs += "gateway=$gateway"
        $setAddrArgs += 'gwmetric=1'
    }
    else {
        # Explicitly clear default gateway when not requested.
        $setAddrArgs += 'gateway=none'
    }
    Invoke-NetshIpv4 -Arguments $setAddrArgs -StepName "set IPv4 address ($newIp/$prefix)"

    # DNS servers.
    if ($dnsServers.Count -gt 0) {
        Invoke-NetshIpv4 -Arguments @('interface', 'ipv4', 'set', 'dnsservers',
                                       "name=$alias", 'source=static',
                                       "address=$($dnsServers[0])", 'register=primary',
                                       'validate=no') `
                         -StepName "set primary DNS ($($dnsServers[0]))"
        for ($i = 1; $i -lt $dnsServers.Count; $i++) {
            Invoke-NetshIpv4 -Arguments @('interface', 'ipv4', 'add', 'dnsservers',
                                           "name=$alias",
                                           "address=$($dnsServers[$i])",
                                           "index=$($i + 1)",
                                           'validate=no') `
                             -StepName "add DNS #$($i + 1) ($($dnsServers[$i]))"
        }
    }
    else {
        Invoke-NetshIpv4 -Arguments @('interface', 'ipv4', 'set', 'dnsservers',
                                       "name=$alias", 'source=dhcp') `
                         -StepName "reset DNS to DHCP" `
                         -AllowFailure
    }
}

function Set-MigrationNetworkCategoryPrivate {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InterfaceAlias)

    # Network category requires an active connection profile, which only
    # exists when the link is up. On a disconnected NIC, skip with a hint
    # so the operator knows to handle it post-connection.
    try {
        $nc = Get-NetConnectionProfile -InterfaceAlias $InterfaceAlias -ErrorAction Stop
    }
    catch {
        Write-Host "[skip] no connection profile for '$InterfaceAlias' (link down). Windows will default new connections to Public; run this step again after LAN cable is connected if needed." -ForegroundColor Yellow
        return
    }

    if ($nc.NetworkCategory -ne 'Private') {
        try {
            Set-NetConnectionProfile -InterfaceIndex $nc.InterfaceIndex -NetworkCategory Private -ErrorAction Stop
            Write-Host "[ok] network category set to Private (was $($nc.NetworkCategory))" -ForegroundColor Green
        }
        catch {
            Write-Host "[warn] failed to set network category: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "[skip] network category already Private" -ForegroundColor DarkGray
    }
}

function Restore-MigrationNetworkConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Snapshot)

    $alias = $Snapshot.interfaceAlias

    if ($Snapshot.dhcpEnabled) {
        Invoke-NetshIpv4 -Arguments @('interface', 'ipv4', 'set', 'address',
                                       "name=$alias", 'source=dhcp') `
                         -StepName "restore IPv4 to DHCP"
        Invoke-NetshIpv4 -Arguments @('interface', 'ipv4', 'set', 'dnsservers',
                                       "name=$alias", 'source=dhcp') `
                         -StepName "restore DNS to DHCP" `
                         -AllowFailure
    }
    else {
        # Static restore: primary IP first, then any secondaries.
        if ($Snapshot.ipAddresses -and $Snapshot.ipAddresses.Count -gt 0) {
            $primary = $Snapshot.ipAddresses[0]
            $mask = ConvertTo-Ipv4Mask -PrefixLength ([int]$primary.prefixLength)
            $args1 = @('interface', 'ipv4', 'set', 'address',
                       "name=$alias", 'source=static',
                       "address=$($primary.address)", "mask=$mask")
            if (-not [string]::IsNullOrWhiteSpace($Snapshot.defaultGateway)) {
                $args1 += "gateway=$($Snapshot.defaultGateway)"
                $args1 += 'gwmetric=1'
            }
            else {
                $args1 += 'gateway=none'
            }
            Invoke-NetshIpv4 -Arguments $args1 -StepName "restore primary IPv4 ($($primary.address)/$($primary.prefixLength))"

            for ($i = 1; $i -lt $Snapshot.ipAddresses.Count; $i++) {
                $ip = $Snapshot.ipAddresses[$i]
                $m  = ConvertTo-Ipv4Mask -PrefixLength ([int]$ip.prefixLength)
                Invoke-NetshIpv4 -Arguments @('interface', 'ipv4', 'add', 'address',
                                               "name=$alias",
                                               "address=$($ip.address)",
                                               "mask=$m") `
                                 -StepName "restore additional IPv4 ($($ip.address))" `
                                 -AllowFailure
            }
        }
        else {
            # Snapshot recorded no manual addresses (interface was effectively
            # blank). Clear current static IPs by switching to DHCP-source as
            # a neutral default; operator can adjust manually if needed.
            Invoke-NetshIpv4 -Arguments @('interface', 'ipv4', 'set', 'address',
                                           "name=$alias", 'source=dhcp') `
                             -StepName "clear IPv4 (snapshot had no static IPs)" `
                             -AllowFailure
        }

        # DNS restore.
        if ($Snapshot.dnsServers -and $Snapshot.dnsServers.Count -gt 0) {
            Invoke-NetshIpv4 -Arguments @('interface', 'ipv4', 'set', 'dnsservers',
                                           "name=$alias", 'source=static',
                                           "address=$($Snapshot.dnsServers[0])", 'register=primary',
                                           'validate=no') `
                             -StepName "restore primary DNS"
            for ($i = 1; $i -lt $Snapshot.dnsServers.Count; $i++) {
                Invoke-NetshIpv4 -Arguments @('interface', 'ipv4', 'add', 'dnsservers',
                                               "name=$alias",
                                               "address=$($Snapshot.dnsServers[$i])",
                                               "index=$($i + 1)",
                                               'validate=no') `
                                 -StepName "restore DNS #$($i + 1)" `
                                 -AllowFailure
            }
        }
        else {
            Invoke-NetshIpv4 -Arguments @('interface', 'ipv4', 'set', 'dnsservers',
                                           "name=$alias", 'source=dhcp') `
                             -StepName "clear DNS (snapshot had none)" `
                             -AllowFailure
        }
    }

    # Network category restore - best-effort, only if link is up.
    if ($Snapshot.networkCategory) {
        try {
            $nc = Get-NetConnectionProfile -InterfaceAlias $alias -ErrorAction Stop
            if ($nc.NetworkCategory -ne $Snapshot.networkCategory) {
                Set-NetConnectionProfile -InterfaceIndex $nc.InterfaceIndex -NetworkCategory $Snapshot.networkCategory -ErrorAction Stop
                Write-Host "[ok] network category restored to $($Snapshot.networkCategory)" -ForegroundColor Green
            }
        }
        catch {
            Write-Host "[skip] could not restore network category (link may be down): $($_.Exception.Message)" -ForegroundColor DarkGray
        }
    }
}
