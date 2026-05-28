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

- backuper v0.30.0: **アプリ移行チェックツールを system_evidence section に同梱** —
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
        powershell -File + `%*` で `/verbose` などの引数 forward)
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
  - **VERSION**: 0.29.0 → **0.30.0** (MINOR、後方互換な機能追加)
  - **配備**: `E:\fabriq_backuper\` を customer 端末に再配置で反映。
    案件担当が `backuper/data/app_migration_list.sample.csv` をコピーして
    `backuper/data/app_migration_list.csv` を作成し、案件アプリを記述
  - **検証**:
    1. `app_migration_list.sample.csv` を Excel で開き日本語が文字化けしない
       (UTF-8 BOM 効果)
    2. sample をコピーして `app_migration_list.csv` を作成
    3. `git status` で `app_migration_list.csv` が untracked 表示されない
       (= .gitignore 反映)
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
   10. pre-v0.26.0 backup を v0.30.0 で restore → system_evidence は Skipped
       (= バッチ配備されない)、他 sections は通常動作

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
