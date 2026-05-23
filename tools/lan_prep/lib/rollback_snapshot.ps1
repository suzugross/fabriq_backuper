# ============================================================
# Fabriq LAN-Prep - Rollback snapshot serialization
# Captures the current NIC state so Revert-LanMigration can
# restore it after migration.
# ============================================================

function New-RollbackSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InterfaceAlias,
        [Parameter(Mandatory = $true)][string]$Role
    )

    $ipInterface = Get-NetIPInterface -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction Stop
    $dhcpEnabled = ($ipInterface.Dhcp -eq 'Enabled')

    $addresses = @()
    Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.PrefixOrigin -eq 'Manual' } |
        ForEach-Object {
            $addresses += [pscustomobject]@{
                address      = $_.IPAddress
                prefixLength = [int]$_.PrefixLength
            }
        }

    $defaultGw = $null
    $route = Get-NetRoute -InterfaceAlias $InterfaceAlias -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($route) { $defaultGw = $route.NextHop }

    $dnsServers = @()
    $dns = Get-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($dns -and $dns.ServerAddresses) {
        $dnsServers = @($dns.ServerAddresses)
    }

    $networkCategory = $null
    try {
        $nc = Get-NetConnectionProfile -InterfaceAlias $InterfaceAlias -ErrorAction Stop
        $networkCategory = $nc.NetworkCategory.ToString()
    } catch {}

    return [pscustomobject]@{
        schemaVersion   = 1
        capturedAt      = (Get-Date).ToString('o')
        role            = $Role
        interfaceAlias  = $InterfaceAlias
        dhcpEnabled     = $dhcpEnabled
        ipAddresses     = $addresses
        defaultGateway  = $defaultGw
        dnsServers      = $dnsServers
        networkCategory = $networkCategory
    }
}

function Save-RollbackSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $json = $Snapshot | ConvertTo-Json -Depth 10
    # JSON is UTF-8 without BOM per project policy (rule 5).
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $utf8NoBom)
}

function Read-RollbackSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Snapshot file not found: $Path"
    }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}
