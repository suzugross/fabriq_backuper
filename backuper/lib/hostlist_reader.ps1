# ============================================================
# FabriqBackUper - Hostlist Reader
# Loads fabriq's kernel/csv/hostlist.csv via Import-ModuleCsv
# (which transparently decrypts ENC: values using
# $global:FabriqMasterPassphrase). Read-only consumer.
# ============================================================

function Get-FabriqHostlist {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FabriqRoot
    )

    $hostlistPath = Join-Path $FabriqRoot 'kernel\csv\hostlist.csv'
    if (-not (Test-Path $hostlistPath)) {
        Show-Error "Hostlist not found: $hostlistPath"
        return $null
    }

    # Import-ModuleCsv applies ENC: decryption when
    # $global:FabriqMasterPassphrase is set. We pass minimal
    # RequiredColumns; the operator-facing fields will be probed
    # column-by-column below to avoid hard failures on schema
    # variation across fabriq deployments.
    $rows = Import-ModuleCsv -Path $hostlistPath `
        -RequiredColumns @('OldPCname')

    if ($null -eq $rows) {
        Show-Error "Failed to read hostlist (Import-ModuleCsv returned null)."
        return $null
    }

    return @($rows)
}

# Picks one host from the list. If $env:SELECTED_OLD_PCNAME is
# already set, returns the matching row without prompting.
function Select-HostFromList {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Hosts
    )

    if (-not [string]::IsNullOrWhiteSpace($env:SELECTED_OLD_PCNAME)) {
        $existing = $Hosts | Where-Object { $_.OldPCname -eq $env:SELECTED_OLD_PCNAME } | Select-Object -First 1
        if ($null -ne $existing) {
            Show-Info "Inheriting host selection: $($existing.OldPCname)"
            return $existing
        }
    }

    if ($Hosts.Count -eq 0) {
        Show-Error "Hostlist is empty."
        return $null
    }

    # Console picker
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host " Select a host (OldPCname)" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Yellow
    for ($i = 0; $i -lt $Hosts.Count; $i++) {
        $h = $Hosts[$i]
        $newName = if ($h.PSObject.Properties.Name -contains 'NewPCname') { $h.NewPCname } else { '' }
        Write-Host ("  [{0,3}] {1}" -f ($i + 1), $h.OldPCname) -NoNewline -ForegroundColor White
        if (-not [string]::IsNullOrWhiteSpace($newName)) {
            Write-Host "  ->  $newName" -ForegroundColor DarkGray
        } else {
            Write-Host ""
        }
    }
    Write-Host "  [  0] Cancel" -ForegroundColor DarkGray
    Write-Host ""

    while ($true) {
        $sel = Read-Host "Enter number"
        if ($sel -eq '0' -or [string]::IsNullOrWhiteSpace($sel)) {
            return $null
        }
        $idx = 0
        if ([int]::TryParse($sel, [ref]$idx) -and $idx -ge 1 -and $idx -le $Hosts.Count) {
            return $Hosts[$idx - 1]
        }
        Show-Error "Invalid selection: $sel"
    }
}
