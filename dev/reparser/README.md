# dev/reparser/ — Outlook アカウント再解析 PoC

Phase 1 PoC: 既存バックアップの生 `.reg` ファイルから、新パーサーロジックで
アカウント ↔ PST 紐付け情報を再生成するオフラインツールです。

このスクリプトは backup.ps1 / restore.ps1 の本番フローには組み込まれていません。
PoC 用のスタンドアロンツールとして、新パーサーロジックの動作を実バックアップで
検証するためのものです。

## なぜ必要か

`backuper/lib/sections/outlook_pop/backup.ps1` の現行パーサーは Outlook 365
の以下の挙動に対応できていません:

- production `mspst.dll` 形式の `Delivery Store EntryID` から PST パスを抽出
  できない (sample provider 形式しか想定していない)
- 365 で追加された `SMTP Secure Connection` / `Leave on Server` 等の新規値名を
  読みに行っていない
- 複数 PST + 複数アカウントの環境で、ファイル名マッチングを試していない

ただし、バックアップ自体は `reg.exe export` で**プロファイル全体の raw データを
保存している**ため、パーサーを改善すれば既存バックアップから情報を再抽出できます。

本ツールは:
1. 既存バックアップに含まれる `profile_<name>.reg` を読み込み
2. 改善された新パーサーロジックを適用
3. PST 紐付け情報 + アカウント詳細を出力

## 使い方

```powershell
# 単一のバックアップタイムスタンプフォルダを指定して実行
.\dev\reparser\Resolve-OutlookAccountMapping.ps1 `
    -BackupDir "E:\test\outlookbktest\2026_05_21\2026_05_21_184156"
```

実行後、`<BackupDir>\sections\outlook_pop\` 配下に以下のファイルが生成されます:

- `_account_mapping_v2.txt` — operator 向け人間可読版
- `_account_mapping_v2.json` — 機械可読版 (manifest schema v2)

既存の `manifest.json` / `profile_*.reg` / `RESTORE_INSTRUCTIONS.txt` には**一切
変更を加えません** (read-only)。

## アルゴリズム (3 段階フォールバックチェーン)

各アカウントの PST 解決は以下の順に試行:

### Stage 1: ファイル名マッチング (最優先・最高信頼度)
- アカウントの `Email` 値 (REG_SZ) と、プロファイル内 PST ファイルの basename
  (拡張子 `.pst` 除く) を case-insensitive で比較
- 完全一致 → そのアカウントの PST と確定 (信頼度: high)
- Outlook 2010+ の標準命名規則 `<email>.pst` に依存。手動リネーム等されていない
  限り、この段階で 95%+ のケースが解決します。

### Stage 2: EntryID バイナリスキャン (フォールバック)
- `Delivery Store EntryID` のバイト列から UTF-16LE で
  `[A-Z] 00 3A 00 5C 00` (= `X:\`) のパターンを scan
- 見つかった位置から `00 00` (UTF-16LE null) まで読み取り
- 結果が `.pst` で終わる場合採用 (信頼度: medium ~ high)
- production `mspst.dll` 形式・sample EIDMSW 形式どちらにも対応 (format 非依存)

### Stage 3: 単独候補フォールバック
- プロファイル内に PST が 1 つしかない場合は、ambiguity がないのでそれを採用
  (信頼度: medium)

### 失敗時の出力
上記すべてで解決できなかった場合は `path: null` で出力し、`candidates` リストに
全 PST 候補を列挙。operator が手動で紐付けます。

## 追加で抽出する 365 新フィールド

現行 backup.ps1 が見ていない以下のフィールドを追加で取得:

| フィールド名 | 説明 |
|---|---|
| `SMTP Secure Connection` | 0=なし / 1=STARTTLS / 2=SSL/TLS direct |
| `POP3 Secure Connection` | (同上、IMAP 向けも同様) |
| `IMAP Secure Connection` | (同上) |
| `Leave on Server` | POP3 でサーバにメールを残す設定の bit field |

## 検証方法 (この PoC を信頼すべき根拠)

`E:\test\outlookbktest\2026_05_21\2026_05_21_184156` の実バックアップに対して
本スクリプトを実行すると、以下の結果が得られるはずです:

```
=== PST candidates from registry walk: 4 ===
  - C:\Users\K_iuchi\Documents\Outlook ファイル\vpns@e-cri.co.jp.pst
  - C:\Users\K_iuchi\Documents\Outlook ファイル\iuchi@e-cri.co.jp.pst
  - C:\Users\K_iuchi\Documents\Outlook ファイル\ecr-support2@beetech.co.jp.pst
  - C:\Users\K_iuchi\Documents\Outlook ファイル\ecr-support@beetech.co.jp.pst

=== Internet account subkeys found: 9 ===

[Account 00000002] type=pop3 email=iuchi@e-cri.co.jp
  ==> PST: ...\iuchi@e-cri.co.jp.pst   (method: filename-match)

[Account 00000004] type=pop3 email=ecr-support@beetech.co.jp
  ==> PST: ...\ecr-support@beetech.co.jp.pst   (method: filename-match)

[Account 00000006] type=pop3 email=ecr-support2@beetech.co.jp
  ==> PST: ...\ecr-support2@beetech.co.jp.pst   (method: filename-match)

[Account 00000008] type=pop3 email=vpns@e-cri.co.jp
  ==> PST: ...\vpns@e-cri.co.jp.pst   (method: filename-match)

Summary:
  total account subkeys: 4
  PST resolved by filename-match: 4
  PST cross-check agrees: 4
  PST UNRESOLVED: 0
```

このアルゴリズムは Perl による独立実装でも事前検証済みで、PowerShell 版と
完全に同じ結果を返します。

## ファイル構成

```
dev/reparser/
├── README.md                              ← 本ファイル
└── Resolve-OutlookAccountMapping.ps1      ← PoC スクリプト本体
```

## Phase 2 への移行計画

PoC で動作確認できたら、本ロジックを `backuper/lib/sections/outlook_pop/backup.ps1`
に port して、次回以降のバックアップから自動的に新ロジックが使われるようにします。

Phase 1 完了 → Phase 2 (backup.ps1 への移植) の判断材料として、本 PoC の
出力を確認してください。
