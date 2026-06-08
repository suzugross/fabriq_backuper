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
    # v0.63.0: retained as a standalone/legacy helper. The default in-flow
    # path now uses the app-styled Show-UncConnectDialog (see Resolve-UncAccess)
    # so the operator gets path/username prefill instead of a bare Get-Credential.
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
    #
    # v0.63.0: the standalone "UNC 接続" button was removed; UNC credential
    # entry is now unified into the backup/restore flow. When a UNC path is
    # not reachable we pop the app-styled Show-UncConnectDialog (prefilled
    # with the known path + optional username) so the operator only types the
    # password -- replacing BOTH the old Get-Credential prompt and the
    # explicit connect button in a single in-flow step.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        # Optional username preset. Today this comes from
        # migration_profile.backuper.uncUsername; in future it can be
        # resolved from the per-satellite extended hostlist (see seam below).
        # Lets the dialog jump straight to the password field.
        [string]$PresetUsername = ""
    )
    if (-not $Path.StartsWith('\\')) { return $true }   # local path, no UNC concerns

    # v0.67.0 (t-0014): the silent probe + extended-hostlist auto-connect below
    # involve NO operator interaction but can stall on a slow/unreachable share.
    # Show a "読み込み中..." overlay around them so it does not look like a hang,
    # and CLOSE it before the operator-facing Show-UncConnectDialog.
    $busy = Show-BusyOverlay
    try {
        if (Test-UncPath -Path $Path) { return $true }      # already accessible

        # --- 拡張HOSTLIST seam ------------------------------------------------
        # The per-satellite extended hostlist (t-0011) may store connection
        # credentials keyed by PC name, so the operator never types them. If the
        # resolver function is defined, try it SILENTLY here BEFORE prompting.
        $extResolver = Get-Command -Name Connect-UncFromExtendedHostlist -ErrorAction SilentlyContinue
        if ($extResolver -and (& $extResolver -Path $Path)) { return $true }
        # ----------------------------------------------------------------------
    }
    finally {
        Close-BusyOverlay $busy
    }

    # In-flow interactive prompt (app-styled, prefilled with the known path +
    # optional username). Returns the connected path on success or $null.
    $connected = Show-UncConnectDialog -InitialPath $Path -InitialUsername $PresetUsername
    return (-not [string]::IsNullOrWhiteSpace($connected))
}
