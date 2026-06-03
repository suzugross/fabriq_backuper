# Outlook saved-password probe (dev spike)

目的: Fabriq BackUper に「backup 時に保存済み Outlook パスワードを復号して
アカウント設定 (operator handoff) に出力する」機能を実装する前に、**パスワードが
どの形式で保存されているか**を実機で確定するための **読み取り専用**診断スクリプト。

## 確定した事実 (2026-06-03、実バイト解析で確定)

実機 (POP 2件) のレポートから、`POP3 Password` REG_BINARY 値 (273バイト, 先頭
`0x02`) の中身が **標準的な user-scoped DPAPI blob** であることを確認:

```
[00] 02                         ← Outlook の tag バイト
[01] 01 00 00 00                ← DPAPI dwVersion=1
     <provider GUID df9d8cd0-1501-11d1-...>
     <guidMasterKey>
     1c 00 00 00 "POP3 Password" (UTF-16, szDescription)
     0x6610 = CALG_AES_256 / 0x800e = CALG_SHA_512
     salt(32) / hmacKey(32) / ciphertext(64) / signature(64)
```

→ **Credential Manager でも XOR でもなく、`POP3 Password` 値に DPAPI blob が直接
格納**されている。資格情報マネージャーが空でも mailpv が復号できた理由はこれ
(mailpv は `CryptUnprotectData` を呼んでいる。解析仕様 §5.2 の「CredReadA」は崩れた
decompile による誤読)。

**本番への含意**: 復号は **`CryptUnprotectData` を移行元ユーザのセッションで**呼ぶ
必要がある (DPAPI はユーザ束縛)。→ `credentials` セクションと同じ **run-as-source-user
の子プロセス (schtasks /IT)** で、各アカウントの `POP3/IMAP/SMTP Password` 値を読み、
`0x02` を剥がして `CryptUnprotectData` するだけ。Credential Manager マッピングも
mailpv XOR も不要。アカウント紐付けも自明 (blob が各アカウントのサブキー内)。

## このスクリプトがやること

1. mailpv が走査する**全レジストリルートを再帰走査**し、名前に "Password" を含む値を
   **深さ・型に依存せず全件発見**。
2. 各バイナリ値に対し **両方の復号を試行**して成否を報告:
   - **DPAPI** (`CryptUnprotectData`): `0x02` 剥がし (offset=1) と whole (offset=0)。
     `decryptOk` と復号結果 (マスク) + MATCH、`description` を報告。← 現代 Outlook の本命
   - **static-XOR** (鍵 `{0x75,0x18,0x15,0x14}`): 複数オフセット。← 旧 OE / Outlook2002-2010 用
3. `-ExpectedPassword` で**平文を出さずに MATCH/NO-MATCH** を判定。

## 実行コンテキスト

- **Outlook ユーザ本人**で実行 (own HKCU)。**管理者不要**。
- DPAPI 形式は**ユーザセッションでないと復号できない**ので、当該アカウントの所有者で
  実行することが本番経路の証明になる。

## 安全性

- **100% 読み取り専用**。書くのは `-OutPath` の JSON 1 本のみ。
- 復号結果は**既定でマスク**、`*Password*` 生バイトは redact。
- `-ExpectedPassword` に**実パスワードを渡せば、平文を出さずに MATCH** が得られる
  (共有可)。自分の機/VM で中身を見たいときだけ `-RevealPlaintext`。

## 再実行 (確定の最終確認)

自分のアカウントなので、次のどちらかで:

```powershell
cd E:\fabriq_backuper\dev\outlook-pw-probe

# A) 実パスワードを渡して MATCH を確認 (出力は共有可・平文は出ない)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Probe-OutlookPassword.ps1 -ExpectedPassword '<実際のPOPパスワード>'

# B) 自分の機なので平文を見て確認
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Probe-OutlookPassword.ps1 -RevealPlaintext
```

## 確認ポイント (これで本実装に進める)

各 `POP3 Password` finding の `dpapiAttempts` で:

- `offsetStripped=1` の `decryptOk=true` → **DPAPI 復号成功** (0x02 を剥がした blob)
- `description="POP3 Password"` → 期待どおりの DPAPI 記述子
- `-ExpectedPassword` 使用時に `asciiMatch=true` または `utf16Match=true` → **平文一致**、
  かつ ascii/utf16 のどちらが当たったかで **本番のデコード方式が確定**
- `summary.dpapiDecryptOk=true` / `summary.anyDpapiMatch=true`

これらが揃えば、production の復号子スクリプト (移行元ユーザ文脈で `CryptUnprotectData`)
+ handoff 出力の実装に進める。
