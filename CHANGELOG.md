# Changelog

本プロジェクトのすべての注目すべき変更はこのファイルに記録されます。

フォーマットは [Keep a Changelog 1.1.0](https://keepachangelog.com/ja/1.1.0/) に基づき、
バージョニングは [Semantic Versioning 2.0.0](https://semver.org/lang/ja/) に従います。

カテゴリの意味:
- **Added**: 新機能
- **Changed**: 既存機能の変更（後方互換）
- **Deprecated**: 将来削除予定の機能
- **Removed**: 削除された機能
- **Fixed**: バグ修正
- **Security**: セキュリティ関連

## [Unreleased]

### Fixed
- backuper v0.16.0: outlook_pop backup の **PST マッピング失敗バグを修正**。複数 PST + 複数 POP3 アカウントを含む profile (Outlook 365 ClickToRun で typical) において、PoC で 0/4 件しか紐付かなかった問題を解消。
  - `Get-PstPathFromDeliveryStoreEntryId` を **mspst.dll 形式対応の binary scanner** に置換 (UTF-16LE drive letter pattern を走査、production Outlook が使う wrapped 形式に対応)
  - 新規 `Resolve-AccountPst` ヘルパー関数: 3 段階チェーン (filename-match → EntryID scan → single-candidate fallback)。Outlook 2010+ の標準命名規則 `<email>.pst` を最優先で利用、deterministic な紐付けを実現
  - `manifest.json` の `pst.detectionMethod` に新しい識別子 (`filename-match` / `entryid-scan` / `entryid-scan-confirmed` / `single-candidate` / `unresolved`) を出力

### Added
- backuper v0.16.0: Outlook 365 / モダン Outlook で追加された registry value 名の取得 (additive、後方互換)。
  - `POP3 Secure Connection` (`pop3.secureConnection`): 0=暗号化なし / 1=STARTTLS / 2=SSL/TLS direct
  - `IMAP Secure Connection` (`imap.secureConnection`): 同上
  - `SMTP Secure Connection` (`smtp.secureConnection`): 同上、`SMTP Use SSL` (legacy) と併用
  - `Leave on Server` (`options.leaveOnServer`): POP3 サーバ留め置き設定の DWORD bit field
- backuper v0.16.0: restore の `New-OutlookAccountInfoText` 出力強化。operator が手動再構築する際に必要な情報を補完:
  - null 値には "(値なし - autodiscover に依存)" と業界標準デフォルト (SSL なら 995/993/587, 非 SSL なら 110/143/25) を併記
  - `Secure Connection` の値解釈 (0/1/2 → 説明文) を追加
  - `Leave on Server` の raw DWORD 表示

### Changed
- backuper v0.16.0: 既存 `manifest.json` schema は **additive な拡張のみ**で後方互換。
  - 旧バックアップから生成された manifest は新フィールド (`secureConnection` / `options.leaveOnServer`) が欠落しているが、restore 側が null チェックで対応
  - 旧 `pst.detectionMethod` 値 (`profile-subkey-walk` / `entryid-parse-only` / `entryid-parse-confirmed-by-walk`) を新値に統一 — 古いバックアップを読む際は値が新旧混在しうるが、restore 側は detectionMethod を診断表示にのみ使用するため影響なし

### Added
- backuper v0.15.0: outlook_pop restore に「初回起動用ショートカット生成」オプションを
  追加。移行先の PST 内に残存する仕分けルールが移行先 PC で MAPI Entry ID の不整合により
  受信時エラーを起こす問題への対策。
  - **UI 変更** ([restore_view.ps1](backuper/lib/ui/restore_view.ps1)): 「対象ユーザ」 combo の
    下に「Outlook 追加オプション」セクションを新設、「初回起動用ショートカットを生成 (推奨)」
    チェックボックス (デフォルト ON) と説明 hint label を追加。プリンタリストの Y 座標を
    76px 下にシフトし、grid 高さを 350→274px に圧縮 (Y+H=614 の下端は不変)。
  - **新規関数** `New-OutlookRuleClearShortcut`
    ([outlook_pop/restore.ps1](backuper/lib/sections/outlook_pop/restore.ps1)): WScript.Shell
    COM 経由で target user の Desktop に `Outlook を初回起動 (仕分けルールをクリア).lnk` を
    生成。target は `OUTLOOK.EXE /cleanclientrules` (Microsoft 公式の客户端ルール削除スイッチ)。
  - **新規 SectionParam** `CreateRuleClearShortcut` (bool, default $false): restore_view から
    UI チェックボックスの値が渡される。チェック ON 時のみショートカット生成を実行。
  - **既存バグ修正**: restore_view が outlook_pop に `TargetUserProfilePath` を渡していなかった
    ため、admin 昇格時に `$env:USERPROFILE` フォールバックで admin profile を見ていた問題を解消。
  - **新規 Summary フィールド** `ruleClearShortcut`: 生成成功時はショートカットの絶対パス、
    そうでなければ `$null`。manifest aggregate に伝搬。
  - **完了 popup と RESTORE_INSTRUCTIONS.txt / _account_settings.txt** にショートカット案内を追記
    (チェック ON 時のみ)。
  - **不変**: manifest schema (新規 Summary key は additive) / section interface /
    Strategy B-light のトランスフォーム (T1-T6) / Strategy A / B の判定ロジック /
    fabriq main への書き込みなし
  - **設計判断**: COM API には `ExportRules`/`ImportRules` メソッドが存在せず (公式 PIA で
    確認)、`.rwz` 形式の自動エクスポートは実現不可。ルールを保存するのではなく **破損する
    可能性のあるルールを明示的にクリア** することで、operator が手動再設定する方が確実な
    動作になるとの判断。サーバサイドルール (IMAP / Exchange) は `/cleanclientrules` の
    対象外のため影響なし。

- backuper v0.14.0: WinForms UI 文言の全面的な日本語化。Status enum 日本語
  マッピング関数 `Get-LocalizedStatusLabel` を `backuper/lib/ui/progress_view.ps1`
  に新規追加。Set-EntryStatus のマーカー文字列、Show-CompletionPopup のタイトル、
  backup_view / restore_view の Add-ProgressLog ラッパー部分などから利用。

### Changed
- backuper v0.14.0: UI 文言を日本語化。対象は WinForms UI 全体 (main_form,
  backup_view, restore_view, progress_view, userdata_edit_dialog,
  unc_connect_dialog, unc_helper, user_selector) と outlook_pop restore が
  生成する `RESTORE_INSTRUCTIONS.txt` / `_account_settings.txt` 本文 + 完了ポップアップ。
  - manifest schema / section interface / DataGridView `.Name` / ValidateSet /
    CSV column 名 / hostlist.csv の `OldPCname` / `NewPCname` ヘッダ表示
    / aggregate manifest 診断ラベル ("aggregate manifest | collectedAt=...")
    / section script の console output (Show-Info 等) は変更なし
  - userdata_edit_dialog の `OnConflict` ComboBox items (`skip`/`overwrite`
    /`rename`) は CSV シリアライズ値のため英語維持
  - section script (printer/userdata/outlook_pop の backup.ps1) の
    Add-ProgressLog 引数は英語維持、engine 側 (backup_view / restore_view) で
    operator 向けの主要メッセージのみ翻訳
  - 日本語追加に伴い unc_helper / unc_connect_dialog / userdata_edit_dialog /
    user_selector / outlook_pop\restore.ps1 に UTF-8 BOM を付与 (PS5.1 が
    BOM なし UTF-8 の日本語を ANSI として誤解釈するため)
  - `ファイル...` ボタンを `File...` (60px) から日本語化のため幅 70px に拡張
    ([userdata_edit_dialog.ps1](backuper/lib/ui/userdata_edit_dialog.ps1))

### Changed
- backuper v0.13.0: fabriq main (`e:\fabriq\apps\fabriq_backuper\`) から本 repo
  (`E:\fabriq_backuper\`) に分離独立。fabriq_checksheet と同形の code-detached +
  runtime-data-hybrid pattern を採用。
  - `backuper/common.ps1` に kernel/common.ps1 + checksheet/common.ps1 由来の
    15 関数を vendoring (Show-* / Test-AdminPrivilege / Resolve-HkcuRoot /
    Import-ModuleCsv / Test-MasterPassphrase / Unprotect-FabriqValue /
    Find-FabriqRoot / etc.)
  - fabriq main の所在は `Find-FabriqRoot` による sibling-directory auto-discovery
    (兄弟ディレクトリから「名前に fabriq を含む + `kernel\csv\hostlist.csv` を持つ」
    を探索)
  - 新 entry script `fabriq_backuper.ps1` + `backuper/main.ps1` (自己 spawn guard +
    passphrase styled dialog + fabriq root picker (複数候補時) + GUI launch)
  - アクセントカラー lavender `#9366BD` / hover `#7F52A6` (passphrase + picker
    の最初の画面で family 区別)
  - C# launcher `Fabriq_BackUper.exe` (`dev/launcher/Launcher_BackUper.cs`) は
    path 調整 + rebuild
  - 過去の Phase 2.x commits (v0.10.0 〜 v0.13.0) は fabriq main repo の
    historical reference として保持、本 repo では新規 commit から開始
