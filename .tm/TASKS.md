# タスク管理表 — fabriq_backuper

<!-- このファイルは TM アプリが .tm/tasks.json から自動生成します。
     直接編集しないでください（次回保存で上書きされます）。
     タスクの追加・更新は tasks.json か TM アプリから行ってください。 -->
最終更新: 2026-06-08 09:53

## 未着手 (4)

### [t-0004] リモートデスクトップ機能

**内容:**

・移行先PCへ Windows標準の RDP で接続できるようにする。
・データ移行後すぐ画面を確認したいがディスプレイが余っていない時の補助。
・資格情報は、共有フォルダで使ったものを流用する想定。

<sub>更新: 2026-06-06 13:39 ／ 作成: 2026-06-05 20:36</sub>

### [t-0007] レジストリバックアップ

**内容:**

レジストリキーをバックアップし、そのまま移行先へリストアできる機能。
理想はユーザデータと同じようにレジエディターでそのPCのレジストリを表示させたうえで、GUI上でバックアップが必要なキーを選択できるようにしたい。
それがなんのレジストリキーかをタイトルやメモなどでわかるようにしたい。
リストアは.regをインポートできるように集約フォルダに配備する

<sub>更新: 2026-06-06 13:44 ／ 作成: 2026-06-06 13:42</sub>

### [t-0013] ディスク容量やバックアップデータ量の表示

**内容:**

ディスクの空き容量やバックアップデータ量、そして、その差分（リストアしたあとの想定ディスク空き容量）を、リストア画面の目につくところに表示させ、リストア前に軽く状況を確認できるようにしたい。目につくとはいっても大きく表示させる必要はなし


<sub>更新: 2026-06-08 09:51 ／ 作成: 2026-06-08 09:48</sub>

### [t-0014] 資格情報読み込み待ちについて

**内容:**

現状、資格情報を裏で読み込んでいそうな画面において、アプリが応答なしとなってさもハングしているかのような動きを見せたり、なにもなく待ち状態になっており、オペレータが不安がるので、読み込み中、のような画面を作ってほしい。あくまで読み込んでいるのがわかる雰囲気だけで大丈夫です。

<sub>更新: 2026-06-08 09:53 ／ 作成: 2026-06-08 09:51</sub>

## 対応中 (1)

### [t-0011] 拡張HOSTLIST

**内容:**

FabriqがもつHOSTLISTとは別で、このアプリがもつHOSTLISTを用意したい。新旧PC名カラムはそのままに、本アプリでいうと、視覚情報などを書き込めるようにすると、そのPCで必要な資格情報が自動で読み込まれて、入力される仕組み。
拡張ホストリストは、念のため、Fabriqのホストリストと突合せ、新旧PC名カラムのエントリが完全に一致しているときのみ採用する。
Fabriq側のホストリストのPCエントリが絶対的な正とするため。

**Claudeメモ:**

P0+P1 実装+敵対的レビュー完了(v0.64.0・実バグ0)。実装範囲=P0+P1/サイレント自動接続/独立EXE管理ツール/単一ファイル(ユーザ選択)。追加: common.ps1 Protect-FabriqValue(Unprotect の厳密な逆・byte-identical 検証済) / backuper/lib/extended_hostlist.ps1(reader 生読み+平文guard / 純突合 Resolve-ExtendedHostlistMatch=(OldPCname,NewPCname)完全一致 trim+大小無視 空は空のみ / Get-PresetUncUsername / seam Connect-UncFromExtendedHostlist=識別は $script:CurrentHost・オンデマンド復号・成功時のみ true・失敗で従来ダイアログ) / main.ps1 dot-source / backup_view+restore_view 4 call sites で拡張username優先 / extended_hostlist.sample.csv+.gitignore(live除外) / 独立ツール fabriq_exthostlist.ps1+.bat+tools/exthostlist_editor/lib/exthostlist_editor_view.ps1(Fabriq pair から seed=書込時突合強制・Protect+round-trip 検証後保存・平文非書込)。多エージェントレビュー26報告→実バグ0(crypto 8項目 byte-identical/突合 値ベース大小無視で正/seam graceful degradation)。残: P2(視覚情報 session_form/handoff_viewer 表示・後回し)・Fabriq_ExtHostlist.exe ビルド(暫定.bat)・実機スモーク(登録ツールで ENC: 登録→backup/restore でサイレント自動接続→不一致/未登録は従来ダイアログ)。 【v0.64.1】スキーマ簡素化: UncHost/UncShare 列を削除(未参照だったため)。接続先共有は seam がフローの $Path から導出・資格情報特定は新旧PC名なので、ユーザ名+パスワードのみで足りる(ユーザ指摘)。新スキーマ=Enabled,OldPCname,NewPCname,UncUsername,UncPassword,VisualLabel,VisualColor,Note。

<sub>更新: 2026-06-08 09:34 ／ 作成: 2026-06-07 18:31</sub>

## 完了 (8)

### [t-0001] バックアップデータのクリーンアップについて

**内容:**

これをbackuper本体に統合すると、機能が混雑してオペレータが混乱しそうなので
LANPREPと同じく、別exeとして分離させたい。
機能自体は全く同一で、HOSTLISTに該当する端末のバックアップデータを削除する専用GUI。

**Claudeメモ:**

完了(v0.54.0, commit 8785f51)。cleanup を独立ツール Fabriq_Cleanup.exe に分離(LAN-Prep 同レイヤー)。C1=Get-CleanupProtectedRoots を common.ps1 へ移設, C2=独立ツール一式(common.ps1 を dot-source/エンジンは本体残置), C3=本体から cleanup view/モード撤去。実機(SZK-TEST01)で hostlist 読込+対象ホスト自動選択(NewPCName優先)を確認OK。D4/backup マーカー不変。LAN-Prep ack チェックは未リバート LAN-Prep の安全弁として現状維持。

<sub>更新: 2026-06-05 23:12 ／ 作成: 2026-06-05 20:33</sub>

### [t-0002] リストア時の実行サマリがOutlookのプロファイルしか表示されず

**内容:**

ユーザデータのリスト状況も確認できるようにしたい。
（バックアップ時は上記のことができている）

**Claudeメモ:**

実装完了(v0.55.1, 未コミット)。根本原因: Initialize-ProgressEntries が毎回 Rows.Clear() で項目グリッドを全消去→リストアで userdata と outlook_pop の両 section が呼ぶため後の section が前を消し Outlook profile のみ残存(backup は userdata のみ呼ぶので正常だった)。修正: progress_view.ps1 の当該 Clear を除去し section 横断で累積表示(run 開始の Clear は Initialize-ProgressView が担当, entry id は section 一意で Set-EntryStatus は正しい行を更新)。静的検証OK(84/84,123/123,BOM)。残: 実機で userdata+outlook 同時リストアで両方表示を確認。

<sub>更新: 2026-06-06 13:33 ／ 作成: 2026-06-05 20:34</sub>

### [t-0003] バックアップ画面のやりなおしループ（リストアの D6 と対称）

**内容:**

・バックアップ完了後もバックアップ画面に戻れるようにする。
 ・万一バックアップが失敗したら、その分だけ同一セッションで再試行できる。
 ・可能であれば、バックアップ完了済みかどうかのステータス管理も行う。

**Claudeメモ:**

実装完了→コミット(v0.56.0)。セッション一貫バックアップ: アプリ起動〜終了=1セッション=1バックアップ。同一セッション・同一ホストの2回目以降は初回集約dir(同TS)へ自動統合(トグルなし), 再起動で新TS。失敗の穴埋め/成功後の項目追加とも同じ1バックアップに統合。engine -RetryIntoAggregateDir / manifest_aggregator Merge-AggregateManifest / userdata id-mapマージ(新規項目は衝突しない新id採番) / backup_view UI / progress_view ラベル。多エージェント敵対的検証3R(HIGH data-loss・medium状態誤報を検出→修正→指摘ゼロ)。残: 実機スモーク。

<sub>更新: 2026-06-07 13:33 ／ 作成: 2026-06-05 20:35</sub>

### [t-0005] LANPREP後の自動Backuper起動について

**内容:**

可能であれば、LANPREPにおける移行元・先の選択によって、backupe画面でも押せるボタンを動的に変更してほしい。いまだとバックアップとかリストアがどちらも表示されていると思います。
もちろん今でもEnterを押下したら自動で選択した役割が選択されますが、オペレータが間違えて、ボタンで選んでしまうとも限らないので。

**Claudeメモ:**

実装完了(v0.55.0, 未コミット)。session_form.ps1 で PreselectMode(役割)に応じ非該当ボタンを無効化+グレーアウト(neutral gray/fgDim/Enabled=false/Cursor=Default)。source→Backup はリストア無効, target→Restore はバックアップ無効。手動起動(PreselectMode='')は両方有効, Enter は役割側, 既存役割バナーで理由表示。静的検証OK(括弧55/55,144/144,BOM)。残: 実機で役割別ボタン無効化の確認。

<sub>更新: 2026-06-06 13:33 ／ 作成: 2026-06-05 20:43</sub>

### [t-0006] デスクトップ集約フォルダの集約

**内容:**

現状、オペレータが使用するための情報集約フォルダをデスクトップに配置しているが、これを、Backuper内の専用ディレクトリに移動させた上で、LANPREPやcleanupと同様に個別アプリ化する。そのディレクトリを走査し、ホストリストで選択された端末用の集約フォルダを見つける。
最終的には、そのアプリのGUI上で、各種情報を閲覧できるようにする。（それぞれの設定情報確認基盤は整っている認識なのでそれを呼び出すショートカットをわかりやすくGUI上に配置するのがいいと感じている。）

**Claudeメモ:**

第1段(ビューア本体)+第2段(集約フォルダ移設)とも実装+コミット済。第1段 v0.58.0-0.58.2(88c6d28本体/b892969 Outlookアカウント別+AutoScroll/d157420 .txtアプリ内ビューア)。第2段 v0.59.0: 集約フォルダ出力先を移行先Desktop→<BackuperRoot>/Handoff/<日付>_<OldPC>_BK へ移設。Resolve-OperatorHandoffRootLocal新規(Desktop版は温存=後方互換)/Get-CleanupCandidate Root3b追加(ビューア+Cleanup双方が発見)/restore_view切替+チェックボックス文言+README+宣言コメント更新/Get-CleanupSourceLabelにHandoff(Backuper)ラベル追加。安全弁は子孫削除許可で新場所も削除可。section配備はroot非依存で不変・schema/interface不変。敵対的レビュー2R(stage1 PASS / stage2=確定2件[低:source label/stale comment]修正済)。全コミット実機未確認(実機スモーク推奨)。

<sub>更新: 2026-06-07 13:33 ／ 作成: 2026-06-06 13:34</sub>

### [t-0008] リストア画面に更新(選択中バックアップ再読込)ボタンを追加

**内容:**

移行先でリストア画面を開いたまま、移行元がバックアップを追記/穴埋め(セッション統合)した内容を画面を開き直さずに反映できるようにする。選択中バックアップの manifest を読み直してエントリ一覧・状態・警告を更新する。

**Claudeメモ:**

実装完了(v0.57.0,未コミット)。restore_view に更新ボタン追加→Update-RestoreSelection(選択中バックアップの manifest を disk から再読込→エントリ/状態/警告を再構築)を呼ぶ。エントリ操作行右端 X818。engine/選択契約 不変。残: 実機確認。

<sub>更新: 2026-06-07 13:33 ／ 作成: 2026-06-07 11:06</sub>

### [t-0009] アプリケーション突合ビューア

**内容:**

現在、PC情報に格納されている、アプリケーション突合バッチですが、これを専用ビューアに仕立てたのち、PC情報とは別のセクションとして、アプリケーション情報セクションを設けてそこに格納したい。
ハンドオフビューア上で選択して、突合を行い、視覚的にわかりやすい形で移行が必要なアプリを表示させる。
また、可能であれば、事前に設定された突合リストと、新PCのアプリケーション情報（動的に取得）を比較し、移行が完了しているかどうかも含めた確認ができる機能もあると、都合がよい。
つまり
・旧PCアプリケーション情報
・突合リスト
・新PCアプリケーション情報
の三点を比較し、
・移行が必要なアプリはなにか
・移行が終わっているのかどうか
を確認できるイメージです。

**Claudeメモ:**

完了。アプリケーション突合ビューア: P0-P3 実機確認OK(旧PC×突合リスト×新PC の3点比較で 移行済/要移行/未検出 を色分け判定)。突合は MatchPatterns(|=OR・大小無視の部分一致)を旧PC・新PC 双方に共通 Compare-AppMigrationList で適用。新PCは Get-LiveInstalledApp で起動時ライブ取得(本体 asInvoker・現ユーザ HKCU/HKLM)。アプリ情報は独立 application section(handoff 05)へ移設・後方互換 dual-location。コミット 5c3e9be/13f25aa/01db74b/3f94bb7/23abd52(v0.59.1-0.62.0)。P4(legacy Check-AppMigration.bat 廃止)は不実施=オフライン fallback として残置(ユーザ判断)。

<sub>更新: 2026-06-07 18:13 ／ 作成: 2026-06-07 13:33</sub>

### [t-0010] UNCについて

**内容:**

現状、UNCボタンから明示的に接続確認を行うか、バックアップボタンを押下すると、未接続の状態であれば、標準ダイアログから資格情報を求められるようになっているが、これをUNCボタンを全面的に排除して、手順の流れで資格情報を入力する形式に統一したい。そうした場合のデメリットも検討してほしい。

**Claudeメモ:**

完了(v0.63.0)。UNC 接続ボタンを backup/restore 両画面から撤去し、資格情報入力を手順フローに一本化。Resolve-UncAccess を Get-Credential→Show-UncConnectDialog(プリフィル)に格上げ+ -PresetUsername(profile uncUsername) 追加。backup=開始時に保存先認証。restore=①参照前の preset 事前認証(ツリー探索用)②選択後 manifest 読取前③Invoke-RestoreStart で timestamp/Browse 双方を engine 前に認証 の3点でボタン代替、New-PSDrive global+Test-UncPath 短絡で二重プロンプトなし。Connect-UncWithCredentials は legacy 残置。拡張HOSTLIST 差し込み口(Connect-UncFromExtendedHostlist フック)を inert で設置(将来 PC 別資格情報の事前流し込み構想)。多エージェント敵対的レビュー(22報告→実バグ0: cross-file 依存 main.ps1 128/129 で充足/idempotency/PS5.1 null-safe/btnUncConnect 完全除去)。残:実機スモーク(profile有り UNC backup/restore で password のみ入力→成功, 既知トレードオフ=profile無し手動UNC restore は事前認証導線弱)。

<sub>更新: 2026-06-07 18:54 ／ 作成: 2026-06-07 18:16</sub>

## 保留 (1)

### [t-0012] バックアップおよびリストア機構超大型改修

**内容:**

現状、ローカル運用型バックアップは移行先の共有フォルダへ一括で運び、そこから移行先PCにて改めて本来の配備先へ配送する流れ。これは悪く言うと二度手間になる。そこで、その運用を解消すべく以下の手法を採れるか、また、時間的な節約になるかも含めて検討したい。
１．移行先で先に配備先のフォルダを共有つけて作っておく（ユーザデータ移行リストを基に動的に配備）
２．移行元で、移行リストをもとに動的に共有フォルダのUNCパスを算出→実際の配送リストとして使用。
３．ネットワーク越しに直接それぞれの配備先に配送
４．Outlookなどの設定値データは従来通り、ハンドオフ運用（このデータの格納先は変わらずアプリ内のディレクトリ）

再配送を挟まない分、時間が節約になると思うが、メリットデメリットを洗い出して、実装価値を割り出してほしい。


**Claudeメモ:**

検討完了(多エージェント評価WF: 現状機構マッピング4 + 次元別評価5 + 統合提言)。結論=現仕様での実装は非推奨(do-not)。根拠: (1)時短前提が誤り: canonical local mode では staging=backupRootUnc=移行先PCの共有 で既に移行先上にあり、1回目=ネットワークhop/2回目=移行先内ローカルコピー。直接配送は『移行先内ローカルコピー(高速)』のみ削減・ネットワークbytesは不変 -> 生コピー時短は僅少(推定0-5分・大半はオペレータ時間)。(2)Step1/2 ブロック: 移行先ユーザの profile path は restore 時にオペレータが選ぶ値で source は backup 時に知り得ない(Fabriq hostlist は PC名のみ・t-0011 は UNC 認証用で profile-mapping 不可)。直接配送は cross-user 移行(restore.ps1 Expand-PathWithUser 再展開)を破壊。(3)Step3 危険: 2nd copy が onConflict/.bak/restored-marker/cross-user の本体。live profile 直書きは Outlook/Chrome 等の file-lock 違反 + staging snapshot 消失で中断時に live profile 半壊(復旧不能)、t-0003 retry/t-0008 reload/D2-D4 も破綻。(4)coupling/security: lockstep 化で arrival-wait 無効化、live profile を LAN に Everyone:Full 共有。代替案(価値=オペレータ時間 を安全に取る): staging 維持のまま backup 後に restore を自動チェーン。段階: P0 計測(restore ローカルleg を実測、小さければ中止) -> P1 auto-chain(staging 維持・安全) -> P2 PoC(temp-then-rename 直接配送, 要 target-user field + t-0011)。ユーザ決定待ち。 【決定 2026-06-07】ユーザ判断: 実装しない(現状維持で棚上げ)。現2コピー方式(staging->再配送)を維持。t-0012 は保留でクローズ(将来 再検討する場合は P0計測->P1自動チェーン から)。

<sub>更新: 2026-06-07 20:00 ／ 作成: 2026-06-07 19:14</sub>

