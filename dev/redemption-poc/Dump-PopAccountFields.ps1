# ============================================================
# dev/redemption-poc : Dump-PopAccountFields.ps1   (EXPERIMENT / RE oracle)
#
# Hobby RE step (b): harvest the EXACT account-manager property tags that
# Outlook for Microsoft 365 (64-bit) persists for a POP3 account, using
# Redemption as an oracle (RDOAccount.Fields[propTag] reads the raw tag).
#
# This converts the published/cross-validated tag list (PROP_INET_* /
# PROP_SMTP_* / PROP_ACCT_*) into ground-truth OBSERVED on the actual
# target build -- the reference your native (no-Redemption) SetProp code
# must reproduce, and the pass/fail oracle for the eventual native account.
#
# 365 is 64-bit here, so this runs in 64-bit PowerShell and uses
# Redemption64.dll (the no-reg loader picks the DLL by process bitness).
# Self-relaunches in 64-bit PowerShell if started 32-bit.
#
# Reads the tags off EXISTING POP3 accounts in the profile. If there are
# none, create one first with Test-CreatePopViaRedemption.ps1.
# NOT wired into backuper/. Read-only probe (no account changes).
# ============================================================
[CmdletBinding()]
param(
    [string]$RedemptionRoot = 'E:\Redemption_test',
    [string]$ProfileName    = ''
)
$ErrorActionPreference = 'Stop'
Write-Host "[Dump-PopAccountFields] revision 2026-05-30a (RE oracle: dump POP3 account tags)"

# ---------- 0. ensure 64-bit (match 64-bit Outlook 365) ----------
if ([IntPtr]::Size -eq 4) {
    $ps64 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'   # System32 = native 64-bit
    if (-not (Test-Path $ps64)) { throw "64-bit PowerShell not found at $ps64" }
    Write-Host "[relaunch] started 32-bit; re-launching in 64-bit PowerShell to match 64-bit Outlook 365..."
    $fwd = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $PSCommandPath)
    foreach ($k in $PSBoundParameters.Keys) { $fwd += "-$k"; $fwd += [string]$PSBoundParameters[$k] }
    & $ps64 @fwd
    exit $LASTEXITCODE
}
Write-Host "[env] PowerShell bitness: 64-bit (IntPtr.Size=$([IntPtr]::Size))  -- matches 64-bit Outlook 365"

# ---------- 1. load Redemption (no registry) ----------
$redDll32 = Join-Path $RedemptionRoot 'Redemption\Redemption.dll'
$redDll64 = Join-Path $RedemptionRoot 'Redemption\Redemption64.dll'
$interop  = Join-Path $RedemptionRoot 'Redemption\Interop.Redemption.dll'
$loaderCs = Join-Path $RedemptionRoot 'RedemptionLoader\C#\RedemptionLoader.cs'
foreach ($f in @($redDll64,$interop,$loaderCs)) { if (-not (Test-Path -LiteralPath $f)) { throw "missing Redemption file: $f" } }
foreach ($f in @($redDll32,$redDll64,$interop)) { try { Unblock-File -LiteralPath $f -ErrorAction SilentlyContinue } catch {} }
Add-Type -Path $interop
Add-Type -TypeDefinition (Get-Content -LiteralPath $loaderCs -Raw) -ReferencedAssemblies $interop -Language CSharp
[Redemption.RedemptionLoader]::DllLocation32Bit = $redDll32
[Redemption.RedemptionLoader]::DllLocation64Bit = $redDll64
$session = [Redemption.RedemptionLoader]::new_RDOSession()
Write-Host "[redemption] RDOSession created (no-reg, 64-bit)."

# ---------- 2. logon ----------
$miss = [System.Reflection.Missing]::Value
$prof = if ([string]::IsNullOrWhiteSpace($ProfileName)) { $miss } else { $ProfileName }
$session.Logon($prof, $miss, $true, $false, $miss, $true)   # ShowDialog=true so MAPI can pick/prompt the profile
Write-Host "[logon] OK. Accounts in profile: $($session.Accounts.Count)"

# ---------- 3. candidate tags (from research; PROP_TAG = (id<<16)|PT_type) ----------
$U=0x001F; $L=0x0003; $B=0x0102   # PT_UNICODE / PT_LONG / PT_BINARY
$tags = [ordered]@{
    'PROP_ACCT_ID                (0x00010003)' = 0x00010003
    'PROP_ACCT_NAME              (0x0002001F)' = 0x0002001F
    'PROP_ACCT_USER_DISPLAY_NAME (0x000B001F)' = 0x000B001F
    'PROP_ACCT_USER_EMAIL_ADDR   (0x000C001F)' = 0x000C001F
    'PROP_ACCT_STAMP             (0x000D001F)' = 0x000D001F
    'PROP_ACCT_SEND_STAMP        (0x000E001F)' = 0x000E001F
    'PROP_ACCT_DELIVERY_STORE    (0x00180102)' = 0x00180102
    'PROP_ACCT_DELIVERY_FOLDER   (0x00190102)' = 0x00190102
    'PROP_INET_SERVER  POP3 host (0x0100001F)' = 0x0100001F
    'PROP_INET_USER    POP3 user (0x0101001F)' = 0x0101001F
    'PROP_INET_PORT    POP3 port (0x01040003)' = 0x01040003
    'PROP_INET_SSL     POP3 ssl  (0x01050003)' = 0x01050003
    'PROP_INET_USE_SPA POP3 spa  (0x01080003)' = 0x01080003
    'PROP_POP_LEAVE_ON_SERVER    (0x10000003)' = 0x10000003
    'PROP_SMTP_SERVER            (0x0200001F)' = 0x0200001F
    'PROP_SMTP_PORT              (0x02010003)' = 0x02010003
    'PROP_SMTP_SSL legacy        (0x02020003)' = 0x02020003
    'PROP_SMTP_USE_AUTH          (0x02030003)' = 0x02030003
    'PROP_SMTP_USER              (0x0204001F)' = 0x0204001F
    'PROP_SMTP_USE_SPA           (0x02070003)' = 0x02070003
    'PROP_SMTP_AUTH_METHOD       (0x02080003)' = 0x02080003
    'PROP_SMTP_SECURE_CONNECTION (0x020A0003)' = 0x020A0003
}
# password tags are intentionally NOT read (Redemption blocks reading them)

function Format-Val($v) {
    if ($null -eq $v) { return '(null/not set)' }
    if ($v -is [byte[]]) { return ('hex[' + $v.Length + ']=' + (($v | ForEach-Object { '{0:x2}' -f $_ }) -join '')) }
    return "$v"
}

# ---------- 4. dump tags for each POP3 account ----------
$popCount = 0
foreach ($acct in $session.Accounts) {
    $atype = "$($acct.AccountType)"   # rdoAccountType: atPOP3=0
    $isPop = ($atype -eq 'atPOP3' -or $atype -eq '0')
    Write-Host ("`n==== Account: " + $acct.Name + "   type=" + $atype + (if($isPop){'  [POP3]'}else{''})) -ForegroundColor Cyan
    if (-not $isPop) { Write-Host "   (skipping non-POP3 account)"; continue }
    $popCount++
    foreach ($t in $tags.GetEnumerator()) {
        $val = $null; $err = $null
        try { $val = $acct.Fields($t.Value) } catch { $err = $_.Exception.Message }
        if ($null -ne $err) { Write-Host ("   {0} : (error: {1})" -f $t.Key, $err) }
        else                { Write-Host ("   {0} : {1}" -f $t.Key, (Format-Val $val)) }
    }
}
$session.Logoff()
Write-Host ""
if ($popCount -eq 0) {
    Write-Host "No POP3 accounts found. Create one first via Test-CreatePopViaRedemption.ps1, then re-run." -ForegroundColor Yellow
} else {
    Write-Host "Dumped $popCount POP3 account(s). These are the GROUND-TRUTH tags your native SetProp must reproduce."
}
