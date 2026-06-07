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

function Get-ExtendedHostlist {
    # Raw read (NO decryption): returns the ENABLED rows with UncPassword left as
    # raw ENC: ciphertext so Connect-* can decrypt on demand. Visual + username
    # fields are plaintext. Returns @() when the file is absent or unreadable.
    #
    # Load guard (mirrors the migration_profile no-plaintext-password rule):
    # a row whose UncPassword is set but NOT ENC:-prefixed is WARNED + ignored,
    # so a plaintext password can never silently sit in the file.
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
        # Enabled filter (default include when the column is absent/blank).
        if ($r.PSObject.Properties.Name -contains 'Enabled') {
            $ev = "$($r.Enabled)".Trim()
            if ($ev -eq '0' -or $ev -ieq 'false' -or $ev -ieq 'no') { continue }
        }
        $old = if ($r.PSObject.Properties.Name -contains 'OldPCname') { "$($r.OldPCname)".Trim() } else { '' }
        if ([string]::IsNullOrWhiteSpace($old)) {
            Show-Skip "Extended hostlist: a row with empty OldPCname was skipped."
            continue
        }
        $pw = if ($r.PSObject.Properties.Name -contains 'UncPassword') { "$($r.UncPassword)" } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($pw) -and -not $pw.StartsWith('ENC:')) {
            Show-Warning "Extended hostlist: UncPassword for '$old' is not ENC:-encrypted; row ignored (plaintext passwords are not allowed)."
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

function Resolve-ExtendedHostlistMatch {
    # PURE reconciler: returns ONLY the extended rows ADOPTED against the Fabriq
    # hostlist (absolute source of truth). Adoption = exactly one Fabriq row with
    # an identical normalized (OldPCname, NewPCname) key. Side-effect-free except
    # for warnings on ambiguous/duplicate keys.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()]$FabriqHosts,
        [Parameter(Mandatory)][AllowEmptyCollection()]$ExtendedRows
    )
    $fabriqKeys = @{}
    foreach ($h in @($FabriqHosts)) {
        $o = if ($h.PSObject.Properties.Name -contains 'OldPCname') { "$($h.OldPCname)".Trim() } else { '' }
        if ([string]::IsNullOrEmpty($o)) { continue }
        $key = Get-NormalizedHostKey -Row $h
        if ($fabriqKeys.ContainsKey($key)) { $fabriqKeys[$key]++ } else { $fabriqKeys[$key] = 1 }
    }
    $adopted = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($r in @($ExtendedRows)) {
        $o = if ($r.PSObject.Properties.Name -contains 'OldPCname') { "$($r.OldPCname)".Trim() } else { '' }
        if ([string]::IsNullOrEmpty($o)) { continue }
        $key = Get-NormalizedHostKey -Row $r
        if (-not $fabriqKeys.ContainsKey($key)) { continue }          # no fabriq match -> ignore
        if ($fabriqKeys[$key] -gt 1) {
            Show-Warning "Extended hostlist: fabriq has a duplicate ($o) pair; row not adopted (ambiguous)."
            continue
        }
        if ($seen.ContainsKey($key)) {
            Show-Warning "Extended hostlist: duplicate extended row for ($o); first wins."
            continue
        }
        $seen[$key] = $true
        [void]$adopted.Add($r)
    }
    return @($adopted.ToArray())
}

function Get-ExtendedHostEntry {
    # Return the ADOPTED extended row whose (OldPCname, NewPCname) exactly matches
    # the given Fabriq host, or $null. Reconciles the extended file against the
    # loaded Fabriq hostlist ($script:Hostlist = absolute truth). Emits a one-time
    # session summary so reconciliation results (incl. ignored typo rows) are
    # visible without per-row noise.
    param([Parameter(Mandatory)]$FabriqHost)
    if ($null -eq $FabriqHost) { return $null }
    $fabriq = if ($null -ne $script:Hostlist) { @($script:Hostlist) } else { @() }
    if ($fabriq.Count -eq 0) { return $null }
    $ext = Get-ExtendedHostlist
    if ($ext.Count -eq 0) { return $null }
    $adopted = @(Resolve-ExtendedHostlistMatch -FabriqHosts $fabriq -ExtendedRows $ext)
    if (-not $script:ExtHostlistSummaryShown) {
        Show-Info ("Extended hostlist: {0} row(s), {1} adopted, {2} ignored (no fabriq match)." -f `
            $ext.Count, $adopted.Count, ($ext.Count - $adopted.Count))
        $script:ExtHostlistSummaryShown = $true
    }
    $hk = Get-NormalizedHostKey -Row $FabriqHost
    foreach ($r in $adopted) {
        if ((Get-NormalizedHostKey -Row $r) -eq $hk) { return $r }
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
