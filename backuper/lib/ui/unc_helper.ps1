# ============================================================
# FabriqBackUper - UNC Path Helper (Phase 2.4)
# Test reachability of a UNC path, prompt for credentials via
# Get-Credential (Windows-standard) and map via New-PSDrive when
# the destination requires authentication.
# ============================================================

function Test-UncPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not $Path.StartsWith('\\')) { return $true }   # not UNC, treat as reachable here
    try {
        $null = Get-Item -Path $Path -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Connect-UncWithCredentials {
    # Pop a Windows-standard credential dialog and map the share via
    # New-PSDrive with -Credential. Returns $true on success, $false otherwise.
    param([Parameter(Mandatory = $true)][string]$UncPath)

    # Extract \\server\share for the credential target
    $shareRoot = if ($UncPath -match '^(\\\\[^\\]+\\[^\\]+)') { $Matches[1] } else { $UncPath }

    $cred = Get-Credential -Message "$shareRoot への認証情報を入力してください"
    if ($null -eq $cred) { return $false }

    # Unique PSDrive name (avoid collision with prior mappings)
    $driveName = "FabriqBU$([System.Diagnostics.Process]::GetCurrentProcess().Id)"
    try {
        # If already exists from a previous attempt, remove first
        if (Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue) {
            Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue
        }
        $null = New-PSDrive -Name $driveName -PSProvider FileSystem `
            -Root $shareRoot -Credential $cred -Scope Global -ErrorAction Stop
        return $true
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "${shareRoot} のマウントに失敗しました: $($_.Exception.Message)",
            "Fabriq BackUper",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return $false
    }
}

function Resolve-UncAccess {
    # Probe + optionally prompt for credentials. Returns $true if we end
    # up with a working path, $false if user cancelled or auth failed.
    # ('Resolve' is an approved PowerShell verb.)
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not $Path.StartsWith('\\')) { return $true }   # local path, no UNC concerns
    if (Test-UncPath -Path $Path) { return $true }      # already accessible
    return (Connect-UncWithCredentials -UncPath $Path)
}
