# Fabriq BackUper

Windows ユーザデータ・プリンタ・Outlook 環境のバックアップ／リストア専業 satellite app。

- **Operator-facing entry**: `Fabriq_BackUper.exe` (repo root)
- **Internal entry**: `backuper/main.ps1` (dot-sourced by `fabriq_backuper.ps1`)
- **VERSION**: 独立 SemVer (fabriq main の kernel と independent)
- **設計仕様**: 旧 `apps/fabriq_backuper/SPEC.md` を参照 (Stage 3 で本 repo に移植予定)

## 役割

PC キッティングの前後で実施する backup / restore を担う。**fabriq main とは
独立した repo** で、`kernel/common.ps1` には依存せず必要な関数を
`backuper/common.ps1` に vendoring 済み。ランタイムでは fabriq main の
`kernel/csv/hostlist.csv` / `kernel/txt/passphrase_verify.txt` /
`kernel/KERNEL_VERSION` のみ read-only で参照する。

## 起動

```
Fabriq_BackUper.exe をダブルクリック
  ↓
パスフレーズ入力 (styled WinForms dialog)
  ↓
fabriq root auto-discovery (兄弟ディレクトリから検出)
  ↓
ホスト選択 (既セット時は skip)
  ↓
Backup or Restore モード選択
  ↓
section 選択 (printer / userdata / outlook_pop / ...)
  ↓
実行 → 結果表示
```

## バックアップ出力

```
Backup/<OldPCname>/<yyyy_MM_dd_HHmmss>/
  manifest.json                       (fabriq-backuper-snapshot schemaVersion=1)
  sections/
    printer/                          (printer section 出力)
    userdata/                         (userdata section 出力)
    outlook_pop/                      (outlook POP/IMAP 設定 + .reg export)
  _execution_log.txt
```

## ディレクトリ構成

```
E:\fabriq_backuper\
├── CLAUDE.md                            プロジェクトルール
├── README.md                            本ファイル
├── CHANGELOG.md                         Keep a Changelog 1.1.0
├── VERSION                              独立 SemVer (現在 0.13.0)
├── Fabriq_BackUper.exe                  C# launcher (Stage 5 で path 調整 + rebuild)
├── fabriq_backuper.ps1                  entry script (self-spawn guard、main.ps1 を dot-source)
└── backuper\                            実装本体
    ├── common.ps1                       vendored kernel functions (15 個) + Find-FabriqRoot
    ├── main.ps1                         main flow (passphrase → fabriq discovery → GUI launch)
    ├── data\
    │   ├── sections.csv                 section registration
    │   └── userdata_list.csv            userdata defaults
    └── lib\
        ├── engine.ps1                   orchestrator
        ├── hostlist_reader.ps1
        ├── manifest_aggregator.ps1
        ├── sections\
        │   ├── outlook_pop\{backup,restore}.ps1
        │   ├── printer\{backup,restore}.ps1
        │   └── userdata\{backup,restore}.ps1
        └── ui\... (WinForms)
```

## fabriq main との関係

- **依存方向**: backuper → fabriq main (read-only data 参照)
- **fabriq main の所在**: 兄弟ディレクトリ (例: `E:\fabriq\`) を `Find-FabriqRoot` で
  auto-discover
- **discovery 失敗時**: backuper は起動不可、errorメッセージ表示
- **fabriq main の更新**: backuper は影響を受けない (vendored functions が変わらない限り)

## 履歴

- **〜2026-05-19**: `e:\fabriq\apps\fabriq_backuper\` で開発、Phase 2.13.0 まで完成
  (commit `7376805`)
- **2026-05-20**: 本 repo に分離独立 (Stage 0-7 移行作業)

過去の Phase 2.x commits は fabriq main repo (e:\fabriq) の git log を参照。
