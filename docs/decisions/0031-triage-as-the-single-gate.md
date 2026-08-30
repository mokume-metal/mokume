<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# ADR-0031: 完了条件の性質で承認を分けるのをやめ、記録と着手時の再チェックへ置き換える

## 状態

採用 (2026-08-31)

## 文脈

[ADR-0002](0002-issue-lifecycle-and-merge-approval.md) 決定 1 は Issue の完了条件を 2 つに分けた。機械検査で判定できるもの (`verify: machine`) は無人で通し、判断を含むもの (`verify: human`) は人間の Approve を待つ。決定 3 の `review-gate` がそのルーティングを行い、決定 5 は「機械クラスの領土を広げ続ける」と書いた。

**263 件のマージ実績で測ったところ、`verify: human` は一度も PR を止めていなかった** ([#618](https://github.com/mokume-metal/mokume/issues/618))。

### 承認を要求していたのは、ほとんどがルールセットだった

マージ済み PR 263 件を「対象 Issue の `verify:` ラベル」×「ルールセットの `required_reviewers` が課す重要パスに触れたか」で割ると:

| | 重要パスに触れる | 触れない |
| --- | --- | --- |
| `verify: human` | 48 | **36** |
| `verify: machine` | 56 | 108 |
| ラベルなし | 10 | 5 |

承認が要った PR は 138 件で、そのうち **`verify: human` が固有に承認を要求したのは右上の 36 件だけ** (全体の 13.7%) である。残りはルールセットが同じ人へ同じ承認を要求しており、ラベルは重複していた。

### その 36 件は、一度も差し戻されていない

| 測ったこと | 実測 |
| --- | --- |
| 承認された | 35 / 36 |
| 変更要求 (`CHANGES_REQUESTED`) | **0 件** (263 件全体でも 0 件) |
| 承認レビューの本文 | サンプル 7 件すべて空 |
| 作成 → 初承認 | 中央値 **11 分** / 30 分以内に 30 件 |

「判断を含むから人が見る」というフィルタとして働いておらず、実態は**ボタンを 1 回押させるだけの遅延装置**だった。押させた回数も測れる — 承認が要った 138 件に対し、人が Approve を押したのは **161 回**である ([#612](https://github.com/mokume-metal/mokume/issues/612) が名指しする承認の消失により、[#279](https://github.com/mokume-metal/mokume/pull/279) は 1 PR で 8 回押されている)。

### 分類そのものが逸脱していた

| Issue 番号帯 | `verify: human` の比率 |
| --- | --- |
| #1-100 | 15% |
| #201-300 | 40% |
| #401-500 | 48% |
| #501-600 | **57%** |

決定 5 は機械クラスを広げると書いたが、実測は逆へ動いていた。しかも完了条件の節を持つ Issue の割合は human 21/25・machine 19/25 で、**ゴールの明確さに差が無い**。分けている基準が「機械検査で表現できるか」から「なんとなく目を通したい」へ流れていた。規律だけで支えていたので、逸脱を止めるものが無かった。

### 承認を外すと、何も残らない

一方で、承認を外すだけでは記録が失われる。直近 100 PR に付いたコメントは 32 件 (0.32/PR)、行単位のレビューは **0 件**である。[ADR-0002](0002-issue-lifecycle-and-merge-approval.md) 決定 6 が記録の置き場を PR へ寄せた後も、PR 側には「何をどう処理したか」がほとんど残っていない。承認が形式だったとしても、それは「人が一度見た」という最後の印ではあった。

### トリアージ済みでも、着手時に妥当とは限らない

もう一つ、ラベルは付いた時点の判断しか表さない。直近 100 Issue のうち **11 件**で、着手時に完了条件が動いている:

| Issue | 何が起きたか |
| --- | --- |
| [#457](https://github.com/mokume-metal/mokume/issues/457) | 「着手にあたって本文とタイトルを書き換えた」「**起票時の 3 条件は、もう満たされていた**」— `git log -S` で確かめたら別の PR が既に解消していた |
| [#448](https://github.com/mokume-metal/mokume/issues/448) | 「本文の完了条件を現実に合わせて直した。載せ替える組み込みは **4 つではなく 2 つ**」 |
| [#493](https://github.com/mokume-metal/mokume/issues/493) | 「後続コメントで前提が変わっていないか」を**手で確かめた形跡** |

再チェックは実務では既に必要とされているのに、**このリポジトリには機構が 1 つも無い**。担い手は個人環境のプラグインだけで、それは [ADR-0017](0017-agent-support-locality.md) 決定 1・2 が禁じている形そのものである (入れている人にだけ効く支援を前提にすると、規約が環境によって変わる)。

現状の起票 → 着手のリードタイムは中央値 1.5 時間・最大 2.9 日と短く、陳腐化はまだ表面化しにくい。だがそれは**メンテナが 1 件ずつ指示しているから**であって、複数の Issue をまとめて自律的に処理するようになれば必ず伸びる。

## 決定

### 1. `verify:` ラベルを 1 種類に畳み、承認の要求源をルールセット一本にする

`verify: machine` / `verify: human` を **`verify: triaged`** の 1 種類に置き換える。ラベルが表すのは「完了条件が固まっている」ことだけで、完了条件の性質は表さない。

**着手ゲートは変えない。** ラベルが無い Issue には着手しない・ラベルの不在が未トリアージを表す・付け損ねは「着手できない」側へ倒れる ([ADR-0002](0002-issue-lifecycle-and-merge-approval.md) 決定 1 が `status: needs-triage` を廃止したときの向き) は、そのまま生き続ける。`verify:` の綴りを保つのも同じ理由で、[ADR-0004](0004-issue-classification-by-issue-type.md) の「ラベルは Issue Type と直交する属性だけを表す」という枠組みを動かさずに済む。

承認を要求するのは**ルールセットの `required_reviewers` だけ**になる (`docs/decisions/` ・ `.github/` ・ `.claude/` の 3 パスに team `maintainers` の 1 承認)。ADR・CI 設定・エージェント設定を触る変更が人の目を通ることは変わらない。

### 2. 承認の代わりに、PR 本文へ「完了条件 × 検証」の対応表を要求する

PR の `## 確認方法` 節に、**対象 Issue の完了条件ごとに、何をどう確かめたか**を書く。まとめて閉じるなら Issue ごとに分けて書く。

`review-gate` はこの節に**対象 Issue の番号がすべて現れること**だけを見る。**内容が正しいかは見ない** — [ADR-0019](0019-drawing-verification.md) 決定 1 と `scripts/check-drawing-evidence.sh` が採る形と同じで、防ぐのは書き忘れであって意図的な迂回ではない。正しさの担い手は読む人間と AI の目である。

**新しいジョブもスクリプトも作らない。** 既にある `review-gate` の責務を広げるだけで足りる ([ADR-0008](0008-mechanism-needs-demonstrated-harm.md) 決定 5 の段 1)。

### 3. 1 PR の粒度を「1 つの説明で筋が通る範囲」とする

「1 PR = 1 関心事」を置き換える。同じ親を持つ sub-issue 群も、作業中に踏んで起票した障害も、**1 つの PR 本文で筋が通るなら**まとめて閉じてよい。閉じる Issue は `Closes #N` を複数書く (`review-gate` は以前から複数の紐づけを検査している)。

**「気付いたら起票する」は変えない** — 起票を省いて直接直すと、変更の理由がどこにも残らない。変わるのは、起票した Issue をその場で解決してよいことである。粒度が大きくなっても追跡が効くのは、決定 2 の対応表が Issue ごとに条件と検証を並べるからで、この 2 つは対になっている。

### 4. 着手時の再チェックを機構にする

**ラベルが付いていることは、いま妥当であることを意味しない。** 着手時に完了条件を現行のコードと突き合わせ、ずれていれば Issue 本文を更新してからプランを出す。

これを規約ではなく機構で担保する。`scripts/plan-record.sh` の `capture` が既に**着手の瞬間に発火する唯一のフック**なので、その責務を広げ、プランに次の 2 つが無ければ差し戻す:

1. 対象 Issue の番号
2. **完了条件の現況** — 各条件が「まだ有効」「既に満たされている」「差し替えが要る」のどれか

ここでも見るのは構造の有無だけで、判定が正しいかは見ない。**新しいフックもスクリプトも作らない** — 配線は `.claude/settings.json` に既にある。

着手時 (手元・迂回できる) と PR (CI・必須) の二段になり、片方が黙っても記録は残る。

## 影響

- ラベルは `verify: machine` を `verify: triaged` へ rename し、`verify: human` を削除する。rename は closed の Issue まで一度に移るので、履歴の読み替えは要らない
- ラベル由来の承認機構が丸ごと消える。`scripts/request-review.sh` (とそのテスト) を削除し、`.github/workflows/ci.yml` の `approval-signal` ジョブと `human-approval` の commit status を畳み、ルールセットの必須チェックからも外す。`scripts/review-gate.sh` の終了コードは 0・1 の 2 つに戻る (`PENDING=20` は消える)
- [#111](https://github.com/mokume-metal/mokume/issues/111) / [#256](https://github.com/mokume-metal/mokume/issues/256) / [#282](https://github.com/mokume-metal/mokume/issues/282) / [#494](https://github.com/mokume-metal/mokume/issues/494) / [#575](https://github.com/mokume-metal/mokume/issues/575) / [#577](https://github.com/mokume-metal/mokume/issues/577) / [#583](https://github.com/mokume-metal/mokume/issues/583) / [#584](https://github.com/mokume-metal/mokume/issues/584) が積み上げた修正は、対象ごと無くなる。**それらが間違っていたわけではない** — 承認待ちを故障と区別する・待っていることを人へ届ける、はどれもラベル由来の承認が要る前提では正しかった。前提のほうを畳んだ
- [ADR-0007](0007-approvability-invariant.md) の不変条件は**変わらない**。承認が要る PR は重要パスに触れるものだけになるが、その PR の author が唯一の承認者であってはならないことに変わりはなく、`review-gate` の検査も残る
- `verify: human` を承認の根拠として引いていた記述 ([ADR-0003](0003-agent-identity-separation.md) 決定 5・[ADR-0005](0005-pr-labels-as-machine-input.md)・[ADR-0017](0017-agent-support-locality.md)・[ADR-0019](0019-drawing-verification.md)) は、決定 1 に置き換わる
- [ADR-0002](0002-issue-lifecycle-and-merge-approval.md) 決定 5 (機械クラスの領土を広げ続ける) は役目を終える。分類が無くなるので広げる先が無い。**検査を増やし続けること自体は変わらない** — それは [ADR-0001](0001-founding-principles.md) 原則 8 が持つ
- 承認が減るぶん、merge 後に問題が見つかる割合は上がりうる。そのとき戻すべきは `verify: human` ではなく、**何が見落とされたかを名指しできる検査**である ([ADR-0008](0008-mechanism-needs-demonstrated-harm.md) の順序 — 実害 → Issue → 機構)
