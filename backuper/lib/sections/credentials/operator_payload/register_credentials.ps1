# ============================================================
# Fabriq BackUper - 資格情報 復元ヘルパ (operator-facing)
#
# 同フォルダの credentials_list.csv を読み込み、Windows 資格情報
# マネージャに各エントリを再登録します。パスワードはエントリ
# ごとに operator が対話入力します (Read-Host -AsSecureString)。
#
# RestoreHint='manual' のエントリ (トークン系 Generic / 証明書系 /
# blob 長 0 など、パスワード再入力では復元できないもの) はデフォ
# ルトでスキップされます。
#
# 「登録.bat」をダブルクリックして起動するのが推奨です (PS1 の
# ExecutionPolicy / コンソール codepage / 終了時の pause を
# bat 側で面倒見ます)。
#
# このスクリプトは管理者権限を **必要としません**。現在の
# ユーザの資格情報マネージャに書き込みます。
# ============================================================

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------
# P/Invoke - CredRead / CredWrite
# ----------------------------------------------------------
Add-Type -Namespace FabriqBackUperRestore -Name CredApi -MemberDefinition @"
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct CREDENTIAL {
    public UInt32 Flags;
    public UInt32 Type;
    [MarshalAs(UnmanagedType.LPWStr)] public string TargetName;
    [MarshalAs(UnmanagedType.LPWStr)] public string Comment;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
    public UInt32 CredentialBlobSize;
    public IntPtr CredentialBlob;
    public UInt32 Persist;
    public UInt32 AttributeCount;
    public IntPtr Attributes;
    [MarshalAs(UnmanagedType.LPWStr)] public string TargetAlias;
    [MarshalAs(UnmanagedType.LPWStr)] public string UserName;
}

[DllImport("Advapi32.dll", SetLastError = true, EntryPoint = "CredReadW", CharSet = CharSet.Unicode)]
public static extern bool CredRead(string targetName, UInt32 type, UInt32 flags, out IntPtr credentialPtr);

[DllImport("Advapi32.dll", SetLastError = true, EntryPoint = "CredWriteW", CharSet = CharSet.Unicode)]
public static extern bool CredWrite([In] ref CREDENTIAL credential, UInt32 flags);

[DllImport("Advapi32.dll", SetLastError = false)]
public static extern void CredFree(IntPtr cred);
"@ -ErrorAction Stop

function _TypeCode([string]$Name) {
    switch ($Name) {
        'Generic'                { 1 }
        'DomainPassword'         { 2 }
        'DomainCertificate'      { 3 }
        'DomainVisiblePassword'  { 4 }
        'GenericCertificate'     { 5 }
        'DomainExtended'         { 6 }
        default { 0 }
    }
}

function _PersistCode([string]$Name) {
    switch ($Name) {
        'Session'      { 1 }
        'LocalMachine' { 2 }
        'Enterprise'   { 3 }
        default { 2 }
    }
}

function Test-CredentialExists {
    param([string]$TargetName, [uint32]$Type)
    $ptr = [IntPtr]::Zero
    $ok = [FabriqBackUperRestore.CredApi]::CredRead($TargetName, $Type, 0, [ref]$ptr)
    if ($ok -and $ptr -ne [IntPtr]::Zero) {
        [FabriqBackUperRestore.CredApi]::CredFree($ptr)
        return $true
    }
    return $false
}

function Write-CredentialFromSecure {
    param(
        [string]$TargetName,
        [string]$UserName,
        [uint32]$Type,
        [uint32]$Persist,
        [string]$Comment,
        [SecureString]$Password
    )

    # Convert SecureString to UTF-16LE bytes (no null terminator)
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    $blobPtr = [IntPtr]::Zero
    try {
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $blobBytes = [System.Text.Encoding]::Unicode.GetBytes($plain)
        $blobSize  = [uint32]$blobBytes.Length

        if ($blobSize -gt 0) {
            $blobPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal([int]$blobSize)
            [System.Runtime.InteropServices.Marshal]::Copy($blobBytes, 0, $blobPtr, [int]$blobSize)
        }

        $cred = New-Object FabriqBackUperRestore.CredApi+CREDENTIAL
        $cred.Flags              = 0
        $cred.Type               = $Type
        $cred.TargetName         = $TargetName
        $cred.Comment            = $Comment
        $cred.CredentialBlobSize = $blobSize
        $cred.CredentialBlob     = $blobPtr
        $cred.Persist            = $Persist
        $cred.AttributeCount     = 0
        $cred.Attributes         = [IntPtr]::Zero
        $cred.TargetAlias        = $null
        $cred.UserName           = $UserName

        $ok = [FabriqBackUperRestore.CredApi]::CredWrite([ref]$cred, 0)
        if (-not $ok) {
            $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "CredWrite failed: Win32Error=$err"
        }
    } finally {
        # Zero and free plaintext / BSTR
        if ($blobPtr -ne [IntPtr]::Zero) {
            # Best-effort zero before free
            $zeroSize = [int][uint32]$blobBytes.Length
            if ($zeroSize -gt 0) {
                $zero = New-Object byte[] $zeroSize
                [System.Runtime.InteropServices.Marshal]::Copy($zero, 0, $blobPtr, $zeroSize)
            }
            [System.Runtime.InteropServices.Marshal]::FreeHGlobal($blobPtr)
        }
        if ($null -ne $blobBytes) {
            for ($i = 0; $i -lt $blobBytes.Length; $i++) { $blobBytes[$i] = 0 }
        }
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

# ----------------------------------------------------------
# Locate CSV (same directory as this script)
# ----------------------------------------------------------
$scriptDir = $PSScriptRoot
$csvPath = Join-Path $scriptDir 'credentials_list.csv'

if (-not (Test-Path $csvPath)) {
    Write-Host ('credentials_list.csv が見つかりません: {0}' -f $csvPath) -ForegroundColor Red
    exit 1
}

$rows = @(Import-Csv -Path $csvPath -Encoding UTF8)

Write-Host ('=' * 64) -ForegroundColor Cyan
Write-Host '資格情報の復元 (Fabriq BackUper)'
Write-Host ('=' * 64) -ForegroundColor Cyan
Write-Host ('対象 CSV : {0}' -f $csvPath)
Write-Host ('行数     : {0}' -f $rows.Count)
Write-Host ('実行ユーザ: {0}\{1}' -f $env:USERDOMAIN, $env:USERNAME)
Write-Host ''

if ($rows.Count -eq 0) {
    Write-Host '登録対象がありません。' -ForegroundColor Yellow
    exit 0
}

# ----------------------------------------------------------
# Iterate rows
# ----------------------------------------------------------
$total       = $rows.Count
$successCnt  = 0
$skipManual  = 0
$skipExist   = 0
$skipUser    = 0
$failCnt     = 0
$idx         = 0

foreach ($row in $rows) {
    $idx++
    Write-Host ('-' * 64)
    Write-Host ('[{0}/{1}]' -f $idx, $total)
    Write-Host ('  Target   : {0}' -f $row.Target)
    Write-Host ('  Type     : {0}' -f $row.Type)
    Write-Host ('  UserName : {0}' -f $row.UserName)
    Write-Host ('  Persist  : {0}' -f $row.Persist)
    if (-not [string]::IsNullOrWhiteSpace($row.Comment)) {
        Write-Host ('  Comment  : {0}' -f $row.Comment)
    }
    Write-Host ('  Hint     : {0} (BlobSize={1})' -f $row.RestoreHint, $row.BlobSize)

    # Manual hint - default skip
    if ($row.RestoreHint -eq 'manual') {
        Write-Host '  ※ このエントリはトークン系 / 証明書系 / blob 長 0 のため、パスワード' -ForegroundColor Yellow
        Write-Host '     再入力では復元できないと判定されています (RestoreHint=manual)。' -ForegroundColor Yellow
        $ans = Read-Host '  それでも再登録を試みますか? [y/N]'
        if ($ans -notmatch '^[yY]') {
            Write-Host '  スキップしました。' -ForegroundColor DarkGray
            $skipManual++
            continue
        }
    }

    # Resolve type code
    $typeCode = _TypeCode $row.Type
    if ($typeCode -eq 0) {
        Write-Host ('  ! 未知の Type "{0}" — スキップします。' -f $row.Type) -ForegroundColor Red
        $failCnt++
        continue
    }

    # Existing collision check
    $exists = $false
    try { $exists = Test-CredentialExists -TargetName $row.Target -Type $typeCode } catch {
        Write-Host ('  ! 既存確認に失敗: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
    }
    if ($exists) {
        Write-Host '  ★ 同じ Target/Type の資格情報が既に登録されています。' -ForegroundColor Yellow
        $ans = Read-Host '  上書きしますか? [y/N]'
        if ($ans -notmatch '^[yY]') {
            Write-Host '  スキップしました。' -ForegroundColor DarkGray
            $skipExist++
            continue
        }
    }

    # Prompt for password
    Write-Host '  パスワードを入力してください (空 Enter でスキップ):' -NoNewline
    $secure = Read-Host -AsSecureString ' '
    if ($null -eq $secure -or $secure.Length -eq 0) {
        Write-Host '  パスワード未入力 — スキップしました。' -ForegroundColor DarkGray
        $skipUser++
        continue
    }

    # Write
    try {
        Write-CredentialFromSecure `
            -TargetName $row.Target `
            -UserName   $row.UserName `
            -Type       $typeCode `
            -Persist    (_PersistCode $row.Persist) `
            -Comment    $row.Comment `
            -Password   $secure
        Write-Host '  ✓ 登録しました。' -ForegroundColor Green
        $successCnt++
    } catch {
        Write-Host ('  ! 登録失敗: {0}' -f $_.Exception.Message) -ForegroundColor Red
        $failCnt++
    }
}

# ----------------------------------------------------------
# Summary
# ----------------------------------------------------------
Write-Host ''
Write-Host ('=' * 64) -ForegroundColor Cyan
Write-Host '完了'
Write-Host ('=' * 64) -ForegroundColor Cyan
Write-Host ('  対象             : {0} 件' -f $total)
Write-Host ('  登録成功         : {0} 件' -f $successCnt) -ForegroundColor Green
Write-Host ('  スキップ (manual): {0} 件' -f $skipManual) -ForegroundColor DarkGray
Write-Host ('  スキップ (既存)  : {0} 件' -f $skipExist) -ForegroundColor DarkGray
Write-Host ('  スキップ (未入力): {0} 件' -f $skipUser) -ForegroundColor DarkGray
Write-Host ('  失敗             : {0} 件' -f $failCnt) -ForegroundColor $(if ($failCnt -gt 0) { 'Red' } else { 'Gray' })
Write-Host ''
Write-Host '登録された資格情報は "cmdkey /list" または "コントロール パネル → 資格情報マネージャ" で確認できます。'

if ($failCnt -gt 0) { exit 2 }
exit 0
