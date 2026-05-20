# Fabriq BackUper - 仕様書（v0.1 初期構想）

## 概要

**Fabriq BackUper** は、Fabriq フレームワークの satellite app として動作する
**Windows ユーザデータ・プリンタ環境のバックアップ／リストア専業ツール**。

- 親プロジェクト: Fabriq v3.4+（Windows PC キッティングフレームワーク）
- 配置: `apps/fabriq_backuper/` 配下
- 言語: PowerShell 5.1
- Operator-facing entry: `Fabriq_BackUper.exe`（fabriq root、~57 KB C# wrapper）
- 依存: Fabriq kernel 公開 API §1〜§5（KERNEL_API.md）
- Min Kernel API: 2.0.0

## 設計思想

### 三本柱

1. **fabriq とは疎結合**
   - kernel/common.ps1 を dot-source して公開 API のみ利用
   - hostlist.csv を read-only で消費
   - fabriq session（profile 実行、resume_state.json 等）には一切干渉しない

2. **FabriqIOS と同型の satellite パターン**
   - apps/ 配下の self-contained sub-project
   - Self-spawning subprocess pattern（global state 汚染回避）
   - Independent VERSION（kernel と独立した SemVer）
   - Defensive log-output suppression

3. **将来の backup モジュール統合のハブ**
   - printer_backup + userdata_backup を section として吸収
   - Plug-in 設計：`lib/sections/<name>/` に新 section を drop 可能
   - Aggregate manifest で section 横断の単一スナップショット

## 配置とディレクトリ構造

```
e:\fabriq\
  Fabriq_BackUper.exe                    ← C# launcher (operator-facing entry)
  apps\
    fabriq_backuper\
      fabriq_backuper.ps1                ← internal entry (self-spawning)
      README.md
      SPEC.md (このファイル)
      VERSION                             ← 独立 SemVer
      data\
        sections.csv                      ← 登録 section 一覧
        userdata_list.csv                 ← userdata section 用の対象一覧
        printer_config.csv                ← printer section 用の設定
        restore_config.csv                ← 共通 restore overrides
      lib\
        engine.ps1                        ← orchestrator
        hostlist_reader.ps1               ← fabriq hostlist の復号読み取り
        manifest_aggregator.ps1           ← 集約 manifest 生成
        ui\
          host_selector.ps1               ← OldPCname dropdown
          section_selector.ps1            ← 実行 section 選択 UI
          progress_view.ps1               ← 進捗表示（Phase 3）
        sections\
          printer\
            backup.ps1
            restore.ps1
          userdata\
            backup.ps1
            restore.ps1
      Backup\                            ← 出力先（framework overlay 除外要、Phase 3）
        <OldPCname>\
          <yyyy_MM_dd_HHmmss>\
            manifest.json                 ← fabriq-backuper-snapshot v1
            sections\
              printer\
                manifest.json             ← fabriq-printer-backup v1（個別）
                drivers/, printsettings/, ...
              userdata\
                manifest.json             ← fabriq-userdata-backup v1（個別）
                entries/01/data/, ...
            _execution_log.txt            ← 全 section 実行の合算ログ
            _restore_notes.txt
      tests\

  dev\launcher\
    Launcher_BackUper.cs                 ← C# launcher source
    app_backuper.manifest                 ← UAC requireAdministrator
    build_backuper.ps1                    ← csc.exe を呼ぶビルドスクリプト
```

## 起動経路（EXE 単独）

operator-facing は `Fabriq_BackUper.exe` 一系統のみ。FabriqApps ダイアログ
からは除外（`fabriq_ios` と同様）。

| 経路 | 用途 | 想定 |
|---|---|---|
| `Fabriq_BackUper.exe` (ダブルクリック) | Operator | 既定 |
| `Fabriq_BackUper.exe` (ショートカット / タスクスケジューラ) | 自動化 | OK |
| `powershell.exe -File apps\fabriq_backuper\fabriq_backuper.ps1` | 内部 / 検証 | 案内しない |
| Dashboard FabriqApps から起動 | **使わない** | `apps_dialog.ps1` の exclusion list に `fabriq_backuper` を追加 |

EXE → ps1 → self-spawning subprocess の 3 段経由で、どの経路でも最終的に
独立 subprocess に収束する（FabriqIOS 同型）。

## fabriq との結合点

| 結合点 | 種類 | 仕組み |
|---|---|---|
| `kernel/common.ps1` 公開関数 (§1) | PowerShell dot-source | `. (Join-Path $script:FabriqRoot 'kernel\common.ps1')` |
| `kernel/common.ps1` 公開グローバル (§2) | 読み取り/書き込み | `$global:FabriqMasterPassphrase` をセットして hostlist 復号 |
| `kernel/csv/hostlist.csv` | CSV ファイル read | `Import-ModuleCsv` 経由（自動復号） |
| `kernel/txt/passphrase_verify.txt` | ファイル read | `Test-MasterPassphrase` の検証トークン |
| KERNEL_VERSION | ファイル read | manifest に記録 |

**触らないもの:**
- profiles/, modules/, kernel/json/（resume_state 等）, logs/, evidence/
- fabriq の execution history / status monitor / evidence pipeline

## マスターパスフレーズ運用

FabriqIOS の [enable_disable.ps1](../fabriq_ios/lib/commands/enable_disable.ps1) と
同じ idiom を踏襲。

```powershell
# 起動時に prompt
$secure = Read-Host -Prompt 'Fabriq Master Passphrase' -AsSecureString
$plain  = [System.Net.NetworkCredential]::new('', $secure).Password

# kernel が用意した検証トークンで突合
$verifyPath = Join-Path $script:FabriqRoot 'kernel\txt\passphrase_verify.txt'
if (-not (Test-MasterPassphrase -Passphrase $plain -VerifyTokenPath $verifyPath)) {
    Show-Error 'Invalid master passphrase'
    return
}

# グローバルにセット → Import-ModuleCsv が ENC: 値を自動復号
$global:FabriqMasterPassphrase = $plain
```

セキュリティ:
- パスフレーズは subprocess の memory にのみ滞在、終了で消失
- manifest.json 等の output ファイルには **絶対に書かない**（ENC: 値ですら）
- 親 process が fabriq dashboard でセッション中なら、起動済みの
  `$env:SELECTED_OLD_PCNAME` を継承（パスフレーズ再入力をスキップ可）

## ホスト選択 (`SELECTED_OLD_PCNAME` 解決)

| 起動コンテキスト | 挙動 |
|---|---|
| `$env:SELECTED_OLD_PCNAME` がセット済み（fabriq 親 session 由来） | パスフレーズ入力スキップ、ホスト selector もスキップ、即 backup/restore メニュー |
| 未セット（standalone 起動） | パスフレーズ入力 → hostlist 復号 → 内蔵 host selector で OldPCname 選択 → 環境変数セット |

## Section 契約

新 section を追加できる plug-in interface（FabriqBackUper internal contract）。

**ディレクトリ規約:**
```
lib/sections/<section_name>/
  backup.ps1   ← 必須
  restore.ps1  ← 必須
  (任意のヘルパー .ps1 / data CSV / 等)
```

**Backup script の入出力契約:**

```powershell
# 入力（engine が dot-source 後に呼ぶ）:
#   $SectionOutputDir : "<BackupRoot>/<OldPCname>/<ts>/sections/<section>/"
#   $OldPcName        : string
#   $SectionDataDir   : "apps/fabriq_backuper/data/" （section が必要なら参照）
#   $script:FabriqRoot: fabriq root（共通 API 経由なら不要）

# 出力:
#   $SectionOutputDir 配下に manifest.json + データ
#   Console に [SUCCESS] / [WARNING] / [ERROR] ログ（kernel common.ps1 経由）
#   return: PSCustomObject @{
#       Status     = 'Success' | 'Partial' | 'Failed' | 'Skipped'
#       ElapsedMs  = [int]
#       Summary    = [ordered]@{ ... }  # section 固有
#       Warnings   = @(...)
#   }
```

**Restore script の入出力契約:**

```powershell
# 入力:
#   $SectionInputDir : "<BackupRoot>/<OldPCname>/<ts>/sections/<section>/"
#   $OldPcName       : string
#   $RestoreOptions  : PSCustomObject (restore_config.csv から派生)

# 出力:
#   Console ログ
#   return: PSCustomObject @{ Status; ElapsedMs; Summary; Warnings }
```

**sections.csv (registry):**
```csv
Enabled,SectionName,DisplayName,Description
1,printer,Printer Environment,Drivers / ports / print settings
1,userdata,User Data,Files and directories
0,future_section,(未実装),(placeholder)
```

## Manifest スキーマ (`fabriq-backuper-snapshot` schemaVersion=1)

```json
{
  "schemaVersion": 1,
  "manifestType": "fabriq-backuper-snapshot",
  "backuperVersion": "0.1.0",
  "fabriqKernelVersion": "3.4.0",
  "collectedAt": "2026-05-14T...",
  "oldPcName": "PC-001",
  "computerName": "DESKTOP-ABCD",
  "hardwareUniqueId": "...",
  "osVersion": "10.0.26200.0",
  "osArch": "amd64",
  "sections": {
    "printer": {
      "enabled": true,
      "status": "Success",
      "elapsedMs": 12345,
      "manifestPath": "sections/printer/manifest.json",
      "summary": { "printers": 12, "drivers": 6, "totalBytes": 256720327 }
    },
    "userdata": {
      "enabled": true,
      "status": "Partial",
      "elapsedMs": 67890,
      "manifestPath": "sections/userdata/manifest.json",
      "summary": { "entries": 5, "files": 1234, "totalBytes": 5000000000 }
    }
  },
  "summary": {
    "sectionCount": 2,
    "successCount": 1,
    "partialCount": 1,
    "failedCount": 0,
    "totalBytes": 5256720327
  },
  "warnings": []
}
```

各 section 内の `manifestPath` で示される個別 manifest は、現行
`fabriq-printer-backup` / `fabriq-userdata-backup` の schema をそのまま使用。
集約 manifest は section への pointer + summary のみ持つ。

将来の `kernel/BACKUPER_SNAPSHOT_MANIFEST.md` で外部 consumer 向け公開契約化
予定（Phase 3）。

## Backup Workflow

```
1. Fabriq_BackUper.exe 起動
2. fabriq_backuper.ps1（self-spawning subprocess）
3. kernel/common.ps1 dot-source
4. パスフレーズ入力 → Test-MasterPassphrase（既にセット済みなら skip）
5. ホスト選択 UI（$env:SELECTED_OLD_PCNAME 既セット時は skip）
6. Section selector UI（sections.csv ベース、operator がチェック）
7. Engine が enabled section を順次実行:
     - SectionOutputDir = Backup/<OldPCname>/<ts>/sections/<name>/
     - section の backup.ps1 を dot-source / & 呼び出し
     - 戻り値を集約
8. manifest_aggregator.ps1 が集約 manifest 生成
9. _execution_log.txt / _restore_notes.txt 書き出し
10. 結果 UI 表示
```

## Restore Workflow

```
1. Fabriq_BackUper.exe 起動（"Restore" モード選択）
2. kernel/common.ps1 dot-source
3. パスフレーズ入力（必要なら）
4. ホスト選択 → OldPCname
5. Backup/<OldPCname>/ 配下を走査、timestamp 一覧表示 → operator 選択
   （未指定時は最新を auto-select）
6. 選択 manifest を validate（schemaVersion / manifestType）
7. Section selector UI（manifest.sections から enabled なものを既定 checked）
8. Engine が enabled section を順次実行:
     - SectionInputDir = Backup/<OldPCname>/<ts>/sections/<name>/
     - section の restore.ps1 を呼び出し
9. 結果 UI 表示
```

## UI 構成

Phase 1 PoC: Console + 簡易メニュー（fabriq main の `Build-CategoryMenu` 流儀）

Phase 3: WinForms（fabriq_operator の dark theme 流用）
- Mode 選択: Backup / Restore
- ホスト selector: OldPCname dropdown（hostlist 復号後）
- Section selector: チェックボックス（sections.csv ベース）
- 進捗 panel: section ごとの状態 + spinner
- 結果 panel: success / partial / failed カウント + warnings

## 既存 fabriq modules との関係

| Phase | `modules/extended/printer_backup` | `modules/extended/userdata_backup` | FabriqBackUper |
|---|---|---|---|
| Phase 1 PoC | 残置・並走 | 残置・並走 | wrapper 経由で呼び出す |
| Phase 2 sections 内製化 | 残置・並走 | 残置・並走 | sections/printer, sections/userdata を内製化 |
| Phase 3 UI 強化 | **Deprecated 明記** | **Deprecated 明記** | β-stable maturity |
| Phase 4 stable | **削除** | **削除** | 唯一の backup/restore 経路 |

Phase 1〜2 中は operator が好きな方を選べる過渡期。CHANGELOG / Guide で
"FabriqBackUper への移行を推奨" を明記。

## 段階的ロードマップ

### Phase 0: 設計確定（このドキュメントで完了）
- アーキ・契約・配置の合意
- SPEC.md / README.md の存在
- メモリ保存（project_fabriq_backuper_plan.md）

### Phase 1: PoC (最小実装)
- `apps/fabriq_backuper/` scaffold（FabriqIOS から boilerplate copy）
- self-spawning subprocess + kernel dot-source
- hostlist_reader + host selector UI（Console 簡易）
- sections/printer/backup.ps1, restore.ps1 = 既存 modules を **& 呼び出す wrapper**
- 同 userdata
- manifest_aggregator で集約 manifest 生成
- `dev/launcher/Launcher_BackUper.cs` + `build_backuper.ps1` + `Fabriq_BackUper.exe` ビルド
- `apps/fabriq_operator/lib/apps_dialog.ps1` の exclusion list に `fabriq_backuper` 追加

完了基準: 1 ホスト分の backup + restore が EXE 起動経由で動く

### Phase 2: sections 内製化
- modules/extended/printer_backup のロジックを `sections/printer/` に正式移植
- 同 userdata
- 既存 modules は Deprecated 化前の最終バージョンを保持（並走運用）
- sections.csv の整備、新 section 追加 doc

完了基準: 既存 modules を呼ばずに backup/restore 完結

### Phase 3: UI 強化 + 契約公開化
- WinForms UI（fabriq dark theme）
- 進捗表示、結果サマリ
- `kernel/BACKUPER_SNAPSHOT_MANIFEST.md` 公開契約 docs
- `dev/framework_overlay_rules.json` を拡張し
  `apps/fabriq_backuper/Backup/` を overlay 対象外に
- README / CHANGELOG で modules 側を Deprecated 明示

### Phase 4: stable
- 既存 modules（printer_backup / userdata_backup）を削除
- β-stable maturity 宣言

## セキュリティと注意事項

| 項目 | 対応 |
|---|---|
| パスフレーズの memory 滞在 | subprocess のみ、終了で消失 |
| manifest / log への秘密漏洩 | manifest / log には **平文も ENC: 値も書かない** |
| Backup ディレクトリの ACL | Phase 3 で restrictive ACL を検討（現状 default operator 権限） |
| 平文データの保管 | Backup/<OldPCname>/.../data/ には対象ファイルが平文で保存される（backup の本質） |
| robocopy /B backup mode | admin 権限必須（locked file 読み取り対応） |
| Cross-PC restore の SID 不整合 | userdata の IncludeAcl=1 で警告（既存 module と同じ挙動） |
| Driver private DEVMODE 復元 | printer section の既知制約（driver version match 推奨） |

## 将来の検討事項

- **framework overlay 除外**: `apps/fabriq_backuper/Backup/` を patch overlay
  対象外にする `dev/framework_overlay_rules.json` 拡張。schemaVersion bump
  候補（Phase 3）
- **増分バックアップ**: 現行は full only。robocopy `/MIR` + 差分 timestamp で
  対応余地あり（必要性が出てから）
- **スケジューラ統合**: タスクスケジューラから `Fabriq_BackUper.exe` を呼ぶ
  非対話モード（要件次第）
- **外部退避**: backup フォルダを外付け HDD / ネットワーク共有に書く設定
  オプション（要件次第）
- **増設可能な section**: app_settings_backup（ブラウザ profile / IME 辞書等）、
  network_config_backup 等の plug-in 候補
