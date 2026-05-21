# ============================================================
# Build-ProfileFromTemplate.ps1
# ----------------------------------------------------------------
# 実験スクリプト (Phase 2 PoC):
# 「キャプチャ済み .reg をテンプレートとして新規プロファイル
#  registry を script ベースで動的生成できるか」を検証する。
#
# 戦略:
#   - 既存 .reg (例: ソース PC でキャプチャしたもの) を
#     雛形として読み込む
#   - per-profile UID (16 byte の MAPIUID で profile ごとに
#     一意なもの) を全部新しい GUID に rotation
#   - well-known MAPI 定数 (MapiSvc.inf 由来など、profile を
#     跨いで同一の GUID) は preserve
#   - 古いユーザのファイルパスを新ユーザのパスに rewrite
#   - "Delivery Store EntryID" 等の machine-bound binary は
#     strip して Outlook に regenerate させる
#
# 期待される動作:
#   - 出力 .reg を target PC に import すると、source PC と
#     同じアカウント構成 (POP3 サーバ / SMTP サーバ / PST バインド)
#     の profile が新規に作成される
#   - パスワードは DPAPI 制約により初回送受信時に手動入力
#
# 注意事項:
#   - これは実験的な PoC。本番には組み込まない
#   - 必ず TEST 用 Windows ユーザで試行すること
#   - import 前に target PC で既存 Outlook profile を完全削除
#     しておくこと (上書きで profile が壊れる可能性)
# ============================================================

[CmdletBinding()]
param(
    # キャプチャ済み .reg ファイルへのパス (例: backup の
    # sections/outlook_pop/profile_Outlook.reg)
    [Parameter(Mandatory = $true)]
    [string]$TemplateReg,

    # 出力先の .reg ファイルパス
    [Parameter(Mandatory = $true)]
    [string]$OutputReg,

    # 移行元 PC のユーザ名 (.reg 内に登場する旧ユーザ名)
    [Parameter(Mandatory = $true)]
    [string]$SourceUser,

    # 移行先 PC のユーザ名 (新規プロファイルが配置されるユーザ)
    [Parameter(Mandatory = $true)]
    [string]$TargetUser,

    # 新プロファイル名。$null なら template と同じ名前を維持。
    [string]$NewProfileName = $null,

    # 詳細ログ
    [switch]$VerboseOutput
)

$ErrorActionPreference = 'Stop'

function Write-PgInfo  { param([string]$m) Write-Host "[INFO] $m"  -ForegroundColor Cyan }
function Write-PgOk    { param([string]$m) Write-Host "[OK]   $m"  -ForegroundColor Green }
function Write-PgWarn  { param([string]$m) Write-Host "[WARN] $m"  -ForegroundColor Yellow }

# ============================================================
# 既知の MAPI 定数 (rotation 対象から除外)
# ----------------------------------------------------------------
# これらは MapiSvc.inf 由来 / MAPI 標準 / OLE 標準で、
# どの PC でも同一の GUID。書き換えると profile が壊れる。
# ============================================================
$KnownConstants = @(
    # MAPI Section Provider (... のための well-known)
    '0a0d020000000000c000000000000046',
    '8503020000000000c000000000000046',
    # Personal Folders (MSPST) provider GUID
    '13dbb0c8aa05101a9bb000aa002fc45a',
    # MS Outlook Address Book provider
    '9207f3e0a3b11019908b08002b2a56c2',
    # 別 MS Address Book / Internet account provider
    'f86ed2903a4a11cfb57e524153480001',
    # Internet Account section (POP3/IMAP/SMTP のコンテナ)
    '9375cff0413111d3b88a00104b2a6676'  # lowercase で比較
) | ForEach-Object { $_.ToLowerInvariant() }

# ============================================================
# .reg ファイルの I/O ヘルパー
# ============================================================
function Read-RegFileRaw {
    # UTF-16LE で .reg を読み、文字列として返す。BOM はそのまま。
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Template .reg not found: $Path"
    }
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::Unicode)
}

function Write-RegFileRaw {
    # UTF-16LE BOM 付きで .reg を書き出す。
    #
    # 注: [System.Text.Encoding]::Unicode は WriteAllText 時に自動的に
    # BOM を emit するので、$Content 側で BOM を持ち込まないようにする
    # (ReadAllText が BOM を保持していた場合の double-BOM 回避)。
    param([string]$Path, [string]$Content)
    if ($Content -notmatch '^﻿?Windows Registry Editor') {
        Write-PgWarn "Output content does not start with the expected header"
    }
    # 先頭 BOM を削除 (WriteAllText が再度付与する)
    if ($Content.Length -gt 0 -and $Content[0] -eq [char]0xFEFF) {
        $Content = $Content.Substring(1)
    }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.Encoding]::Unicode)
}

# ============================================================
# UID 検出 / 分類
# ============================================================
function Get-AllProfileUids {
    # .reg 内の subkey 名としての UID のみを抽出する。
    #
    # 重要: 値内の任意の 16-byte hex 列を「UID」として扱うのは危険。
    # MAPI バイナリプロパティ (例: "MSUPST M" の UTF-16LE 表現
    # 4d,00,53,00,55,00,50,00,53,00,54,00,20,00,4d,00) や
    # EntryID 内の embedded 文字列 (mspst.dll など) と区別できないため、
    # これらを誤って rotation すると registry が破損する。
    #
    # 安全な戦略: subkey 名としての出現 (= 確実に MAPIUID) のみを
    # rotation 候補とし、値内の cross-reference (Service UID 等) は
    # この UID の byte sequence に一致する箇所を後段で置換する。
    #
    # 返り値: ハッシュ。
    #   Key   : 32-char hex (lowercase、カンマなし)
    #   Value : 大文字小文字保持の元 subkey 表記
    param([string]$Content)

    $uids = [ordered]@{}

    $subkeyMatches = [regex]::Matches($Content, '\\([0-9a-fA-F]{32})\]')
    foreach ($m in $subkeyMatches) {
        $key = $m.Groups[1].Value.ToLowerInvariant()
        if (-not $uids.Contains($key)) {
            $uids[$key] = $m.Groups[1].Value
        }
    }

    return $uids
}

function Test-IsRotatableUid {
    # この UID は rotation 対象か?
    # well-known なら除外、それ以外は rotation 候補。
    param([string]$HexNoSeparator)
    $k = $HexNoSeparator.ToLowerInvariant()
    return ($KnownConstants -notcontains $k)
}

function New-MapiUid {
    # 新しい 16 byte ランダム GUID を hex (no separator, lowercase)
    # で返す。
    $g = [System.Guid]::NewGuid()
    $bytes = $g.ToByteArray()
    return (-join ($bytes | ForEach-Object { '{0:x2}' -f $_ }))
}

function ConvertTo-HexCsv {
    # 32-char hex (no separator) -> "xx,xx,...,xx" (lowercase) に変換
    param([string]$HexNoSeparator)
    $parts = for ($i = 0; $i -lt $HexNoSeparator.Length; $i += 2) {
        $HexNoSeparator.Substring($i, 2)
    }
    return ($parts -join ',')
}

# ============================================================
# UID rotation の適用
# ============================================================
function Invoke-UidRotation {
    # $Content 内の per-profile UID を $Map に従って書き換える。
    # 書き換え対象は:
    #   - subkey 名: \<oldhex>]   ->  \<newhex>]
    #   - 値の hex csv: "xx,xx,..." を一括置換
    #     大文字小文字混在に対応 (regex で case-insensitive)
    param(
        [string]$Content,
        [hashtable]$Map   # oldhex(lowercase) -> newhex(lowercase)
    )

    foreach ($oldHex in $Map.Keys) {
        $newHex = $Map[$oldHex]

        # subkey 名の置換 (case-insensitive)
        $Content = [regex]::Replace(
            $Content,
            '\\' + $oldHex + '\]',
            ('\' + $newHex + ']'),
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

        # 値の hex csv (16 byte シーケンス) の置換
        $oldCsv = ConvertTo-HexCsv -HexNoSeparator $oldHex
        $newCsv = ConvertTo-HexCsv -HexNoSeparator $newHex
        $Content = [regex]::Replace(
            $Content,
            [regex]::Escape($oldCsv),
            $newCsv,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }

    return $Content
}

# ============================================================
# user 名の rewrite (パス内)
# ============================================================
function Invoke-UserPathRewrite {
    # ソース user 名を target user 名に置換。次の 2 箇所を対象:
    #
    # 1. プレーン文字列値:
    #    "001f0102"="C:\\Users\\K_iuchi\\..."
    #    .reg の文字列はバックスラッシュが \\ にエスケープされている。
    #
    # 2. hex 値内の UTF-16LE バイト列:
    #    パス値 (001f6700 / 001f6610 / 001f0433 等) は
    #    UTF-16LE で hex 化されている:
    #      K  _  i  u  c  h  i
    #      4B 00 5F 00 69 00 75 00 63 00 68 00 69 00
    #    これを target user の UTF-16LE byte 列に置換。
    #
    # 長さが変わる場合の影響:
    #   - 001f6700 等のプレーンパスは長さ可変なので OK
    #   - 一方 "Delivery Store EntryID" 等の binary blob は
    #     内部に offset table を持つため不可。よって本関数では
    #     EntryID 系は触らず別の strip 関数に任せる。
    param(
        [string]$Content,
        [string]$SourceUser,
        [string]$TargetUser
    )

    if ([string]::IsNullOrWhiteSpace($SourceUser) -or
        [string]::IsNullOrWhiteSpace($TargetUser)) { return $Content }

    if ($SourceUser -ieq $TargetUser) {
        Write-PgInfo "Source user == target user, skipping path rewrite"
        return $Content
    }

    # 1) プレーン文字列値内の置換
    #    \\Users\\<old>\\ の形を \\Users\\<new>\\ に
    $patternPlain = '\\\\Users\\\\' + [regex]::Escape($SourceUser) + '\\\\'
    $replacePlain = '\\Users\\' + $TargetUser + '\\'
    # 注: regex の置換側ではバックスラッシュをそのまま書く
    $Content = [regex]::Replace(
        $Content,
        $patternPlain,
        ('\\Users\\' + $TargetUser + '\\'),
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

    # 2) hex 値内の UTF-16LE バイト列の置換
    #    "\Users\<src>\" の前後を含めた UTF-16LE バイトを構築
    $srcUtf16 = [System.Text.Encoding]::Unicode.GetBytes("\Users\$SourceUser\")
    $dstUtf16 = [System.Text.Encoding]::Unicode.GetBytes("\Users\$TargetUser\")
    $srcCsv = ($srcUtf16 | ForEach-Object { '{0:x2}' -f $_ }) -join ','
    $dstCsv = ($dstUtf16 | ForEach-Object { '{0:x2}' -f $_ }) -join ','

    # 継続行 collapse 後でないと csv が分断されるため、いったん
    # collapse して置換してから戻す。
    $collapsed = $Content -replace '\\\r?\n\s+', ''
    $collapsed = [regex]::Replace(
        $collapsed,
        [regex]::Escape($srcCsv),
        $dstCsv,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

    # collapse 後の content をそのまま戻す (継続行は復元しないが
    # reg.exe import は単一行 hex も受け入れるため問題なし)
    return $collapsed
}

# ============================================================
# EntryID strip (machine-bound binary を削除して Outlook に
# regenerate させる)
# ============================================================
function Invoke-EntryIdStrip {
    # 次の値名を含む行を削除:
    #   "Delivery Store EntryID"
    #   "Delivery Folder EntryID"
    #   "IMAP Store EID"
    # 継続行も一緒に削除する必要があるため、collapse した状態で
    # 行単位で除去する。
    param([string]$Content)

    # collapse 済みであることを想定
    $stripPatterns = @(
        '^"Delivery Store EntryID"=.*$',
        '^"Delivery Folder EntryID"=.*$',
        '^"IMAP Store EID"=.*$'
    )

    $lines = $Content -split '\r?\n'
    $kept = New-Object System.Collections.Generic.List[string]
    $stripped = 0
    foreach ($line in $lines) {
        $skip = $false
        foreach ($pat in $stripPatterns) {
            if ($line -match $pat) { $skip = $true; break }
        }
        if ($skip) { $stripped++; continue }
        $kept.Add($line) | Out-Null
    }
    Write-PgInfo "Stripped $stripped EntryID-bearing lines (Outlook regenerates these on first open)"
    return ($kept -join "`r`n")
}

# ============================================================
# Profile 名の変更
# ============================================================
function Invoke-ProfileRename {
    # subkey [...\Profiles\<old>] と [...\Profiles\<old>\...]
    # を新名前に書き換える
    param([string]$Content, [string]$OldName, [string]$NewName)
    if ([string]::IsNullOrWhiteSpace($NewName) -or $NewName -eq $OldName) {
        return $Content
    }
    $pattern = '\\Profiles\\' + [regex]::Escape($OldName) + '(\\|\])'
    $replace = '\Profiles\' + $NewName + '$1'
    $Content = [regex]::Replace(
        $Content,
        $pattern,
        $replace,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    return $Content
}

# ============================================================
# Main flow
# ============================================================

Write-PgInfo "Template : $TemplateReg"
Write-PgInfo "Output   : $OutputReg"
Write-PgInfo "Source user: $SourceUser  =>  Target user: $TargetUser"
if ($NewProfileName) {
    Write-PgInfo "Profile rename: -> $NewProfileName"
}

$content = Read-RegFileRaw -Path $TemplateReg
Write-PgOk "Template read: $($content.Length) chars"

# --- 1. UID 検出 ---
$allUids = Get-AllProfileUids -Content $content
Write-PgInfo "Detected unique UIDs in template: $($allUids.Count)"

$rotatable = @{}   # oldhex -> newhex
$preserved = New-Object System.Collections.Generic.List[string]
foreach ($k in $allUids.Keys) {
    if (Test-IsRotatableUid -HexNoSeparator $k) {
        $rotatable[$k] = New-MapiUid
        if ($VerboseOutput) {
            Write-Host "  ROTATE  $k -> $($rotatable[$k])"
        }
    } else {
        $preserved.Add($k) | Out-Null
        if ($VerboseOutput) { Write-Host "  PRESERVE $k (well-known MAPI constant)" }
    }
}
Write-PgInfo "  Rotatable: $($rotatable.Count)"
Write-PgInfo "  Preserved (well-known): $($preserved.Count)"

# --- 2. UID rotation 適用 ---
$content = Invoke-UidRotation -Content $content -Map $rotatable
Write-PgOk "UID rotation applied"

# --- 3. user 名 / パス rewrite ---
$content = Invoke-UserPathRewrite -Content $content -SourceUser $SourceUser -TargetUser $TargetUser
Write-PgOk "User path rewrite applied"

# --- 4. Profile 名変更 (optional) ---
if (-not [string]::IsNullOrWhiteSpace($NewProfileName)) {
    # template から元の profile 名を抽出 (最初の subkey)
    if ($content -match '\\Profiles\\([^\\\]]+)') {
        $oldProfileName = $matches[1]
        $content = Invoke-ProfileRename -Content $content -OldName $oldProfileName -NewName $NewProfileName
        Write-PgOk "Profile renamed: $oldProfileName -> $NewProfileName"
    }
}

# --- 5. EntryID strip ---
$content = Invoke-EntryIdStrip -Content $content
Write-PgOk "EntryID strip applied"

# --- 6. 出力 ---
Write-RegFileRaw -Path $OutputReg -Content $content
$outBytes = (Get-Item -LiteralPath $OutputReg).Length
Write-PgOk "Wrote: $OutputReg ($outBytes bytes)"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " 生成完了。次のステップで実機検証してください:" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  1. ターゲット PC で TEST 用 Windows ユーザにログイン"
Write-Host "  2. (重要) 既存の Outlook profile を削除"
Write-Host "     Control Panel > Mail > Show Profiles > Remove"
Write-Host "  3. 生成された .reg を import:"
Write-Host "       reg.exe import `"$OutputReg`""
Write-Host "  4. Outlook を起動"
Write-Host "  5. プロファイルが開けば成功。各アカウントを確認:"
Write-Host "     File > Account Settings > Account Settings"
Write-Host "  6. 各アカウントで初回送受信時にパスワードを入力"
Write-Host ""
Write-Host "失敗パターンと診断:"
Write-Host "  - 'Cannot open this folder set'  -> rotation の漏れ / 余分"
Write-Host "  - profile は開くが PST が attach されない -> path rewrite 失敗"
Write-Host "  - アカウントは見えるがメール送受信エラー -> password 入力後再試行"
Write-Host ""
