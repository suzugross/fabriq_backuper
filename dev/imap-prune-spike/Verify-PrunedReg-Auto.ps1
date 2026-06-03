# ============================================================
# dev/imap-prune-spike : Verify-PrunedReg-Auto.ps1   (EXPERIMENT ONLY)
# Generic offline self-consistency check: derives the IMAP targets from the
# SOURCE .reg, then asserts the pruned OUTPUT has no dangling IMAP reference,
# preserves every POP account + its Delivery Store EntryID verbatim, and that
# all PT_MV_BINARY values still round-trip (width-aware). Does NOT prove the
# Outlook live-load (that is the operator test).
# ============================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$InReg,
    [Parameter(Mandatory=$true)][string]$OutReg
)
$ErrorActionPreference = 'Stop'
$MAPI_SERVICES_MUID='9207f3e0a3b11019908b08002b2a56c2'; $INTERNET_ACCT_GUID='9375CFF0413111d3B88A00104B2A6676'
$PSTPRX_ASCII=[byte[]](0x70,0x73,0x74,0x70,0x72,0x78,0x2e,0x64,0x6c,0x6c)

function Get-Leaf([string]$k){ ($k -split '\\')[-1] }
function ConvertTo-HexLeaf([byte[]]$b){ (($b|ForEach-Object{'{0:x2}' -f $_}) -join '') }
function Test-Eq([byte[]]$a,[byte[]]$b){ if($a.Length-ne$b.Length){return $false}; for($i=0;$i -lt $a.Length;$i++){if($a[$i]-ne$b[$i]){return $false}}; return $true }
function Find-Bytes([byte[]]$hay,[byte[]]$needle){ if($needle.Length-eq0 -or $hay.Length -lt $needle.Length){return @()}; $h=@(); for($i=0;$i -le $hay.Length-$needle.Length;$i++){$m=$true;for($j=0;$j -lt $needle.Length;$j++){if($hay[$i+$j]-ne$needle[$j]){$m=$false;break}};if($m){$h+=$i}}; return $h }
function ConvertTo-Bytes([string]$h){ if($h.Trim().Length-eq0){return [byte[]]@()}; return [byte[]](($h -split ',')|Where-Object{$_.Trim().Length-gt0}|ForEach-Object{[byte]([Convert]::ToInt32($_.Trim(),16))}) }
function Read-Mv([byte[]]$b){
    if($b.Length -lt 4){return $null}; $count=[BitConverter]::ToUInt32($b,0); if($count -gt 100000){return $null}
    if($count -eq 0){return ,([pscustomobject]@{Width=16;Els=(New-Object System.Collections.Generic.List[object])})}
    foreach($w in @(16,8)){ $hdr=4+$count*$w; if($b.Length -lt $hdr){continue}
        $off0=if($w -eq 16){[BitConverter]::ToUInt64($b,12)}else{[uint64][BitConverter]::ToUInt32($b,8)}
        if([uint64]$off0 -ne [uint64]$hdr){continue}
        $els=New-Object System.Collections.Generic.List[object];$ok=$true
        for($i=0;$i -lt $count;$i++){$base=4+$i*$w; if($w -eq 16){$len=[long][BitConverter]::ToUInt64($b,$base);$off=[long][BitConverter]::ToUInt64($b,$base+8)}else{$len=[long][BitConverter]::ToUInt32($b,$base);$off=[long][BitConverter]::ToUInt32($b,$base+4)}
            if($off -lt 0 -or $len -lt 0 -or ($off+$len) -gt $b.Length){$ok=$false;break}
            if($len -eq 0){$els.Add([byte[]]@())}else{$els.Add([byte[]]($b[$off..($off+$len-1)]))}}
        if($ok){return ,([pscustomobject]@{Width=$w;Els=$els})} }
    return $null
}
function Write-Mv($els,$width){ $count=$els.Count;$hdr=4+$count*$width;$offs=@();$o=$hdr; foreach($e in $els){$offs+=$o;$o+=$e.Length;if($o%4 -ne 0){$o+=(4-($o%4))}}; $out=New-Object byte[] $o; [BitConverter]::GetBytes([uint32]$count).CopyTo($out,0); for($i=0;$i -lt $count;$i++){$base=4+$i*$width; if($width -eq 16){[BitConverter]::GetBytes([uint64]$els[$i].Length).CopyTo($out,$base);[BitConverter]::GetBytes([uint64]$offs[$i]).CopyTo($out,$base+8)}else{[BitConverter]::GetBytes([uint32]$els[$i].Length).CopyTo($out,$base);[BitConverter]::GetBytes([uint32]$offs[$i]).CopyTo($out,$base+4)}; if($els[$i].Length-gt0){[Array]::Copy($els[$i],0,$out,$offs[$i],$els[$i].Length)}}; return ,([byte[]]$out) }

function Read-Reg([string]$path){
    $raw=[System.IO.File]::ReadAllText($path,[System.Text.Encoding]::Unicode); $lines=$raw -split "`r?`n"
    $logical=New-Object System.Collections.Generic.List[string];$cur='';$acc=$false
    foreach($ln in $lines){ if($acc){$cur+=$ln.TrimStart()}else{$cur=$ln}; if($cur.TrimEnd().EndsWith('\')){$cur=$cur.TrimEnd();$cur=$cur.Substring(0,$cur.Length-1);$acc=$true}else{$logical.Add($cur);$cur='';$acc=$false} }
    $curKey='';$vals=@();$keys=New-Object System.Collections.Generic.List[string];$hasImap=@{};$hasPop=@{};$valByKN=@{}
    foreach($L in $logical){
        if($L -match '^\[(.+)\]\s*$'){$curKey=$Matches[1];$keys.Add($curKey);continue}
        if($L -match '^"IMAP Server"='){$hasImap[$curKey]=$true}
        if($L -match '^"POP3 Server"='){$hasPop[$curKey]=$true}
        if($L -match '^"(.+?)"=hex(?:\(([0-9a-fA-F]+)\))?:(.*)$'){ $b=ConvertTo-Bytes $Matches[3]; $vals+=[pscustomobject]@{Key=$curKey;Leaf=(Get-Leaf $curKey);Name=$Matches[1];Bytes=$b}; $valByKN[$curKey+'|'+$Matches[1]]=$b }
    }
    return [pscustomobject]@{Keys=$keys;Vals=$vals;HasImap=$hasImap;HasPop=$hasPop;ValByKN=$valByKN}
}

$in=Read-Reg $InReg; $out=Read-Reg $OutReg
function GetKeyByLeaf($reg,$leafLower){ foreach($k in $reg.Keys){ if((Get-Leaf $k).ToLower() -eq $leafLower){return $k} } return $null }

# ---- derive IMAP targets from SOURCE ----
$imapUids=@(); $deleteLeaves=@(); $popSrcLeaves=@()
foreach($k in $in.Keys){
    if($in.HasPop[$k] -and ($k -match [regex]::Escape($INTERNET_ACCT_GUID))){ $popSrcLeaves += (Get-Leaf $k) }
    if(-not $in.HasImap[$k]){continue}; if($k -notmatch [regex]::Escape($INTERNET_ACCT_GUID)){continue}
    $deleteLeaves += (Get-Leaf $k)
    $svc=$in.ValByKN[$k+'|Service UID']
    if($svc -and $svc.Length -eq 16){ $imapUids+=,([byte[]]$svc); $svcLeaf=ConvertTo-HexLeaf $svc
        $ssk=GetKeyByLeaf $in $svcLeaf; if($ssk){ $deleteLeaves+=(Get-Leaf $ssk); $rec=$in.ValByKN[$ssk+'|01023d00']
            if($rec -and $rec.Length -eq 16){ $imapUids+=,([byte[]]$rec); $rk=GetKeyByLeaf $in (ConvertTo-HexLeaf $rec); if($rk){$deleteLeaves+=(Get-Leaf $rk)} } } }
}
$markers=@(); $markers+=$imapUids; $markers+=,$PSTPRX_ASCII

$pass=0;$fail=0
function Chk($n,$c){ if($c){$script:pass++;Write-Host "  [PASS] $n"}else{$script:fail++;Write-Host "  [FAIL] $n"} }

Write-Host "=== source: POP subkeys=$($popSrcLeaves.Count) ($($popSrcLeaves -join ',')) | IMAP delete-leaves=$($deleteLeaves.Count) ==="
$ob=[System.IO.File]::ReadAllBytes($OutReg); Chk "output UTF-16LE+BOM" ($ob.Length-ge2 -and $ob[0]-eq0xff -and $ob[1]-eq0xfe)

Write-Host "`n--- (1) NO IMAP refs in output (derived markers + pstprx) ---"
$mi=0; foreach($m in $imapUids){ $hits=@($out.Vals|Where-Object{(Find-Bytes $_.Bytes $m).Count -gt 0}); Chk ("IMAP UID #$mi ("+(ConvertTo-HexLeaf $m)+") absent") ($hits.Count-eq0); $mi++ }
$ph=@($out.Vals|Where-Object{(Find-Bytes $_.Bytes $PSTPRX_ASCII).Count -gt 0}); Chk "pstprx.dll absent in all values" ($ph.Count-eq0)
$imapServerVals=@($out.Vals|Where-Object{$_.Name -eq 'IMAP Server' -or $_.Name -eq 'IMAP Store EID'}); Chk "no 'IMAP Server'/'IMAP Store EID' values" ($imapServerVals.Count-eq0)

Write-Host "`n--- (2) IMAP subkeys deleted / POP subkeys retained ---"
foreach($d in ($deleteLeaves|Select-Object -Unique)){ Chk "IMAP subkey ...\$d removed" (-not ($out.Keys|Where-Object{(Get-Leaf $_)-eq$d})) }
foreach($p in $popSrcLeaves){ Chk "POP subkey ...\$p present" ([bool]($out.Keys|Where-Object{(Get-Leaf $_)-eq$p})) }

Write-Host "`n--- (3) each POP Delivery Store EntryID preserved verbatim ---"
foreach($p in $popSrcLeaves){
    $sk=GetKeyByLeaf $in $p.ToLower(); $ok2=GetKeyByLeaf $out $p.ToLower()
    $sdse=$in.ValByKN[$sk+'|Delivery Store EntryID']; $odse=if($ok2){$out.ValByKN[$ok2+'|Delivery Store EntryID']}else{$null}
    Chk "POP ...\$p DSE present+identical" ($sdse -and $odse -and (Test-Eq $sdse $odse))
}

Write-Host "`n--- (4) all output PT_MV_BINARY round-trip (width-aware) ---"
$mv=$out.Vals|Where-Object{$_.Name -match '^1102[0-9a-fA-F]{4}$'}; $rtFail=0
foreach($v in $mv){ $p=Read-Mv $v.Bytes; if($null -eq $p){Write-Host "    [BADFRAME] $($v.Name)";$rtFail++;continue}; $ser=Write-Mv $p.Els $p.Width; if(-not(Test-Eq $ser $v.Bytes)){Write-Host "    [RT-FAIL] $($v.Name)";$rtFail++} }
Chk "all $($mv.Count) MV values valid+round-trip" ($rtFail-eq0)

Write-Host ""
Write-Host "VERIFY RESULT: PASS=$pass FAIL=$fail"
if($fail -eq 0){ Write-Host "ALL OFFLINE CHECKS PASSED (live Outlook load still required)" }
