# dev/profile-generator/ — Profile スクリプト生成 実験

**ステータス: PoC (実験段階)。本番組み込み前提ではありません。**

「キャプチャした `.reg` をテンプレートとして、script ベースで新規プロファイル
を動的生成できるか」を検証するための実験用ツールです。

## 背景

現状の Strategy B-light (`backuper/lib/sections/outlook_pop/restore.ps1`) は:
- ソース PC の `.reg` をキャプチャ
- T1〜T6 のヒューリスティック変換で source-binding を strip / rewrite
- `reg.exe import` で target PC に適用

という流れですが、以下の問題があります:

1. **PST マッピング失敗** (Phase 1 PoC で既に修正済み)
2. **MAPIUID / Service UID のクロスリファレンスが脆い** (Phase 2.12 の苦闘の歴史)
3. **月次 Outlook 更新で T1-T6 が壊れるリスク**

本実験では、**UID rotation アプローチ** で問題 2-3 を構造的に解消できるかを検証します。

## アプローチ: UID Rotation

ソース PC の `.reg` を**テンプレート**として活用するが、以下を実施:

| 操作 | 対象 | 目的 |
|---|---|---|
| **UID Rotation** | per-profile MAPIUID (22 個) | source PC 固有のバインディングを除去し、target PC で fresh な ID として認識させる |
| **Well-known 保持** | MAPI 標準定数 (6 個) | MapiSvc.inf 由来の GUID は profile を跨いで同一なので保持 |
| **User Path Rewrite** | `\Users\<src>\` パターン | 旧ユーザ名 → 新ユーザ名 (UTF-16LE 内も含めて置換) |
| **EntryID Strip** | `Delivery Store EntryID` 等 | machine-bound binary を削除し Outlook に regenerate させる |

### Well-known MAPI 定数 (rotation 対象外)
以下は **profile を跨いで同一の GUID** であり、保持が必須:
```
0a0d020000000000c000000000000046  - MAPI Section Provider
8503020000000000c000000000000046  - MAPI Service Provider
13dbb0c8aa05101a9bb000aa002fc45a  - Personal Folders (MSPST)
9207f3e0a3b11019908b08002b2a56c2  - MS Outlook Address Book
f86ed2903a4a11cfb57e524153480001  - 別 MS provider
9375CFF0413111d3B88A00104B2A6676  - Internet Account section
```

### 重要な実装上の判断: UID 検出は subkey 名のみ
値内の任意の 16-byte 列は **MAPI バイナリ構造内の偶然の一致**である可能性が高い (例: `4d005300550050005300540020004d00` = `"MSUPST M"` の UTF-16LE)。
これらを誤って rotation すると registry が破損します。

そのため**UID 検出は subkey 名 (`\[0-9a-f]{32}\]` パターン) のみ**から行い、
検出した UID の byte sequence を後段で値内も含めて置換します。これにより
false positive を排除しつつ、cross-reference (Service UID / Preferences UID 等) も
正しく追従します。

## 使い方

```powershell
.\dev\profile-generator\Build-ProfileFromTemplate.ps1 `
    -TemplateReg "E:\test\outlookbktest\2026_05_21\2026_05_21_184156\sections\outlook_pop\profile_Outlook.reg" `
    -OutputReg   "E:\test\generated_profile.reg" `
    -SourceUser  "K_iuchi" `
    -TargetUser  "test_user" `
    -VerboseOutput
```

実行すると以下が出力されます:
- `<OutputReg>` のパスに新しい `.reg` ファイル (UTF-16LE BOM 付き)
- 標準出力に rotation / preserve / 置換回数のログ

## 実験フェーズ (推奨実施順)

### Phase 1: アルゴリズム検証 (オフライン、完了済み)
- Perl による独立実装で rotation ロジックを検証
- テストフィクスチャに対して:
  - 22 件の per-profile UID 検出
  - 22 件の subkey 名置換
  - 34 件の cross-reference 値置換
  - 23 件のユーザパス UTF-16LE 置換
  - 旧 UID の残存ゼロ ✓
  - 6 件の well-known 定数すべて保持 ✓

### Phase 2: 出力 .reg の構文検証 (操作者実施)
1. 上記コマンドで `.reg` を生成
2. 適当なテキストエディタ (UTF-16LE 対応) で開いて目視確認
   - subkey 名が全て fresh な GUID に置き換わっていること
   - `\Users\test_user\` のような置換が適用されていること
   - `Delivery Store EntryID` 等の行が消えていること
   - `[HKEY_CURRENT_USER\Software\Microsoft\Office\16.0\Outlook\Profiles\Outlook]` という root は維持されていること

### Phase 3: 実機 import 試験 (操作者実施、最重要)

**前提準備 (必ず実施)**:
- TEST 用 Windows ユーザでログイン (本番ユーザでは絶対に試行しない)
- 既存の Outlook profile を削除:
  - Control Panel > Mail > Show Profiles > Remove
- `Documents\Outlook ファイル\` 配下に PST ファイルを準備
  - `Build-ProfileFromTemplate.ps1` 出力時には `\Users\test_user\Documents\Outlook ファイル\<email>.pst` が想定パス
  - 実際の PST ファイルを上記パスに配置

**実行**:
```powershell
reg.exe import "E:\test\generated_profile.reg"
```

**検証項目**:

| # | 検証内容 | 期待結果 | 失敗時の意味 |
|---|---|---|---|
| 1 | Outlook を起動 | プロファイル選択画面で "Outlook" が表示 | rotation 後の subkey 構造が壊れている |
| 2 | "Outlook" を選択して開く | エラーなく起動 | UID cross-reference の不整合 |
| 3 | "ファイル > アカウント設定 > アカウント設定" | 4 つの POP3 アカウントが表示 | account subkey の subkey 構造異常 |
| 4 | 各 POP3 アカウントの「変更」を確認 | サーバ名 / ユーザ名 / ポート設定が表示 | account value の損失 |
| 5 | "データファイル" タブで PST 確認 | 4 つの PST がマウントされている | path rewrite 失敗 / PST ファイル不在 |
| 6 | 一つのアカウントで送受信 | パスワード入力プロンプト後、送受信成功 | サーバ設定不整合 |

### Phase 4: 失敗パターンの診断 (もし失敗したら)

| エラー | 原因の可能性 | 次に試すこと |
|---|---|---|
| `Cannot open this folder set` | UID rotation の漏れ / 余分 | well-known 定数リストを見直す。または rotation を保守的に (少数だけ) して二分探索 |
| profile は開くがアカウントが表示されない | account subkey の値が消えた | EntryID strip で削りすぎていないか確認 |
| アカウントは見えるが PST 未アタッチ | path rewrite 失敗 / PST 実体ファイル不在 | `\Users\test_user\Documents\Outlook ファイル\<email>.pst` の物理ファイル有無を確認 |
| 「PR_STORE_PROVIDERS が見つからない」 | MAPI Section Provider (`0a0d0200...`) が壊れた | 該当 subkey の内容を template と diff |
| 起動時に Outlook がクラッシュ | binary 内に意図せず rotation が適用された | false positive 検出ロジックを見直し、より保守的に |

## 制約・既知の限界

### 1. IMAP は依然として制約あり
- IMAP 新規アカウント作成は `IOLkAccountMgr` の未文書化部分に依存
- Redemption も IMAP は modify/delete のみで作成不可
- 本ツールは template に IMAP アカウントが含まれていれば rotation するが、
  サーバ側のフォルダ同期メタデータが target PC で valid になるかは未検証

### 2. パスワードは移行不可
- DPAPI 暗号化のため、どの手法を使っても PC を跨ぐと復号不可
- 初回送受信時に operator が手動入力

### 3. 月次 Outlook 更新で壊れる可能性
- Outlook が新しいプロパティを追加した場合、template に含まれない値が必要になる可能性
- Microsoft 公式仕様ではないため、長期的なメンテ責任は self

### 4. 同名 profile が既存だと衝突
- import 前に既存 profile を削除する必要あり
- `-NewProfileName` パラメータで別名にして衝突回避も可能

### 5. 4-byte UID (例: Mini UID) は rotation 対象外
- 本実装では 16-byte UID (subkey 名と一致) のみ rotation
- Mini UID (4 byte DWORD) や Service UID 値内の同一表現は別途検討

## ファイル構成

```
dev/profile-generator/
├── README.md                          ← 本ファイル
└── Build-ProfileFromTemplate.ps1      ← PoC スクリプト本体 (~500 行)
```

## Phase 2 への port を検討する条件

実機 import で **Phase 3 の検証項目 1〜5 をクリア**したら、本ロジックを
`backuper/lib/sections/outlook_pop/restore.ps1` の Strategy B-light を置換する
新 strategy として組み込む価値があります。

逆に Phase 3 のいずれかで詰まる場合は、原因を特定して本実験を更新する必要があります。
詰まったポイントが「UID rotation 自体」なのか「特定の MAPI 構造の rewrite 漏れ」なのか
を切り分ければ、現実的な実装範囲が見えてきます。
