# imap-prune-spike (EXPERIMENT ONLY — 本番 backuper/ 非組込)

## 目的
IMAP と POP の両方を含む Outlook プロファイルの registry export (`profile_Outlook.reg`)
から、**IMAP の service / store / account を offline で除去**し、**POP-only の pruned .reg**
を生成する研究スパイク。狙いは「IMAP混在プロファイルでも POP だけ自動復元」(goal 2) の
**実装可能性を 1 点の実機テストで yes/no に確定**すること。

> これは実験であり、`backuper/` の本番コードには一切組み込まれていない。出力 .reg の
> 実機 import だけが残る未知（後述）。

## 背景（なぜ難しいか）
Outlook の profile は MAPI の cross-reference graph を持つ。IMAP account を消すには、
account subkey だけでなく、それを参照する **flat 配列**（`01023d0e` service / `01023d00`
store）と、**offset 表つき MV_BINARY 配列**（`11023d05` / `1102039b` / `11020434` /
`11026620` / `11026626`）から該当要素を除去し、**count と全 absolute offset を作り直す**
必要がある。1 箇所でも dangling reference が残ると、same-version (16.0→16.0) の strict
validator が profile open を拒否し **起動時 silent crash**（v0.18.0 で観測）になる。

## 解決した部分（offline、実証済み）
- **MV_BINARY 形式を確定**: `{uint32 count; count×(uint64 len, uint64 absOffset);
  各 blob 後に 4-byte 境界への zero padding}`。実 capture の **6/6 配列が
  parse→serialize でバイト完全一致 (round-trip identity)**。
- **IMAP 参照を実バイトで完全マップ**し、content-driven に除去（要素が IMAP marker
  = `b04917cf`(svc UID) / `61f1f7b7`(store rec) / `pstprx.dll` を含むか で判定）。
- 生成物は **16/16 offline check PASS**（IMAP 参照ゼロ・POP DSE バイト一致・全 MV
  round-trip・flat 配列正縮小）。

## ファイル
- `Build-PrunedReg.ps1` — pruned .reg を生成（parser + round-trip 実証済み serializer +
  除去ロジック）。
- `Verify-PrunedReg.ps1` — 生成物の offline 自己無矛盾チェック（実機 load は検証しない）。
- `profile_Outlook.POP-only.reg` — 生成された候補（live-test 対象）。

## 使い方（offline）
```powershell
powershell -ExecutionPolicy Bypass -File .\Build-PrunedReg.ps1
powershell -ExecutionPolicy Bypass -File .\Verify-PrunedReg.ps1   # 16/16 PASS を確認
```

## 汎用版 + 複数アカウント検証 (2026-05-30 追記)
- `Build-PrunedReg-Auto.ps1` / `Verify-PrunedReg-Auto.ps1` = **IMAP UID をハードコードせず
  動的導出**する汎用版（任意の `profile_Outlook.reg` を受け取る）。
- 第 1 capture (1POP+1IMAP suzuki) で **hardcode 版とバイト完全一致 + 16/16 PASS**。
- 第 2 capture (`2016pop_and_imap` = **2 POP + 2 IMAP**, suzuki@/sales1@) で **18/18 PASS**:
  2 IMAP を全除去・**2 POP の Delivery Store EntryID を各自バイト一致で保持**・全 MV round-trip。
- **★ 環境差の発見**: PT_MV_BINARY (`1102xxxx`) の **descriptor 幅は環境依存**。第 1 capture は
  16byte (`u64 len, u64 off`)、第 2 capture は 8byte (`u32 len, u32 off`)。**Outlook の bitness
  由来と推定**。`Read-Mv` は **off[0] がどちらの header size に一致するかで幅を自動判別**し、
  source の幅を保ったまま再シリアライズする (round-trip exact)。固定幅前提だと Int32 overflow で
  壊れる — 第 2 capture を試して初めて顕在化した。
- 安全装置: parse 不能な `1102xxxx` が IMAP marker を含む場合は **UNSAFE と表示して止める**
  (verbatim 出力で dangling 参照を残さない)。

実行例:
```powershell
.\Build-PrunedReg-Auto.ps1  -InReg <profile.reg> -OutReg <out.reg>
.\Verify-PrunedReg-Auto.ps1 -InReg <profile.reg> -OutReg <out.reg>
```

## ★ operator live-test 手順（唯一の残る未知）
**必ずテスト機 / 使い捨てプロファイルで。本番 Outlook では行わない。** 事前に対象の
`HKCU\...\Office\16.0\Outlook\Profiles\Outlook` を export してバックアップすること。

1. **same-version (Outlook 16.0)** のテスト機を用意（元 capture 機のクローンが理想）。
2. baseline 確認: まず **元の（未 prune の）`profile_Outlook.reg`** を import → Outlook 起動
   → IMAP+POP が両方見え、各 account が自分の store に紐づくことを確認（環境が正常な基準）。
3. profile を一旦 export 退避 → `reg import profile_Outlook.POP-only.reg`（**管理者でなく
   対象ユーザとして**）。
4. **Outlook 起動**。観察ポイント:
   - ✅ profile が **開くか**（silent crash / 「フォルダーセットを開けません」が出ないか）。
   - ✅ **POP account が自分の PST に紐づくか**（IMAP は消えているのが期待）。
   - ❌ 落ちる/開かない → prune が strict validator を満たしていない（下記残リスク参照）。
5. 結果（開いた/落ちた + スクショ/ログ）を記録。**これが「理論上決定的」を yes/no に変える
   唯一のエビデンス**。

## 残リスク（offline check を通っても crash しうる要因）
1. **4-byte Mini-UID の dangling**: 本スパイクの marker は 16-byte UID + `pstprx.dll`。
   MAPI が使う 4-byte mini-uid で IMAP service を指す参照が別途あれば取りこぼす（未走査）。
2. **`11020434` を count=0 の空 MV** にしている。Outlook が「値が存在しない」ことを期待
   する場合は crash しうる → その時は **値ごと削除**（`"11020434"=-`）を試す。
3. **strict validator の未文書 invariant**: 我々のモデル外の不変条件で弾かれる可能性。
4. 本 .reg は **source の PST パスを保持**（T8 rebase 未適用）。load テストには無関係
   （PST 不在なら Outlook が促すだけ）だが、実移行で使うなら別途 T8 rebase が必要。

## 一般化の限界
`Build-PrunedReg.ps1` の `$DELETE_LEAVES` と flat UID は **この 2026_05_19 capture 固有**の
UID をハードコードしている。別 capture に使うには、対象プロファイルから「`IMAP Server` を
持つ account subkey → その `Service UID` → 参照される store-record/store-service」を**動的に
辿って導出**する必要がある（MV/flat の要素判定は marker 駆動なので既に汎用）。本番化する
場合の必須要件。

## 結論（feasibility）
- **① offline pruned .reg 生成 = 実証済み**（serializer round-trip 一致 + 16/16 check PASS）。
- **② 実機 Outlook が受理するか = 唯一の未知**。上記 live-test が通れば初めて本番 transform
  （MV_BINARY serializer の組込 + IMAP UID の動的導出）を scope する価値が出る。通らなければ
  **IMAP混在は Strategy A 据え置きが確定**。
