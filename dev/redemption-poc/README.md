# redemption-poc (EXPERIMENT ONLY — 本番 backuper/ 非組込)

## 目的
goal-2（IMAP混在から POP だけ救済）の**別アプローチ**。offline-prune は「load はするが送受信不能」と実機で確定したため、**Redemption（Outlook の実 Extended-MAPI コードパス）で POP アカウントを LIVE 生成**する。Outlook 自身が `0a0d02`/transport/send-receive 配線を構築するので**機能するはず**。各アカウントは移行 PST を `DeliverToStore` で配信先にバインド。

- **レジストリ無汚染**: Redemption の `RedemptionLoader`（regsvr32 不要）を使用。
- **32bit**: Outlook 2016=32bit に合わせ 32bit PowerShell へ自動 relaunch、Redemption.dll(32bit) を使用。
- POP 設定・PST パスは **backup の manifest.json から実行時に読む**（Japanese パス literal を避ける）。

## 確定した Redemption API (Interop v6.7.0.0, reflection で確認)
- `RDOSession.Logon(ProfileName, Password, ShowDialog, NewSession, ParentWnd, NoMail)`
- `RDOStores.AddPSTStore(Path, [Format], [DisplayName])` → `RDOPstStore`
- `RDOAccounts.AddPOP3Account(Name, Address, POP3Server, SMTPServer, UserName, Password)` → `RDOPOP3Account`
- POP3 account props: `POP3_Port/POP3_UseSSL/POP3_UserName/POP3_Password`, `SMTP_Port/SMTP_UseSSL/SMTP_UseAuth/SMTP_UserName`, **`DeliverToStore`(RDOStore)** = 配信先 PST, `Save()`
- ※ IMAP は `AddPOP3Account` のような作成 API が無い（POP のみ。IMAP は引き続き Strategy A 手動）

## 実行手順（32bit Outlook 2016 のテスト機で）
1. **Outlook を閉じる**。
2. **空でよいので Outlook プロファイルを用意**（コントロールパネル>メール>プロファイル）。既定 profile を使うなら `-ProfileName` 省略。
3. **移行 PST 2 つを manifest の `pst.sourcePath`（`C:\Users\y_suzuki\Documents\Outlook ファイル\`）に配置**（別場所なら `-PstOverrideDir`）。
4. **Redemption_test フォルダをこの機にローカルコピー**し `-RedemptionRoot` で指定。
5. 実行（64bit で起動しても自動で 32bit に relaunch する）:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Test-CreatePopViaRedemption.ps1 `
       -ManifestPath <manifest.json のパス> -RedemptionRoot <Redemption_test のローカルパス>
   ```
6. **Outlook 起動 → 各アカウントのパスワード入力 → 送受信**。
   - POP3 port/SSL は manifest が空だったため既定 (995/SSL) を使用。サーバに合わなければ Outlook で調整、または `-DefaultPop3Port/-DefaultPop3SSL` で指定。

## 判定
- ✅ **送受信が動けば** → Redemption live 生成で goal-2 が機能成立（offline-prune の限界を突破）→ 本番統合設計へ。
- ❌ 動かない → さらに調査。

## fallback（no-reg loader が Add-Type で詰まった場合のテスト用）
一時的に登録: `regsvr32 Redemption\Redemption.dll`（管理者・要 32bit regsvr32 = `C:\Windows\SysWOW64\regsvr32.exe`）→ スクリプトを `New-Object -ComObject Redemption.RDOSession` に差し替え。テスト後 `regsvr32 /u` で解除。**本番は no-reg 一択**（非管理者・無汚染）。

## 本番化時の留意
- **ライセンス**: Redemption は商用。製品同梱・再配布には **Redemption 再配布ライセンスが必要**（テストは無償可）。採用判断の最重要点。
- bitness は対象 Outlook に合わせる（32/64 両 DLL 同梱）。
