# タスク管理表 — fabriq_backuper

<!-- このファイルは TM アプリが .tm/tasks.json から自動生成します。
     直接編集しないでください（次回保存で上書きされます）。
     タスクの追加・更新は tasks.json か TM アプリから行ってください。 -->
最終更新: 2026-06-06 13:44

## 未着手 (3)

### [t-0004] リモートデスクトップ機能

**内容:**

・移行先PCへ Windows標準の RDP で接続できるようにする。
・データ移行後すぐ画面を確認したいがディスプレイが余っていない時の補助。
・資格情報は、共有フォルダで使ったものを流用する想定。

<sub>更新: 2026-06-06 13:39 ／ 作成: 2026-06-05 20:36</sub>

### [t-0006] デスクトップ集約フォルダの集約

**内容:**

現状、オペレータが使用するための情報集約フォルダをデスクトップに配置しているが、これを、Backuper内の専用ディレクトリに移動させた上で、LANPREPやcleanupと同様に個別アプリ化する。そのディレクトリを走査し、ホストリストで選択された端末用の集約フォルダを見つける。
最終的には、そのアプリのGUI上で、各種情報を閲覧できるようにする。（それぞれの設定情報確認基盤は整っている認識なのでそれを呼び出すショートカットをわかりやすくGUI上に配置するのがいいと感じている。）

<sub>更新: 2026-06-06 13:39 ／ 作成: 2026-06-06 13:34</sub>

### [t-0007] レジストリバックアップ

**内容:**

レジストリキーをバックアップし、そのまま移行先へリストアできる機能。
理想はユーザデータと同じようにレジエディターでそのPCのレジストリを表示させたうえで、GUI上でバックアップが必要なキーを選択できるようにしたい。
それがなんのレジストリキーかをタイトルやメモなどでわかるようにしたい。
リストアは.regをインポートできるように集約フォルダに配備する

<sub>更新: 2026-06-06 13:44 ／ 作成: 2026-06-06 13:42</sub>

## 対応中 (1)

### [t-0003] バックアップ画面のやりなおしループ（リストアの D6 と対称）

**内容:**

・バックアップ完了後もバックアップ画面に戻れるようにする。
 ・万一バックアップが失敗したら、その分だけ同一セッションで再試行できる。
 ・可能であれば、バックアップ完了済みかどうかのステータス管理も行う。

**Claudeメモ:**

調査完了+計画確定(MVP採用)。D6雛形=ReturnView→ProgressReturnBtn→Switch-View→Show-XView が選択リセット→再選択→再実行。計画: B1 戻るループ(backup_view:671 に -ReturnView 'Backup'; progress_view:221 ラベルに Backup ケース; 完了は Backup で素直に Close=auto-revert は Restore のみ; Show-BackupView 戻り時再描画)。B3 状態表示(実行後 $result.SectionResults + sections/userdata/manifest.json items.entries[].status を $script:BackupLastResult に保持→Show-BackupView で section/entry の 成功/部分/失敗 を表示・失敗ハイライト)。再試行=全体再実行で新ts に1つの完全バックアップ(失敗分のみ再選択は分割注意のオプション扱い)。engine 不変。状態は in-session(永続化は scope 外)。予想 v0.55.1→v0.56.0(MINOR)。実装承認待ち。

<sub>更新: 2026-06-06 00:09 ／ 作成: 2026-06-05 20:35</sub>

## 完了 (3)

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

### [t-0005] LANPREP後の自動Backuper起動について

**内容:**

可能であれば、LANPREPにおける移行元・先の選択によって、backupe画面でも押せるボタンを動的に変更してほしい。いまだとバックアップとかリストアがどちらも表示されていると思います。
もちろん今でもEnterを押下したら自動で選択した役割が選択されますが、オペレータが間違えて、ボタンで選んでしまうとも限らないので。

**Claudeメモ:**

実装完了(v0.55.0, 未コミット)。session_form.ps1 で PreselectMode(役割)に応じ非該当ボタンを無効化+グレーアウト(neutral gray/fgDim/Enabled=false/Cursor=Default)。source→Backup はリストア無効, target→Restore はバックアップ無効。手動起動(PreselectMode='')は両方有効, Enter は役割側, 既存役割バナーで理由表示。静的検証OK(括弧55/55,144/144,BOM)。残: 実機で役割別ボタン無効化の確認。

<sub>更新: 2026-06-06 13:33 ／ 作成: 2026-06-05 20:43</sub>

