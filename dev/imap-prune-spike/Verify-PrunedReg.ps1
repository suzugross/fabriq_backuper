# ============================================================
# dev/imap-prune-spike : Verify-PrunedReg.ps1   (EXPERIMENT ONLY)
# Offline self-consistency checks on the pruned .reg. Does NOT prove
# Outlook will load it (that is the operator live-test); it proves the
# pruned file has no dangling IMAP references, valid MV_BINARY framing,
# and intact POP data.
# ============================================================
[CmdletBinding()]
param(
    [string]$InReg  = 'E:\test\outlookbktest\2026_05_19_IMAP_and_POP3\profile_Outlook.reg',
    [string]$OutReg = ''
)
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($OutReg)) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    if ([string]::IsNullOrWhiteSpace($scriptDir)) { $scriptDir = (Get-Location).Path }
    $OutReg = Join-Path $scriptDir 'profile_Outlook.POP-only.reg'
}

function Read-RegValues([string]$path) {
    $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::Unicode)
    $lines = $raw -split "`r?`n"
    $logical = New-Object System.Collections.Generic.List[string]; $cur=''; $acc=$false
    foreach ($ln in $lines) {
        if ($acc) { $cur += $ln.TrimStart() } else { $cur = $ln }
        if ($cur.TrimEnd().EndsWith('\')) { $cur=$cur.TrimEnd(); $cur=$cur.Substring(0,$cur.Length-1); $acc=$true }
        else { $logical.Add($cur); $cur=''; $acc=$false }
    }
    $curKey=''; $vals=@(); $keys=New-Object System.Collections.Generic.List[string]
    foreach ($L in $logical) {
        if ($L -match '^\[(.+)\]\s*$') { $curKey=$Matches[1]; $keys.Add($curKey); continue }
        if ($L -match '^"(.+?)"=hex(?:\(([0-9a-fA-F]+)\))?:(.*)$') {
            $name=$Matches[1]; $hb=$Matches[3]
            $b=@(); if ($hb.Trim().Length-gt0){ $b=($hb -split ',')|?{$_.Trim().Length-gt0}|%{[byte]([Convert]::ToInt32($_.Trim(),16))} }
            $vals += [pscustomobject]@{ Key=$curKey; Leaf=($curKey -split '\\')[-1]; Name=$name; Bytes=[byte[]]$b }
        }
    }
    return [pscustomobject]@{ Keys=$keys; Vals=$vals }
}
function Find-Bytes([byte[]]$hay,[byte[]]$needle){
    if($needle.Length -eq 0 -or $hay.Length -lt $needle.Length){return @()}
    $h=@(); for($i=0;$i -le $hay.Length-$needle.Length;$i++){ $m=$true; for($j=0;$j -lt $needle.Length;$j++){if($hay[$i+$j]-ne$needle[$j]){$m=$false;break}}; if($m){$h+=$i} }; return $h
}
function Test-Eq([byte[]]$a,[byte[]]$b){ if($a.Length-ne$b.Length){return $false}; for($i=0;$i -lt $a.Length;$i++){if($a[$i]-ne$b[$i]){return $false}}; return $true }
function Read-Mv([byte[]]$b){
    $count=[BitConverter]::ToUInt32($b,0); $els=New-Object System.Collections.Generic.List[object]
    for($i=0;$i -lt $count;$i++){ $base=4+$i*16; $len=[int][BitConverter]::ToUInt64($b,$base); $off=[int][BitConverter]::ToUInt64($b,$base+8)
        if(($off+$len)-gt $b.Length){ return $null }
        if($len-eq0){$els.Add([byte[]]@())}else{$els.Add([byte[]]($b[$off..($off+$len-1)]))} }
    return ,$els
}
function Write-Mv($els){
    $count=$els.Count; $hdr=4+$count*16; $offs=@(); $o=$hdr
    foreach($e in $els){$offs+=$o;$o+=$e.Length; if($o%4 -ne 0){$o+=(4-($o%4))}}
    $out=New-Object byte[] $o; [BitConverter]::GetBytes([uint32]$count).CopyTo($out,0)
    for($i=0;$i -lt $count;$i++){ [BitConverter]::GetBytes([uint64]$els[$i].Length).CopyTo($out,4+$i*16); [BitConverter]::GetBytes([uint64]$offs[$i]).CopyTo($out,4+$i*16+8); if($els[$i].Length-gt0){[Array]::Copy($els[$i],0,$out,$offs[$i],$els[$i].Length)} }
    return ,([byte[]]$out)
}

$markers = [ordered]@{
  'IMAP-svc b04917cf' = [byte[]](0xb0,0x49,0x17,0xcf,0x85,0xe4,0x94,0x49,0xb3,0x58,0xb4,0x3f,0x1a,0x8d,0xa4,0x2c)
  'IMAP-rec 61f1f7b7' = [byte[]](0x61,0xf1,0xf7,0xb7,0xb6,0xbb,0xc7,0x42,0xbc,0x74,0x84,0x87,0x20,0x49,0xb9,0x96)
  'IMAP-acct 5b98da28'= [byte[]](0x5b,0x98,0xda,0x28,0xa3,0x7e,0xc5,0x40,0xa7,0x64,0x70,0x9b,0x14,0xb8,0x15,0xe0)
  'pstprx.dll'        = [byte[]](0x70,0x73,0x74,0x70,0x72,0x78,0x2e,0x64,0x6c,0x6c)
}

$pass=0; $fail=0
function Check($n,$c){ if($c){$script:pass++; Write-Host ("  [PASS] $n")} else {$script:fail++; Write-Host ("  [FAIL] $n")} }

$in  = Read-RegValues $InReg
$out = Read-RegValues $OutReg

# BOM + parseability
$ob=[System.IO.File]::ReadAllBytes($OutReg)
Check "output is UTF-16LE+BOM (ff fe)" ($ob.Length -ge 2 -and $ob[0]-eq0xff -and $ob[1]-eq0xfe)
Check "output header line present" (([System.IO.File]::ReadAllText($OutReg,[System.Text.Encoding]::Unicode)) -match 'Windows Registry Editor Version 5\.00')

Write-Host "`n--- (1) NO dangling IMAP references anywhere ---"
foreach($mk in $markers.Keys){
    $hits = @($out.Vals | Where-Object { (Find-Bytes $_.Bytes $markers[$mk]).Count -gt 0 })
    Check ("no '$mk' in any value (found in $($hits.Count) values)") ($hits.Count -eq 0)
}

Write-Host "`n--- (2) subkey deletions / POP retention ---"
foreach($d in @('00000004','61f1f7b7b6bbc742bc7484872049b996','b04917cf85e49449b358b43f1a8da42c')){
    Check "IMAP subkey ...\$d removed" (-not ($out.Keys | Where-Object { ($_ -split '\\')[-1] -eq $d }))
}
foreach($p in @('00000002','00000003')){
    Check "POP subkey ...\$p present" ([bool]($out.Keys | Where-Object { ($_ -split '\\')[-1] -eq $p }))
}

Write-Host "`n--- (3) POP Delivery Store EntryID unchanged (00000002) ---"
$inDse  = $in.Vals  | Where-Object { $_.Leaf -eq '00000002' -and $_.Name -eq 'Delivery Store EntryID' } | Select-Object -First 1
$outDse = $out.Vals | Where-Object { $_.Leaf -eq '00000002' -and $_.Name -eq 'Delivery Store EntryID' } | Select-Object -First 1
Check "POP DSE present in output" ($null -ne $outDse)
if ($inDse -and $outDse) { Check "POP DSE bytes identical to source" (Test-Eq $inDse.Bytes $outDse.Bytes) }

Write-Host "`n--- (4) flat service/store arrays shrunk correctly (9207f3e0) ---"
$d0e = $out.Vals | Where-Object { $_.Leaf -eq '9207f3e0a3b11019908b08002b2a56c2' -and $_.Name -eq '01023d0e' } | Select-Object -First 1
$d00 = $out.Vals | Where-Object { $_.Leaf -eq '9207f3e0a3b11019908b08002b2a56c2' -and $_.Name -eq '01023d00' } | Select-Object -First 1
Check "01023d0e now 2 svc UIDs (32B)" ($d0e -and $d0e.Bytes.Length -eq 32)
Check "01023d00 now 1 store (16B)"    ($d00 -and $d00.Bytes.Length -eq 16)

Write-Host "`n--- (5) all remaining MV_BINARY round-trip (valid framing) ---"
$mv = $out.Vals | Where-Object { $_.Name -match '^1102[0-9a-fA-F]{4}$' }
$rtFail=0
foreach($v in $mv){
    $p = Read-Mv $v.Bytes
    if ($null -eq $p) { Write-Host ("    [BADFRAME] $($v.Name) len=$($v.Bytes.Length)"); $rtFail++; continue }
    $ser = Write-Mv $p
    if (-not (Test-Eq $ser $v.Bytes)) { Write-Host ("    [RT-FAIL] $($v.Name)"); $rtFail++ }
}
Check "all $($mv.Count) MV_BINARY values valid + round-trip" ($rtFail -eq 0)

Write-Host ""
Write-Host ("VERIFY RESULT: PASS=$pass FAIL=$fail")
if ($fail -eq 0) { Write-Host "ALL OFFLINE CHECKS PASSED (live Outlook load still required = the real unknown)" }
