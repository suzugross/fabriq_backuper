# ============================================================
# dev/imap-prune-spike : Build-PrunedReg-Auto.ps1   (EXPERIMENT ONLY)
#
# Generalized version of Build-PrunedReg.ps1: instead of hard-coding the
# IMAP UIDs of one specific capture, it DERIVES the IMAP service / store /
# account from ANY profile_Outlook.reg, then prunes them.
#
# Derivation (offline, from the .reg alone):
#   1. IMAP account subkeys = subkeys under ..\9375CFF0..\<8hex> that carry
#      an "IMAP Server" value. Their "Service UID" = the IMAP service UID(s).
#   2. IMAP store-service subkeys = the Profiles\<prof>\<UID> subkey whose
#      leaf == an IMAP service UID. Its "01023d00" = the IMAP store-record UID.
#   3. IMAP store-record subkeys = the subkey whose leaf == that store-record UID.
#   delete subkeys : the account + store-service + store-record subkeys.
#   edit flat arr  : <servicesKey>\01023d0e (drop IMAP svc UID slots),
#                    <servicesKey>\01023d00 (drop IMAP store-record slots).
#                    servicesKey = the subkey whose leaf is the well-known
#                    MAPI-services MUID 9207f3e0a3b11019908b08002b2a56c2.
#   rebuild MV_BIN : every 1102xxxx (PT_MV_BINARY) value; drop elements that
#                    carry an IMAP marker (svc UID / store-rec UID / pstprx.dll).
#                    Values with no IMAP element are left byte-verbatim.
#
# The MV_BINARY serializer is round-trip byte-identity proven.
# NOT wired into production backuper/.
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
    $OutReg = Join-Path $scriptDir 'profile_Outlook.POP-only.AUTO.reg'
}

$MAPI_SERVICES_MUID = '9207f3e0a3b11019908b08002b2a56c2'   # well-known constant
$INTERNET_ACCT_GUID = '9375CFF0413111d3B88A00104B2A6676'   # well-known constant
$PSTPRX_ASCII = [byte[]](0x70,0x73,0x74,0x70,0x72,0x78,0x2e,0x64,0x6c,0x6c)  # "pstprx.dll"

# ---------- generic helpers ----------
function Get-Leaf([string]$key) { ($key -split '\\')[-1] }
function ConvertTo-HexLeaf([byte[]]$b) { (($b | ForEach-Object { '{0:x2}' -f $_ }) -join '') }
function Test-BytesEqual([byte[]]$a,[byte[]]$b){ if($a.Length-ne$b.Length){return $false}; for($i=0;$i -lt $a.Length;$i++){if($a[$i]-ne$b[$i]){return $false}}; return $true }
function Find-Bytes([byte[]]$hay,[byte[]]$needle){ if($needle.Length-eq0 -or $hay.Length -lt $needle.Length){return @()}; $h=@(); for($i=0;$i -le $hay.Length-$needle.Length;$i++){$m=$true;for($j=0;$j -lt $needle.Length;$j++){if($hay[$i+$j]-ne$needle[$j]){$m=$false;break}};if($m){$h+=$i}}; return $h }
function ConvertTo-Bytes([string]$hexBody){ if($hexBody.Trim().Length-eq0){return [byte[]]@()}; return [byte[]](($hexBody -split ',')|Where-Object{$_.Trim().Length-gt0}|ForEach-Object{[byte]([Convert]::ToInt32($_.Trim(),16))}) }
# PT_MV_BINARY: {uint32 count; count*(len, off); blob+pad4 each}. Descriptor
# width is environment-dependent: 16B (u64 len, u64 off) on one Outlook
# serialization, 8B (u32 len, u32 off) on another (bitness). Read-Mv DETECTS
# the width via which header size matches off[0], so prune preserves the
# source width (round-trip exact). Returns {Width; Els} or $null if unparseable.
function Read-Mv([byte[]]$b){
    if($b.Length -lt 4){ return $null }
    $count=[BitConverter]::ToUInt32($b,0)
    if($count -gt 100000){ return $null }
    if($count -eq 0){ return ,([pscustomobject]@{ Width=16; Els=(New-Object System.Collections.Generic.List[object]) }) }
    foreach($w in @(16,8)){
        $hdr=4+$count*$w
        if($b.Length -lt $hdr){ continue }
        $off0 = if($w -eq 16){[BitConverter]::ToUInt64($b,12)}else{[uint64][BitConverter]::ToUInt32($b,8)}
        if([uint64]$off0 -ne [uint64]$hdr){ continue }
        $els=New-Object System.Collections.Generic.List[object]; $ok=$true
        for($i=0;$i -lt $count;$i++){ $base=4+$i*$w
            if($w -eq 16){$len=[long][BitConverter]::ToUInt64($b,$base);$off=[long][BitConverter]::ToUInt64($b,$base+8)}
            else        {$len=[long][BitConverter]::ToUInt32($b,$base);$off=[long][BitConverter]::ToUInt32($b,$base+4)}
            if($off -lt 0 -or $len -lt 0 -or ($off+$len) -gt $b.Length){$ok=$false;break}
            if($len -eq 0){$els.Add([byte[]]@())}else{$els.Add([byte[]]($b[$off..($off+$len-1)]))} }
        if($ok){ return ,([pscustomobject]@{ Width=$w; Els=$els }) }
    }
    return $null
}
function Write-Mv($els,$width){ $count=$els.Count;$hdr=4+$count*$width;$offs=@();$o=$hdr; foreach($e in $els){$offs+=$o;$o+=$e.Length;if($o%4 -ne 0){$o+=(4-($o%4))}}; $out=New-Object byte[] $o; [BitConverter]::GetBytes([uint32]$count).CopyTo($out,0); for($i=0;$i -lt $count;$i++){$base=4+$i*$width; if($width -eq 16){[BitConverter]::GetBytes([uint64]$els[$i].Length).CopyTo($out,$base);[BitConverter]::GetBytes([uint64]$offs[$i]).CopyTo($out,$base+8)}else{[BitConverter]::GetBytes([uint32]$els[$i].Length).CopyTo($out,$base);[BitConverter]::GetBytes([uint32]$offs[$i]).CopyTo($out,$base+4)}; if($els[$i].Length-gt0){[Array]::Copy($els[$i],0,$out,$offs[$i],$els[$i].Length)}}; return ,([byte[]]$out) }
function Format-HexValue([string]$name,[byte[]]$bytes){ $prefix=if($name-eq'@'){'@=hex:'}else{'"'+$name+'"=hex:'}; if($bytes.Length-eq0){return @($prefix)}; $hx=$bytes|ForEach-Object{'{0:x2}' -f $_}; $perLine=25;$lines=@(); for($k=0;$k -lt $hx.Count;$k+=$perLine){$chunk=$hx[$k..([Math]::Min($k+$perLine-1,$hx.Count-1))];$isLast=($k+$perLine -ge $hx.Count);$joined=($chunk -join ',');$line=if($k-eq0){$prefix+$joined}else{'  '+$joined};if(-not $isLast){$line+=',\'};$lines+=$line}; return $lines }
function Remove-FlatSlots([byte[]]$b, $uidList){ $keep=New-Object System.Collections.Generic.List[byte];$removed=0; for($o=0;$o -lt $b.Length;$o+=16){$slot=[byte[]]($b[$o..($o+15)]);$isImap=$false;foreach($u in $uidList){if(Test-BytesEqual $slot $u){$isImap=$true}};if($isImap){$removed++}else{$keep.AddRange($slot)}}; return @{Bytes=[byte[]]$keep.ToArray();Removed=$removed} }
function Remove-MvImapElement([byte[]]$b, $markers){
    $p=Read-Mv $b
    if($null -eq $p){ $hasImap=$false; foreach($m in $markers){if((Find-Bytes $b $m).Count -gt 0){$hasImap=$true}}; return @{Bytes=$b;Removed=0;NewCount=-1;Unparsed=$true;HasImap=$hasImap} }
    $keep=New-Object System.Collections.Generic.List[object];$removed=0
    foreach($el in $p.Els){$isImap=$false;foreach($m in $markers){if((Find-Bytes $el $m).Count -gt 0){$isImap=$true}};if($isImap){$removed++}else{$keep.Add($el)}}
    return @{Bytes=(Write-Mv $keep $p.Width);Removed=$removed;NewCount=$keep.Count;Unparsed=$false;HasImap=$false}
}

# ---------- parse input ----------
if (-not (Test-Path -LiteralPath $InReg)) { throw "input not found: $InReg" }
$rawText = [System.IO.File]::ReadAllText($InReg, [System.Text.Encoding]::Unicode)
$phys = $rawText -split "`r`n"

# logical (continuation-joined) pass for derivation
$logical = New-Object System.Collections.Generic.List[string]; $cur=''; $acc=$false
foreach ($ln in $phys) { if($acc){$cur+=$ln.TrimStart()}else{$cur=$ln}; if($cur.TrimEnd().EndsWith('\')){$cur=$cur.TrimEnd();$cur=$cur.Substring(0,$cur.Length-1);$acc=$true}else{$logical.Add($cur);$cur='';$acc=$false} }
$curKey=''; $valByKeyName=@{}; $keyHasImap=@{}; $keyHasPop=@{}; $allKeys=New-Object System.Collections.Generic.List[string]
foreach ($L in $logical) {
    if ($L -match '^\[(.+)\]\s*$') { $curKey=$Matches[1]; $allKeys.Add($curKey); continue }
    if ($L -match '^"IMAP Server"=') { $keyHasImap[$curKey]=$true; continue }
    if ($L -match '^"POP3 Server"=') { $keyHasPop[$curKey]=$true; continue }
    if ($L -match '^"(.+?)"=hex(?:\(([0-9a-fA-F]+)\))?:(.*)$') { $valByKeyName[$curKey+'|'+$Matches[1]] = (ConvertTo-Bytes $Matches[3]) }
}
function Get-KeyByLeaf([string]$leafHexLower){ foreach($k in $allKeys){ if((Get-Leaf $k).ToLower() -eq $leafHexLower){ return $k } } return $null }

# ---------- DERIVE imap targets ----------
$imapSvcUids = @(); $storeRecUids = @()
$deleteLeaves = New-Object System.Collections.Generic.List[string]
foreach ($k in $allKeys) {
    if (-not $keyHasImap[$k]) { continue }
    if ($k -notmatch [regex]::Escape($INTERNET_ACCT_GUID)) { continue }
    $acctLeaf = Get-Leaf $k
    $deleteLeaves.Add($acctLeaf)
    $svc = $valByKeyName[$k + '|Service UID']
    if ($svc -and $svc.Length -eq 16) {
        $imapSvcUids += ,([byte[]]$svc)
        $svcLeaf = ConvertTo-HexLeaf $svc
        $storeSvcKey = Get-KeyByLeaf $svcLeaf
        if ($storeSvcKey) {
            $deleteLeaves.Add((Get-Leaf $storeSvcKey))
            $rec = $valByKeyName[$storeSvcKey + '|01023d00']
            if ($rec -and $rec.Length -eq 16) {
                $storeRecUids += ,([byte[]]$rec)
                $recKey = Get-KeyByLeaf (ConvertTo-HexLeaf $rec)
                if ($recKey) { $deleteLeaves.Add((Get-Leaf $recKey)) }
            }
        }
    }
}
$imapUidList = @(); $imapUidList += $imapSvcUids; $imapUidList += $storeRecUids
$mvMarkers   = @(); $mvMarkers   += $imapUidList; $mvMarkers += ,$PSTPRX_ASCII
$servicesKey = Get-KeyByLeaf $MAPI_SERVICES_MUID
$servicesLeaf = if ($servicesKey) { Get-Leaf $servicesKey } else { $null }

# ---------- reachability: also delete IMAP-only subkeys (prefs/transport/search
# residue) the 3-step chain misses. A GUID subkey reachable from an IMAP account
# but NOT from any POP account (and not well-known) is IMAP residue -> delete.
# (orphan-by-UID over-flags because native profiles also have UID-unreferenced
# subkeys; bipartite reachability is the correct discriminator.)
$WELL_KNOWN = @($MAPI_SERVICES_MUID, $INTERNET_ACCT_GUID.ToLower(),
    '0a0d020000000000c000000000000046','8503020000000000c000000000000046','f86ed2903a4a11cfb57e524153480001')
# leaf -> 16-byte UID (only 32-hex GUID subkeys are UID-addressable)
$guidLeaves = @($allKeys | ForEach-Object { Get-Leaf $_ } | Where-Object { $_ -match '^[0-9A-Fa-f]{32}$' } | Select-Object -Unique)
$leafUid = @{}
foreach ($g in $guidLeaves) { $bytes = New-Object System.Collections.Generic.List[byte]; for ($p=0;$p -lt 32;$p+=2){ $bytes.Add([byte]([Convert]::ToInt32($g.Substring($p,2),16))) }; $leafUid[$g.ToLower()] = $bytes.ToArray() }
# MULTI-HOP closure scanning $valByKeyName directly per node (a precomputed
# adjacency under-reached at hop 2; direct scan is correct).
function Get-Reach($seedLeaves) {
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $queue = New-Object System.Collections.Generic.Queue[string]
    foreach ($s in $seedLeaves) { $sl=$s.ToLower(); if($seen.Add($sl)){ $queue.Enqueue($sl) } }
    while ($queue.Count -gt 0) {
        $cur=$queue.Dequeue()
        foreach ($kn in $valByKeyName.Keys) {
            $fk = ($kn -split '\|')[0]
            $ownerLeaf = (Get-Leaf $fk).ToLower()
            if ($ownerLeaf -ne $cur) { continue }
            $v = $valByKeyName[$kn]
            foreach ($g in $guidLeaves) { $gl=$g.ToLower(); if ($gl -eq $cur) { continue }; if ((Find-Bytes $v $leafUid[$gl]).Count -gt 0) { if ($seen.Add($gl)) { $queue.Enqueue($gl) } } }
        }
    }
    return $seen
}
$imapAcctSeeds = @($allKeys | Where-Object { $keyHasImap[$_] -and ($_ -match [regex]::Escape($INTERNET_ACCT_GUID)) } | ForEach-Object { Get-Leaf $_ })
$popAcctSeeds  = @($allKeys | Where-Object { $keyHasPop[$_]  -and ($_ -match [regex]::Escape($INTERNET_ACCT_GUID)) } | ForEach-Object { Get-Leaf $_ })
$imapReach = Get-Reach $imapAcctSeeds
$popReach  = Get-Reach $popAcctSeeds
$reachDelete = @()
foreach ($g in $guidLeaves) { $gl=$g.ToLower(); if ($WELL_KNOWN -contains $gl) { continue }; if ($imapReach.Contains($gl) -and -not $popReach.Contains($gl)) { $reachDelete += $g } }
foreach ($d in $reachDelete) { if (-not ($deleteLeaves -contains $d)) { $deleteLeaves.Add($d) } }

Write-Host "==== DERIVED IMAP targets ===="
Write-Host ("  IMAP reachability extra subkeys (prefs/transport/search residue): " + (@($reachDelete) -join ', '))
Write-Host ("  ALL subkeys to DELETE: " + ($deleteLeaves -join ', '))
Write-Host ("  IMAP service UID(s): " + (($imapSvcUids | ForEach-Object { ConvertTo-HexLeaf $_ }) -join ', '))
Write-Host ("  IMAP store-record UID(s): " + (($storeRecUids | ForEach-Object { ConvertTo-HexLeaf $_ }) -join ', '))
Write-Host ("  services key leaf: " + $servicesLeaf)
Write-Host ""

# ---------- rewrite (physical-line preserving) ----------
$outLines = New-Object System.Collections.Generic.List[string]
$curKey=''; $drop=$false; $applied=@(); $unsafe=@(); $i=0
while ($i -lt $phys.Count) {
    $ln = $phys[$i]
    if ($ln -match '^\[(.+)\]\s*$') {
        $curKey=$Matches[1]; $leaf=Get-Leaf $curKey
        $drop = ($deleteLeaves -contains $leaf)
        if ($drop) { $applied += "DELETE key ...\$leaf" } else { $outLines.Add($ln) }
        $i++; continue
    }
    if ($ln -match '^("(.+?)"|@)=') {
        $name = if ($Matches[1] -eq '@') {'@'} else {$Matches[2]}
        $unit=@($ln); while($unit[-1].TrimEnd().EndsWith('\')){$i++;$unit+=$phys[$i]}; $i++
        if ($drop) { continue }
        $leaf=Get-Leaf $curKey
        $joined=($unit -join '')
        $emitted=$false
        if ($joined -match '=hex(?:\([0-9a-fA-F]+\))?:(.*)$') {
            $bytes = ConvertTo-Bytes ($Matches[1] -replace '\\','')
            if ($leaf -eq $servicesLeaf -and $name -eq '01023d0e') {
                $r=Remove-FlatSlots $bytes $imapUidList; $applied+="FLAT  ...\$leaf\$name removed=$($r.Removed)  $($bytes.Length)->$($r.Bytes.Length)B"
                foreach($o in (Format-HexValue $name $r.Bytes)){$outLines.Add($o)}; $emitted=$true
            }
            elseif ($leaf -eq $servicesLeaf -and $name -eq '01023d00') {
                $r=Remove-FlatSlots $bytes $imapUidList; $applied+="FLAT  ...\$leaf\$name removed=$($r.Removed)  $($bytes.Length)->$($r.Bytes.Length)B"
                foreach($o in (Format-HexValue $name $r.Bytes)){$outLines.Add($o)}; $emitted=$true
            }
            elseif ($name -match '^1102[0-9a-fA-F]{4}$') {
                $r=Remove-MvImapElement $bytes $mvMarkers
                if ($r.Unparsed -and $r.HasImap) {
                    # cannot parse as MV yet it references IMAP -> emitting verbatim
                    # would leave a dangling reference. Flag as UNSAFE (do not ship).
                    $script:unsafe += "UNSAFE: ...\$leaf\$name is an unparseable MV that contains an IMAP marker (cannot prune safely)"
                    $applied+="WARN  ...\$leaf\$name UNPARSEABLE+IMAP -> left verbatim (UNSAFE)"
                } elseif ($r.Removed -gt 0 -and $r.NewCount -eq 0) {
                    # all elements were IMAP -> a native POP-only profile has NO such
                    # value at all. OMIT it entirely (do not write an empty count=0 MV,
                    # which native lacks and which left send/receive broken).
                    $applied+="MV    ...\$leaf\$name removedEl=$($r.Removed) newCount=0 -> VALUE OMITTED (native has none)"
                    $emitted=$true
                } elseif ($r.Removed -gt 0) {
                    $applied+="MV    ...\$leaf\$name removedEl=$($r.Removed) newCount=$($r.NewCount)  $($bytes.Length)->$($r.Bytes.Length)B"
                    foreach($o in (Format-HexValue $name $r.Bytes)){$outLines.Add($o)}; $emitted=$true
                }
                # removed==0 (parseable, no IMAP) -> fall through to verbatim (byte-identity)
            }
        }
        if (-not $emitted) { foreach($u in $unit){$outLines.Add($u)} }
        continue
    }
    $outLines.Add($ln); $i++
}

$utf16Bom = New-Object System.Text.UnicodeEncoding($false, $true)
[System.IO.File]::WriteAllText($OutReg, (($outLines -join "`r`n")), $utf16Bom)
Write-Host "==== transforms applied ===="
$applied | ForEach-Object { Write-Host "  $_" }
Write-Host ""
if ($unsafe.Count -gt 0) {
    Write-Host "==== !!! UNSAFE — DO NOT live-test this output !!! ===="
    $unsafe | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
}
Write-Host "Output: $OutReg"
