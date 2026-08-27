<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# ADR-0002: Issue ライフサイクルとマージ承認

## 状態

採用 (2026-08-26)

## 文脈

このリポジトリの main へのマージは merge queue と required check (`ci-gate`) が機械的に守っている (ADR-0001 原則 8)。しかし CI が保証できるのは不変条件と回帰の不在であって、「その PR で Issue が解消したか」は別問題である。解消の判定が機械検査で表現できる場合 (テスト・lint・golden image) は green を根拠に自動でマージしてよいが、判断を含む場合 (設計の良し悪し・文書の質・API の手触り) は人間の確認を挟みたい。

一方で、Issue の起票は雑なメモ・思いつき・不確かな報告を歓迎したい。「解消条件が機械判定可能か」は起票時には分からないことが多く、事実確認と意図の議論を経て初めて決まる。分類を起票の条件にすると、気軽に積める文化を壊す。

また本 ADR を書いた時点では、メンテナと AI エージェントが**同一アカウント**で PR を作っていた。GitHub は自分の PR を自分で承認できないため、native の required approving reviews が使えなかった (有効化すると全 PR がデッドロックする)。この前提は [ADR-0003](0003-agent-identity-separation.md) が解消し、決定 4 は native 一本化へ改訂されている。

運用してみると、**記録が Issue のコメントに偏った** ([#148](https://github.com/mokume-metal/mokume/issues/148))。Issue は 86 件に 116 コメント (1 件あたり 1.35) が積まれ、PR は 55 件に 12 コメント (0.22)、行単位のレビューコメントは 0 件だった。実装中の発見も、プランからの差分も、条件ごとの詳細な完了報告も Issue に書かれ、Issue が実装ログになっていた。原因は本 ADR の決定 2 と AGENTS.md が**着手後の記録まで Issue 固定で書いていた**ことにある。機構のほうは先に正しい形になっていて、`scripts/plan-record.sh` の投稿先解決は「PR があればそこ、無ければ Issue」と器の有無で選んでいた。文書が機構に追いついていない。

`status: needs-triage` も廃止した ([#156](https://github.com/mokume-metal/mokume/issues/156))。このラベルは「`verify:` がまだ無い」ことの写しで、**機械の読み手が一つも無かった** — 着手ゲートを実際に守る `scripts/review-gate.sh` が見るのは `verify:` の有無だけである。写しは実測でずれていて、`verify: machine` との併存が 2 件、closed への残置が 5 件あった。決定的だったのは**付与の失敗が危険側に倒れる**ことで、Triage の run が落ちて付かなかった Issue は `label:"status: needs-triage"` の検索から漏れ、未合意のまま着手可能に見えた ([#93](https://github.com/mokume-metal/mokume/issues/93))。`verify:` の不在で未トリアージを表せば、同じ失敗はそのまま「着手できない」に倒れる。

## 決定

### 1. Issue のライフサイクル — 分類は議論の成果物

```
起票 (無条件)  →  議論  →  トリアージ完了  →  着手
```

- **起票**: 書式・分類を要求しない。機械が下書きするのはタイトルからの Issue Type だけで、ラベルは付かない
- **議論**: 事実確認・意図のすり合わせをコメントで行い、「どうなれば解消と言えるか」が収束したら **Issue 本文に反映する** (本文が正典・経緯はコメントに残る)
- **トリアージ完了**: 完了条件の機械判定可否を判定し、`verify: machine` (どの検査で判定するかを本文に明記) または `verify: human` を付与する。**verify ラベルの付与がトリアージ完了の印であり、その不在が未トリアージを表す** — 未トリアージ側に別のラベルを置かない (写しになり、付け損ねが危険側に倒れる)
- 自明な Issue は議論を省略し、起票直後にメンテナがラベルを付けてよい (fast path)

### 2. 着手の条件

`verify:` ラベルが無い Issue には着手しない。着手時のプランは、合意済みの完了条件を引用して書く。置き場は**対象 Issue のコメント** — この時点ではまだ PR が無いためで、PR ができて以降の記録は PR 側へ移る (決定 6)。

### 3. PR のルーティング — review-gate

required check `review-gate` が PR ごとに判定する:

| 状態 | 判定 |
|---|---|
| `Closes #N` が無く `no-issue` ラベルも無い | 赤 (Issue 駆動の徹底) |
| 対象 Issue に `verify:` ラベルが無い | 赤 (完了条件が未確定のまま実装に入っている) |
| `verify: human` | メンテナの Approve レビューが付くまで赤 |
| `verify: machine` | 検査群 (`ci-check` 等) のみで通過 |
| Changes requested が未解消 | 赤 |

**重要パスの承認要求は review-gate ではなく CODEOWNERS が担う** ([ADR-0003](0003-agent-identity-separation.md))。`.github/CODEOWNERS` に挙げたパス (`docs/decisions/`・`.github/`・`.claude/`) に触れる PR は、GitHub が自動でメンテナへレビューを要求し、承認が無ければマージできない。公開 API 面はコードが生まれた時点で CODEOWNERS に追加する。

`verify: human` だけは CODEOWNERS で表現できない (パスではなく Issue の性質で決まる) ため、review-gate に残している。

### 4. 人間の承認は native の Approve レビューに一本化する

承認の表現は **GitHub native の Approve レビュー**とする。帰属・push による stale 化の扱い・複数メンテナへの拡張・CODEOWNERS 連携が揃った専用機構だからである。Changes requested のレビューが未解消の場合は赤のまま。

当初はメンテナと PR 作成者が同一アカウントで、自分の PR を Approve できなかったため、`review: approved` ラベルを暫定の fallback として認めていた。**この fallback は廃止した。** ラベルはエージェント自身も付けられるため、承認ゲートを止めているのが仕組みではなくエージェントの自制でしかなかった。

出口は [ADR-0003](0003-agent-identity-separation.md) が実行した — エージェントに GitHub App の identity を与えて PR の作成者を分離し、**自分の PR は自分で承認できない**というプラットフォームの制約が効く状態にしたうえで、ラベルをリポジトリから削除した。重要パスの承認要求は CODEOWNERS へ移り、そこでは App の承認では要件を満たせない (CODEOWNERS にはユーザーとチームしか書けない)。

### 5. 機械クラスの領土を広げ続ける

`verify: human` は「機械検査がまだ無い」ことの表明でもある。テスト・golden image・schema 照合が充実するほど、同種の Issue を `verify: machine` へ移す。新しい検査を入れるときは、対象を意図的に壊して**赤くなることを確認してから**組み込む (壊しても緑の検査は検査ではない)。

### 6. 記録の置き場は情報の寿命で決める

Issue と PR のどちらに書くかは、**「この PR が merge された後も読まれるか」**で決める。

| 内容 | 置き場 | 理由 |
| --- | --- | --- |
| 問題の分析・トリアージ・完了条件の議論 | **Issue** | 解決手段が決まる前の情報。PR がまだ無い |
| 着手時プラン | **Issue** | 同上。次のセッションは Issue から入る |
| 実装判断・プランからの差分・作業中の発見 | **PR** | diff の隣で読む必要がある |
| CI の状況・作り直しの経緯・レビュー | **PR** | その PR 固有。merge で役目を終える |
| 完了条件そのものが動く話 | **Issue** | 完了条件は Issue 本文が正典 (決定 1) |
| 完了報告 | **Issue に 1 通** | 「条件 N は PR #M で満たされた」の対応表まで |
| 恒久的な決定 | **ADR** | コメントに置いたままにしない |

運用としては 1 行で足りる — **PR ができるまでは Issue、できてからは PR**。例外は表の下 3 行だけである。

この分け方は GitHub 自身の構造と一致する。PR は diff・行単位のレビュー・suggestion を持ち merge で役目を終えるが、Issue は問題が解消するまで生き、1 つの Issue に複数の PR がぶら下がる。ADR-0001 原則からの「正典の在処」もこの形になる — **決定は ADR、問題は Issue、変更の理由は PR**。

**完了報告は Issue に対応表 1 通まで**とし、条件ごとの詳細は PR へリンクする。「本文が正典なのだから完了条件に印を付けて本文を書き換えれば足りる」は採らない。本文の編集履歴は実質読めず、それでは **close の根拠がタイムラインから消える**。逆に条件ごとの経緯を Issue に書き下すと、決定 1 が本文へ寄せたはずの正典がコメント側へ散る。

**PR を作ったとき Issue へ「実装 PR は #N」とは書かない。** 本文の `Closes #N` から GitHub が双方のタイムラインに相互リンクを描くので、写しが増えるだけである。

**この決定のために新しい機構は作らない。** `scripts/plan-record.sh` の投稿先解決が既に「PR があればそこ、無ければ Issue」の順で器を選んでおり、決定 6 はその挙動を文書側で認めたものである ([ADR-0008](0008-mechanism-needs-demonstrated-harm.md) 決定 5 の段 1 — 既存の機構の責務を広げる)。

## 影響

- ラベル体系に `verify: machine` / `verify: human` / `no-issue` を追加する (`review: approved` と `status: needs-triage` も一度は追加したが、前者は identity 分離の完了に伴い、後者は #156 で削除した)
- review-gate の実装は独立した Issue で行う。実装までの間、本 ADR のルーティングは運用で守る
- AGENTS.md の「進め方」「マージの判断基準」「コメント」を本 ADR に接続する
- エージェントは `verify:` の無い Issue に着手できない。議論を経ずに merge へ到達する経路が構造的に消える
- ADR・workflows・`.claude/` の変更は常にメンテナの承認を要する。当初この効果は規約止まりだったが (ラベルはエージェント自身も付けられた)、[ADR-0003](0003-agent-identity-separation.md) の identity 分離と CODEOWNERS への移行によって**構造として成立した**
- 決定 6 は文書だけで守る。判定は「その情報が merge 後も読まれるか」という実質的な判断で、機械にできるのは投稿先が器の有無と合っているかまでであり、それは `scripts/plan-record.sh` が既に見ている
- 行単位のレビューコメントが使われていない件は決定 6 の射程外に置いた。指摘は PR 本文のコメントで実際に届いており、実害が示されていない ([ADR-0008](0008-mechanism-needs-demonstrated-harm.md) の順序 — 実害 → Issue → 機構)
