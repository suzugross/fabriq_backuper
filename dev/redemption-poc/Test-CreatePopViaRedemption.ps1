# ============================================================
# dev/redemption-poc : Test-CreatePopViaRedemption.ps1   (EXPERIMENT ONLY)
#
# Goal-2 alternative: instead of offline-pruning IMAP out of a captured
# profile (proven to load but NOT send/receive), CREATE the POP accounts
# LIVE via Redemption (Outlook's own Extended-MAPI code path). Outlook then
# builds all internal state (0a0d02 / transport / send-receive wiring), so
# the account is fully functional. Each account is bound to its migrated PST
# as the delivery store (DeliverToStore).
#
# - NO registry pollution: uses Redemption's RedemptionLoader (no regsvr32).
# - 32-bit: Outlook 2016 here is 32-bit, so this relaunches itself in 32-bit
#   PowerShell and uses Redemption.dll (32-bit).
# - Reads POP account settings + PST paths from the BACKUP manifest.json
#   (so no Japanese path literals in this ASCII script).
# - NOT wired into backuper/. A research probe only.
#
# PRECONDITIONS on the test box (32-bit Outlook 2016):
#   1. Outlook is CLOSED.
#   2. A (default) Outlook MAPI profile exists (even empty). Create via
#      Control Panel > Mail > Show Profiles if needed; pass its name with
#      -ProfileName, or leave blank to use the default profile.
#   3. The migrated PSTs are placed at the paths recorded in the manifest
#      (pst.sourcePath), OR pass -PstOverrideDir to point at a folder that
#      contains <email>.pst files.
#   4. The Redemption folder (Redemption.dll/Redemption64.dll/
#      Interop.Redemption.dll + RedemptionLoader\C#\RedemptionLoader.cs) is
#      copied LOCALLY on this box; pass its root with -RedemptionRoot.
#
# After running: open Outlook, enter each account password, run Send/Receive.
# ============================================================
[CmdletBinding()]
param(
    [string]$ManifestPath  = 'E:\test\outlookbktest\2016pop_and_imap\2026_05_30_201918\sections\outlook_pop\manifest.json',
    [string]$RedemptionRoot = 'E:\Redemption_test',
    [string]$ProfileName   = '',          # '' = default profile
    [string]$PstOverrideDir = '',         # '' = use manifest pst.sourcePath verbatim
    # connection defaults used when the manifest leaves them blank (xserver.jp typical) -- ADJUST IF NEEDED:
    [int]$DefaultPop3Port  = 995,
    [bool]$DefaultPop3SSL  = $true,
    [int]$DefaultSmtpPort  = 587,
    [bool]$DefaultSmtpSSL  = $true
)
$ErrorActionPreference = 'Stop'
Write-Host "[Test-CreatePopViaRedemption] revision 2026-05-30c (profile enum + robust logon)"

# ---------- 0. relaunch in 32-bit PowerShell to match 32-bit Outlook ----------
if ([IntPtr]::Size -eq 8) {
    $ps32 = Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $ps32)) { throw "32-bit PowerShell not found at $ps32" }
    Write-Host "[relaunch] running 64-bit; re-launching in 32-bit PowerShell to match 32-bit Outlook..."
    # forward ONLY the parameters the user actually passed (empty-string defaults
    # and unbound switches must NOT be forwarded, or arg-binding breaks).
    $fwd = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $PSCommandPath)
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        $fwd += "-$k"
        if ($v -is [bool]) { $fwd += ($(if ($v) { '1' } else { '0' })) } else { $fwd += [string]$v }
    }
    & $ps32 @fwd
    exit $LASTEXITCODE
}
Write-Host "[env] PowerShell bitness: 32-bit (IntPtr.Size=$([IntPtr]::Size))  -- matches 32-bit Outlook"

# ---------- 1. load Redemption (no registry) ----------
$redDll32  = Join-Path $RedemptionRoot 'Redemption\Redemption.dll'
$redDll64  = Join-Path $RedemptionRoot 'Redemption\Redemption64.dll'
$interop   = Join-Path $RedemptionRoot 'Redemption\Interop.Redemption.dll'
$loaderCs  = Join-Path $RedemptionRoot 'RedemptionLoader\C#\RedemptionLoader.cs'
foreach ($f in @($redDll32,$interop,$loaderCs)) { if (-not (Test-Path -LiteralPath $f)) { throw "missing Redemption file: $f" } }
# clear Mark-of-the-Web so .NET will load the assemblies (harmless if not blocked)
foreach ($f in @($redDll32,$redDll64,$interop)) { try { Unblock-File -LiteralPath $f -ErrorAction SilentlyContinue } catch {} }

Add-Type -Path $interop
Add-Type -TypeDefinition (Get-Content -LiteralPath $loaderCs -Raw) -ReferencedAssemblies $interop -Language CSharp
[Redemption.RedemptionLoader]::DllLocation32Bit = $redDll32
[Redemption.RedemptionLoader]::DllLocation64Bit = $redDll64
$session = [Redemption.RedemptionLoader]::new_RDOSession()
Write-Host "[redemption] RDOSession created (no-reg). Version check via Logon..."

# ---------- 2. read POP accounts from manifest ----------
$m = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$pop = @()
foreach ($p in $m.items.profiles) { foreach ($a in $p.accounts) { if ("$($a.type)" -eq 'pop3') { $pop += $a } } }
if ($pop.Count -eq 0) { throw "no POP3 accounts in manifest" }
Write-Host "[manifest] POP accounts: $($pop.Count)"

# ---------- 3. logon to the profile ----------
$miss = [System.Reflection.Missing]::Value

# enumerate MAPI profiles so we can see the real names (MAPI_E_LOGON_FAILED is
# usually a wrong/nonexistent profile name, or Outlook still running).
$profRoot = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows Messaging Subsystem\Profiles'
$profiles = @(); $defaultProf = $null
if (Test-Path $profRoot) {
    $profiles = @(Get-ChildItem $profRoot -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName })
    try { $defaultProf = (Get-ItemProperty -Path $profRoot -Name 'DefaultProfile' -ErrorAction Stop).DefaultProfile } catch {}
}
Write-Host ("[profiles] available: [" + ($profiles -join ', ') + "]   default: " + $defaultProf)

$target = if (-not [string]::IsNullOrWhiteSpace($ProfileName)) { $ProfileName }
          elseif ($defaultProf) { $defaultProf }
          else { $null }
if ($target -and $profiles.Count -gt 0 -and ($profiles -notcontains $target)) {
    Write-Host "[warn] profile '$target' is NOT in the list above -- MAPI will show a picker."
}
Write-Host ("[logon] target profile: " + $(if($target){"'$target'"}else{'(MAPI picker)'}) + "  -- ENSURE OUTLOOK IS CLOSED")

# ShowDialog=$true so MAPI can use the named profile or prompt a picker if needed;
# NewSession=$false (do not force a brand-new MAPI session).
$prof = if ($target) { $target } else { $miss }
try {
    $session.Logon($prof, $miss, $true, $false, $miss, $true)
} catch {
    throw ("Logon failed: " + $_.Exception.Message + "`n  -> Close Outlook completely, and pass a profile from the list above via -ProfileName. Profiles: [" + ($profiles -join ', ') + "]")
}
Write-Host "[logon] OK. Default store: $($session.Stores.DefaultStore.Name)"

# ---------- 4. per account: add PST store + create POP3 account bound to it ----------
foreach ($a in $pop) {
    $email = "$($a.email)"
    $srcPst = "$($a.pst.sourcePath)"
    if ([string]::IsNullOrWhiteSpace($srcPst)) { Write-Host "  [skip] $email : no pst.sourcePath"; continue }
    $pstPath = if ([string]::IsNullOrWhiteSpace($PstOverrideDir)) { $srcPst } else { Join-Path $PstOverrideDir (Split-Path $srcPst -Leaf) }
    if (-not (Test-Path -LiteralPath $pstPath)) { throw "PST not found at: $pstPath  (place the migrated PST there, or use -PstOverrideDir)" }

    Write-Host "  [account] $email"
    Write-Host "    PST: $pstPath"
    # add (or reuse) the PST store as delivery target
    $store = $session.Stores.AddPSTStore($pstPath)
    Write-Host "    store added: $($store.Name)"

    $name   = if ($a.displayName) { "$($a.displayName)" } else { $email }
    $pop3srv= "$($a.pop3.server)"
    $smtpsrv= if ($a.smtp.server) { "$($a.smtp.server)" } else { $pop3srv }
    $user   = if ($a.pop3.userName) { "$($a.pop3.userName)" } else { $email }
    # AddPOP3Account(Name, Address, POP3Server, SMTPServer, UserName, Password)
    $acct = $session.Accounts.AddPOP3Account($name, $email, $pop3srv, $smtpsrv, $user, '')   # password entered later in Outlook
    $acct.POP3_Port   = if ($a.pop3.port) { [int]$a.pop3.port } else { $DefaultPop3Port }
    $acct.POP3_UseSSL = if ($null -ne $a.pop3.useSSL -and "$($a.pop3.useSSL)" -ne '') { [bool][int]$a.pop3.useSSL } else { $DefaultPop3SSL }
    $acct.SMTP_Port   = if ($a.smtp.port) { [int]$a.smtp.port } else { $DefaultSmtpPort }
    $acct.SMTP_UseSSL = if ($null -ne $a.smtp.useSSL -and "$($a.smtp.useSSL)" -ne '') { [bool][int]$a.smtp.useSSL } else { $DefaultSmtpSSL }
    $acct.SMTP_UseAuth = if ($null -ne $a.smtp.useAuth -and "$($a.smtp.useAuth)" -ne '') { [bool][int]$a.smtp.useAuth } else { $true }
    if ($a.smtp.userName) { $acct.SMTP_UserName = "$($a.smtp.userName)" }
    if ($a.replyEmail)    { $acct.ReplyAddress  = "$($a.replyEmail)" }
    if ($a.organization)  { $acct.Organization  = "$($a.organization)" }
    $acct.DeliverToStore = $store         # <-- bind delivery to the migrated PST
    $acct.Save()
    Write-Host ("    created POP3 account: " + $email + "  pop=" + $pop3srv + ":" + $acct.POP3_Port + " ssl=" + $acct.POP3_UseSSL + "  -> store '" + $store.Name + "'")
}

$session.Logoff()
Write-Host ""
Write-Host "DONE. Now: open Outlook, enter each account password, run Send/Receive."
Write-Host "If POP port/SSL are wrong for your server, fix them in Outlook account settings (manifest left them blank; defaults used)."
