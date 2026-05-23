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
