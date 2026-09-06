---
name: stock-triage
description: 未トリアージの Issue を 1 件ずつ調べて、完了条件を本文へ書き、着手できる在庫にする (印は付けない)。ready-queue.sh の stock 行を材料にする。Use when the ready queue is running low, when building up triaged issues for later work, when an untriaged issue needs its completion criteria investigated and written, or 在庫を作って / 未トリアージを調べて.
---

<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# 未トリアージを在庫にする (B-1)

**規律の正典は [ADR-0036](../../../docs/decisions/0036-unattended-issue-processing.md) 決定 3** で、
ここは手順だけを持つ。決定が言っているのは 1 行である — **材料はエージェントが作り、印はメンテナが押す。**

基準を「調査して本文を固めた者」まで広げないのは、トリアージが担っているのが完了条件だけでは
ないからである。起票は「雑でよい・思いつき歓迎」なので (ADR-0002)、**起票は着手の意思ではない。**
「やると決める」ほうは人に残っている。

この仕事が変えるのは押す回数ではなく、**押す場所と時刻**である — 端末の前でプランを承認する
代わりに、GitHub でラベルを 1 つ押せばよくなり、材料は人が居ない間に溜まる。

## 1. 対象を選ぶ

```bash
bash scripts/ready-queue.sh
```

`stock` の行が対象である (エージェントが起票したのに無印で、型が Bug / Task / Docs のもの)。
**1 件だけ取る。**

> **一括でやらない。** [ADR-0002](../../../docs/decisions/0002-issue-lifecycle-and-merge-approval.md)
> 決定 1 追補が禁じているのは「中身を見ずに印を付けること」で、まとめて調べれば必ずそこへ倒れる。
> 追補の 2026-09-07 改訂が緩めたのは**着手を待つこと**だけで、1 件ずつであることは動いていない。

## 2. 現況を確かめる (ここが本体)

**Issue は書かれた時点の話しかしていない。** 調べる前に必ず取り直す:

```bash
git fetch origin main && git log --oneline origin/main -5
```

見るのは 4 つ:

| 見るもの | 打つもの | なぜ |
| --- | --- | --- |
| 既に直っていないか | `git log -S '<本文が挙げた綴り>' origin/main` | [#997](https://github.com/mokume-metal/mokume/issues/997) は修正が既に main に入っていたのに着手された |
| 本文が指す行番号・綴りがいまも同じか | 実際にそのファイルを開く | 行番号は動く。動いていたら本文を直す |
| 前提が動いていないか | 関連する PR / ADR を読む | 起票時に正しかった観測が、いまは別の姿になっていることがある |
| 重複が無いか | `gh issue list --search '<言葉>' --state all` | 同じことが 2 本立っていたら、片方を not planned で閉じる |

**調べても分からなかったことは、分からなかったと書く。** 起票者が「原因が読めない」と書いた
Issue は、たいてい本当に読めない — 埋めずに、**確かめられたところまで**を書く。

## 3. 型を確かめる

[ADR-0004](../../../docs/decisions/0004-issue-classification-by-issue-type.md) の 5 型
(`Bug` / `Feature` / `Task` / `Design` / `Docs`)。付いていなければ付ける (ラベルではなく Issue Type)。

```bash
gh issue edit <番号> --repo mokume-metal/mokume  # 型の付与は gh の Issue Type 欄
```

## 4. 完了条件を本文へ書く

書き方は 1 つ — **いまのコードで確かめられる言い方にする。** 「〜が改善されている」ではなく
「〜を打つと〜が出る」「〜という検査がある」。読む人が着手時に突き合わせられなければ、
[ADR-0031](../../../docs/decisions/0031-triage-as-the-single-gate.md) 決定 4 の再チェックが働かない。

**起票時の記述がずれていたら、消さずに直す。** ADR の改訂と同じ作法で「**当初は〜と書かれていた**」
を残す — 何が変わったのかが読めなくなると、次に同じ調査をやり直すことになる。

本文の編集は `gh issue edit <番号> --body-file <ファイル>`。

## 5. 印は付けない

**`verify: triaged` を付けない。** ここで手が止まるのが正しい。

> 例外は [ADR-0002](../../../docs/decisions/0002-issue-lifecycle-and-merge-approval.md) 決定 1 追補が
> 認めている「**自分が起票し、本文に完了条件を書けた Issue**」だけで、それは作業中に踏んで
> その場で起票したものを指す ([ADR-0036](../../../docs/decisions/0036-unattended-issue-processing.md) 決定 6)。
> **後から調べに来た他人の Issue はここに当たらない。**

## 6. 経緯を 1 通残す

```bash
bash scripts/comment.sh issue <番号> --body-file <ファイル>
```

書くのは「何を確かめたか」と「本文をどう変えたか」まで。**押してほしいことも 1 行書く** —
材料が揃ったことが伝わらないと、溜めた意味が無い。

## しないこと

- **直さない。** これは在庫を作る仕事で、着手ではない。直したくなったら、それは印が付いてから
  改めて着手すればよい (調べた内容は本文とコメントに残っている)
- **完了条件を書けなかったら、書けないまま置く。** 書けないことが「判断が要る」の印である
  (ADR-0036 決定 6 の 3 行目)。無理に埋めると、着手した人が現実と食い違う条件に当たる
- **型が Design / Feature のものを掘りに行かない。** `ready-queue.sh` が `stock` から外している
  のは、判断が要る側だからである
