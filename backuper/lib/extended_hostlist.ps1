# ============================================================
# FabriqBackUper - Extended Hostlist (t-0011, v0.64.0)
#
# A per-satellite, BackUper-owned hostlist (backuper/data/extended_hostlist.csv),
# SEPARATE from the Fabriq hostlist. It carries the same identity keys
# (OldPCname, NewPCname) plus per-PC UNC credentials (UncPassword stored as a
# portable, master-passphrase-gated "ENC:" value) and visual info.
#
# SAFETY: the Fabriq hostlist is the ABSOLUTE source of truth. An extended row
# is ADOPTED only when its (OldPCname, NewPCname) pair EXACTLY matches a Fabriq
# row (trim + case-insensitive). Unmatched rows are silently ignored (never
# fatal, never written back).
#
# This module powers the inert Connect-UncFromExtendedHostlist seam in
# unc_helper.ps1: when present + a credential matches the in-session selected
# host, the UNC share auto-connects with zero operator interaction; otherwise
# behaviour is identical to before (falls through to Show-UncConnectDialog).
#
# Credential handling: UncPassword is kept as raw ENC: ciphertext in the rows
# returned by the reader; it is decrypted ON DEMAND inside
# Connect-UncFromExtendedHostlist and never cached as plaintext.
# ============================================================

function Get-ExtendedHostlistPath {
    # Resolve the live extended hostlist CSV path under <BackuperRoot>\data\.
    param([string]$BackuperRoot = $null)
    if ([string]::IsNullOrWhiteSpace($BackuperRoot)) {
        if (-not [string]::IsNullOrWhiteSpace($script:BackuperRoot)) {
            $BackuperRoot = $script:BackuperRoot
        } elseif (-not [string]::IsNullOrWhiteSpace($script:FabriqBackuperRoot)) {
            $BackuperRoot = $script:FabriqBackuperRoot
        }
    }
    if ([string]::IsNullOrWhiteSpace($BackuperRoot)) { return $null }
    return (Join-Path $BackuperRoot 'data\extended_hostlist.csv')
}

function Get-ExtendedHostlistRows {
    # Raw read of ALL extended rows (NO Enabled / credential / decrypt filtering).
    # Used both for the strict host-set gate AND per-host lookup; UncPassword stays
    # as raw ENC: so Connect-* decrypts on demand. Returns @() when the file is
    # absent/unreadable. Rows with an empty OldPCname are dropped (with a skip log).
    param([string]$Path = $null)
    if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Get-ExtendedHostlistPath }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return @()
    }
    $rows = $null
    try {
        # Raw Import-Csv (NOT Import-ModuleCsv) so ENC: values stay encrypted
        # here; -Encoding UTF8 reads the UTF-8 BOM file unambiguously under PS5.1.
        $rows = @(Import-Csv -Path $Path -Encoding UTF8)
    } catch {
        Show-Warning "Extended hostlist read failed: $($_.Exception.Message)"
        return @()
    }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in $rows) {
        $old = if ($r.PSObject.Properties.Name -contains 'OldPCname') { "$($r.OldPCname)".Trim() } else { '' }
        if ([string]::IsNullOrWhiteSpace($old)) {
            Show-Skip "Extended hostlist: a row with empty OldPCname was skipped."
            continue
        }
        [void]$out.Add($r)
    }
    return @($out.ToArray())
}

function Get-NormalizedHostKey {
    # Build the normalized reconciliation key from a row: trim both names and
    # lower-case (Windows computer names are case-insensitive). Empty NewPCname
    # is preserved as empty so empty==empty is the only empty match.
    param([Parameter(Mandatory)]$Row)
    $old = if ($Row.PSObject.Properties.Name -contains 'OldPCname') { "$($Row.OldPCname)".Trim() } else { '' }
    $new = if ($Row.PSObject.Properties.Name -contains 'NewPCname') { "$($Row.NewPCname)".Trim() } else { '' }
    return ($old + '|' + $new).ToLowerInvariant()
}

function Test-ExtendedHostlistGate {
    # STRICT whole-list gate (t-0011): returns a result whose .Match is $true ONLY
    # when the extended (OldPCname,NewPCname) host set EXACTLY equals the Fabriq
    # host set (both directions). Fabriq = absolute source of truth, so ANY
    # discrepancy -- an extended host not in Fabriq (orphan/stale/forged) OR a
    # Fabriq host not covered by the extended list -- fails the gate and the WHOLE
    # extended list must be ignored. Credentials and Enabled do NOT affect the gate
    # (host-name-only / empty-credential / disabled rows still count toward the set
    # by their OldPCname|NewPCname pair). Pure (side-effect-free) so it is testable.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()]$FabriqHosts,
        [Parameter(Mandatory)][AllowEmptyCollection()]$ExtendedRows
    )
    $fset = @{}
    foreach ($h in @($FabriqHosts)) {
        $o = if ($h.PSObject.Properties.Name -contains 'OldPCname') { "$($h.OldPCname)".Trim() } else { '' }
        if ([string]::IsNullOrEmpty($o)) { continue }
        $fset[(Get-NormalizedHostKey -Row $h)] = $true
    }
    $eset = @{}
    foreach ($r in @($ExtendedRows)) {
        $o = if ($r.PSObject.Properties.Name -contains 'OldPCname') { "$($r.OldPCname)".Trim() } else { '' }
        if ([string]::IsNullOrEmpty($o)) { continue }
        $eset[(Get-NormalizedHostKey -Row $r)] = $true
    }
    $extOnly = @($eset.Keys | Where-Object { -not $fset.ContainsKey($_) })
    $fabOnly = @($fset.Keys | Where-Object { -not $eset.ContainsKey($_) })
    return [pscustomobject]@{
        Match    = ($extOnly.Count -eq 0 -and $fabOnly.Count -eq 0)
        ExtOnly  = $extOnly
        FabOnly  = $fabOnly
        FabCount = $fset.Count
        ExtCount = $eset.Count
    }
}

function Get-ExtendedHostEntry {
    # Return the extended row to USE for the given Fabriq host, or $null.
    #
    # STRICT GATE: the extended list is adopted ONLY when its (OldPCname,NewPCname)
    # host set EXACTLY equals the Fabriq host set ($script:Hostlist = absolute
    # truth). ANY discrepancy -> the WHOLE extended list is ignored (every host
    # uses the manual dialog). A one-time session summary reports the outcome.
    # When adopted, returns the matching ENABLED row for this host (disabled or
    # absent -> $null = manual). Credentials are validated later in Connect-*.
    param([Parameter(Mandatory)]$FabriqHost)
    if ($null -eq $FabriqHost) { return $null }
    $fabriq = if ($null -ne $script:Hostlist) { @($script:Hostlist) } else { @() }
    if ($fabriq.Count -eq 0) { return $null }
    $rows = Get-ExtendedHostlistRows
    if ($rows.Count -eq 0) { return $null }
    $gate = Test-ExtendedHostlistGate -FabriqHosts $fabriq -ExtendedRows $rows
    if (-not $script:ExtHostlistSummaryShown) {
        if ($gate.Match) {
            Show-Info ("Extended hostlist: host set matches fabriq exactly ({0} host(s)) -> ADOPTED." -f $gate.ExtCount)
        }
        else {
            Show-Warning ("Extended hostlist: host set does NOT match fabriq (extended-only={0}, fabriq-only={1}) -> ENTIRE LIST IGNORED (all hosts use the manual UNC dialog)." -f `
                $gate.ExtOnly.Count, $gate.FabOnly.Count)
        }
        $script:ExtHostlistSummaryShown = $true
    }
    if (-not $gate.Match) { return $null }   # strict gate failed -> ignore whole list

    $hk = Get-NormalizedHostKey -Row $FabriqHost
    foreach ($r in $rows) {
        if ((Get-NormalizedHostKey -Row $r) -ne $hk) { continue }
        if ($r.PSObject.Properties.Name -contains 'Enabled') {
            $ev = "$($r.Enabled)".Trim()
            if ($ev -eq '0' -or $ev -ieq 'false' -or $ev -ieq 'no') { continue }   # disabled -> manual
        }
        return $r
    }
    return $null
}

function Get-PresetUncUsername {
    # Best preset UNC username for the in-session selected host, used to prefill
    # the FALLBACK Show-UncConnectDialog when silent auto-connect did not run /
    # failed. Prefers the adopted extended-hostlist username over the migration
    # profile username; returns the supplied profile username (or '') otherwise.
    # NOTE: password is intentionally NOT surfaced here (never prefilled into a
    # visible dialog field) -- it is used only for silent connect in the seam.
    param([string]$ProfileUsername = '')
    try {
        if ($null -ne $script:CurrentHost) {
            $entry = Get-ExtendedHostEntry -FabriqHost $script:CurrentHost
            if ($null -ne $entry -and $entry.PSObject.Properties.Name -contains 'UncUsername') {
                $u = "$($entry.UncUsername)".Trim()
                if (-not [string]::IsNullOrWhiteSpace($u)) { return $u }
            }
        }
    } catch { }
    return $ProfileUsername
}

function Connect-UncFromExtendedHostlist {
    # SEAM TARGET (called by Resolve-UncAccess in unc_helper.ps1 BEFORE the manual
    # dialog). Anchors identity on the IN-SESSION selected host
    # ($script:CurrentHost), NOT the UNC server segment of $Path (which is an IP,
    # unreliable to reverse-map). On a matched, adopted, fully-credentialled host
    # it decrypts the password ON DEMAND, maps the share via New-PSDrive, and
    # probes reachability. Returns $true ONLY on success; $false on any miss so
    # the caller falls through to Show-UncConnectDialog (zero behaviour change).
    param([Parameter(Mandatory)][string]$Path)
    try {
        if ([string]::IsNullOrWhiteSpace($global:FabriqMasterPassphrase)) { return $false }
        if ($null -eq $script:CurrentHost) { return $false }

        $entry = Get-ExtendedHostEntry -FabriqHost $script:CurrentHost
        if ($null -eq $entry) { return $false }

        $user  = if ($entry.PSObject.Properties.Name -contains 'UncUsername') { "$($entry.UncUsername)".Trim() } else { '' }
        $encPw = if ($entry.PSObject.Properties.Name -contains 'UncPassword') { "$($entry.UncPassword)" } else { '' }
        if ([string]::IsNullOrWhiteSpace($user) -or [string]::IsNullOrWhiteSpace($encPw) -or -not $encPw.StartsWith('ENC:')) {
            return $false
        }

        # Decrypt on demand; never cache the plaintext.
        $plainPw = Unprotect-FabriqValue -EncryptedValue $encPw -Passphrase $global:FabriqMasterPassphrase
        if ([string]::IsNullOrEmpty($plainPw)) { return $false }
        $secPw = ConvertTo-SecureString $plainPw -AsPlainText -Force
        $cred  = New-Object System.Management.Automation.PSCredential ($user, $secPw)
        $plainPw = $null

        # Share root from the requested path (same regex as unc_connect_dialog.ps1).
        $shareRoot = if ($Path -match '^(\\\\[^\\]+\\[^\\]+)') { $Matches[1] } else { $Path }
        $driveName = "FabriqBU$([System.Diagnostics.Process]::GetCurrentProcess().Id)"
        if (Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue) {
            Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue
        }
        $null = New-PSDrive -Name $driveName -PSProvider FileSystem -Root $shareRoot `
            -Credential $cred -Scope Global -ErrorAction Stop

        if (Test-Path -LiteralPath $Path) {
            Show-Info "Extended hostlist: auto-connected $shareRoot as $user."
            return $true
        }
        return $false
    } catch {
        return $false
    }
}
