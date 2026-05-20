# ============================================================
# FabriqBackUper - CSV I/O Helpers (Phase 2.7)
# Read / write userdata_list.csv with 1-generation .bak rotation
# before overwrite (destructive-edit safety).
# ============================================================

function Read-UserdataCsv {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path $Path)) { return @() }
    # Use Import-ModuleCsv so ENC: values would be decrypted if present
    # (currently unused for userdata_list.csv but harmless to route through it).
    $rows = Import-ModuleCsv -Path $Path `
        -RequiredColumns @('Enabled','SourcePath','Recurse','ExcludePattern','OnConflict','IncludeAcl')
    if ($null -eq $rows) { return @() }
    return @($rows)
}

function Save-UserdataCsv {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][array]$Entries
    )

    # Rotate previous CSV to .bak (1-generation) before overwriting.
    # Protects operator from accidental data loss when grid state writes
    # back to disk.
    if (Test-Path $Path) {
        $bak = "$Path.bak"
        try { Copy-Item -Path $Path -Destination $bak -Force -ErrorAction Stop } catch { }
    }

    $rowsOut = foreach ($e in $Entries) {
        [PSCustomObject][ordered]@{
            Enabled        = "$($e.Enabled)"
            SourcePath     = "$($e.SourcePath)"
            Recurse        = "$($e.Recurse)"
            ExcludePattern = "$($e.ExcludePattern)"
            OnConflict     = "$($e.OnConflict)"
            IncludeAcl     = "$($e.IncludeAcl)"
            Description    = "$($e.Description)"
        }
    }
    $rowsOut | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8 -Force
}
