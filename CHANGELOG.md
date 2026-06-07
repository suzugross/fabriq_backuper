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

### Added
- backuper v0.58.2: **移行情報ビューア：参照 .txt をアプリ内ビューアで表示（notepad を使わない）(TM t-0006)** —
  プリンタ設定（`_printer_settings.txt`）などの参照テキストを、既定アプリ（notepad）ではなく**アプリ内の
  読み取り専用テキストビューア** `Show-HvTextViewer`（等幅 Consolas・縦横スクロール・選択コピー可・書込なし・
  `[System.IO.File]::ReadAllText` で BOM 自動判定）で表示し、移行先 PC の環境に痕跡を残さない。プリンタは
  `_printer_settings.txt` があれば「プリンタ設定を表示」（in-app）、無ければ「プリンタフォルダを開く」にフォールバック。
- backuper v0.58.1: **移行情報ビューア：Outlook をアカウント別ショートカットに (TM t-0006)** —
  `02_outlook_アカウント情報` 直下の per-account 起動 .bat（`<番号> <email> の設定を表示.bat`）を全列挙し、
  メールアカウントごとに「表示」ショートカットを生成（複数アカウントをすべて反映）。ショートカットパネルは
  スクロール対応（`AutoScroll`）。per-account .bat は確認なしで起動（読み取り専用ビューア）、適用系 .bat
  （登録／Restore-Outlook／Install-Printers）は従来どおり確認あり。per-account .bat が無い旧レイアウトは
  単一の「Outlook 設定を表示」にフォールバック。移行元PC情報は当面フォルダを開く据え置き（将来 ビューア拡張余地）。
- backuper v0.58.0: **新ツール「Fabriq 移行情報ビューア」(Fabriq_HandoffViewer.exe) — 集約フォルダのホスト別ブラウザ＋既存ビューアへのショートカット (TM t-0006 第1段)** —
  LAN-Prep / Cleanup と同レイヤーの独立アプリ。ホストリストで選択した端末の operator handoff（集約）フォルダを
  `Get-CleanupCandidate`（`Kind='handoff'`）で発見し、自端末を `Resolve-HostByComputerName` で自動選択、選択フォルダに対し
  既存の各種ビューア／ランチャを1クリックで起動する。
  - **発見・ホスト照合は再利用**：cleanup エンジンの `Get-CleanupCandidate` をそのまま使い handoff のみ抽出（新規 scanner なし）。
    subdir 名は `Resolve-OperatorHandoffSectionDir`（共有）で解決（名前の二重定義なし）。
  - **ショートカット GUI**：資格情報を表示（`Show-Credentials.ps1 -CsvPath`）／ Outlook 設定を表示
    （`Show-OutlookAccounts.ps1 -DataDir`）は単体 GUI を起動；移行元PC情報／プリンタはフォルダ・既定アプリで開く；
    登録／Outlook 自動復元／プリンタインストールの各 .bat も起動可（実行前に確認ダイアログ）。存在しない subdir/資産はグレーアウト。
  - **構成**：[fabriq_handoffviewer.ps1](fabriq_handoffviewer.ps1)（入口・cleanup 骨格を踏襲）／
    [handoffviewer_view.ps1](tools/handoff_viewer/lib/handoffviewer_view.ps1)／
    `dev/launcher/{Launcher_HandoffViewer.cs, app_handoffviewer.manifest(asInvoker), build_handoffviewer.ps1}`／`Fabriq_HandoffViewer.exe`。
    本体は **asInvoker**（読み取り専用ブラウザ・各 .bat が自前で user 文脈/UAC を処理）。
  - restore / backuper 本体 / manifest schema は不変（第1段では集約フォルダの出力先は無変更。Backuper 内移設は t-0006 第2段で別途）。
- backuper v0.57.0: **リストア画面に「更新」ボタン — 選択中バックアップの再読込 (TM t-0008)** —
  リストア画面のエントリ操作行に「更新」ボタンを追加。選択中バックアップの manifest を disk から読み直し
  ([restore_view.ps1](backuper/lib/ui/restore_view.ps1) の `Update-RestoreSelection`)、エントリ一覧・種別/状態・
  バックアップ警告・問題件数を最新化する。移行先でリストア画面を開いたまま、移行元が v0.56.0 のセッション統合で
  バックアップを追記/穴埋めした分を、画面を開き直さずに取り込める。engine / 選択契約 / manifest schema は不変。
- backuper v0.56.0: **バックアップのセッション一貫化＋やりなおしループ (TM t-0003)** —
  リストアの D6 と対称に、バックアップ完了後も「バックアップ画面へ戻る」で操作を続けられる。さらに
  **アプリ起動〜終了を1セッション＝1バックアップ**とし、同一セッション・同一ホストでの2回目以降の実行は
  **最初の集約dir (同タイムスタンプ) に自動統合**される (アプリ再起動で新しいバックアップ)。部分失敗の穴埋めも、
  成功後の項目追加も、すべて同じ1つのバックアップに「育てる」形でまとまる。
  - **B1 戻るループ**: `Invoke-BackupStart` が `-ReturnView 'Backup'` で進捗画面に「バックアップ画面へ戻る」を表示
    ([backup_view.ps1](backuper/lib/ui/backup_view.ps1) / [progress_view.ps1](backuper/lib/ui/progress_view.ps1))。
    完了ボタンは Backup では素直に閉じる (auto-revert は Restore 限定)。
  - **セッション統合 (トグルなし・自動)**: 同一セッションで先行集約dir があれば常にそこへ統合。戻った時は
    「**失敗したもののみチェックを残す**」(成功項目はオフ) でプリセレクトし、状態サマリ
    「セッション継続中：このバックアップは &lt;TS&gt; に統合されます」を表示。userdata セクションは追加項目を取れるよう
    チェック維持、`system_evidence` は常時 ON。
  - **マージ実装 (engine は後方互換)**: `Invoke-BackuperBackupCore -RetryIntoAggregateDir` (新規・optional) で
    元dir再利用、[manifest_aggregator.ps1](backuper/lib/manifest_aggregator.ps1) の `Merge-AggregateManifest` が
    aggregate manifest を更新 (summary 再集計・`lastRetriedAt`)、[userdata/backup.ps1](backuper/lib/sections/userdata/backup.ps1)
    は呼出側の元id (`RetryEntryIds`) で**元の entry dir に上書き**＋ per-entry manifest を id 一致でマージ。
    元バックアップに無い新規項目は**衝突しない新 id を採番**して追加 (既存の成功項目を壊さない)。再実行で項目を
    外して Skipped になっても**既存の成功/失敗状態を降格しない**。
  - normal backup / restore / manifest schema は不変。多エージェント敵対的検証3ラウンドで data-loss / 状態誤報を
    検出→修正済み (実機スモーク推奨)。

### Changed
- backuper v0.59.0: **集約フォルダを移行先 Desktop → Backuper 内 `Handoff\` へ移設 (TM t-0006 第2段)** —
  restore の operator handoff（集約）フォルダの出力先を、移行先ユーザの Desktop から
  **`<BackuperRoot>\Handoff\<yyyy_MM_dd>_<OldPCname>_BK`**（`Backup\` と並ぶ sibling）へ変更。
  Fabriq 移行情報ビューアで集中的に閲覧でき、`Get-CleanupCandidate` にも新 root を追加したので
  ビューア・Cleanup の双方が新場所を発見する。
  - `Resolve-OperatorHandoffRootLocal`（[common.ps1](backuper/common.ps1)・新規 additive）を追加。
    Desktop 版 `Resolve-OperatorHandoffRoot` と root 非依存の `Resolve-OperatorHandoffSectionDir` は温存（後方互換）。
  - `Get-CleanupCandidate` に「Root 3b: `<BackuperRoot>\Handoff\*_BK`」走査を追加（Desktop 走査も維持）。
    Cleanup 安全弁（`Test-CleanupPathSafe`）は protected root の子孫削除を許可するため新場所も削除可。
  - [restore_view.ps1](backuper/lib/ui/restore_view.ps1)：handoff root 解決を新 resolver に切替、
    チェックボックス文言と README を更新。section の配備は `OperatorHandoffSubdir`（root 非依存）経由のため不変。
  - manifest schema / section interface は不変。

### Fixed
- backuper v0.55.1: **リストアの「項目別の状態」グリッドに userdata 項目が出ない不具合を修正 (TM t-0002)** —
  `Initialize-ProgressEntries` が呼ばれる度に `Rows.Clear()` でグリッドを全消去していたため、リストアで
  userdata と outlook_pop の両 section が呼ぶと**後に走った section が前の項目を消し**、Outlook profile だけが
  残っていた (バックアップは userdata のみが呼ぶため正常だった)。Clear を外し **section 横断で項目を累積表示**
  するよう変更 (run 開始時の Clear は `Initialize-ProgressView` が担当、entry id は section 単位で一意なので
  `Set-EntryStatus` は正しい行を更新)。
  - 対象: [progress_view.ps1](backuper/lib/ui/progress_view.ps1)。engine / Summary 集計・完了ポップアップは不変。

### Changed
- backuper v0.55.0: **LAN-Prep 役割起動時に session 画面のボタンを役割ロック (TM t-0005)** —
  LAN-Prep の移行元/先選択で Backuper を起動した時 (`PreselectMode`=Backup/Restore)、
  session_form の**非該当ボタンを無効化 (グレーアウト)** し、オペレータの誤クリックを防止。
  - source→Backup は「リストア」を、target→Restore は「バックアップ」を無効化
    (neutral gray + dim text + `Enabled=$false`)。Enter は従来どおり役割側ボタンを実行し、
    既存の役割バナーが理由を表示。
  - 手動起動 (`PreselectMode=''`) は両ボタン有効のまま (現状維持)。engine / 選択契約は不変。
  - 対象: [session_form.ps1](backuper/lib/ui/session_form.ps1)。
- backuper v0.54.0: **クリーンアップ機能を独立 EXE に分離 (TM t-0001)** —
  バックアップデータのクリーンアップ (移行後に残った backup tree / 集約フォルダ / LAN-Prep フォルダの
  ホスト単位一括削除) を、BackUper 本体から **LAN-Prep と同レイヤーの独立ツール `Fabriq_Cleanup.exe`** に
  分離。本体 UI から「クリーンアップ」モードを外し、操作画面を簡素化。
  - **新ツール (LAN-Prep 構成を踏襲・common.ps1 を vendoring せず dot-source)**:
    [fabriq_cleanup.ps1](fabriq_cleanup.ps1) (repo 直下エントリ) ＋
    [tools/cleanup/lib/cleanup_view.ps1](tools/cleanup/lib/cleanup_view.ps1) (本体から移設＋**対象ホスト
    コンボ併設**で standalone 化) ＋ [Launcher_Cleanup.cs](dev/launcher/Launcher_Cleanup.cs) /
    [app_cleanup.manifest](dev/launcher/app_cleanup.manifest) (**asInvoker**＝admin 強制なし) /
    [build_cleanup.ps1](dev/launcher/build_cleanup.ps1) (csc ビルド)。
  - **クリーンアップ・エンジンは common.ps1 に残置** (Get-CleanupCandidate / Remove-CleanupArtifact /
    Test-CleanupPathSafe / New-CleanupMarker / Write-CleanupHistory 等)。BackUper の backup マーカー記録と
    リストア側 D4 (ユーザデータ削除) が引き続き使用するため。新ツールは同じ common.ps1 を dot-source。
  - **C1 (D4 保護)**: `Get-CleanupProtectedRoots` を cleanup_view.ps1 から **common.ps1 へ移設** (D4 と
    新ツールの双方がエンジンから解決)。
  - **C3 (本体撤去)**: `backuper/lib/ui/cleanup_view.ps1` 削除、main.ps1 のロード、main_form.ps1 の
    `Cleanup` ValidateSet ＋ `Views['Cleanup']`、session_form.ps1 の「クリーンアップ」ボタン＋ハンドラを撤去。
    エンジン・backup マーカー・D4 は不変。
  - **対象ホスト自動選択**: 起動時に `$env:COMPUTERNAME` を hostlist と突合し、NewPCName 優先
    (無ければ OldPCName) で一致行を自動選択＋候補スキャン (`Resolve-HostByComputerName` 再利用)。
    cleanup は移行後の新 PC で動かす前提のため NewPCName を優先。operator はコンボで変更可。
  - **1行 hostlist の取りこぼし対策**: `@(Get-FabriqHostlist …)` で配列化し `.Count` を安定化
    (PS5.1 で単一要素戻り値が scalar に unwrap され「1件あるのに 0件扱い」になる罠の回避)。
    hostlist パスと cold-load 行数の診断ログも追加。
  - 配備: `Fabriq_Cleanup.exe` を `dev/launcher/build_cleanup.ps1` でビルド (csc 必要)。`.ps1` は
    powershell から直接実行可。
- backuper v0.52.0: **リストア前の空き容量チェックを「実データ比較＋ブロック」に作り直し (要件 必須1)** —
  v0.48.0 の「しきい値超で警告のみ (続行可)」を廃止し、**容量不足なら リストアを中止 (ブロック)** に変更。
  - 判定式: **`空き容量 − 選択リストアデータ ≥ 10GB` で許可、未満はブロック**。ローカル運用ではバックアップ
    データは既に対象ディスク上にあり、リストアで増えるのは戻したコピーの **+1×** のみ → ×2 は不要 (×1)。
  - サイズは**オペレータが選択したエントリに追随** (`Get-RestoreSelectionSizeBytes`、harvest 後に算出)。
  - 余裕 (headroom) は**既定 10GB**。`profile.restore.freeSpaceHeadroomBytes` で上書き可 (UI 設定は廃止)。
  - **fail-open**: 測定不能時 (UNC ソース / ドライブ取得失敗 / サイズ 0) はブロックせず通過。DriveInfo は
    対象ユーザの profile ドライブのみ (`RestoreExplicitDir`(UNC 可) には当てない)。
  - 不足時のダイアログは数値 (データ量 / 空き / 不足) ＋「不要データ削除・分割リストアで対応」を明示。
  - UI の「空き容量しきい値(MB)」フィールド＋状態変数を撤去。`Get-RestoreFreeSpaceMarginBytes` →
    `Get-RestoreFreeSpaceHeadroomBytes` に作り替え。
  - [restore_view.ps1](backuper/lib/ui/restore_view.ps1) ＋ [migration_profile.sample.json](backuper/data/migration_profile.sample.json)
    (`restore.freeSpaceMarginBytes` → `freeSpaceHeadroomBytes`=10GB)。engine / section interface 不変。
- backuper v0.51.0: **リストア画面のエントリ表示を単一リストに集約** —
  従来バラバラだった「セクションチェックグリッド / ユーザデータ選択モーダル / 資格情報選択モーダル /
  プリンタ別グリッド」を、**1つの DataGridView (セクション見出し行 + エントリ行)** に統合。見づらさを解消。
  - セクション見出し行のチェック = section on/off (内部の隠し `RestoreSectionChecks` をミラー駆動。
    B 失敗警告 / Invoke-RestoreStart の `$picked` 契約は不変)。OFF で配下エントリをグレーアウト。
  - エントリ行: **userdata / credentials / printer は per-entry チェック** (現状の選択粒度を維持)、
    outlook_pop / msime_dict / system_evidence は情報行。userdata 行に D3「復元」状態列、リスト下に
    D4「選択のバックアップ削除」ボタンをインライン移設。
  - **エンジン契約は完全に不変**: グリッドから `IncludeEntries / IncludeTargets / IncludePrinters` +
    `PickedSections` を harvest し、従来と同一の SectionParams を生成 (manifest / section interface 不変)。
  - 対象ユーザ / handoff / Outlook オプション / 空き容量しきい値(C) / 戻りループ(D6) は温存。
  - 旧モーダル関数 (`Show-UserdataSelectDialog` / `Invoke-Restore{Userdata,Credentials}Select` /
    `Update-Restore*StatusLabel`) は呼び出し元を全撤去し dead code 化 → v0.51.1 で撤去。
  - [restore_view.ps1](backuper/lib/ui/restore_view.ps1) のみ (engine / プロファイル変更なし)。

### Removed
- backuper v0.51.1: **集約UI後の dead code 掃除** — v0.51.0 でモーダル / 別グリッドを単一リストに
  統合した際に呼び出し元を失った関数・変数・ファイルを撤去 (挙動変化なし)。
  - [restore_view.ps1](backuper/lib/ui/restore_view.ps1): 旧モーダル 5 関数 (`Show-UserdataSelectDialog` /
    `Invoke-RestoreUserdataSelect` / `Invoke-RestoreCredentialsSelect` / `Update-RestoreUserdataStatusLabel` /
    `Update-RestoreCredentialsStatusLabel`、計 356 行) と dead script-vars (`RestoreUserdataButton` /
    `RestoreCredentialsButton` / `RestoreUserdataStatusLabel` / `RestoreCredentialsStatusLabel` /
    `RestoreUserdataLastSource` / `RestoreCredentialsLastSource`) を撤去。
    `RestoreUserdataIncludeTargets` / `RestoreCredentialsIncludeTargets` は引き続き使用のため温存。
  - `backuper/lib/ui/credentials_select_dialog.ps1` (`Show-CredentialsSelectDialog`) を削除し、
    main.ps1 のロードリストから除外。
  - 括弧 366/366 balanced、BOM 維持。静的検証のみ (PowerShell 実行不可環境)。

### Added
- backuper v0.53.0: **リストア後のネットワーク自動復元 (要件 A / 自動IP復元)** —
  移行先でリストアが成功したら、LAN-Prep のネットワーク復元 (元の IP に戻す) を**自動実行**。
  オペレータにバッチ操作 (press any key 等) をさせない。ローカル運用フローの finale。
  - **発火ゲート (全条件)**: role=target (`FABRIQ_BACKUPER_ROLE` or `share.hostRole`) ＋ local mode
    (profile schemaVersion 2) ＋ **`$result.Status == 'Success'`** (Partial/Failed は D6 ループへ) ＋
    ロールバックスナップショット存在 ＋ **未 revert (`_revert_done.json` 不在＝冪等)** ＋
    `rollback.revertNetwork != false` ＋ `rollback.autoRevert != false`。
  - **UX**: 進捗画面の **[完了] ボタン押下を「移行を終える」操作**とし、その時に revert を実行
    (GUI 通知「元の IP に戻す・移行用 LAN は切断」→ OK → 実行 → 結果表示 → アプリ終了)。
    Partial/Failed は [リストア画面へ戻る](D6) で revert せず継続。バッチ prompt は一切なし。
  - **`Revert-LanMigration.ps1` に `-Unattended` 追加**: "Press Enter to exit" 2 箇所をガードし完全無人化
    (確認 y/N は既存 `-Force`)。`Invoke-RestoreAutoRevert` が `-Force -Unattended` で起動 (親プロセスの
    昇格を継承・同期待ち・exit code で成否表示)。
  - 破壊的だがゲート厳格＋冪等。失敗時は手動 Revert を案内 (リストア自体は完了済み)。GUI はローカル
    完結のため IP 変更後も生存。手動 restore / source / 非 local / Partial・Failed は不変。
  - [restore_view.ps1](backuper/lib/ui/restore_view.ps1) (`Invoke-RestoreAutoRevert` ＋ status 記録) ＋
    [progress_view.ps1](backuper/lib/ui/progress_view.ps1) (完了ボタンで発火) ＋
    [Revert-LanMigration.ps1](tools/lan_prep/Revert-LanMigration.ps1) (`-Unattended`) ＋
    [migration_profile.sample.json](backuper/data/migration_profile.sample.json) (`rollback.autoRevert`)。
- backuper v0.50.0: **部分リストア後のやりなおしループ (要件 D6)** —
  リストア完了後にリストア画面へ戻り、未済/Partial だけ再リストアしたり、不要データを削除してから
  再実行できるようにした。従来は完了画面の「完了」=アプリ終了のみで反復不能だった。
  - **G1 (戻る導線)**: Progress ビューに「リストア画面へ戻る」ボタンを併設 (`Initialize-ProgressView`
    の新 `-ReturnView` が設定された実行＝リストアのみ表示、`Set-ProgressFinished` で出現)。
    `Invoke-RestoreStart` は `-ReturnView 'Restore'` を渡す。**バックアップは ReturnView 未設定で
    従来どおり「完了」=終了のまま不変**。
  - **G2 (戻り時の状態更新)**: 戻るボタンは `Switch-View 'Restore'` → on-show フック `Show-RestoreView`
    が走り、combo 再発火で manifest 再キャッシュ・失敗警告 (B) 再評価・ユーザデータ選択リセットが
    自動。`Show-RestoreView` 冒頭でも選択を明示リセット (堅牢化)。同バックアップが選択済みのまま、
    ダイアログ再オープンで「復元済」最新表示。リストア後はバックアップが存在するため auto-wait の
    再アーム・到着ポップアップは発生しない。
  - **G3 (resume 既定の精緻化)**: 選択ダイアログで marker の `status` を読み、**Done/AlreadyPresent
    のみ既定で未チェック、Partial は既定チェック** (不完全＝続きを促す)。復元列に「復元済(部分)」表示。
  - [progress_view.ps1](backuper/lib/ui/progress_view.ps1) ＋ [restore_view.ps1](backuper/lib/ui/restore_view.ps1) のみ (engine / プロファイル変更なし)。要件 A はこの完了分岐点の Success ブランチに後で載せる。
- backuper v0.49.0: **ユーザデータの復元済みマーカー → 状態表示 → 削除 (要件 D2-D4)** —
  リストアしたエントリにマーカーを残し、リストア画面で復元済/未を表示、復元済みのバックアップ
  データを削除できるようにした。「未済/失敗だけ再リストア (やりなおし)」と「済データの後片付け」が回る。
  - **D2 (マーカー書込)**: `userdata/restore.ps1` が各エントリの per-entry dir に **`_restored.json`**
    を配置 (`Write-UserdataRestoredMarker`、best-effort・UTF-8 no-BOM、`New-CleanupMarker` とは別名で
    クリーンアップ認識器と非衝突)。**Done/Partial と skip-exists (対象に既存=AlreadyPresent) で書込、
    Failed は書かない**。リストア挙動は不変 (追記のみ)。
  - **D3 (状態表示)**: `Show-UserdataSelectDialog` に `-AggregateDir` と **「復元」列**を追加。
    `_restored.json` ＋ `entries\<id>\data` の有無から `復元済(日時)` / 未 / `データ削除済` を表示。
    **復元済みエントリは既定で未チェック** (resume 支援、明示プリセット時はそれを優先)。
  - **D4 (削除)**: ダイアログに「選択のバックアップ削除」ボタン。復元済み行の per-entry dir を
    `Get-CleanupProtectedRoots` → `Remove-CleanupArtifact` で削除 (cleanup エンジンの
    `Test-CleanupPathSafe` 安全弁を再利用、Yes/No 確認、per-entry 限定)。削除後は行を「データ削除済」
    に更新・選択不可化。
  - D5 (manifest prune) は保留 — restore.ps1 のデータフォルダ欠落 graceful 処理に委譲。
  - [userdata/restore.ps1](backuper/lib/sections/userdata/restore.ps1) ＋ [restore_view.ps1](backuper/lib/ui/restore_view.ps1) のみ (engine / プロファイル変更なし)。
- backuper v0.48.0: **リストア前の空き容量チェック (要件 C)** —
  リストア実行の確認直前に、**リストア先ドライブの空き容量 vs リストア実データ量**を比較し、
  (空き − サイズ) がしきい値 (余裕) 未満なら**確認ダイアログに警告行を畳み込む** (警告のみ・続行可)。
  - **サイズは manifest のバイト数から算出** (UNC 再スキャンなし)。チェック済みセクションの
    `sections.<k>.summary.totalBytes` ＋ userdata は**選択エントリ (D1) の `byteCount` 合計**。
  - **空きは対象ユーザの profile ドライブ**を `[System.IO.DriveInfo]` で取得。UNC ソース / 修飾子
    取得不可 / 各種エラーは **fail-open (チェック省略、リストアは止めない)**。`RestoreExplicitDir`
    (UNC 可) には DriveInfo しない。
  - **しきい値は UI＋プロファイルで設定可**: リストア画面に「空き容量しきい値(MB)」フィールド
    (プロファイル値で seed)、既定 1GB。プロファイルに `restore.freeSpaceMarginBytes` を追加
    (additive・schemaVersion は 2 のまま、未設定は null-guard で既定 1GB)。
  - [restore_view.ps1](backuper/lib/ui/restore_view.ps1) ＋ [migration_profile.sample.json](backuper/data/migration_profile.sample.json)
    のみ (engine / section / main.ps1 変更なし)。
- backuper v0.47.0: **リストアのバックアップ失敗警告 (要件 B)** —
  リストア画面で、選択中のバックアップ自体に取得失敗があった場合に色付き警告を表示。read-only で
  リストアは止めない (警告のみ)。
  - **チェック済みセクション**の Failed/Partial を集計 (見出し件数と括弧内のセクション名を同一集合
    から算出するので不整合なし)、さらに **userdata の entry 単位「取得不可」(Failed/Partial/Skipped=
    missing-source) 件数**も加算。**失敗 or userdata取得不可>0=赤 / 部分のみ=アンバー / クリーン=非表示**。
  - 死蔵だった `$script:RestoreCurrentManifest` ＋ userdata 問題件数を取得元選択時 (timestamp / Browse
    両経路) にキャッシュし `Show-RestoreBackupWarnings` が描画。**取得元変更・セクションのチェック切替で
    即再評価**。
  - per-entry の詳細は D1「ユーザデータ選択」ダイアログの状態列でも確認可。
  - [restore_view.ps1](backuper/lib/ui/restore_view.ps1) のみの変更 (engine / section / プロファイル変更なし)。
- backuper v0.46.0: **リストアのユーザデータ選択 (D1): エントリ単位の選択リストア** —
  ローカル運用とは独立した汎用リストア UX 改善の第一歩 (要件 D)。リストア画面にセクション
  ヘッダ行へ「ユーザデータ選択...」ボタン＋モーダルグリッドを追加し、userdata セクションを
  **エントリ単位で選択リストア**できるようにした (credentials 選択 UI と同方式)。
  - 選択は `IncludeEntries` (sourcePath 配列) で [userdata/restore.ps1](backuper/lib/sections/userdata/restore.ps1)
    へ渡す。**フィルタ自体は既存実装** (:28-33, :94-96) で、UI が値を渡していなかったギャップを埋めるもの
    (セクション側の変更なし)。
  - グリッド列: チェック / 元パス / サイズ / 状態。backup 時 Skipped (取得不可) のエントリは
    選択不可・グレー表示 (要件 B の素地)。取得元 (日時 / Browse) 変更で選択をリセット。
  - **既存動作不変**: 未選択 (既定) = 全件リストアで従来どおり。[restore_view.ps1](backuper/lib/ui/restore_view.ps1)
    のみの変更 (engine / プロファイル / 他セクション変更なし)。
- backuper v0.45.0: **新「ローカル」運用モード (P5): LAN-Prep が役割を env 設定し Backuper を自動起動** —
  ローカル運用自動化の大詰め (エンドツーエンド)。[Prepare-LanMigration.ps1](tools/lan_prep/Prepare-LanMigration.ps1)
  の成功パスで `FABRIQ_BACKUPER_ROLE` (= -Role) と (menu が host を解決していれば) `FABRIQ_BACKUPER_AUTO_HOST`
  (= -OldPCName) を環境変数に設定し、`Fabriq_BackUper.exe` を Start-Process で起動。env は
  EXE→ps1→self-spawn 境界を継承するため、Backuper が P3 (ROLE→mode) ＋ P4 (COMPUTERNAME→host) で
  正しい画面・ホストに着地し、移行先は P2 の 0件自動待機へ自然に接続する。
  - **常に自動起動**。`-NoLaunchBackuper` で抑止 (ネットワーク設定のみ / テスト)。EXE 不在時は
    fabriq_backuper.ps1 へフォールバック。起動後に親プロセスの env をクリア (子は生成時にスナップショット
    継承済みで影響なし、menu ループに stale role を残さない)。
  - **パスフレーズは渡さない** (P3 方針)。オペレータが Backuper で入力。
  - menu (fabriq_lanprep.ps1) は変更不要 (-OldPCName は hostlist-driven 時に既に Prepare へ流れる)。
  - **制約**: host 自動選択は hostlist の PCname が平文なら自動、ENC: 暗号化ならパスフレーズ入力後に
    手動選択 (mode 前選択は常に有効)。
- backuper v0.44.0: **新「ローカル」運用モード (P4): COMPUTERNAME による自機の役割対応 自動選択** —
  P3 の残課題 (AUTO_HOST 未指定の移行元が先頭行になる) を解消。共有ヘルパー
  `Resolve-HostByComputerName` ([hostlist_reader.ps1](backuper/lib/hostlist_reader.ps1)) を新設し、
  セッション画面の COMPUTERNAME 自動判定を役割対応へ置換 ([session_form.ps1](backuper/lib/ui/session_form.ps1)):
  - **PreferMode='Backup' (移行元)** → `OldPCname == COMPUTERNAME` 優先 (→ NewPCname フォールバック)
  - **PreferMode='Restore'/'' (移行先/手動)** → `NewPCname == COMPUTERNAME` 優先 (→ OldPCname フォールバック)
  - P3 の AUTO_HOST 明示前選択は引き続き最優先。該当なしは未選択 (P3 警告バナーへ)。
  - ヘルパーは Backuper / LAN-Prep 双方が dot-source する hostlist_reader に配置し P5 で再利用予定。
  - **既存動作**: 移行先 (NewPCname) と AUTO_HOST 明示は不変。手動起動に OldPCname フォールバックが
    追加 (行の前選択=強調のみ、自動実行なし)。
- backuper v0.43.0: **新「ローカル」運用モード (P3): 役割/ホストの自動連携 (env→mode+host 前選択)** —
  LAN-Prep (P5) が env でキャリーする役割とホストを Backuper が消費し、セッション画面で
  **mode (移行元→バックアップ / 移行先→リストア) と対象ホスト行を自動前選択**する第3歩。
  - **env (self-spawn 継承)**: `FABRIQ_BACKUPER_ROLE` (source|target) → mode、`FABRIQ_BACKUPER_AUTO_HOST`
    (OldPCname) → hostlist 行前選択。[main.ps1](backuper/main.ps1) がプロファイル読込後に読取り、
    [session_form.ps1](backuper/lib/ui/session_form.ps1) へ `-PreselectMode`/`-PreselectOldPcName` で渡す。
  - **session_form**: AUTO_HOST 指定時は OldPCname 一致で行前選択 (既存の COMPUTERNAME=NewPCname
    自動判定を上書き、未指定時はフォールバック)。パスフレーズ box の Enter 既定動作を role の mode に
    切替、連携バナーを表示。移行先は Restore 着地後に P2 の 0件自動待機へ自然に接続。
  - **セキュリティ**: パスフレーズは env で渡さず**オペレータが手入力** (CLAUDE.md 準拠)。完全
    ハンズフリー (パスフレーズ受渡し) は別途検討。
  - **既存動作不変**: env 未設定時は従来の手動セッションと完全同一 (前選択引数は既定 '' で no-op)。
- backuper v0.42.0: **新「ローカル」運用モード (P2): リストア側のバックアップ到着ポーリング＋自動選択** —
  P1 (完了フラグ) の消費側。リストア画面が自機ローカル `<BackuperRoot>\Backup\_backup_complete.json`
  (local モードでは移行元が共有越しに書く先) を WinForms `Timer` (2秒) でポーリングし、**新しい
  完了フラグを検知したら該当バックアップを自動選択**する (リストア実行はオペレータ＝管理表 step9)。
  - **待機モード突入は2系統** ([restore_view.ps1](backuper/lib/ui/restore_view.ps1)): ①当該ホストの
    バックアップが0件で `Show-RestoreView` を開くと**自動待機**、②「到着を待つ／待機停止」**手動トグル
    ボタン**を常設。両系統とも同一の start/stop・ベースライン記録・Tick 発火を共用。
  - **stale ガード**: 待機開始時に既存フラグの `placedAt` をベースライン記録し、`oldPcName` 一致かつ
    `placedAt` がベースラインより新しいフラグのみ発火 (過去フラグ・別ホストでは発火しない)。発火時は
    一覧を再生成し `timestamp` 一致エントリを自動選択 (既存 `SelectedIndexChanged` が `RestoreExplicitDir`
    を設定)。タイマは発火／手動停止／`Show-RestoreView` 再入／`バックアップを参照` (手動 Browse)／
    フォーム終了で停止 (リーク防止＋参照ダイアログ表示中の誤発火防止)。datetime 解析失敗時は
    fail-closed (発火しない) で stale フラグの誤選択を回避。
  - **新ヘルパー** [common.ps1](backuper/common.ps1) `Read-BackupCompleteFlag` (`Read-CleanupMarker`
    踏襲)。populate ロジックを `Update-RestoreTimestampCombo` に切出し初期表示と再生成で共用。
  - **既存動作不変**: 待機 OFF (バックアップ有・手動未操作) 時は従来の手動選択フローと完全同一。
- backuper v0.41.0: **新「ローカル」運用モード (P1): バックアップ完了フラグの配置** —
  P0 (移行パス派生) に続く第2歩。バックアップ成功 (非 Failed) の最後に、保存先ルート
  (local モードでは移行先が共有する `<BackuperRoot>\Backup`) へパッシブな完了フラグ
  `_backup_complete.json` を配置 ([engine.ps1](backuper/lib/engine.ps1) の `Invoke-BackuperBackupCore`
  の return 直前)。移行先がこれをポーリング検知し該当バックアップを自動選択する後段 (P2) の信号。
  - **新ヘルパー** ([common.ps1](backuper/common.ps1) `New-BackupCompleteFlag`、`New-CleanupMarker`
    踏襲で best-effort・UTF-8 no-BOM・never throws)。フラグ内容: schemaVersion 1 /
    manifestType `fabriq-backuper-backup-done` / oldPcName / newPcName / timestamp / relativePath /
    status / backuperVersion / placedAt / placedByHost。
  - **パッシブ**: 消費者は P2 (未実装)、Failed 時は書かない。ポータブル運用でも無害 (ルート直下の
    単一ファイルで、`Get-BackupTimestamps` の host サブディレクトリ走査・Cleanup 候補抽出に非干渉)。
- backuper v0.36.0: **Outlook アカウント設定ビューア (疑似画面 GUI) を operator handoff に同梱** —
  移行先での再設定を支援する軽量・依存ゼロの WinForms ビューア
  ([Show-OutlookAccounts.ps1](backuper/lib/sections/outlook_pop/assets/Show-OutlookAccounts.ps1))。
  Outlook の「アカウントの追加 (POP と IMAP)」画面と遷移先「インターネット電子メール設定」
  (全般 / 送信サーバー / 詳細設定タブ) を **ダークな疑似画面**として再現し、移行アカウントの
  設定値を一覧表示する。
  - **データソース 2 モード自動判別**: ① 自作 `accounts.json` (設定＋パスワード入りの 1 枚、
    スキーマは [accounts.sample.json](backuper/lib/sections/outlook_pop/assets/accounts.sample.json)、
    `-AccountsFile` で明示指定も可) を優先 → ② backup handoff の `_data\manifest.json` (構造化) ＋
    `_account_settings.txt` (復元済み平文パスワードを行から抽出)。前者により backup 専用でなく
    **自作設定の汎用ビューア**としても再利用可能。
  - **疑似画面であることを明示**: 全面ダーク配色 ＋ 上部赤帯。設定が必要な画面遷移を強調
    (詳細設定ボタン=赤丸＋「要設定」、送信サーバー/詳細設定タブ=赤 ●)。抽出済みデータは明色、
    未取得項目 (テスト系・タイムアウト・組織/返信 等) はグレーアウトして作業員を迷わせない。
  - **配信先**は実紐づけを表示: per-account の PST (`pst.sourceFileName`) を「既存の Outlook データ
    ファイル」選択＋ファイル名で反映 (IMAP はローカルデータファイルなし表示)。
  - **各値欄に 📋 コピーボタン** (クリックでクリップボードへ)。ポートは値が無い場合のみ「(推定)」を
    付記し、SSL 不明時は非 SSL 標準ポート (POP3=110 / IMAP=143 / SMTP=25) を採用。
  - **配布後の入口は launcher .bat**
    ([アカウント情報を表示.bat](backuper/lib/sections/outlook_pop/assets/アカウント情報を表示.bat)) で
    `powershell -ExecutionPolicy Bypass -STA -File "%~dp0Show-OutlookAccounts.ps1"` 起動。生 .ps1 を
    触らせず実行ポリシーを (システム設定を変えずに) 回避。Restore-Outlook.bat と同方式。
  - **restore.ps1 Stage 5.7**: Strategy A/B を問わず operator handoff フォルダがあれば viewer ＋
    launcher ＋ `_data\manifest.json` を同梱 (Strategy A 経路の `_data` 欠落を補完)。best-effort で、
    失敗しても warn のみ・セクションは継続。
  - **セキュリティ**: 平文パスワードの新規ディスク sink を増やさない (viewer は実行時に既存ファイルを
    読むのみ、メモリ保持。sample JSON は架空値)。.ps1 は UTF-8 BOM、`Copy-Item` でバイト無劣化配置。
  - **検証**: ヘッドレス `-Dump` / `-SelfTest` / `-Shot` (フォーム→PNG レンダリング) で構文・データ層・
    UI 構築・画面外観を確認。実機 manifest (2 POP アカウント) で backup / JSON 両モード描画合格。
  - **対象ファイル**: 新規 assets 3 点 (viewer.ps1 / launcher.bat / accounts.sample.json) ＋
    [restore.ps1](backuper/lib/sections/outlook_pop/restore.ps1) (Stage 5.7 追加)。
- backuper v0.38.0: **資格情報セクションにも一覧ビューア＋フロント整理を適用** —
  Outlook と同方針で、移行先で「旧 PC にどの資格情報が有ったか」を一目で確認できる簡素な GUI
  ビューア
  ([Show-Credentials.ps1](backuper/lib/sections/credentials/operator_payload/Show-Credentials.ps1)) を
  追加。`credentials_list.csv` を読み、ダークなグリッドで Target / Type / UserName / Persist と
  **推奨アクション (登録対象 / 要確認(トークン・参照系) / スキップ(証明書)) を色分け**表示
  (パスワードは元々バックアップに含まれない、純粋な情報表示)。
  - **フロント整理**: 資格情報 handoff (`01_資格情報\`) の補助ファイル (credentials_list.csv /
    register_credentials.ps1 / Show-Credentials.ps1 / README.txt) を `_data\` へ集約し、フロントは
    **`登録.bat` (全件登録) ＋ `資格情報を表示.bat` (ビューア)** の 2 バッチだけに。`登録.bat` /
    viewer launcher は `%~dp0_data\` を起動するよう更新。
  - 作業員は「① ビューアで旧 PC の内容を確認 → ② 全件 `登録.bat`、または別途用意済みのバッチを
    選んで実行」の双方に対応 (ビューアは確認専用でバッチ生成はしない)。
  - **対象**: 新規 operator_payload 2 点 (Show-Credentials.ps1 / 資格情報を表示.bat) ＋
    [credentials/restore.ps1](backuper/lib/sections/credentials/restore.ps1) (deploy を _data\ 構成へ) ＋
    既存 登録.bat / README.txt 更新。

### Changed
- backuper v0.40.0: **新「ローカル」運用モードの基盤 (P0): 移行パスのプロファイル派生** —
  外付けSSD＋専用共有 (`C:\FabriqMigration`) の「リモート」運用を廃し、新旧PCのローカルにアプリを
  配置して**移行先のアプリ内 `Backup` フォルダを共有**する「ローカル」運用へ移行する第一歩
  (大規模改修の P0)。`migration_profile` を **schemaVersion 1→2** に更新 (ハードカット。旧 schema 1
  プロファイルは Backuper では無視・LAN-Prep では FATAL となるため再作成が必要)。
  - **共有リゾルバ新設** ([migration_paths.ps1](backuper/lib/migration_paths.ps1) の
    `Resolve-MigrationPaths`): プロファイルの各パスを実行時に派生する単一の真実源。
    `share.localPath`=`<AUTO>` → `<BackuperRoot>\Backup` (移行先が共有するフォルダ)、
    `backuper.backupRootUnc`=`<AUTO>` → `\\<network.target.ipAddress>\<share.shareName>` (移行元の保存先)、
    `rollback.snapshotPath`=`<AUTO>` → `<BackuperRoot>\_lanprep\_rollback_snapshot.json` (共有外・ローカル)。
    リテラル値を書けば従来どおり優先 (エスケープハッチ)。common.ps1 ではなく軽量 lib に置き、
    LAN-Prep の common.ps1 非依存を維持。
  - **Backuper / LAN-Prep の4経路すべてが同一リゾルバを使用**して手書きパスのドリフトを排除:
    [main.ps1](backuper/main.ps1) (保存先既定)、
    [Prepare-LanMigration.ps1](tools/lan_prep/Prepare-LanMigration.ps1) (共有作成先＋次手順 hint)、
    [fabriq_lanprep.ps1](fabriq_lanprep.ps1) (メニュー Revert の snapshot 解決)、
    [Revert-LanMigration.ps1](tools/lan_prep/Revert-LanMigration.ps1) (note 表示の派生 localPath)。
    **共有フォルダ＝移行先のリストア元フォルダ**となり、後段の自動化 (完了フラグ／ポーリング自動選択)
    の土台になる。backup_view/restore_view の消費側は無改修。
  - **ポータブル運用は不変** (プロファイル不読込時は `<BackuperRoot>\Backup` 既定のまま)。
  - sample profile を schema 2 ＋ `<AUTO>` 規約へ更新、`share.shareName` を `FabriqBackup` に改称。
- backuper v0.39.0: **バックアップ画面のプリンタ初期チェックを「自動復元できるポート」に限定** —
  従来は仮想プリンタ (PDF/XPS/Fax/OneNote/RDP) だけを初期チェックから外し、それ以外は全て
  チェック済みだった。restore が programmatic に再現できるのは TCP/IP 標準ポート・LPR・IP 解決
  できる WSD (→ TCP/IP 9100 救済) のみで、USB / IP 不明 WSD / ローカル / Bonjour / その他は
  ポート再作成も Add-Printer もできず手動再追加になるため、**これらを初期チェックから外す**よう
  既定選択ロジックを変更 ([backup_view.ps1](backuper/lib/ui/backup_view.ps1) の
  `Update-BackupPrinterGrid` ＋ 新 `Test-BackupViewRestorablePort`)。初期状態のみの変更で、
  operator は従来どおり個別チェック / 全選択で USB・WSD なども選べる (後方互換)。
  - **判定ロジックの共通化**: ポート種別判定 `Get-PortType` と WSD の IPv4 抽出
    `Get-IPv4FromLocation` を [backup.ps1](backuper/lib/sections/printer/backup.ps1) のローカル定義
    から [common.ps1](backuper/common.ps1) の `global:` 関数へ移設し、backup section と backup view
    で共用。UI の初期チェック対象が「backup が分類し restore が扱える範囲」と完全一致する。
- backuper v0.37.0: **Outlook handoff をアカウント別ランチャ中心に再構成 (登録すべき件数を可視化)** —
  v0.36.0 の疑似画面ビューアを、移行先で「何件のアカウントを登録すべきか」が一目で分かる構成へ変更。
  - **アカウント別の起動バッチ**: handoff フロントに `① <email> の設定を表示.bat` …を **アカウント数
    だけ**生成 (バッチ本数 = 登録件数)。ダブルクリックで疑似画面がそのアカウントを選択した状態で
    開く ([Show-OutlookAccounts.ps1](backuper/lib/sections/outlook_pop/assets/Show-OutlookAccounts.ps1)
    に `-AccountIndex N` を新設、1 始まり。上部コンボで他アカウントへの切替も可)。
  - **フロントの整理**: 非バッチの補助ファイル (`Show-OutlookAccounts.ps1` / `_account_settings.txt` /
    `RESTORE_INSTRUCTIONS.txt` / `README.txt`) を `_data\` へ集約。フロントは「アカウント別バッチ ＋
    Restore-Outlook.bat」だけになり、作業員が迷わない。
  - viewer は `_data\` から manifest ＋ `_account_settings.txt` を読む。`_data` 名は維持
    (Restore-Outlook.bat の `%~dp0_data\` 依存のため)。平文パスワードの新規ディスク sink は増やさない
    (`_account_settings.txt` を front から `_data\` へ移設しただけ)。生成 `Restore-Outlook.ps1` の
    案内文も `_data\` ＋ アカウント別バッチを指すよう更新。
  - **対象**: assets viewer (`-AccountIndex`) ＋
    [restore.ps1](backuper/lib/sections/outlook_pop/restore.ps1) (Stage 5.7 再構成)。

### Fixed
- backuper v0.35.0: **クリーンアップ機能の LAN-Prep / バックアップ削除バグを修正 (実機テストで顕在化)** —
  v0.34.0 で追加した一括クリーンアップで報告された 2 件を修正:
  - **(1) グリッドのチェックボックスが対話的に切り替えられない**: `Set-GridStyle`
    ([theme.ps1](backuper/lib/ui/theme.ps1)) が DataGridView を `ReadOnly=$true` に設定するため、
    cleanup グリッドのチェックボックス列が編集不可になり、**pre-check 済みの集約/バックアップ行
    しか選択できず、LAN-Prep 行に手動チェックを入れられなかった** (集約フォルダが消えたのは
    pre-check のため)。[cleanup_view.ps1](backuper/lib/ui/cleanup_view.ps1) で Set-GridStyle 後に
    `$grid.ReadOnly = $false` を明示し、列/セル単位の ReadOnly (テキスト列=不可、選択列=可、
    未revert LAN-Prep セル=不可) を効かせる。
  - **(2) バックアップツリーの削除が失敗**: `Remove-CleanupArtifactTree`
    ([common.ps1](backuper/common.ps1)) が `[IO.File]::Delete` を直叩きしていたため、
    **robocopy /COPYALL backup が保持する読み取り専用属性**ファイルで UnauthorizedAccessException、
    深いユーザデータツリーで **長パス (>260 文字)** にも失敗していた (handoff は通常ファイルのため
    成功していた)。削除前に属性を Normal 化 + `\\?\` 長パス prefix (`ConvertTo-CleanupLongPath` 新設)
    + `[IO.Directory]::EnumerateFileSystemEntries` 列挙で堅牢化。**reparse point 非追従**
    (junction/symlink はツリー外へ波及しない) は維持。
  - **(3) 失敗内容が不可視だった**: 結果 popup に**失敗したパスとエラー内容 (先頭 5 件) + 履歴ログ
    パス**を表示し、失敗時は警告アイコンにするよう改善。全削除結果は引き続き
    `<BackuperRoot>\Backup\_cleanup_history.txt` に追記。
  - **修正ファイル**: [backuper/common.ps1](backuper/common.ps1) (Remove-CleanupArtifactTree 書換 +
    ConvertTo-CleanupLongPath 追加)、[backuper/lib/ui/cleanup_view.ps1](backuper/lib/ui/cleanup_view.ps1)
    (grid ReadOnly 解除 + 失敗詳細表示)。
  - **不変**: marker/認識/discovery/containment/revert ゲート/`Test-CleanupPathSafe` 安全弁の
    ロジック。section interface / manifest schema。
  - **検証**: read-only/hidden ファイル込みの再帰削除・長パス prefix・保護パス拒否を実関数テストで
    PASS、既存 31 アサーション回帰 PASS。GUI のチェック操作は要実機再確認。
  - **VERSION**: 0.35.0 据え置き (同 unreleased サイクル内のバグ修正)。

### Added
- backuper v0.35.0: **Outlook 保存パスワードの自動復元を backup に追加 (DPAPI, run-as-source-user)** —
  現代 Outlook (2016/2019/2021/365 = 16.0, 2013 = 15.0) は POP3/IMAP/SMTP の保存パスワードを
  レジストリ値内の **user-scoped DPAPI blob** (`0x02` タグ + `CryptProtectData` 出力、AES-256/
  SHA-512) として保持する (実機バイト解析で確定。Credential Manager でも XOR でもない)。これを
  backup 時に復号し、operator handoff のアカウント設定に出力することで、従来「operator が知らない
  パスワードを手入力」していた痛点を解消する。
  - **復号は移行元ユーザのセッション内でのみ可能** (DPAPI はユーザ束縛。operator が HKU\<SID> を
    オフライン読みしても復号不可)。→ `credentials` セクションと同型の **run-as-source-user 子
    プロセス**で実行: admin==移行元ユーザ時は直接子起動、別ユーザ昇格時は
    `Register-ScheduledTask -LogonType Interactive` (`/IT`)。移行元ユーザ未ログオン時は honest
    Failed (操作者が従来どおり手入力にフォールバック)。
  - **新規ファイル**:
    - [backuper/lib/sections/outlook_pop/dump_outlook_pw.ps1](backuper/lib/sections/outlook_pop/dump_outlook_pw.ps1):
      self-contained 子。移行元ユーザ文脈で各 `*Password*` 値を `CryptUnprotectData` (0x02 剥がし、
      entropy 無し) → UTF-16LE デコードし `{accountKey→plaintext}` を IPC JSON で返す。UTF-8 BOM。
  - **修正ファイル**:
    - [backuper/common.ps1](backuper/common.ps1): 汎用ヘルパ `Invoke-ChildAsTargetUser` を追加
      (schtasks-/IT + ProgramData IPC の子実行を一般化。`credentials` の inline ロジックも将来
      これへ移行可能)。stale IPC ファイルの best-effort sweep 付き。
    - [backuper/lib/sections/outlook_pop/backup.ps1](backuper/lib/sections/outlook_pop/backup.ps1):
      子を spawn し、復号平文を **サイドカー `_account_secrets.json` のみ**へ書込 (version+profile+
      subKey で突合、schtasks-/IT 時は子 identity 検証)。
    - [backuper/lib/sections/outlook_pop/restore.ps1](backuper/lib/sections/outlook_pop/restore.ps1):
      サイドカーを読み、handoff の `RESTORE_INSTRUCTIONS.txt` / `_account_settings.txt` の各
      ユーザ名行直後に `パスワード :` 行を出力 (`New-OutlookAccountInfoText` に `-SecretsByKey`)。
  - **セキュリティ**: 平文は **サイドカー (backup ツリー) と handoff テキストのみ**。manifest.json /
    .reg / `_credentials_list.csv` / コンソール (Show-*) / ユーザ Documents の legacy per-folder
    `_account_settings.txt` には **入れない**。JSON parse 失敗時に例外メッセージを補間しない (壊れた
    JSON 断片＝平文が集約 manifest / `_execution_log.txt` へ漏れるのを防止)。サイドカー・handoff・
    集約フォルダはいずれも v0.34.0 一括クリーンアップの対象。
  - **不変**: 既存 backup/restore の挙動 (復元失敗は非致命)、manifest/.reg schema、section
    interface、`New-OutlookAccountInfoText` の既存呼び出し (`-SecretsByKey` は既定 `@{}`)、EXE。
  - **VERSION**: 0.34.0 → **0.35.0** (MINOR / 後方互換な機能追加)。
  - **配備**: `E:\fabriq_backuper\` を customer 端末に再配置で反映。
  - **検証**: 実機で POP/IMAP 2 アカウントの DPAPI 復号→実パスワード一致を確認 (probe)。実関数の
    自動テスト 14 アサーション PASS (DPAPI 0x02 decode / 実 `Invoke-ChildAsTargetUser`+実子の
    self end-to-end / 親マージ→サイドカー→restore ローダ→profile|subKey 突合)。敵対レビュー反映済
    (平文漏れ監査・identity 検証・honest unavailable)。
- backuper v0.34.0: **移行成果物の一括クリーンアップ機能を追加 (削除マーカー + 自己識別ファイルの二段認識)** —
  移行作業後に各所へ散在する機密フォルダ (① backup ツリー = 平文ユーザデータ、
  ② デスクトップ集約フォルダ = 資格情報/Outlook/PC情報、③ 移行先 LAN-Prep フォルダ
  `C:\FabriqMigration`) を、Backuper の新「クリーンアップ」モードからホスト単位で
  まとめて削除できるようにした。手作業で散在フォルダを探して消していた運用を、
  確認付きワンボタンに置き換える (Revert-LanMigration が明示的に残す「手動削除して
  ください」のフォルダを肩代わりする位置づけ)。
  - **設計判断 (operator 確認済み)**:
    - **台帳なし・マーカーあり**: 中央索引は持たず、各フォルダ root に自己記述 marker
      `_fabriq_artifact.json` を best-effort で配置 (= 分散台帳。フォルダと共に移動し
      desync しない)。認識は **marker OR 既存の自己識別ファイルの二段**: backup =
      `manifest.json` (`fabriq-backuper-snapshot`)、lanprep = `_rollback_snapshot.json`、
      handoff = 名前 `*_<OldPC>_BK` ＋ (README.txt or `0N_` subdir)。marker 書込失敗でも
      取りこぼさない。
    - **ホスト識別子は成果物が自持ち** (`oldPcName` / フォルダ名) なので別表不要。
      lanprep のみ snapshot に host id が無いため、内包する backup の `oldPcName` から
      間接帰属。
    - **走査 root は有界**: `<BackuperRoot>\Backup\`(USB は相対でドライブレター非依存) /
      profile `share.localPath`(＋固定ドライブ root を1階層走査してリネーム保険) /
      全ローカルプロファイルの Desktop。移行先 PC 1台でスコープ内を全網羅。
    - **revert ゲート**: lanprep フォルダは network 復元の生命線 (`_rollback_snapshot.json`)
      を同居するため、**`_revert_done.json` (Revert-LanMigration が成功時に配置) がある時のみ
      削除可**。共有消滅/IP は removeShare 条件付き・snapshot 永続のため不採用。未配置時は
      行を選択不可にし「先に『元に戻す』を実行」へ誘導 (ack で手動解除可)。
    - **削除安全弁**: `Test-CleanupPathSafe` がドライブ root / UNC root / `C:\Windows` /
      `C:\Users` / ユーザ profile root / Desktop root / fabriq main 配下 / repo /
      BackuperRoot / `Backup` root を deny。`Backup\<OldPC>\<ts>` 等の深い子のみ許可。
      `Remove-Item -Recurse` は ReparsePoint (junction/symlink) を辿らない再帰削除で
      ツリー外への波及を防止。**強確認** (対象ホスト名のタイプ入力一致) を要求。
  - **新規ファイル**:
    - [backuper/lib/ui/cleanup_view.ps1](backuper/lib/ui/cleanup_view.ps1): クリーンアップ
      画面 (候補グリッド / LAN-Prep ack / 強確認ダイアログ / 削除結果サマリ)。UTF-8 BOM。
  - **修正ファイル**:
    - [backuper/common.ps1](backuper/common.ps1): cleanup ヘルパ群を追加 (`New-CleanupMarker`
      / `Read-CleanupMarker` / `Test-CleanupArtifactRecognized` / `Test-CleanupPathSafe` /
      `Test-LanPrepReverted` / `Get-CleanupCandidate` / `Remove-CleanupArtifact` /
      `Remove-CleanupArtifactTree` / `Write-CleanupHistory` / `Get-CleanupSourceLabel`)。
    - [backuper/lib/engine.ps1](backuper/lib/engine.ps1): backup の aggregateDir 生成直後に
      backup-tree marker を best-effort 書込。
    - [backuper/lib/ui/restore_view.ps1](backuper/lib/ui/restore_view.ps1): handoff root の
      mkdir + README 直後に handoff marker を best-effort 書込 (全 section skip でも認識可)。
    - [backuper/lib/ui/session_form.ps1](backuper/lib/ui/session_form.ps1): 第3アクション
      ボタン「クリーンアップ」追加 (`Mode='Cleanup'`)。Backup/Restore ボタンを再配置。
    - [backuper/lib/ui/main_form.ps1](backuper/lib/ui/main_form.ps1): `InitialMode` の
      ValidateSet に `Cleanup` を追加、`$script:Views['Cleanup']=New-CleanupView` を登録。
    - [backuper/main.ps1](backuper/main.ps1): `lib\ui\cleanup_view.ps1` を dot-source 対象に追加。
    - [tools/lan_prep/Revert-LanMigration.ps1](tools/lan_prep/Revert-LanMigration.ps1): 成功時に
      snapshot 隣へ `_revert_done.json` (`fabriq-lanprep-revert-done`) を配置 (ASCII)。
  - **不変**:
    - 既存 backup/restore/lanprep の挙動 (marker 書込は best-effort で失敗しても本処理継続)。
    - aggregate / section manifest schema、section interface、fabriq main への書込み (なし)。
    - `main.ps1` の `Start-FabriqBackuperGui` シグネチャ (cleanup_view は dot-source スコープ
      の `$script:MigrationProfile` を既存 view 同様に直接参照、新パラメータ不要)。
    - EXE は無変更 (再ビルド不要)。
  - **VERSION**: 0.33.4 → **0.34.0** (MINOR / 後方互換な機能追加)。
  - **配備**: `E:\fabriq_backuper\` を customer 端末に再配置で反映。
  - **検証 (実関数で自動テスト済 = 37 アサーション PASS)**:
    1. marker round-trip / 3 種別の認識 / revert ゲート (marker 有無)
    2. `Test-CleanupPathSafe`: ドライブ・UNC・Windows・Users・profile・Desktop・fabriq subtree・
       repo・BackuperRoot・Backup root の deny と、`Backup\<host>\<ts>` / Desktop `*_BK` /
       `C:\FabriqMigration` の allow
    3. `Get-CleanupCandidate`: USB backup / lanprep / ネスト backup の発見、ネスト backup から
       の lanprep host 帰属、containment (ParentPath)、未revert フラグ
    4. `Remove-CleanupArtifact`: 再帰削除 / 保護パス拒否 (backuper root・fabriq subtree) /
       欠落 Skipped、`Write-CleanupHistory` 追記
    5. (要実機) GUI: セッション画面「クリーンアップ」→ 候補表示 → チェック → ホスト名
       タイプ確認 → 削除 → 結果サマリ。LAN-Prep 行は `_revert_done.json` 不在時 選択不可。

### Changed
- backuper v0.33.4: **自動復元 (POP-only) の operator 案内を実手順に刷新** —
  従来の案内は「Restore-Outlook.bat 実行後 Outlook を 2 回起動・パスワード入力」
  だったが、現場の実手順と乖離していた。実際の微調整作業（コントロールパネル
  「メール」→「プロファイルの表示」を開いて閉じる〔プロファイル選択プロンプト回避〕
  →「電子メール アカウント」で各アカウントの「変更」からパスワードのみ入力→
  Outlook 起動時の仕分けルール・リセット〔全 OFF→適用→全 ON→適用→手動実行1回、
  または「仕分けルールをクリア」ショートカットで一括クリア〕→送受信確認）に合わせて
  案内文を書き換え。
  - 対象 3 箇所: `New-OutlookHandoffReadme` の README.txt 本文 (common.ps1)、
    生成バッチ Restore-Outlook.ps1 の "NEXT" コンソール文言 (ASCII)、完了 popup 本文
    (restore.ps1、handoff-OFF legacy 経路のみ表示)。
  - **仕分けルールクリア ショートカットの配置を集約フォルダに統一**: 従来は
    対象ユーザの Desktop 直下に置いていた「Outlook を初回起動 (仕分けルールを
    クリア).lnk」を、他の Outlook 復元ファイルと同じ操作者集約フォルダ
    (02_outlook_アカウント情報) に配置するよう変更 (`New-OutlookRuleClearShortcut`
    に `-DestinationDir` を追加、`$operatorHandoffSubdir` を渡す)。handoff フォルダが
    無い legacy 経路では従来どおり Desktop にフォールバック (その経路の popup 文言は
    Desktop 表記のまま正しい)。README はショートカット位置を「このフォルダ」に更新。
  - **文言＋ショートカット配置のみの変更**。復元ロジック・manifest・バッチ動作・
    ショートカットの中身 (/cleanclientrules) は不変。
  - **VERSION**: 0.33.3 → **0.33.4** (PATCH / operator ドキュメント刷新 + 成果物配置統一)。

### Fixed
- backuper v0.33.3: **単一PST・カスタム名 PST の B-light 復元で DSE が欠落ファイルを指す
  desync を修正 (Strategy B-light ではリネームを skip)** —
  Stage 2 は単一PST profile の PST を `<email>.pst` にリネーム ([restore.ps1:1186]) する一方、
  T8/001f6700 の DSE パス書換は**ディレクトリ prefix のみ rebase しファイル名は原名のまま**
  ([restore.ps1:534-547])。このため**元PSTが `<email>.pst` 以外の名前**（`Outlook.pst`/
  `個人用.pst` 等の legacy 名。backup の PST 解決は EntryID 主導なので普通に発生）だと、
  reg import 後の **Delivery Store EntryID が実在しないファイルを指し**、Outlook がデータ
  ファイルを再要求/既定 store へ再バインド → T8 の per-account binding 保持が無効化されていた。
  - **修正 (案B)**: 新ヘルパ `Test-OutlookProfileAutoEligible`（`AttemptStrategyB AND handoff
    present AND profile に regExport AND POP-only`）を Stage 2 前に追加し、**auto-eligible な
    単一PST profile はリネームを skip**（既存の複数PST と同じ `renameSkipped=$true`／原名保持
    ブランチを流用）。placed file が**byte-proven の DSE が指す rebased-原名のまま残り desync 解消**。
  - **T8/byte-transform は一切無変更**（DSE/DFE バイト・GOLD 一致・複数POP collapse 修正
    v0.33.0 は不変）。リネームが実際に起きる場合（元名 ≠ `<email>.pst`）だけを gate するため、
    元名=`<email>.pst` の**最頻ケースは完全不変**（rename は元々 no-op）。
  - **不変**: 複数PST（既に skip）／IMAP／pst 無し／Strategy A（IMAP混在・reg無・opt-out は
    引き続きリネーム＝path-collision-attach 維持）。`_account_settings.txt` は既に
    `renameSkipped` を扱えるため文言が原名基準に正確化するのみ。
  - **唯一のトレードオフ**: Stage 2 で eligible だが Stage 3 で transform 失敗 → Strategy A
    降格の稀ケースで、PST が原名のまま（自動 path-collision-attach は効かず operator が
    RESTORE_INSTRUCTIONS の原名で browse）。機能喪失ではなく自動度がわずかに下がるのみ。
  - **VERSION**: 0.33.2 → **0.33.3** (PATCH / desync バグ修正)。

- backuper v0.33.2: **Outlook 2013 (15.0) のバックアップが profile_*.reg を出力しない不具合を修正
  (空 16.0 キーによる version shadowing)** —
  移行元が **Outlook 2013 (15.0) 専用機**でも、HKCU ユーザ hive に過去の Outlook 2016/365 が
  残した**空の `Office\16.0\Outlook\Profiles` キー**があると、backup の Profiles probe が
  **「16.0 を先に試し、存在したら即 break」**するため 16.0 を掴み、本物の 15.0 プロファイルを
  一度も列挙せず **profile 0 件・reg 0 件を無警告で skip** していた (manifest は
  `outlookVersion=16.0` だが `installedOutlook.registryVersion=15.0` という矛盾を記録)。
  HKLM 実機 probe (`Get-OutlookInstallInfo`) は 15.0 を**正しく検出していたのに version 選択に
  使われていなかった**のが核心。section 誕生時 (fabriq-main 2026-05-16) から潜在していたバグで、
  v0.32.0 のバッチ化とは無関係 (移行元機に空 16.0 キーが現れた時のみ顕在化)。
  - **修正**: probe を「存在する**全** version を収集 (break しない)」に変更し、HKLM probe 後に
    新ヘルパ `Select-OutlookProfilesVersion` で最終選択 — **(1) HKLM 実機 version (profile を
    実際に持つ場合のみ) → (2) profile 数が最多の version → (3) first present** の優先順位。
    `manifest.outlookVersion` も実列挙 version を記録 (restore 側 T1 の cross-version rebase が
    依存する load-bearing 値)。
  - **silent-skip 再発防止**: 「Outlook は install 済みなのに POP/IMAP account 0 件」を warning に
    格上げ (Exchange/M365 OAuth 専用なら正常、と明記)。shadow を検知・回避した場合も
    operator-visible な warning を記録。
  - **回帰なし**: 対照群 (2016/365 capture) は HKLM==enumerated==16.0 で選択結果が現行と同一、
    side-by-side は HKLM 最上位版を優先、HKLM null 時はフォールバックで現行同等まで縮退するのみ。
    restore 側・manifest schema は無変更。
  - **VERSION**: 0.33.1 → **0.33.2** (PATCH / バグ修正)。

- backuper v0.33.1: **Outlook パス書換を full profile-prefix rebase に統一 (別ドライブ/リダイレクト profile 対応)** —
  v0.33.0 の T4/T8 パス書換は `\Users\<user>\` ディレクトリに anchor していたが、
  **移行元と移行先でドライブが違う** (例 `D:\Users\…` → `C:\Users\…`) / **プロファイルが
  非 `\Users\` 親にリダイレクト** (例 `D:\Profiles\suzuki`・ProfilesDirectory 変更・
  ローミング) の場合に、PST パスの prefix が正しく rebase されず stale path
  (= 当該 account が未バインド) になっていた。`Convert-RegFileToStrategyBLight` に
  `-SourceProfilePath` / `-TargetProfilePath` を追加し、両方ある時は
  **Stage 2 の PST 配置と同じ「フル profile prefix rebase」** (`$sourceUserProfile` →
  `$targetUserProfilePath`) を行うよう統一。profile path が無い場合は従来の
  `\Users\<user>\` anchor にフォールバック。
  - **標準ケース (移行元/先とも `C:\Users\<user>`) はバイト同一**で挙動不変 (full-prefix
    と `\Users\` anchor は同じ出力バイトを生成、GOLD バイト一致を再検証済)。
  - ファイル名/mspst ヘッダは引き続き不可侵 (v0.33.0 の hardening を包含)。
  - これで `.DOMAIN`/`.000`/リネーム/別ドライブ/リダイレクト/login==local-part の
    全ケースで正しく rebase される (実関数で全ケース検証済)。
  - **VERSION**: 0.33.0 → **0.33.1** (PATCH / 内部堅牢化)。

- backuper v0.33.0: **複数POP×別PST プロファイルの配信先 collapse を修正 (T8: DSE 書換 + DFE 保持)** —
  2 つ以上の POP アカウントがそれぞれ別 PST を持つプロファイルを自動復元すると、
  全アカウントが同じ(先頭) PST に紐づいてしまう不具合を修正。**root-cause は
  `Convert-RegFileToStrategyBLight` の旧 T2 が各アカウントの "Delivery Store
  EntryID" (DSE) と "Delivery Folder EntryID" (DFE) を strip していたこと**：
  配信先ポインタが消えるため Outlook が初回起動で全アカウントを既定 store に
  再 bind していた。
  - **修正 (T8)**: POP アカウントの DSE/DFE を strip せず —
    - **DSE** = 54byte 定数 mspst ヘッダ + 末尾 PST パス(UTF-16LE) + `00 00`
      (長さフィールド無し)。埋め込みパスの **`\Users\<src>\` ディレクトリ部だけ**を
      `\Users\<dst>\` に書換 (001f6700 と同じ anchor 付きパス)。各 POP
      アカウントが自分の PST に bind されたまま残る。
    - **path 書換の anchor 化 (hardening)**: 当初は username トークンの**盲目的
      置換**だったが、ログイン名がメール local-part の substring の場合
      (例 login `suzuki` + `suzuki@…`) に **PST ファイル名まで巻き込んで書換** →
      存在しない `<dst>@…pst` を指して当該 account が collapse する不具合を
      **実機で確認 (2026-05-30, suzuki→test)**。`\Users\<user>\` ディレクトリに
      anchor することで**ファイル名・mspst ヘッダ・ドメイン**を巻き込まなくなり、
      `l`/`n` 等の短いユーザ名によるヘッダ破壊も同時に根絶。**既存 T4
      (001f6700/001f0433/001f6610) も同欠陥だったため一括で anchor 化**。GOLD の
      バイト一致 (y_suzuki→test) は維持 (AST 抽出した実関数で再検証済)。
    - **DFE** = `00000000` + store の `01020ff9` (PR_RECORD_KEY) + `82800000`。
      パスを含まず import 後も valid なため **verbatim 保持**。
    - 共有 `0a0d02` folder-set index は触らない (stale source パスは Outlook が
      許容するため。実機 export + ライブ実機で確認済)。
  - **エビデンス (BYTE-PROVEN + ライブ確認)**: 2026-05-30 に operator が target
    側の before(collapse) / after(手動「フォルダーの変更」後 = 正常動作) を採取
    (`E:\test\outlookbktest\2026_05_30`, 2-POP suzuki+sales1, y_suzuki→test の
    cross-user)。実装した T8 コードを source に適用した出力 DSE/DFE が、Outlook
    自身が正しく紐づけた時の値と**バイト完全一致**することを検証 (AST 抽出した
    実関数、両アカウント DSE=174byte 一致・DFE 一致)。**さらに実機リストアで
    Outlook の PST 関連付けが正常になることを確認 (ライブ合格)**。
  - **修正ファイル**: [backuper/lib/sections/outlook_pop/restore.ps1](backuper/lib/sections/outlook_pop/restore.ps1)
    の `Convert-RegFileToStrategyBLight` (T2 部を T8 に置換、IMAP Store EID
    strip は防御的に維持)。section interface / manifest schema 不変。
  - **不変**: IMAP 混在プロファイルは引き続き Strategy A 手動 (本関数に来ない)。
    handoff バッチモデル (v0.32.0) / 他 section / fabriq main への書込み (なし)。
  - **VERSION**: 0.32.0 → **0.33.0** (MINOR / Changed)。
  - **配備**: `E:\fabriq_backuper\` を再配置で反映 (EXE 無変更)。

### Changed
- backuper v0.32.0: **Outlook プロファイル自動復元をバッチ化して handoff フォルダに移行** —
  これまで Strategy B-light は**リストア実行中 (engine コンテキスト)** に
  `reg.exe import` で target レジストリを直接書き換えていた。これを printer
  (`Install-Printers.bat`, v0.29.0) / credentials (`登録.bat`) と同じ
  **operator handoff バッチモデル**に統一する。POP-only プロファイルについて、
  リストア時に T1-T6 変換 + hive prefix を `HKEY_CURRENT_USER` に書換した
  **import-ready `.reg`** を生成し、`02_outlook_アカウント情報\` に
  `Restore-Outlook.bat` + `Restore-Outlook.ps1` を配置する。operator は
  **移行先ユーザでログインした状態 (非 admin)** でバッチをダブルクリックする
  ことで、自分の HKCU に直接取り込む。これにより `Resolve-HkcuRoot` の
  HKU\<SID> リダイレクト (v0.17.0 で対処した New-PSDrive scope 脆弱性) を
  Outlook 復元経路から**構造的に排除**する。
  - **設計判断 (operator 確認済み)**:
    - 案A (pre-bake): 変換 (T1-T6) は**リストア時に restore.ps1 が実行**し、
      import-ready `.reg` を `_data\` に出力。繊細な変換エンジンを 1 か所に
      保持し、バッチは「import + verify」の薄い実装。
    - **完全廃止** (printer v0.29.0 型): in-engine の `reg.exe import` を撤廃。
      `Invoke-RegImport` / `Test-AccountImported` 相当は生成バッチ側に移設。
    - **default ON**: UI checkbox 既定を ON 化 (文言「Outlook 自動復元バッチを
      生成 (推奨)」)。OFF で Strategy A ファイルのみ (バッチ非生成)。
  - **リストア時の section popup を抑止 (スムーズ化)**: outlook_pop section が
    Stage 5 で出していた自前モーダル (`Show-CompletionPopup`) を、**operator
    handoff フォルダ使用時 (default) は出さない**よう変更。printer / credentials
    / system_evidence と同じく、案内は handoff の README.txt / Restore-Outlook.ps1
    実行時 console / progress log / run 末尾の共通完了 popup に集約する。
    **handoff OFF (Desktop 集約フォルダが無い legacy opt-out 経路) のときのみ**
    従来通り popup を表示 (案内が辿りにくい backup 元フォルダにしか出ないため、
    この経路の popup を消すと退行する)。run 末尾の共通完了 popup (全 section 1 個)
    は有用なため不変。情報の損失なし (2 回起動 / パスワード / IMAP 手動 / 異
    バージョン clean-up の各案内は README.txt と _account_settings.txt に保持)。
  - **新規ファイル (operator 実機に配備されるもの)**:
    - `02_outlook_アカウント情報\Restore-Outlook.bat`: 移行先ユーザが
      ダブルクリック (UAC 不要、`登録.bat` と同 idiom、`%~dp0` トラップ回避で
      引数なし呼び出し)
    - `02_outlook_アカウント情報\_data\Restore-Outlook.ps1`: ASCII-only。
      preflight (OUTLOOK.EXE close) → `reg.exe import` (HKCU) → POP3 Server
      verify → console/`_RestoreOutlookReport.txt` サマリ。admin 実行時は
      警告 (HKCU 誤爆防止)
    - `02_outlook_アカウント情報\_data\profile_<name>.import.reg`: 変換済み
      (UTF-16LE)
    - `02_outlook_アカウント情報\_data\_restore_config.json`: target/source
      profile + outlook version + auto/manual プロファイル一覧
  - **修正ファイル**:
    - [backuper/lib/sections/outlook_pop/restore.ps1](backuper/lib/sections/outlook_pop/restore.ps1):
      Stage 3+4 の import/verify ループを削除し、pre-bake + handoff バッチ
      生成 (Stage 3/4) に置換。Stage 5 popup を batch-aware 化。`AttemptStrategyB`
      既定を `$true` に。return Summary を `strategy='B (handoff batch)'` /
      `batchGenerated` / `autoProfiles` / `manualProfiles` に更新。**IMAP gate
      は維持** (IMAP を含むプロファイルは Strategy A 手動)。`Get-RegFileSourceHive`
      / `Convert-RegFileToTargetHive` / `Convert-RegFileToStrategyBLight` は
      pre-bake で継続使用。`Invoke-RegImport` / `Test-AccountImported` は
      restore.ps1 からは未使用化 (バッチ側に同等ロジックを inline、将来 cleanup 候補)
    - [backuper/common.ps1](backuper/common.ps1): `New-OutlookHandoffReadme`
      (日本語 README, BOM 付き) を追加。printer の役割分離 pattern と同じく
      restore.ps1 (ASCII) から呼び出し `UTF8Encoding($true)` で出力
    - [backuper/lib/ui/restore_view.ps1](backuper/lib/ui/restore_view.ps1):
      checkbox 既定 ON + 文言更新、`$attemptStrategyB` UI 既定を `$true`、
      全体 handoff README の `02_` 項に Restore-Outlook.bat の使い方を追記
  - **不変**:
    - **PST 配置 (Stage 2) はリストア時のまま据え置き** — admin で動作し実績
      あり、SID リダイレクト問題は registry import 固有のため移設不要。バッチは
      PST 存在を advisory チェックのみ
    - section interface / manifest schema (`fabriq-outlook-pop-backup` v1) 不変
    - backup.ps1 / IMAP gate / multi-PST skip / cross-version (T1) / 「Outlook を
      2 回起動」案内 / rule-clear shortcut (今回スコープ外) は不変
    - fabriq main への書込みなし、EXE 無変更
  - **前提**: リストアは**移行先 PC 上で実行**する運用 (案A の T1 pre-bake は
    target Outlook 版数を restore 時に検出するため)
  - **VERSION**: 0.31.0 → **0.32.0** (MINOR / printer v0.29.0 と同型、
    テスト段階方針につき in-engine import 廃止は後方互換扱わず MINOR)
  - **配備**: `E:\fabriq_backuper\` を再配置で反映 (EXE 無変更)
  - **検証**:
    1. handoff ON + 自動復元 ON で POP-only profile を restore →
       `02_outlook_アカウント情報\` に Restore-Outlook.bat / README.txt /
       `_data\Restore-Outlook.ps1` / `_data\profile_*.import.reg` /
       `_data\_restore_config.json` / `_data\manifest.json` が生成される
    2. **移行先ユーザでログイン**して Restore-Outlook.bat ダブルクリック →
       OUTLOOK 起動検知 (起動中なら閉じる) → import → POP3 Server verify →
       サマリ表示。Outlook 2 回起動でパスワード入力後に送受信成功
    3. **管理者として実行**した場合に警告 + 続行確認が出ること (HKCU 誤爆防止)
    4. IMAP 混在 profile → バッチは POP 分のみ自動化、IMAP は README /
       `_account_settings.txt` の手動手順へ誘導
    5. 全 IMAP 環境 → import-ready .reg 0 件 → バッチは生成されず Strategy A
       ファイルのみ (popup も手動セットアップ案内)
    6. 自動復元 OFF (checkbox) → バッチ非生成、`_account_settings.txt` /
       `RESTORE_INSTRUCTIONS.txt` のみ
    7. `git diff` で fabriq main 配下への書込みが無いこと

### Added
- backuper v0.31.0: **アプリ移行チェックツールを system_evidence section に同梱** —
  案件ごとに「移行先 PC に必要なアプリ」を定義した CSV と、`system_evidence`
  が採取した `11_DesktopApps.csv` / `11_StoreApps.csv` を突き合わせて、operator
  が target PC のデスクトップ集約フォルダで `.bat` をダブルクリックするだけで
  「移行が必要なアプリ」を一覧できる基盤を追加。
  - **新規ファイル**:
    - [.gitignore](.gitignore): repo 直下に新設。`backuper/data/app_migration_list.csv`
      を ignore (案件固有のアプリ名が誤コミットされる事故を防止)。サンプル
      テンプレート (`*.sample.csv`) は commit 対象として残す
    - [backuper/data/app_migration_list.sample.csv](backuper/data/app_migration_list.sample.csv):
      案件定義 CSV のテンプレート。**UTF-8 BOM + CRLF**。Excel で開いた時の
      日本語化け回避のため BOM 必須。10 件の代表アプリ例 (Microsoft 365 /
      Chrome / Acrobat / 秀丸エディタ / TeraTerm 等) を同梱
  - **修正ファイル**:
    - [backuper/common.ps1](backuper/common.ps1) (BOM 付き既存ファイル) に
      helper 2 個を追加:
      - `New-AppMigrationCheckBat`: ASCII only な `.bat` 本体 (chcp 65001 +
        powershell -File、`%*` で `/verbose` などの引数 forward)
      - `New-AppMigrationCheckScript`: 日本語 string label を含む `.ps1`
        本体を返す。restore.ps1 が `UTF8Encoding($true)` で書き出すことで
        BOM 付き UTF-8 ファイルとして配備される。printer の
        `New-PrinterHandoffReadme` / `New-PrinterSettingsText` と同じ
        役割分離 pattern (ASCII only restore.ps1 から helper 経由で日本語
        を扱う、CLAUDE.md 規約 5 準拠)
    - [backuper/lib/sections/system_evidence/restore.ps1](backuper/lib/sections/system_evidence/restore.ps1):
      handoff deploy 直後に新規ステップを挿入。
      - `<repo>/backuper/data/app_migration_list.csv` を handoff 配下に Copy
        (不在時は warning + sample のみ deploy で継続)
      - `<repo>/backuper/data/app_migration_list.sample.csv` を handoff 配下に Copy
      - `Check-AppMigration.bat` (ASCII) を handoff 配下に生成
      - `_data\Check-AppMigration.ps1` (UTF-8 BOM) を handoff 配下に生成
      - `_restore_manifest.json` の `appMigrationCheck` フィールドに deploy
        状況 (toolDeployed / listCsvCopied / sampleCsvCopied) を記録
      - 失敗は warning に降格、section 全体は Success のまま (evidence Copy
        が既に成功しているため)
    - [backuper/lib/ui/restore_view.ps1](backuper/lib/ui/restore_view.ps1):
      handoff folder の README.txt 内、`03_移行元PC情報\` セクションに
      Check-AppMigration.bat の使い方を 5 行追記 (BOM 付き既存ファイル
      なので日本語をそのまま記述)
  - **バッチ実行フロー** (operator 視点):
    1. target PC のデスクトップで `<date>_<host>_BK\03_移行元PC情報\Check-AppMigration.bat`
       をダブルクリック (UAC 不要)
    2. console に「要移行 / 未検出 / サマリ」が日本語表示
    3. 同じ内容が同フォルダの `_AppMigrationReport.txt` に BOM 付き UTF-8
       で保存される (Notepad で開いて日本語正常表示)
    4. `Check-AppMigration.bat /verbose` で「補足: source にあるが案件未登録」
       セクションも表示
  - **マッチング仕様**:
    - 案件定義 CSV の `MatchPatterns` 列を `|` で分割した各パターンを
      case-insensitive 部分一致 (`-like '*pat*'`) で source 採取アプリの
      Name (Desktop は Publisher も) と照合
    - **Desktop apps**: `Name + " | " + Publisher` を hay に
    - **Store apps**: `Name` のみを hay に (StoreApps.csv の Publisher 列は
      `PublisherId` = hash 文字列で人間可読でないため照合対象から除外)
    - 1 案件 entry に複数 source アプリが該当した場合は全部表示
  - **エンコーディング多重ガード**:
    - 案件定義 CSV (operator が Excel 編集) の読み込みは **BOM 自動判定**:
      ファイル先頭 3 bytes が `EF BB BF` → `Import-Csv -Encoding UTF8`、
      無 BOM → `Import-Csv -Encoding Default` (= JP Windows では CP932)。
      Excel の「CSV UTF-8」/「CSV」両方の保存形式に対応
    - `11_DesktopApps.csv` / `11_StoreApps.csv` は backup.ps1 の
      `Export-Csv -Encoding UTF8` で BOM 付き UTF-8 確定なので
      `-Encoding UTF8` 固定で読込
    - `.bat` 冒頭で `chcp 65001` + ps1 冒頭で `[Console]::OutputEncoding =
      UTF8` の二段ガード (どちらか単独では PS5.1 が CP932 を保持する罠)
    - `_AppMigrationReport.txt` は `UTF8Encoding($true)` で BOM 付き出力
      (PS5.1 の `Out-File -Encoding utf8` は BOM 無しを出す罠を回避)
  - **bat の引数渡し設計** (smoke test で発見した罠への対処):
    `"%~dp0"` を引数で渡す古典 trap (末尾 `\` が PowerShell argv parser で
    閉じ quote のエスケープと解釈され、$HandoffDir 末尾に `"` が混入する)
    を回避するため、bat は引数を一切渡さず、ps1 が `$PSScriptRoot`
    (= `<handoff>\_data\`) の親を handoff root として解決する設計に統一。
    printer の Install-Printers.bat と同じパターン。
  - **不在系の挙動** (crash 防止):
    - repo `app_migration_list.csv` 不在 → restore.ps1 が warning、sample
      のみ deploy。bat 実行時に親切なメッセージ表示
    - handoff `app_migration_list.csv` 不在 → bat 実行時に「sample をコピー
      して編集してください」案内 + exit 1
    - `11_DesktopApps.csv` / `11_StoreApps.csv` 不在 (pre-v0.26.0 backup) →
      bat 実行時に「system_evidence 採取がされていない可能性」案内 + exit 1
    - handoff checkbox OFF / pre-v0.26.0 backup → system_evidence/restore.ps1
      自体が早期 Skipped を返すため、バッチ配備自体が行われない (= 既存の
      Skipped 挙動と完全に整合)
  - **不変**:
    - section interface / sections.csv 実行順 / aggregate manifest schema
    - backup 経路 (system_evidence/backup.ps1) は一切変更なし
    - 他 5 sections / engine / restore_view の handoff root mkdir & README
      生成ロジック / fabriq main への書込み (なし)
    - EXE は無変更 (再ビルド不要)
    - **LAN-Prep v0.30.0 への影響なし**: 同じ `[Unreleased]` に独立した
      機能として並ぶ (LAN-Prep entry は本 entry の直下に保持)
  - **VERSION**: 0.29.0 → **0.31.0** (MINOR、後方互換な機能追加)。
    v0.30.0 番号は LAN-Prep entry が既に占有しているため一つスキップ
  - **配備**: `E:\fabriq_backuper\` を customer 端末に再配置で反映。
    案件担当が `backuper/data/app_migration_list.sample.csv` をコピーして
    `backuper/data/app_migration_list.csv` を作成し、案件アプリを記述
  - **検証**:
    1. `app_migration_list.sample.csv` を Excel で開き日本語が文字化けしない
       (UTF-8 BOM 効果)
    2. sample をコピーして `app_migration_list.csv` を作成
    3. `git status` で `app_migration_list.csv` が untracked 表示されない
       (= .gitignore 反映、検証済 = OK)
    4. backup → restore (handoff ON) で `03_移行元PC情報\` 配下に 4 entry
       (Check-AppMigration.bat / app_migration_list.csv /
       app_migration_list.sample.csv / _data\) が配備される
    5. `Check-AppMigration.bat` ダブルクリック → console で要移行 / 未検出 /
       サマリの 3 セクションが日本語正常表示
    6. `_AppMigrationReport.txt` を Notepad で開いて同内容が日本語正常表示
    7. `app_migration_list.csv` をリネーム/削除して bat 実行 → 親切な warning +
       exit (crash しない)
    8. `Check-AppMigration.bat /verbose` で「補足」セクションが追加表示
    9. handoff OFF で restore → バッチ配備されない (system_evidence Skipped)
   10. pre-v0.26.0 backup を v0.31.0 で restore → system_evidence は Skipped
       (= バッチ配備されない)、他 sections は通常動作

### Changed
- backuper v0.31.0: **LAN-Prep 役割ボタン文言を「〜の設定を行う」形に補強** —
  「移行先（新PC）」「移行元（旧PC）」を「移行先（新PC）の設定を行う」
  「移行元（旧PC）の設定を行う」に変更。動作詞 (「設定を行う」) を補うことで
  「クリックすると何が起こるか」が文面で完結。menu_form.ps1 のボタン .Text
  プロパティ 6 箇所のみ変更、.BgColor / 色合い / Click handler / 戻り値 /
  子スクリプト呼び出し / dynamic label updater の改行構造はすべて不変。
  - **不変**: Backuper 配下 / VERSION / theme.ps1 / fabriq_lanprep.ps1 /
    Prepare-LanMigration.ps1 / Revert-LanMigration.ps1 / ボタン色 (移行先 =
    lavender、移行元 = stripeYellow)
  - **VERSION**: 0.31.0 据え置き (cosmetic、Backuper 無影響)

- backuper v0.31.0: **LAN-Prep メニューの役割ボタン文言を短縮 + 移行元ボタンを
  黄色に** — operator が役割をひと目で判別できるよう cosmetic 調整。
  動作 (Click handler / 戻り値 / 子スクリプト呼び出し / 引数) は完全に不変、
  ボタンの `.Text` プロパティと `.BgColor` プロパティのみ変更。
  - **文言**: 「移行先として設定」→「移行先（新PC）」、「移行元として設定」→
    「移行元（旧PC）」。dynamic role-button label updater (hostlist-driven
    モードでのみ動作) の `(profile 値)` / `(この PC = ...)` 接尾も同じ
    新文言で整合
  - **色**: 移行先ボタン = `$script:bgAccent` (lavender #9366BD、不変)、
    移行元ボタン = `$script:stripeYellow` (#F2C94C、既存 theme 定義をそのまま
    使用)。New-StyledButton は bgAccent 以外を受けると ForeColor 自動で
    濃色 (#222222) に切り替わるためコントラスト OK、テーマ整合性も維持
  - **不変**: Backuper 配下 / VERSION / fabriq_lanprep.ps1 /
    Prepare-LanMigration.ps1 / theme.ps1 / Click handler / 戻り値 /
    `$script:_lanPrepMenuResult` の action 値 (`target`/`source`/`revert`/`exit`)
    / FABRIQ_LANPREP_HOSTLIST=1 経路の hostlist combo の挙動
  - **VERSION**: 0.31.0 据え置き (cosmetic、Backuper 無影響)
  - **検証**: メニューを開いて移行先 = 紫、移行元 = 黄色の 2 色配色になる
    こと、ボタンをクリックして従来通り Prepare-LanMigration.ps1 -Role
    target/source が走ること、FABRIQ_LANPREP_HOSTLIST=1 起動で hostlist
    combo 選択時に「移行先（新PC）`\r\n`(この PC = NEW-PC-01)」の改行 2 行
    表示になること

- backuper v0.31.0: **LAN-Prep の hostlist 駆動 + passphrase prompt + fabriq main
  必須化を default OFF に切り替え** — v0.30.0 で追加した hostlist combo / NIC
  combo のうち、現場運用で実利が薄いと判明した hostlist 関連 (PC ペア選択 + ENC:
  暗号化フィールド用 passphrase ダイアログ + fabriq main 不在時の起動拒否) を
  default で実行しないようにした。NIC combo + 移行先 / 移行元 / 元に戻す / 終了
  ボタンだけのシンプルなメニュー画面に戻る。
  - **Backuper への影響**: なし。本 entry の修正対象は LAN-Prep の entry script
    と menu form のみ。`backuper/` 配下と VERSION ファイルは一切変更なし
    (本 release は v0.31.0 据え置きで [アプリ移行チェック entry](#added) と
    同 release に同梱)
  - **隠しスイッチ**: 環境変数 `FABRIQ_LANPREP_HOSTLIST=1` を設定して
    `Fabriq_LanPrep.exe` を起動すると v0.30.0 と同等の動作に復帰
    (hostlist combo + passphrase prompt + fabriq main 必須化が全て有効)。
    将来この機能を完全削除する際の seam として残置
  - **修正ファイル**:
    - [fabriq_lanprep.ps1](fabriq_lanprep.ps1): 起動時に
      `$env:FABRIQ_LANPREP_HOSTLIST -eq '1'` を確認し `$script:HostlistDriven`
      に格納。Find-FabriqRoot 必須ロジック + hostlist load + ENC: 検出 +
      passphrase prompt の 3 ブロックを `if ($script:HostlistDriven)` で囲んだ。
      Show-LanPrepMenu 呼び出しは splat (`@_menuParams`) 化、`-HostRows` と
      `-ShowHostCombo` は hostlist-driven モード時のみ付加
    - [tools/lan_prep/lib/menu_form.ps1](tools/lan_prep/lib/menu_form.ps1):
      `Show-LanPrepMenu` に `[switch]$ShowHostCombo` パラメータを追加
      (default $false)。host combo + label + 後方互換 note + dynamic
      role-button label updater + resolveHost クロージャを
      `if ($ShowHostCombo)` でガード。form 高さも条件付き
      ($ShowHostCombo: 520 / OFF: 440) で動的に縮める
  - **不変ファイル**:
    - [tools/lan_prep/Prepare-LanMigration.ps1](tools/lan_prep/Prepare-LanMigration.ps1):
      `-OldPCName` / `-NewPCName` / `-InterfaceAlias` optional パラメータは
      そのまま温存。default モードでは前 2 つが渡されず profile 値が使われる、
      `-InterfaceAlias` は NIC combo 経由で従来通り渡る
    - [tools/lan_prep/Revert-LanMigration.ps1](tools/lan_prep/Revert-LanMigration.ps1):
      もともと hostlist 無関係、変更なし
    - [tools/lan_prep/lib/menu_form.ps1](tools/lan_prep/lib/menu_form.ps1) 後半
      の `Show-LanPrepPassphrasePrompt` 関数定義: hostlist-driven モードでのみ
      呼ばれるが定義は残置 (dead code 状態だが将来 seam 削除時に一括除去)
    - [backuper/lib/hostlist_reader.ps1](backuper/lib/hostlist_reader.ps1) /
      [backuper/lib/ui/fabriq_select_form.ps1](backuper/lib/ui/fabriq_select_form.ps1):
      fabriq_lanprep.ps1 からの dot-source は残置 (副作用ゼロ、hostlist-driven
      モードで使われる関数群)
    - [backuper/data/migration_profile.sample.json](backuper/data/migration_profile.sample.json):
      schema 不変
  - **デフォルトモードの起動フロー**:
    1. WinForms / Drawing assembly load
    2. backuper common.ps1 / theme.ps1 / fabriq_select_form.ps1 /
       hostlist_reader.ps1 を dot-source (関数定義の load のみ、I/O なし)
    3. menu_form.ps1 を dot-source
    4. VERSION 読込
    5. migration_profile.json 読込 (existing optional load policy)
    6. **`Find-FabriqRoot` を呼ばない** (env が立っていないため)
    7. **hostlist load / passphrase prompt も走らない**
    8. NIC enumeration (Get-NetAdapter) → 既存通り
    9. Show-LanPrepMenu (host combo 非表示の縮小モード)
    10. target / source 経路は v0.30.0 と同様に `-Force` + `exit 0` で
        KeepAwake バトンタッチ
  - **副次効果 (= 設計純化)**:
    - fabriq main 不在でも LAN-Prep が起動できる (USB 持ち回り運用が綺麗)
    - passphrase ダイアログが消える (operator の入力ステップ削減)
    - メニュー画面が 80px 縮小 (520 → 440)、ボタン到達までの目線移動が短く
  - **後方互換**:
    - `FABRIQ_LANPREP_HOSTLIST=1` 起動時は v0.30.0 と同等動作 (UI / I/O / 子
      スクリプト引数の全てを復元)
    - profile.json の `interfaceAlias` は NIC combo の default 選択値として
      引き続き機能 (default モードでも変わらず)
    - 直接 `Prepare-LanMigration.ps1 -Role target` を呼ぶ運用も無影響
    - Revert-LanMigration / KeepAwake / Transcript ログ / top-level trap も
      全て無変更
  - **VERSION**: 0.31.0 据え置き ([アプリ移行チェック entry](#added) と同
    Unreleased サイクルに同梱、Backuper への影響なし)
  - **配備**: `E:\fabriq_backuper\` 再配置のみ。EXE 無変更
  - **検証**:
    1. 環境変数なしで `Fabriq_LanPrep.exe` ダブルクリック → fabriq main 探索
       なし、passphrase ダイアログなし、メニュー画面に NIC combo + 4 ボタン
       (移行先 / 移行元 / 元に戻す / 終了) のみ、host combo + 「対象 PC ペア」
       ラベルが消えていること
    2. `set FABRIQ_LANPREP_HOSTLIST=1` してから EXE 起動 → fabriq main 探索が
       走る、hostlist が ENC: ありなら passphrase ダイアログ表示、メニュー
       画面に host combo + dynamic role-button label が復活
    3. default モードで target/source → KeepAwake 別 window バトンタッチ
       + 親 window 即 close 動作が維持されていること
    4. default モードで revert → profile.rollback.snapshotPath を読んで
       Revert-LanMigration が走ること
    5. fabriq main 不在の PC で default モード起動 → エラーなしで menu まで
       到達できること (= USB 持ち回り運用が成立)
    6. `git diff` で `backuper/` 配下と VERSION に差分が無いこと
  - **将来の seam 削除手順** (静かに削除する際の 4 ステップ):
    1. fabriq_lanprep.ps1: env チェックと `if ($script:HostlistDriven)` ブロック
       (Find-FabriqRoot + hostlist load + passphrase prompt) を削除
    2. fabriq_lanprep.ps1: `backuper/lib/hostlist_reader.ps1` /
       `backuper/lib/ui/fabriq_select_form.ps1` の dot-source 行を削除
    3. menu_form.ps1: `-ShowHostCombo` / `-HostRows` パラメータと if-囲み
       ブロック + `Show-LanPrepPassphrasePrompt` 関数定義を削除
    4. Prepare-LanMigration.ps1: `-OldPCName` / `-NewPCName` optional
       パラメータと plan banner の host pair 行を削除

### Changed
- backuper v0.30.0: **LAN-Prep の target/source 成功時に Y/N 確認 + 完了後
  Enter 押下を省略** — operator が menu の役割ボタン (「移行先として設定 /
  (この PC = NEW-PC-01)」) を押した後、`Apply the above changes? (y/N)` と
  完了後の `Press Enter to close this window` を待たされていた問題に対処。
  Step 4 完了後に KeepAwake.bat が別 window で自動起動するため (v0.28.0)、
  そこで「バトンタッチ」が成立しており、conhost 側で Enter を促す必然性が
  なくなっていた。
  - **修正ファイル** [fabriq_lanprep.ps1](fabriq_lanprep.ps1):
    - try ブロック冒頭で `$result = $null` を先行宣言。menu 到達前の早期
      `return` (fabriq main 不在、dot-source 失敗等) で finally から
      `$result` を参照できるようにする
    - target/source 経路で `Prepare-LanMigration.ps1` を `-Force` 付きで
      呼び出し → 子側 Y/N 確認 (`Apply the above changes? (y/N)`) を
      bypass。menu の役割ボタンが最終確認の役割を担う
    - 呼び出し直前に `$global:LASTEXITCODE = 0` でリセットし、子側完了
      後に親側で確実に exit code を判定可能にする (defensive)
    - `finally` ブロックで `Read-Host "Press Enter to close this window"`
      を条件分岐:
        - **skip 条件**: `$result.action -in @('target','source')` かつ
          `$LASTEXITCODE -eq 0` (= success path) のみ。 `[ok] LAN-Prep
          finished; closing this window. (KeepAwake.bat continues ...)`
          を 1 行表示してから即 close
        - **Read-Host 維持**: 早期 return ($result が $null)、`exit` /
          `revert`、または target/source 失敗 ($LASTEXITCODE != 0)。
          operator が error/cancellation メッセージを読む時間を確保
  - **修正ファイル** [tools/lan_prep/Prepare-LanMigration.ps1](tools/lan_prep/Prepare-LanMigration.ps1):
    - success path の末尾に明示的な `exit 0` を追加。これがないと
      PowerShell は `$LASTEXITCODE` を最後の native 呼出 (netsh 等) の
      値のまま放置するため、親側の skip-Read-Host 判定が壊れる可能性が
      あった。`exit 0` で明示的に 0 を返すことで親の `$LASTEXITCODE`
      チェックが信頼できるシグナルになる
    - **失敗 path は無変更**: 既存の `Read-Host "Press Enter to exit"`
      + `exit 1` を維持。operator は失敗内容を読み終えてから親側にも
      `Press Enter to close` を再度押すことになるが、安全側の挙動
      として許容
  - **不変 ファイル**:
    - [tools/lan_prep/Revert-LanMigration.ps1](tools/lan_prep/Revert-LanMigration.ps1):
      revert は `-Force` を渡さないので Y/N 確認 + Read-Host が従来通り
      残る (operator 希望: revert は確認のためにポーズしたい)
    - [tools/lan_prep/lib/menu_form.ps1](tools/lan_prep/lib/menu_form.ps1):
      menu 自体の挙動には変更なし
    - top-level `trap` ブロック内の `Read-Host "Press Enter to close
      this window"`: 未捕捉 terminating error は確実にメッセージを読ませる
      ため、現状維持
  - **後方互換**:
    - 直接 PowerShell から `Prepare-LanMigration.ps1 -Role target` を
      呼ぶ運用 → `-Force` 来ない → Y/N 確認 + 完了後 Read-Host とも
      従来通り表示される。EXE 経由 (menu) のみ UX 改善
    - revert は全パスで挙動不変
    - 起動前エラー / menu 終了 / Esc キャンセル → Read-Host 維持
  - **ステートマシン**:
    ```
    target/source 成功:
      menu → ボタン押下 → plan 表示 → 即 Step 1-4 → KeepAwake 別 window
        起動 → 親 conhost は "[ok] ... closing this window" 1 行表示で
        即 close (Enter 押下なし)
    target/source 失敗:
      menu → ボタン押下 → plan 表示 → Step N 失敗 → 子側 "Press Enter
        to exit" → exit 1 → 親側 "Press Enter to close this window"
        (2 段 Enter、failure path は安全側として許容)
    revert:
      menu → ボタン押下 → plan 表示 → Y/N 確認 → Step 復元 → 親側
        "Press Enter to close this window" (現状維持)
    exit / Esc:
      menu → 終了 → "Menu cancelled" → 親側 Read-Host (押し間違い対策)
    起動前エラー:
      早期 return → 親側 Read-Host (error message を読ませる)
    ```
  - **VERSION**: 0.30.0 据え置き (UX 改善、interface/schema 不変)
  - **配備方針**: `E:\fabriq_backuper\` 再配置のみ。EXE / Prepare-
    LanMigration.ps1 の interface 不変なので運用変更なし
  - **検証** (operator 側で実機確認):
    1. target 成功 path → Y/N なし、完了後の Enter なし、`[ok]` ログの
       直後にウィンドウが閉じる、KeepAwake.bat の別 window が継続
    2. target 失敗 path (例: profile に存在しない interfaceAlias を
       入れる) → 子側 `Press Enter to exit` → 親側 `Press Enter to
       close` の 2 段 Enter
    3. revert → 従来通り Y/N + 完了後 Enter
    4. menu で `終了` 押下 → 従来通り Read-Host で待機
    5. fabriq main 不在で起動 → 従来通り Read-Host で待機
    6. 直接 `pwsh Prepare-LanMigration.ps1 -Role target` を呼ぶ →
       従来通り Y/N + Read-Host (Force 付かない)

### Added
- backuper v0.30.0: **LAN-Prep メニューを hostlist 駆動に拡張** —
  これまで `migration_profile.json` に hardcode していた PC アイデンティティと
  NIC alias を、起動時の WinForms メニュー上で **fabriq hostlist.csv からの
  選択** + **Get-NetAdapter からのドロップダウン選択** に置き換え。case-by-case
  に profile.json を手編集していた運用を排除し、複数 PC ペアを 1 つの profile
  で運用できるようにする。`migration_profile.json` のスキーマは **無変更**
  (schemaVersion=1)、子スクリプトへは optional パラメータで上書き伝達するので
  完全に後方互換。
  - **新規 メニュー画面構成** ([tools/lan_prep/lib/menu_form.ps1](tools/lan_prep/lib/menu_form.ps1)):
    - hostlist combo: `(未選択 — profile 値で実行)` を sentinel に、続いて
      `OldPCName  ->  NewPCName` 行を一覧表示。未選択時は後方互換モード
    - NIC combo: `Get-NetAdapter | Sort-Object Name` の結果を `Name (Status,
      MediaConnectState)` 形式で全件表示。kitting 中の disconnected NIC も
      選択可能 (現行 lan-prep が想定する link-down 状態でも IP を仕込む
      シナリオを維持)
    - 役割ボタン (移行先 / 移行元) を 2 列横並びに変更。ラベルは hostlist
      選択行に追従して 2 行表示:
        - 行選択あり: `移行先として設定 / (この PC = NEW-PC-01)`
        - 行未選択 : `移行先として設定 / (profile 値)`
    - 戻り値を string token → pscustomobject に変更
      (`action / oldPCName / newPCName / interfaceAlias`)。caller のみが
      影響範囲、外部依存なし
  - **新規 関数** `Show-LanPrepPassphrasePrompt`
    ([tools/lan_prep/lib/menu_form.ps1](tools/lan_prep/lib/menu_form.ps1)):
    hostlist に ENC: 暗号化フィールドが含まれている場合のみ呼ばれる、
    fabriq マスターパスフレーズ入力モーダル。Test-MasterPassphrase で
    verify、成功時に plaintext を返し `$global:FabriqMasterPassphrase`
    に設定後、hostlist を再読込して復号値を menu に渡す。Cancel/検証 NG
    は警告のみ降格して後方互換モード突入。新規 .ps1 ファイルは作らず
    既存 BOM 付き menu_form.ps1 に同居 (Write tool が BOM なし保存する
    制約への対処、CLAUDE.md 規約 5)
  - **修正 ファイル** [fabriq_lanprep.ps1](fabriq_lanprep.ps1):
    - dot-source 追加: `backuper/lib/hostlist_reader.ps1` /
      `backuper/lib/ui/fabriq_select_form.ps1`
    - 起動時に `Find-FabriqRoot` (multi-candidate picker込) を実行、
      fabriq main 不在は **FATAL** で起動拒否 (backuper 本体と同じ依存
      パターン)
    - `Get-FabriqHostlist` で hostlist 読込 → ENC: 検出ロジック →
      passphrase prompt → 再読込 (Import-ModuleCsv は ENC: 未設定でも
      エラーを返さず ENC: 文字列のまま列値に入れるため、別途検出する)
    - `Get-NetAdapter` で NIC 一覧取得 (失敗は warning に降格)
    - `Show-LanPrepMenu` を新シグネチャ (HostRows / Nics /
      DefaultInterfaceAlias) で呼び出し、戻り値の pscustomobject を
      switch で分岐。target/source 経路では optional パラメータ
      (`-InterfaceAlias` / `-OldPCName` / `-NewPCName`) を splat で
      `Prepare-LanMigration.ps1` に転送
  - **修正 ファイル** [tools/lan_prep/Prepare-LanMigration.ps1](tools/lan_prep/Prepare-LanMigration.ps1):
    - optional パラメータ `-InterfaceAlias` `-OldPCName` `-NewPCName`
      を追加 (後方互換: 未指定なら profile 値を使用)
    - `-InterfaceAlias` 指定時は `$netConfig | Select-Object *` で
      shallow copy を作って `.interfaceAlias` を上書き。in-memory
      profile オブジェクトには手を加えない (defensive copy)
    - `-OldPCName` / `-NewPCName` は plan 表示 banner に「Host pair
      (hostlist): OLD-PC-01 -> NEW-PC-01」を追加するためにのみ使用
      (Step 1 以降の動作には影響しない)
  - **不変** ファイル:
    - [tools/lan_prep/Revert-LanMigration.ps1](tools/lan_prep/Revert-LanMigration.ps1):
      revert は snapshot 内の `interfaceAlias` と profile の
      `rollback.snapshotPath` だけで動作するため hostlist 選択は不要。
      無変更
    - [backuper/data/migration_profile.sample.json](backuper/data/migration_profile.sample.json):
      schema 不変なのでサンプルも無変更
    - [tools/lan_prep/lib/network_config.ps1](tools/lan_prep/lib/network_config.ps1) /
      [share_setup.ps1](tools/lan_prep/lib/share_setup.ps1) /
      [firewall.ps1](tools/lan_prep/lib/firewall.ps1) /
      [rollback_snapshot.ps1](tools/lan_prep/lib/rollback_snapshot.ps1):
      menu からの呼び出しは upstream の Prepare-LanMigration が
      吸収するため、ライブラリ側に変更不要
  - **ステートマシン** (operator 視点):
    1. `Fabriq_LanPrep.exe` ダブルクリック (UAC 自動昇格)
    2. fabriq main 自動検出 (見つからなければ起動拒否)
    3. hostlist 読込、ENC: 検出時は passphrase 入力ダイアログ
    4. WinForms メニュー表示:
       - PC ペアを combo から選択 (任意。未選択 = 後方互換モード)
       - NIC を combo から選択 (profile の interfaceAlias が default)
       - 役割ボタン (移行先 / 移行元) を押下、ボタンラベルが選択行に
         追従して `(この PC = NEW-PC-01)` 等を表示
    5. 既存 Prepare-LanMigration が起動、Step 1-4 + KeepAwake 自動起動
       (v0.28.0 で導入したフロー)
    6. operator は backup/restore へ移行
  - **後方互換**:
    - hostlist 読込失敗 / hostlist 行未選択 → 役割ボタンは押下可能、
      profile 値のみで Prepare-LanMigration が動作 (= v0.29.0 等価)
    - profile.json 不在 → 役割ボタン disabled (= v0.29.0 等価)
    - 既存 profile.json の `network.source/target.interfaceAlias` は
      menu の NIC combo の **default 選択値** として機能
    - 直接 `tools/lan_prep/Prepare-LanMigration.ps1 -Role target` を
      PowerShell から呼ぶ運用も維持される (新パラメータは optional)
  - **VERSION**: 0.30.0 据え置き (アプリ移行チェックと同 Unreleased サイクル)
  - **配備方針**:
    1. `E:\fabriq_backuper\` を customer 端末に再配置 (`Fabriq_LanPrep.exe`
       は無変更、ps1 ファイル群のみ差し替わる)
    2. fabriq main (`E:\fabriq\` 等) が同 PC に存在する前提を確認
    3. operator は `Fabriq_LanPrep.exe` をダブルクリック (運用上の操作は
       v0.29.0 から変わらない、メニュー画面に対象 PC ペアと NIC の選択肢が
       増えただけ)
  - **検証**:
    1. fabriq main 存在 + hostlist 平文 → hostlist combo に行が並ぶ、
       NIC combo に adapter 一覧表示
    2. hostlist 行切替で役割ボタンのラベルが追従更新 (改行付き 2 行)
    3. hostlist 未選択 → 後方互換モードのラベル `(profile 値)` で押下可能、
       v0.29.0 と同じ動作で Prepare-LanMigration が走る
    4. fabriq main 不在 → 起動拒否、`%TEMP%\fabriq_lanprep_*.log` に
       `Fabriq main directory not found` が残る
    5. hostlist 読込失敗 → 警告 + 後方互換モード突入、menu 自体は開く
    6. ENC: 検出 → passphrase ダイアログ表示、Cancel で警告 + 後方互換
       モード突入
    7. revert 動作は v0.29.0 と同等 (snapshot 内 alias 使用、hostlist 不要)
    8. profile.network.{role}.interfaceAlias が menu の NIC combo 値で
       in-memory 上書きされること、snapshot ファイル
       (`_rollback_snapshot.json`) にも上書き値が記録されること

### Changed
- backuper v0.29.0: **printer section の restore を operator handoff folder 一本化
  に再設計** —
  [backuper/lib/sections/printer/restore.ps1](backuper/lib/sections/printer/restore.ps1) /
  [backuper/common.ps1](backuper/common.ps1) /
  [backuper/lib/ui/restore_view.ps1](backuper/lib/ui/restore_view.ps1)。
  credentials / outlook_pop / system_evidence と同じ「Desktop\<date>_<host>_BK\」
  集約フォルダ pattern に統一し、printer の自動 install を撤廃して operator が
  バッチを実行するモデルに切り替えた。後方互換不要方針 (テスト段階) に合わせて
  legacy auto-install path は完全に削除した。
  - **handoff folder 構造** (`<TargetDesktop>\<yyyy_MM_dd>_<OldPCname>_BK\04_プリンタ\`):
    ```
    Install-Printers.bat        operator がダブルクリック (UAC 自動昇格)
    README.txt                  日本語の operator 手順 (BOM 付き UTF-8)
    _printer_settings.txt       移行元プリンタ情報サマリ (BOM 付き UTF-8、日本語)
    _data\                      内部ファイル一式 (operator は触らない)
      ├ Install-Printers.ps1    bat から呼ばれる本体 (UTF-8 BOM、ASCII only)
      ├ manifest.json           fabriq-printer-backup の section copy
      ├ printers.json / ports.json / drivers_registered.json / etc.
      ├ drivers/                pnputil 用 INF パッケージ (~80MB)
      └ printsettings/          DEVMODE binary (Base64) + hwconfig (HKLM dump)
    ```
  - **operator が触るのは最大 3 ファイル + 1 サブフォルダ** に整理。`_data\`
    プレフィックスで内部ファイルを視覚的に分離 (Explorer のソートでも下端に来る)。
  - **Install-Printers.ps1** は restore.ps1 の here-string template から生成
    される自己完結スクリプト。restore.ps1 (BOM なしで配備されることがある)
    内に日本語を持ち込めない制約により console messages は ASCII only。日本語
    の手順説明は隣の README.txt と _printer_settings.txt (common.ps1 helper
    経由で BOM 付き出力) で提供する役割分離。
  - **Install-Printers.ps1 の Phase A-E**: 旧 restore.ps1 の自動 install ロジック
    を忠実に inline 移植。
    - **Phase A**: driver install (inbox は `Add-PrinterDriver -Name` のみ、
      OEM は `pnputil /add-driver` + `Add-PrinterDriver`)
    - **Phase B**: port 作成 (TCPIP / LPR、WSD は `wsdResolvedHost` で
      `IP_<ip>` の TCP/IP standard port に救済 = v0.21.0 同等)
    - **Phase C**: `Add-Printer` (WSD rewrite map 適用) + 共有 / コメント /
      場所属性 + `Set-PrinterProperty`
    - **Phase D**: Spooler restart → HKLM hwconfig (Binary / String /
      ExpandString / MultiString / DWord / QWord 各 type 復元) + HKCU DEVMODE
      (Base64 decode → PropertyType=Binary 書込)。`Get-HandoffHkcuRoot` 関数を
      inline で持ち、interactive logged-on user の SID を `Win32_Process`
      explorer.exe 経由で解決して `HKU:\<SID>\Printers\DevModePerUser` に
      書き込む (backuper/common.ps1 の `Resolve-HkcuRoot` と同等ロジック)
    - **Phase E**: 既定プリンタ復元 (`WScript.Network::SetDefaultPrinter`)
  - **UAC self-elevate**: `Install-Printers.ps1` 冒頭で current principal が
    administrator か check、admin でなければ `Start-Process -Verb RunAs` で
    同 script を再起動 → exit。operator はバッチをダブルクリックするだけで
    UAC dialog 経由で admin 権限に到達できる。
  - **IncludePrinters filter (Phase 5)**: restore_view の printer grid で
    operator が deselect した printer を Install-Printers.ps1 でも除外する
    ため、`<handoff>\_data\manifest.json` を rewrite して `items.printers[]` /
    `items.ports[]` / `items.drivers[]` を選択分のみに絞る。`counts` も
    更新。元の `sections/printer/manifest.json` は不変。
  - **日本語 printer 名の文字化け対策** (実機検証で発覚):
    - handoff manifest filter は **BOM 付き UTF-8 で書き出す**
      (`UTF8Encoding($true)`) - 旧 `UTF8Encoding($false)` は PS5.1 の
      Get-Content default が ANSI (CP932) フォールバックする罠を踏ませる
    - Install-Printers.ps1 の `Get-Content` 全箇所 (manifest / properties /
      hwConfig) に **`-Encoding UTF8` 明示** 追加 - BOM 有無に関係なく確実に
      UTF-8 として読む
    - Install-Printers.ps1 の冒頭で **`[Console]::OutputEncoding =
      [System.Text.Encoding]::UTF8`** 設定 - default の CP932 だと non-ASCII
      文字が Write-Host 経由で欠落する可能性 (実機で「PRT会議室２階」等が
      壊れた printer 名で install される事象を観測 → 解消)
  - **handoff README + _printer_settings.txt の日本語化** (Phase 4a):
    operator-facing コンテンツは [common.ps1](backuper/common.ps1) (BOM 付き
    existing file) に新規 helper 2 個 (`New-PrinterHandoffReadme` /
    `New-PrinterSettingsText`) を追加して日本語 string をここで組み立て、
    restore.ps1 (ASCII only) からは関数呼び出しのみで forward する役割分離
    pattern を採用。CLAUDE.md project rule 5 (PS5.1 が BOM なし日本語を ANSI
    誤解釈する問題) を回避する標準解。
  - **legacy auto-install path 完全削除** (Phase 5): 旧 restore.ps1 の
    Compatibility check (osArch / osVersion) + Phase A-E (driver / port /
    printer / hwconfig / DEVMODE / default printer) + 不要 helpers
    (`Test-IsRdpRedirect` / `Test-IsVirtualPrinter` / `Get-IPv4FromLocationCompat` /
    `Resolve-WsdHost` / `_Get-Param`) + legacy SectionParams (`StrictOsVersion` /
    `ReuseInboxDrivers` / `OnConflict` / `RestoreDefaultPrinter` /
    `SkipVirtualPrinters` / `RestoreHardwareConfig`) を一掃。restore.ps1 サイズ
    1078 → 696 行 (= -35%)。
  - **operator handoff checkbox OFF 時の挙動**: printer も install されない
    (`Status='Skipped'`, `reason='Operator handoff folder feature is disabled'`).
    credentials / outlook_pop / system_evidence と一貫した挙動。
  - **mapping 追加**: [common.ps1](backuper/common.ps1) の
    `$script:OperatorHandoffSubdirs` に `'printer' = '04_プリンタ'` を追加。
  - **restore_view.ps1 拡張**: handoff checkbox 文言に「プリンタ」を追記、
    `$sectionParams['printer']` の OperatorHandoffSubdir forward + cleanup 時
    の remove 経路を追加、handoff README 文言に `04_プリンタ\` の使い方
    (operator が触る 3 ファイル + `_data\` は内部) を明示。
  - **不変**:
    - section interface / manifest schema (`fabriq-printer-backup` v1) 不変
    - [backup.ps1](backuper/lib/sections/printer/backup.ps1) は一切変更なし
    - WSD 救済 (v0.21.0) / inbox driver 判定 / DEVMODE Base64 binary 等の
      backup 形式・採取データ・救済 logic は完全踏襲
    - fabriq main への書込みなし
  - **VERSION**: 0.28.0 → **0.29.0** (MINOR、legacy 削除は breaking change だが
    テスト段階方針につき後方互換扱わず、機能追加 / UX 改善 / 内部 API 整理を
    含めて MINOR)
  - **配備**: `E:\fabriq_backuper\` を再配置で反映 (EXE は無変更、再ビルド不要)
  - **検証**:
    1. handoff ON で restore → `04_プリンタ\` 直下に `Install-Printers.bat`
       / `README.txt` / `_printer_settings.txt` / `_data\` の 4 entry のみ
       表示。`_data\` 配下に section copy + Install-Printers.ps1
    2. README.txt / _printer_settings.txt が Notepad で日本語正常表示
       (printer 名も日本語のまま)
    3. `Install-Printers.bat` ダブルクリック → UAC → console で英文の Phase
       A-E 実行ログが出る (日本語 printer 名は正常表示)
    4. Windows の「設定 → プリンターとスキャナー」で日本語 printer 名の
       ままで install されている
    5. restore_view の printer grid で 1 printer を deselect → restore →
       Install-Printers.bat 実行で 1 printer のみ install
    6. handoff OFF で restore → printer は install されない、aggregate
       manifest に Status=Skipped

### Added
- backuper v0.28.0: **lan-prep に KeepAwake (スリープ抑止) ユーティリティを同梱** —
  LAN 直結移行の作業中に PC がスリープに入って backup / restore が中断する事故
  を防ぐため、`FabriqMigration` フォルダに `KeepAwake.bat` + `KeepAwake.ps1` を
  配備し、lan-prep 完了時に自動起動する。
  - **新規 assets** (`tools/lan_prep/assets/`、ASCII only):
    - `KeepAwake.bat`: タイトル付き console wrapper (`Do NOT close while
      backup is running`)
    - `KeepAwake.ps1`: `SetThreadExecutionState(ES_CONTINUOUS |
      ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED)` で sleep + display-off を
      抑止。try / finally で window close 時に確実に `ES_CONTINUOUS` 単独で
      解除。操作者向けメッセージは日本人にも読みやすい平易な英語
    - 実装は fabriq main の `kernel/common.ps1` の `SleepSuppressor` パターン
      を vendoring (CLAUDE.md vendoring 規約に準拠、fabriq main は read-only
      参照のみ)
  - **`Prepare-LanMigration.ps1` の拡張**:
    - **Step 1 直後**: snapshot 保存成功後に `Split-Path -Parent
      $snapshotPath` (= `FabriqMigration` フォルダ) へ `KeepAwake.{bat,ps1}`
      を Copy-Item。失敗は warning に降格して lan-prep 全体は継続
    - **Step 4 直後 (success path)**: `Start-Process KeepAwake.bat` で
      別 console window を spawn。operator は手動でダブルクリックする手間
      なくスリープ抑止状態に入る
    - **failure path**: Step 2-4 のいずれかが throw して catch ブロックに
      落ちた場合は auto-launch しない (= 余計な orphan window を残さない)。
      KeepAwake.bat は Step 1 で既に Copy 済なので、operator が後で手動
      起動も可能
  - **ステートマシン** (operator 視点):
    - lan-prep 完了 → KeepAwake 別 window 起動 → 同 PC で `Fabriq_BackUper.exe`
      を立ち上げて backup / restore → 完了したら KeepAwake window を close
    - source PC / target PC それぞれ独立タイミングで KeepAwake 起動可能 → USB
      で backuper を持ち回る運用 (= source と target で lan-prep のタイミング
      がずれるシナリオ) にも対応
  - **異常系の挙動**:
    - PowerShell が crash / kill された場合: `finally` 経路は走らないが、
      Windows OS が process 終了時に `SetThreadExecutionState` flag を
      自動 cleanup するため、抑止状態が permanent に残ることはない
    - operator がスタートメニューから手動で「スリープ」を選択した場合:
      `SetThreadExecutionState` は automatic sleep のみを抑止する Win32 API
      仕様のため、手動スリープは止められない (= operator 責任の範囲)
    - 二重起動 (KeepAwake.bat を 2 回ダブルクリック): 2 つの独立 process が
      立ち上がり、それぞれ独立にフラグを保持。片方 close でも他方が継続
  - **不変**:
    - backuper 本体 (backuper/) には一切の変更なし
    - fabriq main への書込みなし
    - section interface / manifest schema / sections.csv の実行順 (v0.27.1)
    - `Prepare-LanMigration.ps1` の他 step / Revert-LanMigration.ps1 / lib/
  - **encoding 制約**: KeepAwake.bat / .ps1 は Write tool 経由で生成された
    BOM なし UTF-8 ファイル。PS5.1 の ANSI 誤解釈を避けるため両ファイルとも
    ASCII only で記述 (CLAUDE.md 規約 5)。操作者向けメッセージは英語のみ。
  - **VERSION**: 0.27.1 → **0.28.0** (MINOR、機能追加)
  - **配備**: `E:\fabriq_backuper\` を再配置で反映 (EXE 無変更)
  - **検証**:
    1. lan-prep (source/target どちらでも) 実行 → 成功すると別 console window
       が自動で立ち上がり "Sleep Suppression Active" が表示される
    2. PC の電源設定でスリープタイマーを短くしても、window が開いている間
       はスリープしないこと (= `powercfg /requests` で SYSTEM/DISPLAY が
       SleepSuppressor 名義で active になっていること)
    3. window を X で閉じる or Ctrl+C → "Sleep suppression released" が
       表示され、以後は通常のスリープタイマーに従う
    4. lan-prep を 2 回連続実行 → KeepAwake.bat も 2 重起動するが互いに
       独立、片方閉じても他方が継続
    5. lan-prep が Step 2-4 で失敗 → KeepAwake.bat は配備されるが
       auto-launch されない (operator が後で手動起動可能)

### Changed
- backuper v0.27.1: **section 実行順を再配置** —
  [backuper/data/sections.csv](backuper/data/sections.csv) の行順を変更し、
  printer を末尾、userdata を先頭に並べ替え。backup / restore 双方で同順序
  ([engine.ps1:Get-RegisteredSections](backuper/lib/engine.ps1) が
  `Import-Csv` した結果を順に process するため)。
  - **新しい実行順 (1 → 6)**:
    1. userdata
    2. outlook_pop
    3. credentials
    4. msime_dict
    5. system_evidence
    6. printer
  - **意図**:
    - 大きい userdata robocopy を先頭で走らせて全体時間を読みやすくする
    - printer driver install / WSD 解決 / port 作成は所要時間が読めない
      ため末尾に置き、他 section が確定完了してから余裕を使う
    - handoff folder (credentials / outlook_pop / system_evidence) は
      printer より先に完了 → operator は printer 再起動を促される前に
      handoff folder を確認できる
  - **不変**:
    - section interface / manifest schema / SectionParams forward
    - 各 section の backup/restore ロジック自体
    - aggregate manifest の sections[] は実行順で並ぶが consumer 側に
      順序前提はなく、order-independent に判定可能
    - CheckBox の二段 wrap layout (上段: userdata / outlook_pop /
      credentials、下段: msime_dict / system_evidence / printer)
    - fabriq main への書込み なし
  - **副作用ゼロ**: 各 section の restore I/O は互いに独立 (printer driver
    install ↔ userdata の Desktop 展開 / outlook_pop の PST 配置 /
    credentials の Documents deploy / msime_dict の %APPDATA% 配置 /
    system_evidence の handoff Copy はいずれも他 section に依存しない)。
    動作上の問題は発生しない。
  - **VERSION**: 0.27.0 → **0.27.1** (PATCH、internal config 調整)
  - **配備**: `E:\fabriq_backuper\` を再配置で反映 (EXE 無変更)

### Changed
- backuper v0.27.0: **リストア画面のバックアップ候補解決を multi-root 化 + UX
  改善** — [backuper/lib/engine.ps1](backuper/lib/engine.ps1) /
  [backuper/lib/ui/restore_view.ps1](backuper/lib/ui/restore_view.ps1)。
  migration_profile が読み込まれている時、リストア画面の日時プルダウンが
  ローカル `Backup\` だけでなく `share.localPath` と `backupRootUnc` 配下も
  併せて走査し、優先順位 (Local > ShareLocal > UNC) で重複排除して並べる。
  - **Fix 1 (Phase A): multi-root timestamp discovery** —
    `Get-BackupTimestamps` の signature を拡張:
    - 戻り値: `string[]` → `PSCustomObject[]` (`Name` / `FullPath` / `Source`)
    - 新規 param `-AdditionalRoots [string[]]` で profile 経由の追加 root を渡す
    - root 走査は priority 順 (Local > ShareLocal > UNC)、同 Name は最優先のみ
      保持して de-dup
    - `Source` 判定: path が `\\` で始まれば `'UNC'`、それ以外で AdditionalRoots
      由来なら `'ShareLocal'` (= 通常 target PC 上の SMB 共有元 dir、NTFS 直
      アクセスで最速)
    - combo の表示は `"<Name>  [<Source>]"` 形式で source を明示。operator は
      「ローカル直か / SMB 越しか」を一目で判別できる
  - **engine の path 解決を ExplicitAggregateDir 一本化** —
    `Invoke-BackuperRestoreCore` から `PickedTimestamp` parameter を **削除**。
    UI 側が常に FullPath を解決して `ExplicitAggregateDir` で渡す設計に統一。
    breaking change だがテスト段階方針につき後方互換は不要 ([CLAUDE.md] 規約)。
  - **restore_view 側の対応**:
    - 新規 `$script:RestoreTimestampEntries` で combo index と FullPath を紐付け
    - 新規 `$script:RestoreBrowseMode` フラグで Browse / timestamp 2 mode 判別
      (旧 `$useExplicit` は削除)
    - combo SelectedIndexChanged handler は ExplicitDir 解決のみに責任を限定
      (BrowseMode のライフサイクル管理は Show-RestoreView と Invoke-RestoreBrowse
      の 2 箇所のみで操作する設計に整理、副作用の無い state machine)
  - **Fix 2 (Phase B): Browse mode の視覚的明示** —
    [Invoke-RestoreBrowse](backuper/lib/ui/restore_view.ps1) の成功 path で
    combo を再構成 + 強調表示:
    - combo.Items.Clear() → `(参照: <leaf>)` を 1 item だけ追加 → SelectedIndex=0
      → combo.Enabled = $false (grey-out で操作不可化)
    - BrowseLabel を `$script:fontBold` + `$script:bgAccent` (lavender) で
      強調、Text に full path を表示
    - 「何を選んでいるかわからない」「プルダウンが空」だった v0.26.0 までの
      紛らわしさを解消
    - timestamp mode への復帰経路は session_form 経由 (< 戻る) で
      Show-RestoreView 再呼出し。冒頭で BrowseMode / combo.Enabled / BrowseLabel
      style を normal にリセット
  - **Fix 3 (Phase C): バックアップ参照 button click 〜 dialog 起動の遅延を
    解消** — `Invoke-RestoreBrowse` の SelectedPath プリセット部から
    `Test-Path -LiteralPath` を呼ぶ candidate loop を **完全削除**。
    - 旧: 未認証 UNC に Test-Path を逐次実行 → SMB 認証 challenge 3-5 秒/件 ×
      最大 4 候補 = 20+ 秒の待ち時間 (operator から「資格情報的な処理が走って
      いる?」と観察された遅延)
    - 新: 最初の非空 candidate を **無条件** に `$dlg.SelectedPath` にセット。
      Windows の `FolderBrowserDialog` は存在しない path を渡されても closest
      existing parent にフォールバック表示する標準挙動なので UX 上問題なし
    - target-host detection (`Get-SmbShare -Name`) はローカル share 列挙で
      副作用ゼロ、これは維持
  - **既知の限界 (本リリースでは許容)**:
    `Get-BackupTimestamps` 内にも `Test-Path -LiteralPath $hostBackupRoot` が
    残存しており、UNC root が AdditionalRoots に含まれていると session_form
    → restore 画面遷移時に同パターンの 3-5 秒遅延が発生する。operator 承認の
    上で本リリースでは許容、将来の patch で `Get-SmbConnection` ベースの
    pre-check で対処予定 (案 a)
  - **不変**: section interface / manifest schema / sections.csv /
    backup_view / engine の backup 経路 / fabriq main への書込みなし
  - **VERSION**: 0.26.0 → **0.27.0** (MINOR、internal API 変更 + UX 改善 + 機能拡張)
  - **配備**: `E:\fabriq_backuper\` を再配置で反映 (EXE 無変更)

### Added
- backuper v0.26.0: **新規 section `system_evidence` を追加** — 移行元 PC の
  構成情報 (PC基本情報 / ネットワーク / プリンタ / シリアル / インストール済アプリ /
  Wi-Fi profile / 環境変数) を採取し、リストア時に operator handoff folder の
  `03_移行元PC情報\` 配下に展開する。CLAUDE.md vendoring 規約に従い fabriq
  `modules/standard/evidence_config` 1.7.0 から必要 7 セクションのみを転記
  (重い PnP / GPO / Battery / Office License 等は実行しない、所要時間 30-60 秒)。
  - **採取セクション** (fabriq evidence_config の section 番号と互換):
    - §01 System Basic Info (OS / CPU / Memory / TimeZone / Locale)
    - §06 Network Settings (CSV、ipconfig /all 相当)
    - §07 Printers / Ports List (CSV)
    - §10 PC Serial Number (multi-source + validation)
    - §11 Installed Software (Desktop + Store)
    - §16 Wi-Fi Profiles (**PSK は含めない** = `netsh wlan show profile name=<n>` を
      key=clear なしで実行 + parse 後の deny regex 二段ガード)
    - §27 Environment Variables (Machine + User scopes)
  - **Step 0: lan-prep snapshot harvest**
    ([backup.ps1](backuper/lib/sections/system_evidence/backup.ps1)):
    `$script:MigrationProfile.rollback.snapshotPath` を直接読み、source PC の
    本来の network 設定 (lan-prep 適用前) を `_OriginalNetworkConfig.json` +
    `_OriginalNetworkConfig.txt` に出力。LAN 直結移行で §06 NetworkConfig.csv に
    一時 IP (192.168.250.x 等) が記録される問題を補完する。snapshot 不在は
    Section status=Success のまま注記のみ (USB-only / 通常 backup ケースを normal
    とみなす)。
  - **§11 per-user 走査**: HKLM + HKLM\WOW6432Node に加え、
    `Resolve-HkcuRoot` 経由で **HKU:\<source-sid>\SOFTWARE\\... + WOW6432Node**
    を走査し、異ユーザ admin 昇格運用でも target user 視点の per-user install
    (Just-me インストール) を拾う。CSV に `Scope` 列 (Machine x64 / Machine x86 /
    User x64 / User x86) を additive 追加。
    Store Apps は引き続き current admin の `Get-AppxPackage` で割り切り (= 異ユーザ
    admin では admin 側 Appx しか拾えないが、「管理者推奨アプリ」として運用上許容、
    operator 判断)。
  - **restore = operator handoff folder への deploy**
    ([restore.ps1](backuper/lib/sections/system_evidence/restore.ps1)):
    target PC では evidence 再採取はせず (operator 方針「二度採りしない」)、
    backup 側 `sections\system_evidence\` の成果物を
    `<TargetDesktop>\<yyyy_MM_dd>_<OldPCname>_BK\03_移行元PC情報\` へ Copy。
    backuper internal の `manifest.json` のみ除外。handoff folder の README は
    [restore_view.ps1](backuper/lib/ui/restore_view.ps1) 側で既存統合 README に
    「03_移行元PC情報\」セクションを追記する形で生成 (重複させない設計)。
    `_restore_manifest.json` (`fabriq-system-evidence-restore` schemaVersion=1) を
    handoff subdir 配下に出力。
  - **強制取得**: section CheckBox は **Disabled + Checked 固定** + tooltip
    「移行証跡として必須。選択不可。」で表示 ([backup_view.ps1](backuper/lib/ui/backup_view.ps1) /
    [restore_view.ps1](backuper/lib/ui/restore_view.ps1))。operator が UI から
    OFF にすることは不可。sections.csv は Enabled=1 固定。
  - **section CheckBox レイアウト**: 6 sections 目を追加するため、v0.22.0 で
    1 行 880px ぴったり (width=168 / stride=178) に詰めた構成を **二段 wrap
    (3 sections × 2 行、width=280 / stride=300 / stride_y=30)** に再構成。
    Container Height 26 → 56、下方 widget (Printer / User Data / handoff /
    Outlook extras / 開始ボタン等) を全て Y +30 シフト。Form Height は
    780 → 810 に拡張して restore Start button の見切れを回避。
  - **operator handoff subdir mapping**: [common.ps1](backuper/common.ps1) の
    `$script:OperatorHandoffSubdirs` に `'system_evidence' = '03_移行元PC情報'`
    を追加 (既存の 01_資格情報 / 02_outlook_アカウント情報 と同じ構造)。
  - **encoding 制約**: backup.ps1 / restore.ps1 は Write tool 経由で生成する都合、
    BOM なし UTF-8 で保存される。PS5.1 が BOM なし日本語を ANSI 誤解釈する
    (project rule 5) ため、両ファイルは **ASCII only で記述**。operator-facing な
    日本語コンテンツは BOM 付きで保存される [restore_view.ps1](backuper/lib/ui/restore_view.ps1) /
    [common.ps1](backuper/common.ps1) 側で生成する役割分離を採用。
  - **manifest schema**: `fabriq-system-evidence-backup` schemaVersion=1 + 既存の
    `fabriq-evidence-manifest` 1.7.0 の sections[] 配列を踏襲しつつ、
    `lanPrepSnapshot.{harvested, snapshotPath, originalNetwork}` を additive 拡張。
    `fabriq-system-evidence-restore` schemaVersion=1 を restore manifest として新設。
  - **既存 section / engine / manifest aggregator**: 不変。section interface
    シグネチャ厳守 ([engine.ps1](backuper/lib/engine.ps1) の標準入出力)。
  - **fabriq main への書込み**: なし。fabriq の `modules/standard/evidence_config` は
    spawn / 参照 / 改変いずれも行わない (vendoring 路線、CLAUDE.md ルール 1 / 2 準拠)。
  - **後方互換**: pre-v0.26.0 backup を v0.26.0 で restore すると、system_evidence
    section は backup 側 dir 不在を検知して Status=Skipped (reason="likely a
    pre-v0.26.0 backup") を返す。他 5 sections の restore は通常通り動作。
  - **検証**:
    1. lanprep snapshot あり (LAN 直結) で backup → `_OriginalNetworkConfig.txt` に
       移行前の本来 IP/Gateway/DNS、`06_NetworkConfig.csv` に一時 IP が記録される
       対比が成立すること
    2. 異ユーザ admin 昇格運用で backup → `11_DesktopApps.csv` の Scope 列に
       "User (x64)" / "User (x86)" のエントリが存在 = HKU\<source-sid> 走査機能
    3. `16_WiFiProfiles.txt` に PSK / Key Content / Security key を含む行が
       存在しないこと
    4. restore (handoff ON) → target user Desktop の
       `<date>_<host>_BK\03_移行元PC情報\` に上記成果物 + `_restore_manifest.json`
       が deploy される
    5. restore (handoff OFF) → 03_移行元PC情報 は作られず、section status=Skipped
  - **配備**: `E:\fabriq_backuper\` を再配置で反映。EXE は無変更 (再ビルド不要)。

### Added
- backuper v0.25.0 (work-in-progress, Phase A): **operator handoff folder の
  基盤を追加** —
  [backuper/common.ps1](backuper/common.ps1) /
  [backuper/lib/ui/restore_view.ps1](backuper/lib/ui/restore_view.ps1)。
  - **目的**: 資格情報 / Outlook アカウント情報 等の operator-facing
    artifact が Documents 配下 + 各 PST フォルダ + backup-source sectionDir
    に散らばっていた問題への対応。リストア時にチェックボックスを ON に
    すると、Desktop 配下に `<yyyy_MM_dd>_<OldPCname>_BK\` フォルダを 1 つ作り、
    番号付きサブフォルダ (`01_資格情報` / `02_outlook_アカウント情報`) に
    集約する。
  - **Phase A (今回)**: 基盤のみ。実際の deploy 経路切替は Phase B/C で
    section script を修正する。Phase A 単独では:
    - common.ps1 に新規 helper `Resolve-OperatorHandoffRoot` /
      `Resolve-OperatorHandoffSectionDir` + section -> 日本語 subdir 名の
      固定 mapping `$script:OperatorHandoffSubdirs` を追加
    - restore_view.ps1 に新規 checkbox「operator 用ファイル (資格情報 /
      Outlook 設定) をデスクトップに統合 (推奨)」を追加 (default ON、
      Y=232 に新行挿入)。既存の Outlook 追加オプション以下と printer
      grid + 開始ボタンを **全て Y +30px シフト**
    - `Invoke-RestoreStart` で checkbox ON + targetUserProfilePath あり時に
      `Resolve-OperatorHandoffRoot` で path を計算し、`Resolve-OperatorHandoffSectionDir`
      で section ごとの subdir path を組み立てて SectionParams.credentials /
      .outlook_pop に新規 key `OperatorHandoffSubdir` として forward
    - confirm 後・engine 起動前に handoff root の mkdir + UTF-8 BOM 付き
      README.txt 生成。失敗時は warning + SectionParams から key を削除
      して legacy 経路にフォールバック
  - **動作不変** (Phase A 単独):
    - section script (credentials/restore.ps1, outlook_pop/restore.ps1) は
      無変更 → 新 SectionParam を **受け取っても無視** = 実 deploy は
      v0.24.5 と完全同じ (Documents 配下 + 各 PST フォルダ)
    - checkbox OFF 時は handoff root も作られない (= v0.24.5 と完全同等)
    - manifest schema / section interface / fabriq main への書込みなし
  - **Phase A 完了時の検証**:
    1. checkbox **OFF** で restore → v0.24.5 と完全同等の挙動、Desktop に
       handoff folder は作られない
    2. checkbox **ON** で restore → Desktop に
       `<yyyy_MM_dd>_<OldPCname>_BK\README.txt` が作られる。中身に「01_資格情報」
       「02_outlook_アカウント情報」「PST 本体は Documents\Outlook ファイル\
       に残置」の案内あり。subdir (01_/02_) はまだ作られない (Phase B/C で
       section が必要に応じて mkdir する設計)
    3. credentials / outlook_pop の deploy 先は **両 case とも Documents
       配下** (= section が SectionParam を無視している証拠)
  - **Phase B (完了)**: [credentials/restore.ps1](backuper/lib/sections/credentials/restore.ps1)
    が `SectionParams['OperatorHandoffSubdir']` を受け取り、非空時は
    deploy 先を `<HandoffRoot>\01_資格情報\` に切替え (timestamp suffix
    なし、Documents 経路完全 skip)。SectionParams 解析を if-else
    expression にまとめて `PSUseDeclaredVarsMoreThanAssignments` 誤検知も
    回避。manifest schema / restore_manifest.json のフィールド名は不変
    (`deployDir` 値だけが新 path を反映)。
  - **Phase C (完了)**: [outlook_pop/restore.ps1](backuper/lib/sections/outlook_pop/restore.ps1)
    が `SectionParams['OperatorHandoffSubdir']` を受け取り、非空時は:
    - **Stage 5b** (Strategy A fallback): `RESTORE_INSTRUCTIONS.txt` を
      `<HandoffRoot>\02_outlook_アカウント情報\` に書く (従来は backup
      取得元の `$sectionDir` 配下に書いており operator がアクセス困難
      だった)。subdir mkdir 失敗時は warning + legacy path にフォールバック
    - **Stage 5.5** (常時 _account_settings.txt): per-PST-フォルダの
      `foreach` ループを skip し、`<HandoffRoot>\02_outlook_アカウント情報\
      _account_settings.txt` 1 ファイル固定で書く。`ProfileFilter` を
      省略するので **全 profile × 全 account を含む単一ファイル** に
      集約 (1 profile 環境では既存と内容同等、複数 profile 環境
      [想定外] では従来の per-PST 散布が consolidated 1 ファイルに統合)
    - **popup body** の文言を分岐: 統合 ON 時は「同じフォルダに
      _account_settings.txt も配置」、OFF 時は従来「各 PST 配置先の
      フォルダにも _account_settings.txt が併設」
    - **不変**: PST 本体は Documents\Outlook ファイル\ に残置
      (Outlook プロファイル設定が指す場所のため移動不可)。rule-clear
      shortcut も Desktop 直置きのまま (頻繁にダブルクリックされる
      ICON なので統合フォルダ内に埋めない)。`New-OutlookAccountInfoText`
      関数本体には一切手を入れていない
  - **VERSION**: 0.24.5 → **0.25.0** (MINOR、operator handoff folder 機能完成)
  - **配備**: `E:\fabriq_backuper\` を再配置で反映。EXE は無変更

### Changed
- backuper v0.24.5: **target ホスト上では UNC ではなくローカルパスを優先** —
  [backuper/lib/ui/restore_view.ps1](backuper/lib/ui/restore_view.ps1) の
  `Invoke-RestoreBrowse`。
  - **動機**: target PC は自分自身が SMB 共有を提供しているので、自 PC 上で
    Restore を実行する際は UNC `\\<self-ip>\FabriqMigration` を経由する
    必要はなく、ローカルパス `C:\FabriqMigration` で直接アクセスできる。
    UNC 経由だと認証 / network stack 越しの I/O / SMB 経由オーバーヘッドが
    発生するが、ローカル直接なら全て不要。
  - **target ホスト検出**: `Get-SmbShare -Name profile.share.shareName` を
    試行し、得られた `Path` が `profile.share.localPath` と一致すれば
    「自 PC = target」と判定。一致しない / 共有不在 / 例外 はすべて非 target
    扱い。`Get-SmbShare` は read-only enumeration なので副作用ゼロ。
  - **新しい優先順位** (最初に存在する path が勝つ):
    1. `<share.localPath>\<OldPCname>`   (target ホスト時のみ) - **local 直**
    2. `<share.localPath>`               (target ホスト時のみ) - local share root
    3. `<backuper.backupRootUnc>\<OldPCname>`                 - UNC fallback
    4. `<backuper.backupRootUnc>`                              - UNC share root
    5. (preset 無し)                                           - dialog blank
  - **source PC / 第三者 PC**: target 検出が false になり、UNC fallback (3-4)
    に進む = v0.24.4 と同じ挙動
  - **profile 不在時**: 完全に従来通り (= preset 無し)
  - **不変**: backuper 本体の他箇所 / section interface / manifest schema /
    fabriq main 書込み なし。VERSION: 0.24.4 → 0.24.5 (PATCH、refinement)

- backuper v0.24.4: **リストアの「バックアップを参照...」初期パスを profile +
  選択ホストから自動構築** —
  [backuper/lib/ui/restore_view.ps1](backuper/lib/ui/restore_view.ps1) の
  `Invoke-RestoreBrowse`。
  - migration_profile.json が読み込まれていて、かつ session_form で host
    (OldPCname) が選択されている時、FolderBrowserDialog の `SelectedPath`
    を以下の優先順位でプリセット:
    1. `<backuper.backupRootUnc>\<CurrentHost.OldPCname>` が accessible →
       ここに着地 (= operator は dialog 開いた瞬間に対象 PC のバックアップ
       一覧 (timestamp フォルダ) を見られる)
    2. 1 が不在/未認証 → `<backuper.backupRootUnc>` (共有ルート) を試行
    3. それも不在 → 従来通り SelectedPath は空 (dialog はシステムデフォルト
       位置で開く)
  - **UNC 認証との関係**: `Test-Path` は未認証 UNC で false を返すため、
    operator が事前に「UNC 接続...」で認証を通していないと候補 1/2 とも
    fall-through する。これは既存挙動と同じで、operator のメンタルモデルを
    崩さない。
  - **profile 不在時の挙動**: 完全に従来通り (= dialog がシステムデフォルト
    位置で開く)。
  - **検証**:
    1. target PC で `Fabriq_BackUper.exe` → 「リストア」モード
    2. session_form で対象 OldPCname を選択
    3. restore_view で「UNC 接続...」を押して認証
    4. 「バックアップを参照...」をクリック → dialog 内に `<OldPCname>` 配下の
       timestamp フォルダが並んで見えること
  - **不変**: section interface / manifest schema / backup_view / engine /
    fabriq main 書込み なし。VERSION: 0.24.3 → 0.24.4 (PATCH、UX 改善)。

### Fixed
- backuper v0.24.3: **`Invoke-NetshIpv4` で stdout/stderr に同じ tempfile を
  渡していたバグを修正** —
  [tools/lan_prep/lib/network_config.ps1](tools/lan_prep/lib/network_config.ps1)。
  - **症状**: VM (Windows 11 25H2, PS 5.1.26100.8457) で `Prepare-LanMigration.ps1
    -Role target` の Step 2 (IP 適用) で必ず terminating error:
    > `Start-Process: このコマンドは、"RedirectStandardOutput" と
    > "RedirectStandardError" が同じであるため、実行できません`
  - **真因**: `Start-Process -RedirectStandardOutput $f -RedirectStandardError $f`
    と同一 path を指定していた。PS 5.1 は `$ErrorActionPreference='Stop'` 下で
    これを terminating error として明示的に拒否する仕様。私の実装上のバグ。
  - **修正**: stdout 用 / stderr 用に `[System.IO.Path]::GetTempFileName()` を
    2 回呼んで別 path を確保。読み出し時は両ファイルを `||` で連結して error
    message に含める。`finally` ブロックで両方とも `Remove-Item -Force`。
  - **副次効果**: v0.24.2 で投入した safety net (Transcript + trap + finally
    Read-Host) はこの bug の診断ログを完全に保存していた = 機能は正常。
    operator はログ送付で原因究明できた、という validation も得られた。
  - **不変**: section interface / manifest schema / backuper 本体への影響なし。
    VERSION: 0.24.2 → 0.24.3 (PATCH、純粋な bugfix)。
  - **配備**: `E:\fabriq_backuper\` を再配置で反映。EXE は無変更。

- backuper v0.24.2: **`fabriq_lanprep.ps1` に Transcript ログ + top-level trap
  + finally Read-Host を追加 — window 即閉じ問題への確実な safety net** —
  [fabriq_lanprep.ps1](fabriq_lanprep.ps1)。
  - **背景**: v0.24.1 の pre-flight + try/catch でも、`Prepare-LanMigration.ps1`
    の catch ブロック実行中の何らかの状況 (PSReadLine 干渉? `&` 子呼び出し
    + parent の `$ErrorActionPreference=Stop` の相互作用?) で window が
    閉じてしまい、operator は赤い error メッセージを読み切れない、と
    2026-05-23 報告 (VM, `Ethernet0`)。catch ブロックは実行されている
    (赤い文字が一瞬見える) が `Read-Host` まで到達できないか到達しても
    抜けてから window が落ちる挙動。
  - **修正 1: `Start-Transcript`**: 起動直後 (Add-Type / dot-source の
    **前**) に `%TEMP%\fabriq_lanprep_<yyyyMMdd_HHmmss>.log` に出力開始。
    `$env:TEMP` 不在時は repo root にフォールバック。`Stop-Transcript` は
    `finally` ブロックと top-level trap の両方で呼ぶ (二重呼びは無害)。
    これで window が閉じても全コンソール出力がログファイルに残る → operator
    が `notepad %TEMP%\fabriq_lanprep_*.log` でエラーを後から確認可能。
  - **修正 2: Top-level `trap` ブロック**: try/catch を escape した
    terminating error の最終 receiver。エラー message / `$_.InvocationInfo`
    の ScriptName + ScriptLineNumber + Line / ScriptStackTrace を表示 +
    log file path を案内 + `Read-Host` で停止 + `Stop-Transcript` + `break`。
    `break` で script 終了するが、`Read-Host` が先に走るので必ず operator
    が確認できる。
  - **修正 3: main body を `try { ... } finally { ... }` で wrap**: 正常 path
    と早期 return path の両方で `finally` ブロックの `Read-Host` +
    `Stop-Transcript` が実行される。これまでの早期 `return` (Add-Type 失敗 /
    common.ps1 ロード失敗 / profile password 検知) も window 保持。
  - **早期 return の `Read-Host` 重複削除**: 各 early-return ブロック内の
    `Read-Host "Press Enter to exit"` は finally{} が代行するため削除。
    `return` だけ残す。
  - **不変**:
    - 正常実行 path の動作は不変 (Transcript ログが追加で出力されるだけ)
    - `Prepare-LanMigration.ps1` / `Revert-LanMigration.ps1` / `menu_form.ps1`
      / EXE / 配備物の他のファイルには手を入れていない
    - VERSION: 0.24.1 → 0.24.2 (PATCH、bugfix のみ)
  - **配備方針**: `E:\fabriq_backuper\` を再配置で反映 (EXE は無変更、再ビルド
    不要)。
  - **検証**: VM で再現 → window が即閉じても `notepad
    %TEMP%\fabriq_lanprep_*.log` でエラー全文が見られること / 報告いただいた
    ログ内容で原因を解析して v0.24.3 で対症療法、という流れを想定。

- backuper v0.24.1: **LAN_PREP の Y 押下直後 silent crash を修正 (interfaceAlias
  不一致時の操作性向上)** —
  [tools/lan_prep/Prepare-LanMigration.ps1](tools/lan_prep/Prepare-LanMigration.ps1) /
  [tools/lan_prep/Revert-LanMigration.ps1](tools/lan_prep/Revert-LanMigration.ps1)。
  - **背景**: VM (例: `Ethernet0` がデフォルト alias) で sample profile
    (`イーサネット`) のまま起動すると、Y 押下後の Step 1 (rollback snapshot
    取得) 内の `Get-NetIPInterface -InterfaceAlias 'イーサネット'
    -ErrorAction Stop` が "No matching MSFT_NetIPInterface objects found" で
    throw → `$ErrorActionPreference='Stop'` で script terminate → EXE 起動の
    conhost window が即閉じ → operator は何が起きたか分からない、という
    事象。実機 (Hyper-V VM, `Ethernet0`) で 2026-05-23 観測。
  - **修正 1: Pre-flight adapter check (`Prepare-LanMigration.ps1`)**:
    confirm prompt (Y/N) の **前** に `Get-NetAdapter -Name $netConfig.interfaceAlias
    -ErrorAction Stop` を実行。失敗時は:
    - `Get-NetAdapter | Sort-Object Name` で **使用可能な adapter 一覧を表示**
      (Name / Status / MediaConnectState)
    - 修正先パス (`$ProfilePath`) と修正すべきフィールド
      (`network.source.interfaceAlias` / `network.target.interfaceAlias`) を案内
    - `Read-Host "Press Enter to exit"` で console を保持してから exit 1
  - **修正 2: Step 1-4 全体を try/catch で wrap** (`Prepare-LanMigration.ps1`):
    snapshot 取得 / netsh / 共有作成 / NTFS ACL 等の throw を catch し、
    error message + stack trace + recovery hints (revert command) を表示 →
    `Read-Host` で停止。これにより EXE 起動 conhost でも事後解析が可能に。
  - **修正 3: `Revert-LanMigration.ps1` にも同様の改良**:
    - snapshot 読み込み失敗時の error 表示 + Read-Host
    - profile parse 失敗を warning に降格 (snapshot-only revert で続行)
    - snapshot 内の `interfaceAlias` が現在の PC に無い場合は warning +
      adapter 一覧表示 (= 別マシンの snapshot を持ち込んだケース等を検知)。
      ただし abort せず、revert を試みる (DNS reset 等の部分的復元が効く)
    - Step 全体を try/catch で wrap して error 時の console 保持
  - **不変**:
    - 正常 path (= profile が正しい場合) には影響なし
    - VERSION: 0.24.0 → 0.24.1 (PATCH、bugfix + UX 改善のみ)
    - sample profile の interfaceAlias `イーサネット` 自体は変えていない
      (日本語 Windows 物理機がデフォルトなので、operator がコピー後に
      環境に合わせて編集する前提)。VM ユーザ向けには pre-flight check の
      hint 文 (`'Ethernet'`, `'Ethernet0'`, `'イーサネット'` を例示) で
      ガイドする
  - **検証**: VM で profile の interfaceAlias を間違ったまま起動 →
    adapter 一覧 + 修正先案内が console に残ること / 正しい alias に
    書き換えて再起動 → 通常 path で snapshot + 共有作成 + IP 変更が
    通ること

### Added
- backuper v0.24.0: **`Fabriq_LanPrep.exe` (operator-facing entry) を新設** —
  これまで `tools/lan_prep/Prepare-LanMigration.ps1` を PowerShell から直接
  呼ぶ必要があり、operator にとって UAC 昇格と引数指定 (`-Role target`) が
  ハードルになっていた。Fabriq_BackUper.exe と同形の C# launcher を追加し、
  ダブルクリック → UAC 自動昇格 → WinForms メニュー画面 (lavender テーマ) →
  「移行先」「移行元」「元に戻す」「終了」ボタン、の運用に統一。
  - **新規 `dev/launcher/Launcher_LanPrep.cs`**: `Launcher_BackUper.cs` と
    同パターン。`conhost.exe powershell.exe -File fabriq_lanprep.ps1` を
    `UseShellExecute=true` で起動。AssemblyTitle / Product / 起動先 ps1 名
    のみ差し替え、その他のロジックは backuper launcher と同等。
  - **新規 `dev/launcher/app_lanprep.manifest`**: `requireAdministrator` +
    `dpiAware=true`、`supportedOS` は Windows 7〜10。ビルド時に
    `/win32manifest:` で埋め込まれる。
  - **新規 `dev/launcher/build_lanprep.ps1`**: `build_backuper.ps1` の
    mirror。csc.exe を 64-bit / 32-bit Framework 4.x の順で探索 → `/target:winexe`
    `/platform:anycpu` `/optimize+` でビルドし、`Fabriq_LanPrep.exe` を repo
    root に出力。実行中の同名 EXE があれば warning (`-Force` で override)。
  - **新規 `fabriq_lanprep.ps1` (repo root entry)**:
    - `backuper/common.ps1` + `backuper/lib/ui/theme.ps1` を dot-source し、
      LAN-Prep でも backuper と同じ lavender テーマ・Show-* helper を共有
    - `migration_profile.json` を optional に読み込み (backuper 本体と同じ
      load policy: 不在=silent / schemaVersion mismatch=warning / `password`
      キー混入=FATAL)
    - `Show-LanPrepMenu` を呼んで action 文字列 (`target`/`source`/`revert`/
      `exit`) を取得 → switch で対応する既存 PS1 (`Prepare-LanMigration.ps1`
      または `Revert-LanMigration.ps1`) を `&` で呼び出す
    - Revert action は profile.rollback.snapshotPath をそのまま `-SnapshotPath`
      に渡す。snapshot ファイル不在なら error + skip (Prepare 未実行のケース)
    - 完了後 `Read-Host "Press Enter to close this window"` で console を
      保持し、operator に結果ログを確認させる
  - **新規 `tools/lan_prep/lib/menu_form.ps1`**:
    - `Show-LanPrepMenu` (global function)。modal WinForms ダイアログ
    - レイアウト: 520px 幅、profile 有り 380px / 無し 360px 高さ
    - profile 有り: lavender バナー「LAN 移行 profile: <profileName>」
    - profile 無し: 赤色の警告ラベル「migration_profile.json が未配置です」を
      表示 + Target / Source / Revert ボタンを **Enabled=$false** で disable
      (= 終了ボタンのみ押下可能 → operator が profile を配置してから再起動)
    - ボタン: 移行先 (lavender accent, 大) / 移行元 (lavender accent, 大) /
      元に戻す (中、neutral) / 終了 (小、neutral)
    - Esc キーで「終了」と同等動作
    - クリック時に `$script:_lanPrepMenuResult` を action 文字列に設定して
      フォーム close。caller (`fabriq_lanprep.ps1`) が結果を switch する
  - **既存 `tools/lan_prep/Prepare-LanMigration.ps1` /
    `Revert-LanMigration.ps1` は無変更**。menu からの呼び出しは
    `& "<entry>.ps1" -Role target` のシンプルな子呼び出しで、リファクタや
    関数化は行っていない (= PowerShell から直接呼ぶ運用も従来通り維持)
  - **VERSION**: 0.23.0 → 0.24.0 (MINOR、operator-facing entry 新設)
  - **配備方針**:
    1. user 側で `dev\launcher\build_lanprep.ps1` を実行して
       `Fabriq_LanPrep.exe` をビルド
    2. `E:\fabriq_backuper\` を customer 端末に配置
       (`Fabriq_LanPrep.exe` + `fabriq_lanprep.ps1` + `tools\lan_prep\` +
       `backuper\` 一式)
    3. operator は `Fabriq_LanPrep.exe` をダブルクリック (UAC 自動昇格)
  - **不変**: backuper 本体 / section interface / manifest schema / fabriq
    main への書き込みなし

- backuper v0.23.0: **backuper 本体に LAN 移行 profile reader を組込み** —
  `backuper/data/migration_profile.json` が存在すれば起動時に読み込み、
  WinForms UI 3 箇所のデフォルトに反映する。profile 不在時は完全に
  v0.22.x と同じ挙動 (= additive、後方互換)。
  - **[backuper/main.ps1](backuper/main.ps1)**: VERSION 読込み直後に
    profile reader を挿入。
    - 検出条件: `Test-Path` で `backuper\data\migration_profile.json`
      存在チェック
    - 検証: `schemaVersion` が 1 であることを必須、不一致なら warning +
      ignore (起動継続)
    - **セキュリティ gate**: JSON 文字列内に `"password"` キーが見つかれば
      **FATAL で起動阻止** (defence-in-depth、source-controlled config に
      password が紛れ込む事故を防止)。パスワードは UNC dialog の対話入力
      経由のみで扱う運用に固定
    - parse 失敗は warning + ignore (LAN_PREP tool の fail-fast とは別
      ポリシー。backuper は日常作業ツールなので profile 不正で起動を
      止めるのは厳しすぎる)
    - 成功時は `$script:MigrationProfile` にセット、`Show-Info` で
      profileName を console に出力
  - **[session_form.ps1](backuper/lib/ui/session_form.ps1)**:
    `Show-BackuperSessionForm` に `$MigrationProfile` パラメータを追加
    (optional、default $null)。
    - profile 有りの場合のみ form 高さを 510 → 534 に拡張 (+24px)、title
      label の直下に lavender accent 色のバナー「LAN 移行 profile:
      <profileName>」を 1 行追加
    - profile 無しの場合は v0.22.x と完全に同じレイアウト・高さ (副作用ゼロ)
    - [backuper/main.ps1](backuper/main.ps1) からの呼出しに
      `-MigrationProfile $script:MigrationProfile` を追加
  - **[unc_connect_dialog.ps1](backuper/lib/ui/unc_connect_dialog.ps1)**:
    `Show-UncConnectDialog` に `-InitialUsername` パラメータを追加。
    - `-InitialPath` と `-InitialUsername` の両方が non-empty の場合のみ
      `Add_Shown` イベントで focus を password 欄に移す (= operator は
      password だけ入力すれば良い)。片方しか preset されない場合は
      従来通り path 欄 default focus
    - 既存パラメータ `-InitialPath` のシグネチャは不変、後方互換
  - **[backup_view.ps1](backuper/lib/ui/backup_view.ps1)**:
    - 「保存先ルート」テキストボックスのデフォルト値を
      `$script:MigrationProfile.backuper.backupRootUnc` から取得 (profile
      無しなら従来通り `Join-Path $script:BackuperRoot 'Backup'`)
    - 「UNC 接続...」ボタンの click ハンドラから
      `Show-UncConnectDialog -InitialUsername` に profile の uncUsername を
      forward
  - **[restore_view.ps1](backuper/lib/ui/restore_view.ps1)**:
    - 「UNC 接続...」ボタンの click ハンドラから
      `Show-UncConnectDialog -InitialPath -InitialUsername` の両方を
      profile から forward (restore は source としての UNC を読みに行く
      ため、backupRootUnc がそのまま使える)
  - **profile schema 連携点**:
    - `backuper.backupRootUnc` → backup_view の保存先デフォルト / UNC dialog
      の path preset
    - `backuper.uncUsername` → UNC dialog の username preset
    - `profileName` → session_form のバナー文言
    - `backuper.autoConnectOnLaunch` は schema には存在するが S3 では未使用
      (S4 以降で起動直後 auto-mount を検討)
  - **不変**:
    - section interface / manifest schema 不変
    - section script (printer / userdata / outlook_pop / credentials /
      msime_dict の backup/restore) には一切手を入れていない
    - fabriq main への書き込みなし
    - profile を手動で書き換え可能 (UI 上の preset は変更可能なテキスト)
  - **検証方法**:
    1. profile **無し** で起動 → session form にバナー無く v0.22.x と同じ
       UI 動作
    2. profile **有り** で起動 → session form にバナー、backup_view の
       「保存先ルート」が backupRootUnc に、UNC dialog で path/user 自動入力 +
       focus が password 欄
    3. profile に `password` キーを混入 → 起動時 FATAL で阻止
    4. profile schemaVersion=99 等 → warning 出して通常起動
    5. 既存の backup / restore フロー (printer / userdata / outlook_pop /
       credentials / msime_dict) が手入力でも引き続き動作

- backuper v0.23.0: **LAN 直結移行用 prep tool (`tools/lan_prep/`) を新設** —
  移行元 PC・移行先 PC それぞれで 1 コマンド実行するだけで、移行に必要な
  ネットワーク構成 (static IP / Network Category Private / File and Printer
  Sharing rule) を入れ、移行先 PC では SMB 共有 (`Everyone:Full`) まで
  自動作成する。設定値は profile JSON で一元管理し、backuper 本体側の
  バックアップ宛先プリセットにも将来流用する (S3 で別途実装)。
  - **新規 `tools\lan_prep\Prepare-LanMigration.ps1`** — `-Role source|target`
    で動作分岐:
    - source role: rollback snapshot 取得 → static IP 適用 → (任意) Network
      Category Private 化 / firewall rule 有効化
    - target role: 上記に加えて `New-SmbShare` + NTFS ACL 付与
    - 操作 UX は console + 1 回の Y/N 確認プロンプトのみ。`-Force` で
      バッチ化可能。
    - 異常系: profile 不在 / schemaVersion 不一致 / profile に `password` 文字列
      混入 / 管理者権限不足 → 即時 `exit 1` で fail-fast。
  - **新規 `tools\lan_prep\Revert-LanMigration.ps1`** — `-SnapshotPath` で
    指定された snapshot を読み、DHCP / Static / DNS / Network Category を
    取得時点に復元。target role で `rollback.removeShare=true` なら
    `Remove-SmbShare`。`localPath` のフォルダ自体は削除しない (バックアップ
    実体が残っている可能性、operator 手動判断)。
  - **新規 lib 群**:
    - `lib\network_config.ps1` : `Set-MigrationNetworkConfig` /
      `Set-MigrationNetworkCategoryPrivate` / `Restore-MigrationNetworkConfig`。
      **IPv4 設定は netsh.exe ベース** (`netsh interface ipv4 set address
      source=static address=<ip> mask=<mask> gateway=<gw|none>` +
      `set dnsservers ... source=static address=<dns> validate=no` +
      連番 `add dnsservers index=N`)。
      - **netsh を採用した理由**: NetTCPIP cmdlet (`New-NetIPAddress` 等) は
        media disconnected (LAN ケーブル未接続) な NIC では failure する
        (`"Inaccessible boot device"` 系エラー)。LAN_PREP の主要シナリオ
        「kitting 中の任意タイミング、LAN 未接続状態で先に IP を仕込んでおく」
        が動かなくなるため、レジストリに値を書いて link up 時に適用する
        枯れた netsh API に統一。
      - 読み出し側 (`Get-NetIPAddress` / `Get-NetIPInterface` /
        `Get-NetRoute` / `Get-DnsClientServerAddress`) は disconnected でも
        列挙が動くため、snapshot 取得は引き続き PowerShell cmdlet を使用。
      - `Invoke-NetshIpv4` ラッパが `Start-Process -RedirectStandardOutput`
        で `netsh` を起動し `ExitCode` を捕捉 → 非ゼロは throw (一部だけ
        `-AllowFailure` で warn に降格、例: DNS のセカンダリ追加失敗)。
      - subnet mask は `ConvertTo-Ipv4Mask` で prefix 長から bitmask 文字列を
        生成 (32-bit 文字列 → 8 bit ごとに `[Convert]::ToInt32(_, 2)`)。
      - **Network Category Private 化** だけは connection profile が必要な
        ため netsh では設定できず、Get/Set-NetConnectionProfile を継続使用。
        link down 時は profile が存在しないので warning + skip (operator が
        LAN 接続後に再実行 or Windows の通常 prompt に任せる)。
    - `lib\share_setup.ps1` : `New-MigrationShare` / `Remove-MigrationShare`。
      `smbPermissions` 配列を `Full/Change/Read` の 3 種に振り分けて
      `New-SmbShare -FullAccess/-ChangeAccess/-ReadAccess` の引数を組み立て、
      NTFS ACL は `System.Security.AccessControl.FileSystemAccessRule` を
      `ContainerInherit, ObjectInherit` で付与。
    - `lib\firewall.ps1` : `Enable-FileAndPrinterSharingRule`。英語 OS 用
      DisplayGroup `'File and Printer Sharing'` と日本語 OS 用
      `'ファイルとプリンターの共有'` を両方試行して locale-independent に
      対応。
    - `lib\rollback_snapshot.ps1` : `New-RollbackSnapshot` /
      `Save-RollbackSnapshot` / `Read-RollbackSnapshot`。snapshot JSON は
      UTF-8 without BOM で `[System.IO.File]::WriteAllText` 経由 (PS5.1 の
      `Set-Content -Encoding UTF8` が BOM 付き UTF-8 になる仕様を回避、
      project 規約 5 に準拠)。
  - **新規 `backuper\data\migration_profile.sample.json`** (schemaVersion=1):
    - `network.source` / `network.target` : 各 PC の interfaceAlias / IP /
      prefix / gateway / DNS
    - `network.setNetworkCategoryPrivate` / `enableFileAndPrinterSharing` :
      LAN 直結時に SMB を通すための運用必須項目を flag 化
    - `share` : hostRole / shareName / localPath / smbPermissions /
      ntfsPermissions (一旦 Everyone:Full + Modify 固定で出力)
    - `backuper` : backupRootUnc / uncUsername / autoConnectOnLaunch
      (S3 で backuper 本体から読む予定)。
      **backupRootUnc は LAN_PREP が作る共有のルートそのもの** (例:
      `\\<target>\FabriqMigration`) を指すこと。深い sub-path
      (`\\<target>\FabriqMigration\Backup` 等) を書くと、backup 開始時の
      [unc_helper.ps1](backuper/lib/ui/unc_helper.ps1) `Test-UncPath` が
      存在チェック (`Get-Item`) で fail し、「保存先に接続できません」
      エラーになる ([engine.ps1](backuper/lib/engine.ps1) は
      `<destRoot>/<OldPCname>/<ts>/` を `-Force` で auto-mkdir するが、
      その前段の reachability チェックは destRoot 自体の存在を要求する)。
    - `rollback` : snapshotPath / revertNetwork / removeShare
  - **疎通確認の責務分担**: LAN_PREP は両 PC が同時に LAN 直結されている
    保証がない (kitting タイミングがずれる) ため、ping / `Test-NetConnection`
    の類は **意図的に実施しない**。SMB レイヤの疎通確認は既存の
    [unc_helper.ps1](backuper/lib/ui/unc_helper.ps1) `Test-UncPath` /
    `Connect-UncWithCredentials` で、両 PC 接続完了後の backuper UNC 接続
    試行時に一括で扱う。
  - **backuper 本体は無変更** (common.ps1 / sections / main.ps1 / lib/ui に
    一切手を入れていない)。section interface / manifest schema / fabriq main
    への書き込みなし。backuper の起動経路にも影響なし。
  - **profile 設計上の禁則**: `password` キーは JSON に書かないことを
    `Prepare-LanMigration.ps1` の起動時 regex チェックで強制 (`"password"`
    文字列を見つけた時点で fail-fast)。UNC 接続パスワードは backuper 既存
    [unc_connect_dialog.ps1](backuper/lib/ui/unc_connect_dialog.ps1) で
    operator が入力する運用に振る (S3 で username はプリセット予定)。
  - **検証方法**: 仮想環境 (Hyper-V 2 VM) で先行確認可能:
    1. `migration_profile.sample.json` を `migration_profile.json` に rename
       し interfaceAlias / IP を環境に合わせて編集
    2. source VM で `Prepare-LanMigration.ps1 -Role source` を実行 →
       snapshot 取得 + IP 変更 + revert コマンドが案内されること
    3. target VM で `Prepare-LanMigration.ps1 -Role target` を実行 → 共有
       `\\<target>\FabriqMigration` が作成されていること (`Get-SmbShare` で
       確認)
    4. 両 VM を LAN 接続後、source から `\\<target>\FabriqMigration\Backup`
       に手動アクセスできること
    5. 両 VM で `Revert-LanMigration.ps1 -SnapshotPath <snapshot.json>` →
       元の DHCP / Static / 共有削除が反映されること
  - **配備方針**: `E:\fabriq_backuper\` を再配置すると即時利用可。
    backuper 本体は無変更のため、既存運用への影響なし。

- backuper v0.23.0: **outlook_pop backup 前に Outlook 起動検知 → graceful close
  ポップアップ** を追加 ([backup_view.ps1](backuper/lib/ui/backup_view.ps1) /
  [common.ps1](backuper/common.ps1))。OUTLOOK.EXE が source user で起動したまま
  バックアップを取ると PST ファイル / レジストリ profile が握られたままで
  整合性が崩れる事象を構造的に回避。
  - **新規 helper** [common.ps1](backuper/common.ps1):
    - `Test-OutlookRunningForSource [-SourceUserSid <string>]`:
      `Get-CimInstance Win32_Process` で `Name='OUTLOOK.EXE'` を列挙し、
      `Invoke-CimMethod -MethodName GetOwnerSid` で各プロセス所有者の SID を
      取得して source user SID と一致するもののみを返す。SID 省略時は
      `Resolve-HkcuRoot` の SID (admin 異ユーザ昇格時) → 現在 process の
      `WindowsIdentity` SID の順で自動解決。
    - `Stop-OutlookForSource [-SourceUserSid <string>] [-GracefulWaitSeconds <int>=5]`:
      検出した OUTLOOK.EXE に `Process.CloseMainWindow()` (WM_CLOSE 相当) を
      送って graceful exit を試行 → 最大 5 秒 poll → タイムアウトしたら
      `Stop-Process -Force` で残存 PID を force kill → settling sleep 1s。
      `@{ Result='NoneRunning'|'KilledGraceful'|'KilledForce'; AttemptedIds;
      ForceKilledIds }` を返す。
    - **SID scope 必須の理由**: backuper を admin 異ユーザ昇格で動かす運用
      ケースで、操作者 admin 自身が別 Outlook を開いていてもそれを巻き込まない
      ようにする。`GetOwnerSid` の戻り値で厳密に絞る。
  - **[backup_view.ps1](backuper/lib/ui/backup_view.ps1) `Invoke-BackupStart`**:
    バックアップ確認ダイアログを通過した直後、Progress view へ切り替える
    直前に検知ロジックを挿入。発火条件は **`outlook_pop` セクションが
    今回の run で選択されているとき限定** (printer のみ等の partial backup では
    popup を出さない)。
    - 起動中 Outlook を検出した場合: WinForms MessageBox (YesNo + Warning icon)
      で「[はい] 閉じて続行」「[いいえ] 中止」を提示。escape hatch (「そのまま
      続行」) は意図的に出さない (壊れたバックアップを取らせないため)。
    - 「はい」選択時のみ `Stop-OutlookForSource` を実行。結果サマリは
      `$outlookCloseSummary` に組み立て、Switch-View 後の Add-ProgressLog で
      progress 画面 + 実行ログに残す。
    - 「いいえ」選択時は `return` で `Invoke-BackupStart` を抜ける (section
      view に戻り、operator が手動で閉じてからやり直し)。
  - **`common.ps1` の vendoring 規約**: 上記 2 関数は kernel/common.ps1 由来の
    vendored 関数ではなく **本 repo 独自の追加機能**。関数頭コメントで
    deviation を明示。
  - **動作不変**: section interface / manifest schema / backup section script
    群 / restore 経路 / fabriq main への書込なし。Outlook 未起動環境および
    outlook_pop 未選択の backup は一切影響を受けない。

- backuper v0.22.0: **新規 section `msime_dict` を追加** — Microsoft IME
  のユーザ辞書 (`imjp15cu.dic` + auto-backup) をバックアップ／リストア
  する。OS / IME 種別の分岐を operator に判断させない設計。
  - **パス固定の根拠**: `%APPDATA%\Microsoft\IME\15.0\IMEJP\UserDict\`
    は MSIME 内部バージョン (15.0) で固定されており、Win10 / Win11
    23H2 / 24H2 / 25H2、旧 IME / 新 (Win11 default) IME のいずれでも
    同一パス・同一ファイル形式 (公開情報 + 実機 Win11 25H2 環境で確認
    済)。**operator は IME 種別を一切意識せずに backup / restore できる**。
  - **`backuper/lib/sections/msime_dict/backup.ps1`**:
    - `SourceUserProfilePath\AppData\Roaming\Microsoft\IME\15.0\IMEJP
      \UserDict\` 配下から `imjp15cu.dic` + `imjp15cu.dic_bak` を採取。
    - `robocopy /B` (backup mode) で取得 — IMEJP プロセスが
      `imjp15cu.dic` を握っていてもロック越しに読み出せる。`/R:1 /W:1`
      で stale lock 検知時の retry をすぐ諦め、`/COPY:DT` で data +
      timestamp のみ複製 (ACL はキャリーオーバーしない)。robocopy
      exit code を `$LASTEXITCODE` で見て >= 8 なら warning 立て、
      ファイル単位の `Test-Path` で payload 確定。
    - 学習キャッシュ (`%LOCALAPPDATA%\Microsoft\IME\15.0\IMEJP\Cache
      \imjp15cache.dat`) は **意図的に対象外**。cache 由来のリストア
      不安定化リスクを避け、辞書本体 + auto-backup のみで安全寄りに
      振った設計判断。
    - manifest schema `fabriq-msime-dict-backup` v1 を新設。各ファイル
      の `sourcePath` / `exists` / `bytes` / `lastWrite` /
      `copySucceeded`、トップに `userDictDirExists` / `capturedCount`
      / `totalBytes`。
    - Status 判定:
      - `imjp15cu.dic` 採取成功 → Success (warnings 有なら Partial)
      - UserDict dir そのものが不在 → Skipped (源 PC に IME 辞書なし)
      - dir 存在するが採取失敗 → Failed
  - **`backuper/lib/sections/msime_dict/restore.ps1`**:
    - `TargetUserProfilePath\AppData\Roaming\Microsoft\IME\15.0\IMEJP
      \UserDict\` を deploy 先として、source の `payload/` を展開。
    - **ctfmon ロック対策**: `HKLM\SOFTWARE\Microsoft\Windows NT
      \CurrentVersion\ProfileList` で `TargetUserProfilePath` から
      target SID を逆引き → `Win32_Process` の `Name='ctfmon.exe'` を
      列挙し、`GetOwnerSid` (CIM method) で SID 一致するもののみ
      `Stop-Process`。SID 解決できない場合は kill step を skip
      (admin 側 ctfmon を巻き込んで IME を全停止させないための保護)。
    - 既存 `imjp15cu.dic` は **問答無用で上書き** (退避なし)。
      キッティング前提セマンティクスに振った設計判断。
    - ctfmon kill 後 500ms 待機 → `Copy-Item -Force` で deploy。
      失敗時は warning を立てて当該ファイルだけ skip、全体 Status
      は primary file (`imjp15cu.dic`) の成否で決まる。
    - **target user の再ログインが必要** な旨は console log でも
      明示。即時反映は ctfmon 再起動 + IME 再初期化が必要なため、
      キッティング直後の通常運用 (再起動して引き渡し) ならそのまま
      機能する。
    - manifest schema `fabriq-msime-dict-restore` v1 を新設。
      `targetUserSid` / `ctfmonStopped` / `ctfmonPidsStopped` /
      `deployed[]` を記録。
  - **`backuper/data/sections.csv`** に `msime_dict` 行を追加
    (Enabled=1)。
  - **`backuper/lib/ui/backup_view.ps1`** の `$sectionParams` に
    `msime_dict = @{ SourceUserProfilePath = ... }` を追加。
  - **`backuper/lib/ui/restore_view.ps1`** の `$sectionParams` に
    `msime_dict = @{ TargetUserProfilePath = ... }` を追加。
  - **section CheckBox レイアウト圧縮** (副次対応): 5 セクションを
    880px container に収めるため width=200/stride=215 → width=168/
    stride=178 に変更。最長 DisplayName "Printer Environment" (19
    chars) も Segoe UI 9pt + checkbox indicator 込みで 168px 内に
    収まる。max X = 4*178 + 168 = 880 ぴったり。6 セクション目を
    追加する場合は container を広げるか複数行 wrap に切り替え必要
    (コメント明記)。
  - **section interface** : 不変。
  - **既存 section / manifest aggregator / engine / common.ps1** :
    無変更。

- backuper v0.21.0: **printer section に WSD → TCP/IP standard port 救済機能** を追加。
  WSD (Web Services for Devices) ポートを使うプリンタは、復元時に動的 discovery に
  依存するため、`Add-PrinterPort` で programmatic に再構築できず、その port を参照
  する `Add-Printer` が失敗していた (現場で「上手くいく端末といかない端末がある」
  事象の主因)。本リリースで以下の救済路線を追加。
  - **[backup.ps1](backuper/lib/sections/printer/backup.ps1)** に
    `Get-IPv4FromLocation` ヘルパーを新規追加。WSD discovery で取得した
    `printer.Location` (典型形 `http://<ip>:80/wsd/mex`) から IPv4 を厳密 regex で
    抽出 (各オクテット 0-255 範囲、前後数字なしの境界条件付き)。ホスト名形式は
    cross-PC restore で DNS 非対称になりやすいため意図的に拾わない。
  - **ports.json / manifest.json の port エントリに `wsdResolvedHost` を additive
    追加**。WSD 以外の port では `$null`、WSD でも Location に IP が無ければ `$null`。
  - **WSD warning を Status 切り離し**: v0.20.x 以前は WSD port が 1 つでもあれば
    `$warnings` に積まれて Status=Partial 強制だった。v0.21.0 では IPv4 を resolve
    できた WSD は Show-Info に降格 (warnings に積まない = Status は Success のまま)、
    resolve 不能な WSD のみ warning として残す (= 本当に復元できないため)。
  - **[restore.ps1](backuper/lib/sections/printer/restore.ps1) の WSD case を全面
    書き換え**: 従来は `$warnings += "WSD port skipped"` で必ず skip だったが、
    `wsdResolvedHost` (または backward-compat として `printer.location` からの IP
    抽出) があれば `IP_<ip>` 名で TCP/IP standard port (RAW 9100) を作成。
    同名 port が既存ならそれを再利用。
  - **Phase C で portName の in-memory rewrite を実施**: WSD port を `IP_<ip>` に
    書き換えた場合、後続の `Add-Printer -PortName` 引数を rewrite map で張り替え。
    manifest 自体は不変 (副作用なし、何度 restore しても同じ結果)。
  - **新規 helper** `Resolve-WsdHost`: `wsdResolvedHost` field を最優先、無ければ
    referring printer の `location` から IP 抽出にフォールバック。これにより
    **v0.20.x 以前の既存バックアップでも追加採取なしに救済可能**。
  - **新規 Summary field**: `wsdRewrites` (rewrite 件数)。manifest aggregate にも
    伝搬。
  - **manifest schema** : additive のみ (`wsdResolvedHost` 追加)、後方互換。
  - **section interface** : 不変。
  - **後方互換**: v0.20.x で取った既存バックアップを v0.21.0 の restore で読むと、
    新規フィールド `wsdResolvedHost` は欠落しているが、`Resolve-WsdHost` が printer
    の `location` から IP を抽出するフォールバック経路で救済される。
  - **既知の前提**: 復元先 PC が元の WSD プリンタと同じ LAN セグメントに到達でき、
    RAW 9100 が空いていること。SNMP / LPR 強制環境ではこの方針は使えない (現場
    要件で出てきたら別 SectionParam で port 9515 / LPR モードを追加検討)。

### Added
- backuper v0.20.0: **資格情報リストア時の対象選択ダイアログ** を追加。
  バックアップは全件採取 (= v0.19.x のまま) のまま、**リストア時に CSV
  に含めるエントリを operator が選択** できるようになった。
  - **新規ファイル** [credentials_select_dialog.ps1](backuper/lib/ui/credentials_select_dialog.ps1):
    モーダルダイアログ。バックアップ manifest の credentials 配列を
    DataGridView (Check / Target / Type / UserName / Persist / Hint) で
    一覧表示。デフォルトは全件チェック ON。「全選択」「全クリア」
    「manual を除外」のバルク操作ボタンと、選択件数のリアルタイム表示
    (CommitEdit + CellValueChanged フックで checkbox 変更を即反映)。
    OK で選択済み Target 配列を返す、キャンセルで `$null` を返す。
  - **[restore_view.ps1](backuper/lib/ui/restore_view.ps1)** に
    「資格情報の選択...」ボタン (X=660, Y=202) + 状態ラベル
    (`(未選択 = 全件)` / `N 件選択中`) を「対象ユーザ」コンボの
    右隣に追加。`Invoke-RestoreCredentialsSelect` がバックアップ manifest
    を読み、ダイアログを呼び、結果を `$script:RestoreCredentialsIncludeTargets`
    に保存する。
  - **バックアップソース変更時の自動リセット**: タイムスタンプ combo の
    `SelectedIndexChanged` および browse 経由ソース確定時に、
    IncludeTargets と LastSource を `$null` に戻して
    「古いバックアップの選択を新しいバックアップに適用してしまう」
    事故を防止。
  - **[credentials/restore.ps1](backuper/lib/sections/credentials/restore.ps1)**
    に新規 SectionParam `IncludeTargets` (string array, optional) を追加。
    - `$null` / 未指定 = 全件 deploy (= v0.19.x 動作と同じ、後方互換)
    - 配列指定 = `Target` 列が配列に含まれるエントリのみを deploy CSV
      に書き出し
    - 空配列 (`@()`) = 0 件 deploy (header のみの CSV、operator が
      明示的に「全部いらない」と指定した場合の honest 表現)
    - 非マッチ Target = 単に skip (警告なし、deploy CSV から除外)
    - フィルタ済 CSV は元と同じ UTF-8 BOM + CRLF + 9 列スキーマで再生成
  - **`restore_manifest.json` schema additive 拡張**: `sourceCsvRowCount` /
    `deployedCsvRowCount` / `includeTargetsApplied` の 3 フィールドを
    追加。Section Summary にも同 3 フィールドを追加。
  - **不変**: backup.ps1 / dump_creds.ps1 / 全 operator_payload / engine /
    manifest_aggregator / sections.csv は無変更。manifest schema は
    additive のみで後方互換。v0.19.x で取った既存バックアップを
    v0.20.0 の restore で読んでも問題なし。
  - **PoC artifact**: [dev/credentials_poc/12_restore_filter_harness.ps1](dev/credentials_poc/12_restore_filter_harness.ps1)
    で 4 ケース (null / subset / empty / no_match) を自動検証。

### Changed
- backuper v0.19.2: **credentials section の "OS 自動再生成エントリ" を
  バックアップ時点で除外** ([backup.ps1](backuper/lib/sections/credentials/backup.ps1))。
  - 対象: `MicrosoftAccount:target=SSO_POP_Device` /
    `WindowsLive:target=virtualapp/didlogical` の 2 種 (Windows が
    Microsoft アカウント / Device SSO のためバックグラウンドで自動生成・
    更新するノイズエントリ、BlobSize=0)。
  - これらは復元しても OS が起動時 / MS アカウント再サインイン時に
    自動再生成するため、CSV / manifest に載せても operator が何もできない
    純粋なノイズだった (v0.19.1 までは manual hint で残っていた)。
  - **manifest.json schema に `systemNoiseFilteredCount` を additive 追加**。
    aggregate manifest 経由でフィルタ件数が可視化される。
  - **Section Summary** にも `systemNoiseFilteredCount` を追加。
  - 動作影響: backup の credentials section 出力で credentialCount /
    manualHintCount が実機平均で 2〜4 件減る (該当の 2 ターゲットは
    Win10/11 環境にほぼ確実に存在するため)。restore 側は CSV をそのまま
    読むため自動的に追従、コード変更なし。
  - 拡張性: より多くの noise パターンを除外したくなった場合は
    `Test-IsSystemNoiseCredential` 関数に exact-target match を追加する
    だけで対応可能。

- backuper v0.19.2: **operator-facing register_credentials.ps1 を
  「パスワード入力のみ」フローに簡素化**
  ([register_credentials.ps1](backuper/lib/sections/credentials/operator_payload/register_credentials.ps1))。
  v0.19.0/0.19.1 では各エントリで 2〜3 個の [y/N] 確認プロンプトが出ていたが、
  operator がエントリを目視確認後にパスワードを入力するか否か (= 空 Enter) で
  意思表示できるため、確認プロンプトは冗長と判断。
  - **撤廃したプロンプト**:
    - `※ ... 再登録を試みますか? [y/N]` (manual hint エントリの override
      確認) → 撤廃。manual hint は情報行 1 行に降格 (色: DarkYellow)。
    - `★ 既存資格情報があります。上書きしますか? [y/N]` → 撤廃。問答無用で
      上書き (operator は復元意思を持って起動しているため確認は冗長)。
  - **証明書系の扱い変更**: `DomainCertificate` / `GenericCertificate` は
    password 再入力では復元不可能なため、パスワード入力プロンプトを出さず
    に silent skip (`スキップ (証明書)` カウントとして集計表示)。
  - **新しい操作フロー** (1 エントリあたり):
    1. Target / Type / UserName / Persist / Comment を表示
    2. (manual hint があれば) 「注: blob 長 N のトークン/参照系の可能性」を
       1 行表示
    3. (証明書系なら) silent skip
    4. それ以外は `Password (空 Enter で skip):` プロンプト 1 回
    5. パスワード入力 → 上書きで登録 / 空 Enter → skip
  - **Summary カウンタ変更**: `スキップ (manual)` / `スキップ (既存)` を
    削除、`スキップ (証明書)` を追加。
  - **README.txt 更新**: 復元手順セクションを新フローに合わせて書き直し、
    「スキップされるエントリ (Hint=manual)」セクションを「情報注記
    (blob 長 0 のトークン/参照系の可能性あり)」に改題して decision ではなく
    情報提示として整理。`Hint` を表示列から削除 (operator の意思決定に
    使わない情報になったため)。

### Fixed
- backuper v0.19.1: **section CheckBox レイアウトのオーバーフロー修正** —
  [backup_view.ps1](backuper/lib/ui/backup_view.ps1) /
  [restore_view.ps1](backuper/lib/ui/restore_view.ps1) の section チェック
  ボックスが幅 300px + ピッチ 320px で固定されており、container 幅 880px に
  3 セクション目までしか収まらない状態だった。v0.19.0 で 4 セクション目
  (`credentials`) を追加した際、`credentials` チェックボックスが X=960 から
  描画 (container の右端を 80px 超過) され **GUI 上に表示されない** 状態
  だった。
  - 修正: 幅 300 → 200、ピッチ 320 → 215 に圧縮。4 セクションが
    X=0..200 / 215..415 / 430..630 / 645..845 で全て container 内に
    収まる。
  - 動作影響: backup_view / restore_view の見た目が微変更。section 名
    "Windows Credentials" (19 文字) も 200px 幅に十分収まることを確認。
  - 配備: E:\fabriq_backuper\ を再配置すると即時反映。
  - 既知の制約: 5 セクション目を追加する場合は、container を広げるか
    複数行 wrap に切り替える必要あり (コメントで明記)。

### Added
- backuper v0.19.0: **新規 section `credentials` を追加** — Windows 資格情報
  マネージャ (Credential Manager / Vault) のターゲット名 / ユーザ名 / 種別 /
  Persist / 最終更新時刻を CSV + JSON manifest として採取し、移行先 PC で
  operator がパスワード再入力するための payload (`登録.bat` + PowerShell
  本体 + README + CSV) を target user の Documents に展開する。
  - **パスワードはバックアップに含めない** — Windows DPAPI 仕様で別 PC へ
    持ち越せないため、設計上採取しない。operator が新 PC で各エントリの
    パスワードを手入力する運用に振り切る。
  - **`backuper/lib/sections/credentials/backup.ps1`**:
    - Win32 `CredEnumerateW` を P/Invoke 経由で呼び出し、現在のユーザの
      vault を全件列挙 (`CRED_ENUMERATE_ALL_CREDENTIALS` flag、filter=NULL)。
      フィルタ引数は **`IntPtr` で定義** (PowerShell の `string`→null 変換が
      "" に化けて `ERROR_INVALID_FLAGS` を返すバグを回避)。
    - `Resolve-HkcuRoot` の SID から target user 名 (`DOMAIN\user`) を
      `NTAccount.Translate` で解決。
    - **Admin context と target user が一致する場合 (Case A)**: 子 powershell
      プロセスを直接 spawn (`Start-Process -WindowStyle Hidden`) し、IPC
      JSON 経由で結果を回収。
    - **Admin context と target user が一致しない場合 (Case B、キッティング
      現場で常態化するケース)**: `Register-ScheduledTask` + `LogonType=Interactive`
      (= schtasks の `/IT`) で **target user 権限の子プロセスを spawn**。
      target user がログオン中であれば password 不要で実行可。30 秒の polling
      timeout を持ち、target user 不在 / GPO 制限 / AppLocker 妨害の場合は
      `targetUserDumpMethod=unavailable` と warning を立てて honest に失敗。
    - 各エントリに restoreHint heuristic を付与:
      - `cred-write` (パスワード再入力で復元可能)
      - `manual` (BlobSize=0、token系 Generic =`MicrosoftAccount:` /
        `WindowsLive:` / `OneDrive` / `DriveFS_` / `Office16_Data:` 等、
        証明書系 = `DomainCertificate` / `GenericCertificate`)
    - 出力: `manifest.json` (fabriq-credentials-backup schemaVersion=1) +
      `_credentials_list.csv` (UTF-8 BOM + CRLF、operator 視認用)。
  - **`backuper/lib/sections/credentials/dump_creds.ps1`** — `schtasks /IT`
    spawn または direct sub-process で起動される子スクリプト。`CredEnumerateW`
    を呼び、結果を JSON で `-OutputPath` に書き出すだけの単機能 (no
    common.ps1 依存)。FILETIME 構造体の `dwLow/HighDateTime` は signed Int32
    なので、`-band 0xFFFFFFFF` で sign-extension を抑制してから Int64 に
    組み立てる方式を採用。
  - **`backuper/lib/sections/credentials/restore.ps1`**:
    - section restore 側は **操作 (CredWrite) は一切行わない**。
      `<TargetUserProfilePath>\Documents\FabriqCredentialsBackup_<host>_<ts>\`
      を作成し、CSV + `登録.bat` + `register_credentials.ps1` + `README.txt`
      の 4 ファイルを展開するだけ。これは admin context で `CredWrite` すると
      間違ったユーザの vault に書き込んでしまうため (DPAPI 制約)。
    - operator が target user セッションで `登録.bat` をダブルクリック →
      `register_credentials.ps1` が CSV 各エントリのパスワードを対話入力
      させ、`CredWrite` で正しい (target user) の vault に書き込む二段運用。
  - **`backuper/lib/sections/credentials/operator_payload/register_credentials.ps1`**:
    - operator-facing PowerShell script。`Read-Host -AsSecureString` で
      パスワード入力 → SecureString → BSTR → UTF-16LE bytes → `CredWriteW`
      P/Invoke で登録。完了後は BSTR と blob を zero-fill + free して
      memory に平文を残さない。
    - `restoreHint=manual` の行はデフォルトで skip (y/N 確認で override 可)。
    - 同じ Target/Type の既存 credential 検出 (`CredReadW`) → 上書き確認
      プロンプト。
    - 完了サマリ: 成功 / manual skip / 既存 skip / 未入力 skip / 失敗 の
      件数集計。
  - **`backuper/lib/sections/credentials/operator_payload/登録.bat`** —
    ASCII-only ラッパー (`chcp 65001` + `powershell -NoProfile
    -ExecutionPolicy Bypass -File register_credentials.ps1` + `pause`)。
    GPO で `ExecutionPolicy=AllSigned` が `MachinePolicy` レベルにロック
    されている managed environment では効かないが、Fabriq 想定顧客環境では
    `-ExecutionPolicy` parameter override で十分動作する前提。
  - **`backuper/lib/sections/credentials/operator_payload/README.txt`** —
    operator 向け日本語手順書 (UTF-8 BOM)。復元手順 + RestoreHint=manual の
    エントリ説明 + 登録後の確認方法 + フォルダ取り扱い注意を記載。
  - **`backuper/data/sections.csv`** に `credentials` 行を追加 (Enabled=1)。
  - **`backuper/lib/ui/backup_view.ps1`** の `$sectionParams` に
    `credentials = @{ SourceUserProfilePath = ... }` を追加 (対称性のため)。
  - **`backuper/lib/ui/restore_view.ps1`** の `$sectionParams` に
    `credentials = @{ TargetUserProfilePath = ... }` を追加 (deploy 先
    Documents の解決に必要)。
  - **manifest schema** : `fabriq-credentials-backup` (backup) と
    `fabriq-credentials-restore` (restore) を追加。既存 manifestType に
    一切影響なし、aggregate manifest aggregator は section の
    `InternalManifestPath` を統一的に拾うので追加コードなし。
  - **section interface** : 不変 (既存 signature 厳守)。
  - **既知の制約 (README 同等)** :
    - Web Credentials (`Windows.Security.Credentials.PasswordVault`) は
      本 phase では未対応。`webCredentialCount` は常に 0。
    - 異ユーザ spawn (`schtasks /IT`) は target user がログオン中である
      ことが前提。ログオフ環境では `targetUserDumpMethod=unavailable` で
      Status=Failed。
    - 証明書系 / blob 長 0 / token 系 Generic は restoreHint=manual と
      なり、operator が手動再構築する必要あり。
  - **PoC artifacts** (`dev/credentials_poc/`、本番非組込) :
    - `01_enum_test.ps1` : CredEnumerate P/Invoke 単体検証
    - `02_spawn_test.ps1` : schtasks /IT spawn 識別子検証
    - `03_full_integration.ps1` : 上記 2 つの統合検証 (CredEnumerate via
      schtasks /IT spawn)
    - `10_section_harness.ps1` : credentials/backup.ps1 を engine 経由
      せずに直接呼び出すテストハーネス
    - `11_restore_harness.ps1` : credentials/restore.ps1 を engine 経由
      せずに直接呼び出すテストハーネス

### Changed
- backuper v0.18.3: **`_account_settings.txt` / `RESTORE_INSTRUCTIONS.txt` を
  「アカウント情報のみ」にスリム化** ([restore.ps1](backuper/lib/sections/outlook_pop/restore.ps1) の
  `New-OutlookAccountInfoText`)。手順テキストは別 doc 化のために本ファイルから
  全て削除し、operator-facing 出力をデータ参照シートとしての性格に統一。
  - **削除した section**:
    - 「手動セットアップ手順 (必要な場合のみ)」(steps 1-9)
    - POP path-collision-attach の動作説明 / IMAP OST 新規作成の挙動説明
    - 「異バージョン復元時のクリーンアップ手順」セクション (A/B/C)
    - 「初回起動について」(/cleanclientrules ショートカット案内)
    - status に応じた前置きパラグラフ (「Strategy B 試行しましたが」/「本ファイルは
      アカウントと PST のマッピング...」)
    - per-account の「ウィザード入力項目」見出し (procedural 含意のため
      「アカウント基本情報」へ改題)
  - **データに簡素化した section**:
    - banner: status 分岐をやめて「Outlook アカウント情報」固定
    - IMAP の OST 行: 5 行の説明文 → 1 行の事実記述 (「移行対象外 (per-machine
      DPAPI 暗号化のため)」)
    - Multi-PST 同居: 「★ 注意 ...wizard で Browse で明示選択してください」の
      operator 向け advice を削除し、`binding=<path>` + `その他同居 PST` の純粋な
      列挙データのみに
    - 失敗アカウントの「手動セットアップに必要な情報が揃っていません」→
      「アカウント情報を取得できませんでした」(データ取得状況に言い換え)
  - **`New-OutlookAccountInfoText` signature 縮小**: 未使用化した
    `StrategyBAttempted` / `StrategyBSucceeded` / `IsCrossVersion` /
    `CrossVersionDirection` / `ImapPresent` / `RuleClearShortcutPath` を削除。
    呼び出し側 (Stage 5b RESTORE_INSTRUCTIONS, Stage 5.5 per-profile
    _account_settings.txt) も渡し側を整理。
  - **副次クリーンアップ**: 上記引数を生成するためだけに使われていたグローバル
    変数 `$imapPresent` の検出ブロック (Phase 2.12.3 / 2.13.0 由来) を削除
    (v0.18.2 で popup 側の consumer が消えて以来 dead code)。per-profile IMAP
    検出は Strategy B-light safety gate 内の `$profileHasImap` で完結。
  - **動作不変**: section interface / manifest schema / Strategy B-light の
    判定ロジック / Strategy A の判定ロジック / popup body (Stage 5a/5b) /
    backup 側に一切影響なし。ファイル名 `RESTORE_INSTRUCTIONS.txt` /
    `_account_settings.txt` も維持 (operator-facing tooling の後方互換)。
  - **背景**: 手順テキストの保守は backup 経路と独立に進めたいユーザ要望に
    基づく。本ファイルはバックアップ時点のアカウント・サーバ設定スナップ
    ショットを目視確認するためのデータシートに役割を絞り、手順案内は
    別 scope (将来別 doc/ツール) で対応する。

### Changed
- backuper v0.18.x (final state v0.18.2): **Strategy B-light を POP 専用に変更
  + IMAP 混合プロファイルは main-flow gate で skip → Strategy A 経路**
  ([restore.ps1](backuper/lib/sections/outlook_pop/restore.ps1))。実機検証を
  踏まえた 3 段階の反復で最終形に到達。

  **最終仕様 (v0.18.2):**
  - Strategy B-light の per-profile ループ先頭で `$profileHasImap` を判定し、
    IMAP account を含む profile はバージョン問わず **B-light を skip**、
    その profile の全アカウントを Strategy A (operator wizard) 経路へ。
  - `continue` で次 profile に進むため、同一 restore 内に POP-only profile が
    あれば従来通り B-light で auto-restore (multi-profile mixed の per-profile 独立)。
  - 後処理で `$bLightVerifiedProfileNames` / `$bLightSkippedImapProfileNames` を
    集計し、popup と per-profile `_account_settings.txt` の文言を:
    - 全 profile auto-restore: 既存「Outlook POP - 復元完了 (実験機能)」
    - 一部 auto / 一部 wizard: 新「Outlook POP - 一部自動復元 / IMAP profile は
      wizard 手動」(IMAP-skipped profile 一覧を併記)
    - 全件 skip / 失敗: 既存「Outlook POP - 手動セットアップが必要」
    に分岐。
  - `Convert-RegFileToStrategyBLight` は POP-only profile のみが到達する前提に
    回帰。`$ImapSubKeysToDrop` パラメータ + T7 (IMAP subkey drop) + T5 トリガー
    拡張 (= v0.18.0 で導入し v0.18.1 で同バージョン IMAP に gate を当てた、
    かつ silent crash の原因となっていた経路) は本リリースで **撤回**。

  **反復の経緯 (記録):**
  - **v0.17.0**: Strategy A を default 主軸化。Strategy B-light は opt-in。
    同バージョン IMAP 混合だと送受信時にサーバアクセスエラー (実機観察)。
  - **v0.18.0 (撤回)**: T7 (IMAP account drop) + T5 拡張 (OST service-def drop) を
    追加して「IMAP 混合でも POP は auto-restore」を狙う設計。同バージョン
    16.0→16.0 で target Outlook が起動時に **silent crash** (well-known subkey 内の
    MAPI Section Provider `0a0d02...` 等に dangling MAPIUID 参照が残るため、
    same-version の strict validator が profile open を拒否)。
    Phase 2.12.1 hotfix コメントで既に予告されていた挙動を踏み直し。
  - **v0.18.1 (撤回 / safety gate のみ)**: 同バージョン IMAP 混合のみ
    safety gate で B-light skip。Cross-version IMAP 混合は引き続き T7+T5 で
    処理。一方 single-profile 16.0→16.0 IMAP 混合では POP も自動復元されなく
    なるため operator wizard 全件運用に。
  - **v0.18.2 (最終)**: 「POP-only profile は auto、IMAP 混合 profile は全面
    skip → Strategy A」のシンプルな線引きへ統一。T7 と T5 拡張は不要となり
    削除、`Convert-RegFileToStrategyBLight` の signature を v0.17 形に revert。

  **動作影響まとめ:**
  - 16.0→16.0 POP-only: 動作不変 (B-light 通常実行)
  - 15.0→16.0 POP-only: 動作不変 (B-light 通常実行 + T1 path rewrite)
  - 16.0→16.0 IMAP 混合: silent crash → operator wizard (registry 不変、安全)
  - 15.0→16.0 IMAP 混合: 自動 sync → operator wizard (v0.17 で動いていた auto-recreate
    路線は意図的に放棄。reg-import 経路の信頼性に振った設計判断)
  - 複数 profile 混在: per-profile 独立 (POP-only は B-light、IMAP は wizard)
  - Strategy A (default 主軸): 一切影響なし
  - manifest schema / section interface: 不変

  **operator 側の対症療法** (v0.18.0 適用時に silent crash 事象に遭遇した場合):
  1. コントロールパネル → Mail → プロファイルの表示 → 壊れた "Outlook"
     プロファイルを削除
  2. v0.18.2 以降を再配置して restore やり直し (= IMAP 混合 profile は
     Strategy A 経路に流れる)

  **既知の構造的限界**: IMAP 混合 profile を B-light で安全に POP のみ
  auto-restore する道は、MAPI Section Provider 等の cross-reference を offline
  で選択的に rewrite する未文書化バイナリ構造編集が必要。dev/profile-generator
  の UID rotation PoC は将来この方向を狙う実験だが本番未組込。

### Fixed
- backuper v0.17.0: **`Resolve-HkcuRoot` の HKU PSDrive スコープ漏れバグを修正**
  ([common.ps1](backuper/common.ps1))。`New-PSDrive -Name HKU -PSProvider Registry
  -Root HKEY_USERS` に `-Scope Global` が抜けていたため、関数 return 直後に
  HKU ドライブが消え、caller の `Test-Path "HKU:\$sid\Software\..."` が
  「ドライブが見つかりません」で false 化していた。
  - 観測: 2026-05-22、OLD-PC-01 (異ユーザ admin 昇格 + Outlook 2013) で
    outlook_pop が profile 検出失敗で skip。診断プローブ ([backup.ps1](backuper/lib/sections/outlook_pop/backup.ps1)) で
    `[probe-ps]` が全 9 階層で「ドライブが見つかりません」エラー、一方で `[probe-reg]`
    (Win32 RegOpenKeyEx 直接) はすべて EXIST を返したことから、PowerShell
    provider 側のドライブ消失が確定。
  - 副次効果: printer セクションの per-user DEVMODE 取得も同事象環境で
    silent fail していた ([printer/backup.ps1](backuper/lib/sections/printer/backup.ps1):328
    の `if (Test-Path $devModeKey)` が false 化 → ログにエラー出ず blob 取得スキップ)。
    本修正で同時に解消。
  - vendoring rule への影響: 本修正は kernel/common.ps1 由来の vendored 関数の
    1 行修正 (= 元関数のバグ修正、勝手な再設計ではない)。コメントで deviation を
    明記。fabriq main 側にも同じバグが残存するが、upstream 反映は別タスク。

- backuper v0.17.0: outlook_pop backup の診断プローブ内 `reg.exe query` 呼び出しを
  `Start-Process` + file redirect パターンに変更
  ([backup.ps1](backuper/lib/sections/outlook_pop/backup.ps1))。`& reg.exe query ... 2>&1`
  はミスヒット時の stderr が engine の `$ErrorActionPreference='Stop'` 下で
  terminating error として扱われ、probe loop の途中 (例: `\Office\16.0\Outlook\Profiles`
  不在) でセクション全体が落ちていた。同 trap は restore.ps1 の Invoke-RegImport で
  既知化済 ([restore.ps1:182-189](backuper/lib/sections/outlook_pop/restore.ps1#L182-L189))。

### Added
- backuper v0.17.0: outlook_pop backup の Profiles key 検出失敗時に
  **診断プローブ** を追加 ([backup.ps1](backuper/lib/sections/outlook_pop/backup.ps1))。
  - 動機: 異ユーザ管理者昇格環境で `Test-Path "HKU:\<sid>\Software\Microsoft\Office\15.0\Outlook\Profiles"`
    が silent に false を返し、profile データが実在するにもかかわらず
    `No Outlook 16.0 or 15.0 mail profile registry found — skipping section` で
    skip される事例の切り分け用 (2026-05-22 観測、`OLD-PC-01` Outlook 2013 環境、
    SID `S-1-5-21-3145240271-3526333754-3513013988-1002`)。
  - 失敗時のみ動作 (通常時 = profile 検出成功時は一切走らない)。
  - `Software → Microsoft → Office → {16.0|15.0} → Outlook → Profiles` の各階層を
    PowerShell Registry provider (`Test-Path` / `Get-Item -ErrorAction Stop`) と
    `reg.exe query /ve` の 2 系統で逐次プローブ。
  - 各階層の結果を `[probe-ps] EXIST/MISSING ...` / `[probe-reg] EXIST/MISSING ...` で
    対比ログ出力。provider と reg.exe の差分で「ACL 拒否で provider のみ silent fail」
    か「真に key 不在」かの切り分けが可能。
  - 不変: manifest schema / section interface / Skipped status の返却内容
    (Summary.note のみ "see probe log" を併記する形に微修正)。
  - **Resolve-AccountPst の Stage 1/2 順序を入れ替え**。EntryID binary scan を
    最優先 (= Outlook が実際に "この account の配信先" として binding している
    PST が真実)、filename-match は EntryID が壊れている / 取れない場合の
    fallback に降格。
  - 解決するシナリオ: profile に 2 PST 存在 (`<email>.pst` という古いアーカイブ
    + 現在 EntryID が binding している `個人用.pst` 等の別 PST)。v0.16 では
    filename-match で誤って古いアーカイブを選択していた。
  - Method 識別子変更: `filename-match` → `filename-match-fallback`
    (v0.16 manifest を読む restore でも問題なし — 識別子は診断用)
  - 同じ修正を dev/reparser/Resolve-OutlookAccountMapping.ps1 (PoC) にも対称的に適用

### Changed
- backuper v0.17.0: restore.ps1 の PST リネーム処理に **「マルチ PST プロファイル
  では rename を skip」** ロジックを追加。
  - 動機: <email>.pst という名前の他 PST が共存する場合、自動リネームが古い
    アーカイブを active な PST として auto-attach させてしまうリスクを回避
  - 判定: `pst.profileCandidates` に sourcePath 以外の PST が存在すれば
    マルチ PST と判定 → rename skip、原名のまま配置
  - accountResult に新規フィールド: `renameSkipped` (bool) +
    `otherPstsAtTarget` (array, target user パスにリベース済み)
  - シングル PST 環境では従来通り `<email>.pst` にリネーム
    (Outlook auto-attach の便宜を維持)
- backuper v0.17.0: `New-OutlookAccountInfoText` (= `_account_settings.txt` /
  `RESTORE_INSTRUCTIONS.txt` 生成) にマルチ PST 警告セクションを追加。
  「使用すべき PST」「Outlook wizard で必ず Browse で明示選択」「同じプロファイル
  内の他の PST 一覧」を operator 向けに表示。

### Changed
- backuper v0.17.0: outlook_pop restore の運用方針を **「operator 手動セットアップ
  (Strategy A) を主軸」** に転換。Strategy B-light (registry auto-rebuild) は
  デフォルト OFF となり、UI チェックボックス「レジストリ自動再構築 (実験的)」
  での opt-in が必要に。
  - 動機: v0.16.0 で 365 → 365 単一アカウントは動作確認できたが、MAPI registry
    transforms (T1-T6) のヒューリスティック性質と Microsoft 未公開仕様への依存を
    踏まえ、堅実な運用パスへ寄せた
  - 新規 SectionParam `AttemptStrategyB` (bool, default $false) を outlook_pop に追加
  - restore.ps1: `$attemptStrategyB` チェックを Stage 3+4 の Strategy B trial 直前に
    挿入。false なら直接 Stage 5 (operator handoff) へ
  - restore_view.ps1: 「Outlook 追加オプション」セクションに新チェックボックス
    「レジストリ自動再構築 (実験的、通常は使用しない)」を追加 (default OFF)
  - 完了 popup を 2 種類に分岐: AttemptStrategyB=false 時は「PST 配置完了、
    operator が手動セットアップ」の安心感ある文言 (Status=Success)、
    AttemptStrategyB=true で失敗時は従来の「手動セットアップが必要」(Status=Partial)
  - Strategy B 成功時の popup タイトルに「(実験機能)」を明示
  - 不変: Strategy B-light の実装本体・関数群はすべて保持 (UI opt-in で従来動作可能)

- backuper v0.17.0: **ルールクリアショートカット生成 (v0.15.0 追加機能) もデフォルト
  OFF に変更**。
  - 動機: 実機観察 ("そのままだとエラーが出るが、ルール手動実行 1 回で復活") を
    踏まえ、デフォルトでルール全削除する必要性が下がった
  - operator が必要に応じてチェックボックス opt-in
  - UI hint も「ルールが壊れている場合の対処用」と簡潔化

- backuper v0.17.0: Strategy A フォールバック時の **notepad.exe による
  RESTORE_INSTRUCTIONS.txt 自動オープンを削除**。popup の指示に従って operator が
  必要時に明示的に開く運用に変更。

### UI
- backuper v0.17.0: restore_view.ps1 のレイアウト微調整。Outlook 追加オプション
  セクションに 2 つ目のチェックボックス行が増えたため、プリンタリスト全体を
  Y 方向に +30px シフト、プリンタ grid 高さを 274 → 244 に調整。Y+H=614 の
  下端は維持。

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
