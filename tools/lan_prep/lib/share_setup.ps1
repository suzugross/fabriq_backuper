# ============================================================
# Fabriq LAN-Prep - SMB share helpers
# ============================================================

function New-MigrationShare {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$ShareConfig)

    $shareName = $ShareConfig.shareName
    $localPath = $ShareConfig.localPath

    if (-not (Test-Path -LiteralPath $localPath)) {
        New-Item -ItemType Directory -Path $localPath -Force | Out-Null
        Write-Host "[ok] created local path: $localPath" -ForegroundColor Green
    }

    # Build SMB access argument bag from the smbPermissions array.
    $fullList   = @()
    $changeList = @()
    $readList   = @()
    foreach ($ace in $ShareConfig.smbPermissions) {
        switch ($ace.access) {
            'Full'   { $fullList   += $ace.principal }
            'Change' { $changeList += $ace.principal }
            'Read'   { $readList   += $ace.principal }
            default  { Write-Host "[warn] unknown SMB access level '$($ace.access)' for $($ace.principal), skipping." -ForegroundColor Yellow }
        }
    }
    $smbParams = @{ Name = $shareName; Path = $localPath }
    if ($fullList.Count   -gt 0) { $smbParams['FullAccess']   = $fullList }
    if ($changeList.Count -gt 0) { $smbParams['ChangeAccess'] = $changeList }
    if ($readList.Count   -gt 0) { $smbParams['ReadAccess']   = $readList }

    $existing = Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.Path -ieq $localPath) {
            Write-Host "[skip] share '$shareName' already exists with same path" -ForegroundColor DarkGray
        }
        else {
            Write-Host "[warn] share '$shareName' exists but points to '$($existing.Path)'." -ForegroundColor Yellow
            Write-Host "       removing and recreating with new path '$localPath'..." -ForegroundColor Yellow
            Remove-SmbShare -Name $shareName -Force -ErrorAction Stop
            New-SmbShare @smbParams -ErrorAction Stop | Out-Null
        }
    }
    else {
        New-SmbShare @smbParams -ErrorAction Stop | Out-Null
    }

    # NTFS permissions.
    foreach ($ace in $ShareConfig.ntfsPermissions) {
        try {
            $acl = Get-Acl -Path $localPath
            $rights = switch ($ace.access) {
                'Full'   { 'FullControl' }
                'Modify' { 'Modify' }
                'Read'   { 'ReadAndExecute' }
                default  { 'Modify' }
            }
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $ace.principal,
                $rights,
                'ContainerInherit, ObjectInherit',
                'None',
                'Allow'
            )
            $acl.AddAccessRule($rule)
            Set-Acl -Path $localPath -AclObject $acl
            Write-Host "[ok] NTFS: $($ace.principal):$($ace.access) on $localPath" -ForegroundColor Green
        }
        catch {
            Write-Host "[warn] NTFS ACL grant failed for $($ace.principal): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

function Remove-MigrationShare {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ShareName)

    $existing = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
    if ($existing) {
        Remove-SmbShare -Name $ShareName -Force -ErrorAction Stop
        Write-Host "[ok] removed share: $ShareName" -ForegroundColor Green
    }
    else {
        Write-Host "[skip] share '$ShareName' not found" -ForegroundColor DarkGray
    }
}
