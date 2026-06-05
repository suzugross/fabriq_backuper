# 開発コンテキスト: Fabriq BackUper (独立 satellite)

あなたは現在、Windows ユーザデータ・プリンタ環境のバックアップ／リストア専業
satellite app「Fabriq BackUper」の開発を行っています。本 repo は 2026-05-20 に
fabriq main (`e:\fabriq\apps\fabriq_backuper\`) から分離独立したもので、
fabriq_checksheet と同形 (code-detached + runtime-data-hybrid) のパターンを採用します。

## 設計思想

- fabriq main の `kernel/common.ps1` には**依存しない** — 必要な関数は `backuper/common.ps1`
  に vendoring 済み
- ランタイムでは fabriq main の `kernel/csv/hostlist.csv` / `kernel/txt/passphrase_verify.txt` /
  `kernel/KERNEL_VERSION` を **read-only で参照**する
- fabriq main の所在は `Find-FabriqRoot` による auto-discovery (兄弟ディレクトリから
  「名前に fabriq を含む + kernel\csv\hostlist.csv を持つ」を探索)
- fabriq の resource は**読み取りのみ**、書き込みは一切禁止

## 絶対遵守事項（クリティカル・ルール）

### 1. Fabriq リソースへの書き込み禁止

- `kernel/csv/hostlist.csv`, `kernel/csv/workers.csv`, `kernel/csv/log_destinations.csv`,
  `kernel/txt/passphrase_verify.txt`, `kernel/KERNEL_VERSION` は**読み取りのみ**
- fabriq 側の他ディレクトリ (`kernel/json/`, `evidence/`, `logs/`, `modules/`,
  `apps/` 等) には一切触れない

### 2. `backuper/common.ps1` の関数体系

- 本ファイルは fabriq の `kernel/common.ps1` および fabriq_checksheet の
  `checksheet/common.ps1` から必要な関数を**転記**したものである（依存ではなくコピー）
- 転記元の関数シグネチャ・ロジックを勝手に改変しないこと
- 独自のログ出力（`Write-Host` 等）を直接記述せず、必ず `Show-Info` / `Show-Error` /
  `Show-Success` / `Show-Warning` / `Show-Skip` / `Show-Separator` を使用すること
- 新規関数を追加する前に、`common.ps1` の既存関数と重複がないか確認すること

### 3. fabriq 既存パターンの踏襲

- WinForms UI は fabriq_checksheet の `checksheet/lib/` 群のパターンを参考にすること
- アクセントカラーは **lavender `#9366BD`** (hover `#7F52A6`)、light gray base は
  fabriq main と共通の CentreCOM 風テーマを維持
- 関数名は **PowerShell Approved Verbs** のみ (`Get-Verb` で一覧確認可能)

### 4. 段階的な実装と検証

- いきなりコード全体を書き始めないこと
- まず概要レベルで方針を提示し、承認を得てからコーディングに移ること
- 実装コードと共に、検証手順（テスト方法）を必ず提示すること

### 5. PowerShell スクリプトのエンコーディング規約

| 対象 | エンコーディング | 理由 |
|------|-----------------|------|
| PowerShell スクリプト (*.ps1) | **UTF-8 with BOM** | PS5.1 が BOM なし UTF-8 の日本語を ANSI として誤解釈する |
| CSV ファイル (*.csv) | **UTF-8 with BOM** + CRLF | hostlist.csv (fabriq 共有) の規約に合わせる |
| JSON 読み書き | UTF-8 (BOM 不要) | `ConvertTo-Json` / `ConvertFrom-Json` は UTF-8 前提 |
| ドキュメント (*.md) | UTF-8 (BOM 任意) | GitHub / VSCode 共に自動判別 |

### 6. UI 文言の言語ポリシー

- **コードコメント / Show-Info 系コンソール出力 / Write-Host / manifest field 値**: 英語
  (fabriq main / sections の規約に合わせる、過去の `feedback_scripts_english_only` 準拠)
- **WinForms UI 上の label / button / dialog title**: **日本語可** (operator が現場で
  読む UI 表記なので日本語が自然、fabriq_checksheet も同じ方針)
- 日本語を含む .ps1 は **UTF-8 with BOM 必須** (規約 5 に同じ)

## バージョン管理ルール

- VERSION は fabriq main の kernel と**完全に独立**した SemVer
- 修正ごとに `CHANGELOG.md` の `[Unreleased]` セクションに追記
- カテゴリ: `Added` / `Changed` / `Deprecated` / `Removed` / `Fixed` / `Security`
- 行頭のコンポーネントプレフィックスは `backuper:` を使用 (fabriq main の
  `apps/fabriq_backuper:` から短縮)

### 影響判定 (SemVer)

| 影響 | 昇格 | 例 |
|---|---|---|
| **MAJOR** (X+1.0.0) | manifest schema 破壊的変更 / section interface 破壊 | manifest.json の必須 field 削除・改名 / section script の `$FabriqRoot` パラメータ削除 |
| **MINOR** (X.Y+1.0) | 後方互換な機能追加 | 新 section 追加 / manifest に新 optional field 追加 |
| **PATCH** (X.Y.Z+1) | バグ修正・内部改良 | binding strip 漏れ修正 / UI 文言改善 |

## 実装前の事前宣言（必須）

カーネル相当の `backuper/common.ps1` または section script を修正する前に、
実装開始前のメッセージで以下を宣言する:

```
【変更スコープ宣言】
- 対象: backuper/common.ps1 / backuper/lib/sections/<name> / etc
- 影響: 既存動作への影響説明
- 予想バージョン影響: vN.N.N → vN.N.N (MAJOR / MINOR / PATCH)
- 検証方法: ...
```

## 実装サマリでの最終報告（必須）

実装完了報告に以下を含める:

```
【バージョン影響サマリ】
- backuper VERSION : vN.N.N → vN.N.N (種別 / 理由)
- 配備方針 : E:\fabriq_backuper\ を customer 端末に再配置 / etc
- 検証実施: ...
```

<!-- TM:BEGIN -->
## タスク管理（TM 連携）

このプロジェクトのタスクは、リポジトリ直下の `.tm/tasks.json` で管理されています
（デスクトップアプリ「TM」と共用。人間も Claude も同じファイルを編集します）。
作業の際は次に従ってください。

- **着手前**: `.tm/tasks.json` を読み、未完了タスク（status が「完了」以外）を確認する。
  `.tm/TASKS.md` は人間向けの読みやすいビュー（自動生成・**編集禁止**）。
- **進捗の記録**: 担当したタスクの `claudeNote` に、調査結果・実装方針・気づきを追記する（あなたの作業ログ欄）。
- **状況の更新**: `status` を更新する。許可値は「未着手」「対応中」「レビュー待ち」「完了」「保留」。
- **タスク追加**: `tasks` 配列に要素を追加する。`id` は既存と重複しない一意な文字列（例: `t-0007`）。
- 値を変えたら、そのタスクと（ルートの）`updatedAt` を現在時刻（ISO 8601）に更新する。
- `.tm/TASKS.md` は手で編集しない（TM アプリが tasks.json から再生成する）。

### スキーマ（.tm/tasks.json）

```json
{
  "schemaVersion": 1,
  "project": "fabriq_backuper",
  "updatedAt": "2026-06-05T18:30:00+09:00",
  "tasks": [
    {
      "id": "t-0001",
      "title": "タイトル",
      "content": "詳細な内容（複数行可）",
      "claudeNote": "Claude の作業メモ（複数行可）",
      "status": "対応中",
      "createdAt": "2026-06-05T18:30:00+09:00",
      "updatedAt": "2026-06-05T18:30:00+09:00"
    }
  ]
}
```
<!-- TM:END -->
