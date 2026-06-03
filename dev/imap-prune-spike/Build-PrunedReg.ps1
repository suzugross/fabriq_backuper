# ============================================================
# dev/imap-prune-spike : Build-PrunedReg.ps1   (EXPERIMENT ONLY)
#
# Research spike for "goal 2": from an Outlook profile registry export
# that contains BOTH a POP and an IMAP account, produce a pruned .reg
# with the IMAP service/store/account removed, leaving a POP-only profile.
#
# This is NOT production code and is NOT wired into backuper/. Its sole
# purpose is to generate ONE candidate pruned .reg whose only remaining
# unknown is whether a same-version (16.0) Outlook loads it without the
# historical silent crash. The MV_BINARY serializer below is round-trip
# byte-identity proven against the real capture (6/6).
#
# Removal plan (derived by byte-level reference mapping of the real
# IMAP+POP capture; UIDs are profile-specific to that capture):
#   delete subkeys : 9375CFF0..\00000004  (IMAP account+store service)
#                    <profile>\61f1f7b7...  (IMAP store-record)
#                    <profile>\b04917cf...  (IMAP store-service record)
#   edit flat arr  : 9207f3e0..\01023d0e (-16B IMAP svc UID)
#                    9207f3e0..\01023d00 (-16B IMAP store rec)
#   rebuild MV_BIN : 9207f3e0..\11023d05  0a0d02..\1102039b  0a0d02..\11020434
#                    1b53..\11026620      1b53..\11026626
#   leave as-is    : 0a0d02..\1102022a (mspst/POP-only)
#
# Element identification is CONTENT-DRIVEN (remove the slot/element whose
# bytes carry an IMAP marker) so it is self-checking, not index-hardcoded.
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

# IMAP markers (profile-specific 16-byte UIDs + provider ascii)
$IMAP_SVC_UID   = [byte[]](0xb0,0x49,0x17,0xcf,0x85,0xe4,0x94,0x49,0xb3,0x58,0xb4,0x3f,0x1a,0x8d,0xa4,0x2c)
$IMAP_STORE_REC = [byte[]](0x61,0xf1,0xf7,0xb7,0xb6,0xbb,0xc7,0x42,0xbc,0x74,0x84,0x87,0x20,0x49,0xb9,0x96)
$IMAP_ACCT_UID  = [byte[]](0x5b,0x98,0xda,0x28,0xa3,0x7e,0xc5,0x40,0xa7,0x64,0x70,0x9b,0x14,0xb8,0x15,0xe0)
$PSTPRX_ASCII   = [byte[]](0x70,0x73,0x74,0x70,0x72,0x78,0x2e,0x64,0x6c,0x6c)   # "pstprx.dll"
$IMAP_FLAT_UIDS = @($IMAP_SVC_UID, $IMAP_STORE_REC)                            # 16-byte slots to splice from flat arrays
$IMAP_MV_MARKERS= @($IMAP_SVC_UID, $IMAP_STORE_REC, $PSTPRX_ASCII)            # any => element is IMAP

$DELETE_LEAVES = @(
    '00000004',
    '61f1f7b7b6bbc742bc7484872049b996',
    'b04917cf85e49449b358b43f1a8da42c'
)
# (leaf, valueName) -> kind. flat = splice 16B IMAP slots; mv = drop IMAP element
$MODIFY = @{
    '9207f3e0a3b11019908b08002b2a56c2|01023d0e' = 'flat'
    '9207f3e0a3b11019908b08002b2a56c2|01023d00' = 'flat'
    '9207f3e0a3b11019908b08002b2a56c2|11023d05' = 'mv'
    '0a0d020000000000c000000000000046|1102039b' = 'mv'
    '0a0d020000000000c000000000000046|11020434' = 'mv'
    '1b53c062a24e814f820aed81cdfe2f9c|11026620' = 'mv'
    '1b53c062a24e814f820aed81cdfe2f9c|11026626' = 'mv'
}

# ---------- helpers ----------
function Get-Leaf([string]$key) { ($key -split '\\')[-1] }
function Test-BytesEqual([byte[]]$a, [byte[]]$b) {
    if ($a.Length -ne $b.Length) { return $false }
    for ($i=0; $i -lt $a.Length; $i++) { if ($a[$i] -ne $b[$i]) { return $false } }
    return $true
}
function Find-Bytes([byte[]]$hay, [byte[]]$needle) {
    if ($needle.Length -eq 0 -or $hay.Length -lt $needle.Length) { return @() }
    $hits=@()
    for ($i=0; $i -le $hay.Length-$needle.Length; $i++) {
        $m=$true; for ($j=0;$j -lt $needle.Length;$j++){ if ($hay[$i+$j] -ne $needle[$j]){$m=$false;break} }
        if ($m) { $hits += $i }
    }
    return $hits
}
function ConvertTo-Bytes([string]$hexBody) {
    if ($hexBody.Trim().Length -eq 0) { return [byte[]]@() }
    return [byte[]](($hexBody -split ',') | Where-Object { $_.Trim().Length -gt 0 } | ForEach-Object { [byte]([Convert]::ToInt32($_.Trim(),16)) })
}

# MV_BINARY {uint32 count; count*(uint64 len, uint64 absOff); blob+pad-to-4 each}
function Read-Mv([byte[]]$b) {
    $count = [BitConverter]::ToUInt32($b,0)
    $els = New-Object System.Collections.Generic.List[object]
    for ($i=0; $i -lt $count; $i++) {
        $base=4+$i*16
        $len=[int][BitConverter]::ToUInt64($b,$base)
        $off=[int][BitConverter]::ToUInt64($b,$base+8)
        if ($len -eq 0) { $els.Add([byte[]]@()) } else { $els.Add([byte[]]($b[$off..($off+$len-1)])) }
    }
    return ,$els   # unary comma: prevent PS from unrolling the List on return
}
function Write-Mv($els) {
    $count=$els.Count; $hdr=4+$count*16
    $offs=@(); $o=$hdr
    foreach ($e in $els) { $offs+=$o; $o+=$e.Length; if ($o%4 -ne 0){ $o += (4-($o%4)) } }
    $out = New-Object byte[] $o
    [BitConverter]::GetBytes([uint32]$count).CopyTo($out,0)
    for ($i=0;$i -lt $count;$i++){
        [BitConverter]::GetBytes([uint64]$els[$i].Length).CopyTo($out,4+$i*16)
        [BitConverter]::GetBytes([uint64]$offs[$i]).CopyTo($out,4+$i*16+8)
        if ($els[$i].Length -gt 0){ [Array]::Copy($els[$i],0,$out,$offs[$i],$els[$i].Length) }
    }
    return ,([byte[]]$out)
}
function Remove-FlatImapSlots([byte[]]$b) {
    $keep = New-Object System.Collections.Generic.List[byte]
    $removed=0
    for ($o=0; $o -lt $b.Length; $o+=16) {
        $slot=[byte[]]($b[$o..($o+15)])
        $isImap=$false; foreach ($u in $IMAP_FLAT_UIDS){ if (Test-BytesEqual $slot $u){$isImap=$true} }
        if ($isImap) { $removed++ } else { $keep.AddRange($slot) }
    }
    return @{ Bytes=[byte[]]$keep.ToArray(); Removed=$removed }
}
function Remove-MvImapElement([byte[]]$b) {
    $els = Read-Mv $b
    $keep = New-Object System.Collections.Generic.List[object]
    $removed=0
    foreach ($el in $els) {
        $isImap=$false; foreach ($m in $IMAP_MV_MARKERS){ if ((Find-Bytes $el $m).Count -gt 0){$isImap=$true} }
        if ($isImap) { $removed++ } else { $keep.Add($el) }
    }
    return @{ Bytes=(Write-Mv $keep); Removed=$removed; NewCount=$keep.Count }
}
function Format-HexValue([string]$name, [byte[]]$bytes) {
    $prefix = if ($name -eq '@') { '@=hex:' } else { '"' + $name + '"=hex:' }
    if ($bytes.Length -eq 0) { return @($prefix) }
    $hx = $bytes | ForEach-Object { '{0:x2}' -f $_ }
    $perLine=25; $lines=@()
    for ($k=0; $k -lt $hx.Count; $k+=$perLine) {
        $chunk = $hx[$k..([Math]::Min($k+$perLine-1,$hx.Count-1))]
        $isLast = ($k+$perLine -ge $hx.Count)
        $joined = ($chunk -join ',')
        $line = if ($k -eq 0) { $prefix + $joined } else { '  ' + $joined }
        if (-not $isLast) { $line += ',\' }
        $lines += $line
    }
    return $lines
}

# ---------- read input (UTF-16LE) ----------
if (-not (Test-Path -LiteralPath $InReg)) { throw "input not found: $InReg" }
$rawText = [System.IO.File]::ReadAllText($InReg, [System.Text.Encoding]::Unicode)
$phys = $rawText -split "`r`n"

# ---------- rewrite ----------
$outLines = New-Object System.Collections.Generic.List[string]
$curKey=''; $drop=$false
$applied = @()
$i=0
while ($i -lt $phys.Count) {
    $ln = $phys[$i]
    if ($ln -match '^\[(.+)\]\s*$') {
        $curKey = $Matches[1]
        $leaf = Get-Leaf $curKey
        $drop = ($DELETE_LEAVES -contains $leaf)
        if ($drop) { $applied += "DELETE key ...\$leaf" }
        else { $outLines.Add($ln) }
        $i++; continue
    }
    if ($ln -match '^("(.+?)"|@)=') {
        $name = if ($Matches[1] -eq '@') { '@' } else { $Matches[2] }
        # collect continuation unit
        $unit = @($ln)
        while ($unit[-1].TrimEnd().EndsWith('\')) { $i++; $unit += $phys[$i] }
        $i++
        if ($drop) { continue }   # value belongs to a deleted key
        $leaf = Get-Leaf $curKey
        $modKey = "$leaf|$name"
        if ($MODIFY.ContainsKey($modKey)) {
            # reassemble bytes
            $joined = ($unit -join '')
            if ($joined -match '=hex(?:\([0-9a-fA-F]+\))?:(.*)$') {
                $body = ($Matches[1] -replace '\\','')
                $bytes = ConvertTo-Bytes $body
                if ($MODIFY[$modKey] -eq 'flat') {
                    $r = Remove-FlatImapSlots $bytes
                    $applied += "FLAT  ...\$leaf\$name  removed=$($r.Removed) slot(s)  $($bytes.Length)B -> $($r.Bytes.Length)B"
                    foreach ($o in (Format-HexValue $name $r.Bytes)) { $outLines.Add($o) }
                } else {
                    $r = Remove-MvImapElement $bytes
                    $applied += "MV    ...\$leaf\$name  removedEl=$($r.Removed)  newCount=$($r.NewCount)  $($bytes.Length)B -> $($r.Bytes.Length)B"
                    foreach ($o in (Format-HexValue $name $r.Bytes)) { $outLines.Add($o) }
                }
                continue
            }
        }
        foreach ($u in $unit) { $outLines.Add($u) }   # verbatim
        continue
    }
    $outLines.Add($ln); $i++   # blank / header / misc
}

# ---------- write output (UTF-16LE + BOM, CRLF) ----------
$utf16Bom = New-Object System.Text.UnicodeEncoding($false, $true)
[System.IO.File]::WriteAllText($OutReg, (($outLines -join "`r`n")), $utf16Bom)

Write-Host "==== Build-PrunedReg : transforms applied ===="
$applied | ForEach-Object { Write-Host "  $_" }
Write-Host ""
Write-Host "Output: $OutReg"
Write-Host ("Lines: input=$($phys.Count) output=$($outLines.Count)")
