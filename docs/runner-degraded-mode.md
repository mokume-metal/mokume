<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# 専用機が止まったときの縮退 (必須チェックから `render` を外す)

merge queue の必須チェック `render` は、専用機 `mokume-m4` の 1 台でだけ走る。専用機の runner が止まると、描画に触れない PR (docs・scripts・CI) も含めて、queue に入った PR が期限 (95 分) ごとに弾かれ続ける。専用機は SSH で入れず、runner は物理操作でしか戻せない ([#1767](https://github.com/mokume-metal/mokume/issues/1767))。runner を戻せない間も merge を通すために、**必須チェックから `render` だけを外した保護の定義**を前もって用意してある ([#2252](https://github.com/mokume-metal/mokume/issues/2252))。

この文書が縮退と復帰の手順の唯一の置き場である。`scripts/stall-watch.sh` の読み分け 8 の対処は、ここを指す。

## 誰が・いつ使うか

- **発動するのはメンテナだけである。エージェントは `--apply` を打たない** (`--degraded --apply`・`--restore --apply`)。保護を書き換える操作で、`--apply` を付けなければ何も書き換えない dry-run は誰が打ってもよい (実設定の読み出しだけ)。
- **発動の条件**: 当番 (`scripts/stall-watch.sh`) が `runner-offline` を名乗っていて、専用機の前で runner を戻せない間。runner が戻せるなら戻すのが先で、縮退は戻せない間の手当てである。
- 先に確かめること: `bash scripts/stall-watch.sh` の `runner-offline` の行と、`gh api repos/mokume-metal/mokume/actions/runners` の `status` (メンテナの権限)。

## 発動する

```bash
bash scripts/apply-rulesets.sh --degraded           # 差分を見る (書き換えない)
bash scripts/apply-rulesets.sh --degraded --apply   # 適用する (メンテナだけ)
```

縮退の定義は [`.github/rulesets-degraded/main-protection.json`](../.github/rulesets-degraded/main-protection.json) で、`.github/rulesets/main-protection.json` から必須チェックの `render` だけを外したものである。差分に出るのは `render` を足した 3 行 (`{ "context": "render" }`) だけで、それ以外の行が出たら発動しない (定義が食い違っている。下の「定義の保守」)。

`--degraded` は縮退の定義にある名前 (`main-protection`) の保護だけを送る。ほかのルールセットには触れない。いつもの `bash scripts/apply-rulesets.sh --apply` は `.github/rulesets/` だけを送るので、縮退の定義を送ることはない。

発動すると、queue に入っている PR は `render` を待たずに通る。**PR を出し直す必要も、定義の PR を作る必要もない** (定義はすでに main にある)。

## 失う保証

縮退の間は、**合流後の木の build・test・gpu-ran と描画の検査がどこでも走らない**。merge_group のホストの `ci-check` は build と test を外していて ([#1985](https://github.com/mokume-metal/mokume/issues/1985))、それを担うのが専用機の `render` だけだからである。縮退中に merge したものは、復帰後の最初の merge_group の `render` と定期の検査が見る。

ほかの必須チェック (`ci-gate`・`pr-gate`) は変わらない。必須の承認も `bypass_actors` も変わらない。

## 縮退の間に起きること

- **日次の ruleset のずれの照合** (`.github/workflows/ruleset-drift.yml`) が、`ci: ルールセットが定義とずれている` を起票する。縮退によるものは、**本文の「検査の出力」の差分が `main-protection` の必須チェックから `render` が無い 3 行だけ**で分かる。ほかのずれが混ざっていれば縮退とは別の原因なので、別に調べる。縮退中は閉じない (復帰後に確かめて閉じる)。
- 手元の `bash scripts/check-rulesets.sh` も、同じ `render` の差分を言って赤になる。それが縮退中の正しい状態である。

## 復帰する

復帰の条件は 2 つ。**runner が online に戻っていること**と、**前検査 ([#2588](https://github.com/mokume-metal/mokume/issues/2588)) が緑**であること。

```bash
bash scripts/apply-rulesets.sh --restore           # 差分を見る。render を足す 3 行だけのはず
bash scripts/apply-rulesets.sh --restore --apply   # 適用する (メンテナだけ)
bash scripts/check-rulesets.sh                     # 定義と実設定が一致している (緑)
```

`--restore` は縮退の定義にある名前の保護だけを、`.github/rulesets/` の定義へ戻す。戻したら、**最初の merge_group の `render` が緑で通ること**を見る。縮退中に merge したものがそこで初めて合流後の木の build・test・描画の検査にかかるので、赤ならその PR を直す。最後に、縮退中に立った ruleset-drift の Issue を、再照合が緑なことを確かめて閉じる。

## 例: #2507 の形

専用機が止まり、先頭の `render` が 14 回続けて落ちた (#2507)。当時 (2026-10-12・queue の期限は 60 分だった) は AGENTS.md だけの PR (#2474) も 60 分ごとに弾かれ続けた (いまの期限は 95 分)。この手順で縮退を適用すると、その PR は `render` を待たずに merge される。復帰の適用で `render` が必須に戻る。

## 定義の保守

縮退の定義と `main-protection.json` の差は、**必須チェックの `render` の 1 つだけ**でなければならない。`main-protection.json` を変える PR は、縮退の定義にも同じ変更を入れる。入れ忘れると `scripts/tests/rulesets_test.py` が赤になる (縮退の発動が、意図しない保護の変更を同時に起こさないため)。
