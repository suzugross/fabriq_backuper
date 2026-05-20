# ============================================================
# FabriqBackUper - User Profile Selector Helpers (Phase 2.7)
# Enumerate Win32_UserProfile (non-Special), detect the
# logged-on interactive user (which may differ from the
# elevated admin process owner), and produce dropdown-friendly
# objects.
# ============================================================

function Get-LoggedOnInteractiveProfilePath {
    # Resolve-HkcuRoot already detects the logged-on interactive user
    # via internal kernel logic; we ride on the same SID determination
    # to map back to a profile path on the local PC.
    try {
        $hkcuInfo = Resolve-HkcuRoot
        if ($null -ne $hkcuInfo -and $hkcuInfo.Redirected -and -not [string]::IsNullOrWhiteSpace($hkcuInfo.SID)) {
            $prof = Get-CimInstance Win32_UserProfile -Filter "SID='$($hkcuInfo.SID)'" -ErrorAction SilentlyContinue
            if ($null -ne $prof -and -not [string]::IsNullOrWhiteSpace($prof.LocalPath)) {
                return $prof.LocalPath
            }
        }
    } catch { }
    # Not redirected (or detection failed): we are the logged-on user already.
    return $env:USERPROFILE
}

function Get-UserProfileList {
    # Returns an array of objects:
    #   { UserName; ProfilePath; Sid; IsCurrent; IsLoggedOn; Label }
    # Excludes Special / system profiles. Sorted with logged-on user first.
    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $loggedOnPath = Get-LoggedOnInteractiveProfilePath

    $rows = @()
    try {
        $profiles = @(Get-CimInstance Win32_UserProfile -Filter 'Special = false' -ErrorAction Stop)
        foreach ($p in $profiles) {
            if ([string]::IsNullOrWhiteSpace($p.LocalPath)) { continue }
            $userName = Split-Path $p.LocalPath -Leaf
            $isCurrent  = ($p.SID -eq $currentSid)
            $isLoggedOn = (-not [string]::IsNullOrWhiteSpace($loggedOnPath)) -and `
                          ($p.LocalPath -ieq $loggedOnPath)
            $tag = @()
            if ($isLoggedOn) { $tag += 'logged on' }
            if ($isCurrent)  { $tag += 'current process' }
            $label = if ($tag.Count -gt 0) { "$userName  ($($tag -join ', '))" } else { $userName }
            $rows += [PSCustomObject]@{
                UserName    = $userName
                ProfilePath = $p.LocalPath
                Sid         = $p.SID
                IsCurrent   = $isCurrent
                IsLoggedOn  = $isLoggedOn
                Label       = $label
            }
        }
    } catch { }

    # Sort: logged-on first, current process second, others by UserName.
    $sorted = $rows | Sort-Object `
        @{Expression = { -not $_.IsLoggedOn }}, `
        @{Expression = { -not $_.IsCurrent  }}, `
        @{Expression = { $_.UserName }}
    return @($sorted)
}

function Get-DefaultProfileIndex {
    param([array]$List)
    # Preference: IsLoggedOn first, IsCurrent second, else 0.
    for ($i = 0; $i -lt $List.Count; $i++) {
        if ($List[$i].IsLoggedOn) { return $i }
    }
    for ($i = 0; $i -lt $List.Count; $i++) {
        if ($List[$i].IsCurrent) { return $i }
    }
    if ($List.Count -gt 0) { return 0 }
    return -1
}

function ConvertTo-EnvVarPath {
    # Phase 2.8.0: inverse of Expand-PathWithUser. If $AbsolutePath sits
    # under the selected user's profile, rewrite the prefix back into
    # %APPDATA% / %LOCALAPPDATA% / %USERPROFILE% (longest match first)
    # so entries stored in userdata_list.csv stay portable across users
    # and admin-elevation contexts. Returns $AbsolutePath unchanged when
    # no known prefix matches (e.g. a path under D:\ or another user).
    param(
        [Parameter(Mandatory = $true)][string]$AbsolutePath,
        [string]$UserProfilePath = $null
    )
    if ([string]::IsNullOrWhiteSpace($AbsolutePath)) { return $AbsolutePath }
    if ([string]::IsNullOrWhiteSpace($UserProfilePath)) {
        $UserProfilePath = $env:USERPROFILE
    }
    if ([string]::IsNullOrWhiteSpace($UserProfilePath)) { return $AbsolutePath }

    $appdataPath     = (Join-Path $UserProfilePath 'AppData\Roaming').TrimEnd('\','/')
    $localAppdataDir = (Join-Path $UserProfilePath 'AppData\Local').TrimEnd('\','/')
    $profileDir      = $UserProfilePath.TrimEnd('\','/')
    $abs             = $AbsolutePath.TrimEnd('\','/')

    # Longest-prefix-first to avoid converting AppData paths to
    # %USERPROFILE%\AppData\Roaming when %APPDATA% is more idiomatic.
    foreach ($pair in @(
        @{ Prefix = $appdataPath;     Token = '%APPDATA%' },
        @{ Prefix = $localAppdataDir; Token = '%LOCALAPPDATA%' },
        @{ Prefix = $profileDir;      Token = '%USERPROFILE%' }
    )) {
        $prefix = $pair.Prefix
        if ([string]::IsNullOrWhiteSpace($prefix)) { continue }
        if ($abs.Length -lt $prefix.Length) { continue }
        if ($abs.Substring(0, $prefix.Length) -ieq $prefix) {
            # Match: prefix is followed by either nothing or a separator
            # (so "C:\Users\foo_other" doesn't accidentally match "C:\Users\foo").
            if ($abs.Length -eq $prefix.Length) { return $pair.Token }
            $next = $abs[$prefix.Length]
            if ($next -eq '\' -or $next -eq '/') {
                return "$($pair.Token)$($abs.Substring($prefix.Length))"
            }
        }
    }
    return $AbsolutePath
}

function Expand-PathWithUser {
    # Replace user-scoped env vars (%USERPROFILE% / %APPDATA% /
    # %LOCALAPPDATA% / %USERNAME%) with the chosen user's actual paths,
    # then fall through to standard ExpandEnvironmentVariables for any
    # remaining tokens. Case-insensitive replacement.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$UserProfilePath = $null
    )
    if ([string]::IsNullOrWhiteSpace($UserProfilePath)) {
        return [Environment]::ExpandEnvironmentVariables($Path)
    }
    $userName = Split-Path $UserProfilePath -Leaf
    $appdata  = Join-Path $UserProfilePath 'AppData\Roaming'
    $localApp = Join-Path $UserProfilePath 'AppData\Local'

    # Use case-insensitive regex replacement
    $p = $Path
    $p = [regex]::Replace($p, '%USERPROFILE%',  $UserProfilePath, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $p = [regex]::Replace($p, '%APPDATA%',      $appdata,         [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $p = [regex]::Replace($p, '%LOCALAPPDATA%', $localApp,        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $p = [regex]::Replace($p, '%USERNAME%',     $userName,        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    return [Environment]::ExpandEnvironmentVariables($p)
}
