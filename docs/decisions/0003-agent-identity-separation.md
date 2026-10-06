<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# ADR-0003: エージェントの identity 分離と承認機構

## 状態

採用 (2026-08-26) / 改訂 (2026-08-28): 決定 4 の必須化の手段と決定 5 の報告先 / 改訂 (2026-08-30): 決定 4 が CODEOWNERS を畳む / 改訂 (2026-08-30): 決定 4 のラベル由来の要求を user 宛へ戻す / 一部置換 (→ [ADR-0031](0031-triage-as-the-single-gate.md)): 決定 5 の承認 2 経路 / 改訂 (2026-10-04): 決定 4 が `require_extra_approval_for_unattributed_changes` の意味と、`true` のまま残す理由を書く / 改訂あり (本文の「改訂 (日付)」見出し) / 一部置換 (→ [ADR-0044](0044-maintainer-authored-prs-without-approval-gate.md)): 決定 1・2 の App identity と、決定 3・4 の native の承認の要求

改訂の経緯 (当初の決定・各改訂の理由・置き換わった決定) は [history/0003.md](history/0003.md) にある。本文は現行の決定を書く。

## 文脈

[ADR-0002](0002-issue-lifecycle-and-merge-approval.md) は、メンテナと AI エージェントが**同一の GitHub アカウント**で PR を作ることを前提に設計した。GitHub は自分の PR を自分で承認できないため native の required approving reviews が使えず、承認は `review: approved` ラベルで表現している。

運用してみて、この前提が三つの弱点の共通の根であることが分かった。

**1. 承認が構造ではなく規約になっている。** ラベルはエージェント自身も付けられる。承認ゲートを止めているのは仕組みではなくエージェントの自制であり、[ADR-0001](0001-founding-principles.md) 原則 8「検証は規約でなく構造で」に反する。重要パス (`docs/decisions/` `.github/` `.claude/`) を人間の承認必須にしている目的は**権限の分立** — エージェントが自分の制約を書き換えて自分で通す経路を塞ぐこと — だが、主体が一つしかない以上、分立は成立していない。

**2. 承認が陳腐化しない。** native の Approve には push による stale 化の扱いがあるが、ラベルは承認後に中身が変わっても外れない。

**3. 承認待ちが CI の赤になる。** 承認を required check (`review-gate`) に載せているため、外から見て「承認をまだもらっていない」と「検査が壊れた」が同じ信号になる。実際に、赤い CI を見張る仕組みがこれを故障として誤検出している。

三つは別々の問題ではない。**identity が一つしかない**という単一の根から出ている。個別に手当てすると、対症の仕組みが三つ増えるだけになる。

なお ADR-0002 の決定 4 は出口として「メンテナが複数になったら native へ移行する」ことしか書いていない。メンテナが一人のままでも根を断てる道が、当時は検討されていなかった。

## 決定

### 1. エージェントに GitHub App の identity を与える

**→ [ADR-0044](0044-maintainer-authored-prs-without-approval-gate.md) 決定 1 が置き換えた。** PR はメンテナ名義で作り、App は使わない。置き換わる前の決定 (App の権限表・bypass の種類) は [history/0003.md](history/0003.md) に移した。コミットの author と署名がメンテナのままであることは変わらないので (ADR-0044 決定 1・本 ADR の決定 7)、その段落だけをここに残す。

**コミットの author と署名はメンテナのまま**とする。分離するのは PR 作成の主体であって、著作の主体ではない。署名の検証は鍵に対して行われるため、`signed-commits` ルールセットとも両立する (App のトークンで push したメンテナ署名のコミットが `verified: true` になることを実測した)。

### 2. machine user ではなく App を選ぶ

**→ [ADR-0044](0044-maintainer-authored-prs-without-approval-gate.md) 決定 1 が置き換えた。** 別の identity そのものを持たない。置き換わる前の決定 (machine user との比較) は [history/0003.md](history/0003.md) に移した。

### 3. 承認は native の Approve に戻し、`review: approved` を廃止する

**→ [ADR-0044](0044-maintainer-authored-prs-without-approval-gate.md) 決定 2 が置き換えた。** native の承認も要求しない。`review: approved` の廃止はそのまま。置き換わる前の決定は [history/0003.md](history/0003.md) に移した。

### 4. `required_approving_review_count` は 0 のままにする

**→ [ADR-0044](0044-maintainer-authored-prs-without-approval-gate.md) 決定 2 が置き換えた。** 承認数 0 は変わらないが、`required_reviewers` も空にした。実測と未確認点は、また置くときの手がかりとして [history/0003.md](history/0003.md) に残す。`dismiss_stale_reviews_on_push` と `require_extra_approval_for_unattributed_changes` を定義に残すことは、ADR-0044 決定 2 が持つ。

ルールセットの承認数を 1 に上げると、機械検査だけで完了を判定できる PR (`verify: machine`) まで人間の操作を待つことになり、ADR-0002 決定 1 の「機械クラスは無人で通す」が壊れる。**承認数を 0 に据え置くという決定そのものは変わらない。** 承認数 0 は、同じルールの `require_extra_approval_for_unattributed_changes` が効かないと読む根拠でもある (意味・根拠・未確認点は [history/0003.md](history/0003.md) の「改訂 (2026-10-04)」)。

### 5. 承認を CI から追い出す

承認待ちは required check の赤ではなく、**PR の状態** (`mergeStateStatus` が `BLOCKED`) で表現される。これは failing check ではないため、`ci-gate` の赤は本物の故障だけを意味するようになる (弱点 3 の解消)。

`review-gate` は重要パス判定とラベル fallback を失い、mokume 固有の三点だけを見る短いスクリプトに縮む。

- PR が Issue に紐づいているか (`Closes #N`、例外は `no-issue` ラベル)
- 対象 Issue に `verify:` ラベルがあるか (完了条件が固まっているか)
- 対象 Issue が `verify: human` なら、Approve レビューがあるか

三点目を残すのは、**`verify: human` をパス照合で表現できない**ためである。ルールセットの `required_reviewers` が判定できるのは変更パスであって、Issue の性質ではない (決定 4 の改訂まで代わりに置いていた CODEOWNERS も同じ制約を受けていた)。ここを外すと「完了条件を機械で判定できないと宣言した変更」が誰にも見られずマージされうる。

**→ 三点目 (`verify: human` の Approve) と、承認待ちを `human-approval` という 2 本目の必須チェックで表す手段は、[ADR-0031](0031-triage-as-the-single-gate.md) 決定 1 が `verify: human` ごと畳み、承認そのものは [ADR-0044](0044-maintainer-authored-prs-without-approval-gate.md) 決定 2 が要求しなくなった。** 置き換わる前の決定と 2026-08-28 の改訂は [history/0003.md](history/0003.md) に移した。

### 6. 分離しても残る制約を明記する

これは暗号的な分離ではない。同じマシンにメンテナの認証が残っている限り、エージェントが認証を切り替えて承認する経路は理屈上残る。得られるのは次の二つであり、それ以上を主張しない。

- **意図しない自己承認が構造的に消える** (設定の既定として不可能になる)
- **監査可能性** — 誰が開き誰が承認したかがタイムラインに残る

**push の主体は分離の境界に含めない。** 本 ADR は当初「エージェントが push し PR を開く主体を分離する」と書いていたが、実態はそうなっていなかった ([#106](https://github.com/mokume-metal/mokume/issues/106))。remote が SSH のクローンでは `git push` はメンテナの鍵で通り、`gh pr create` に未 push のブランチを任せた場合や App のトークンで HTTPS へ押した場合は App に帰属する。main の履歴には両方が混在し、同一ブランチでブランチ作成と後続の push が別主体になった例もある。

**揃えなかったのは、揃えても守りが増えないからである。** 上と同じ理由 — 同じマシンにメンテナの鍵が残っている限り、push の帰属はエージェントが選べてしまう。選べる値は監査信号にならないので、経路を固定する機構を足しても得るものが無い ([ADR-0008](0008-mechanism-needs-demonstrated-harm.md))。承認可能性 ([ADR-0007](0007-approvability-invariant.md)) に効くのは PR の author であって push の主体ではないため、不変条件も揺るがない。上の「監査可能性」が主張しているのが**誰が開き誰が承認したか**に限られているのは、そのためである。

**人数は増えていない。** SLSA Source Track の L4 は "two or more trusted **persons**"、CIS の供給網ガイドは "two ... **users**" による承認を求めるが、App はそこに数えられない。メンテナが一人である限りこの水準は達成できず、identity を分けても変わらない。これは AI を導入したことで生じた不足ではなく、一人のプロジェクトが元から持つ限界である。SLSA には bot への例外 (Trusted Robot) があるが、その定義は「robot の identity とコードベースを一方的に変更できないこと」を要求するので、メンテナが単独で書き換えられるエージェントは該当しない。

**AI にレビュー役は与えない。** OpenSSF Scorecard は "Review by bots, including bots powered by AI/ML, do not count as code review" と明文で否定している。エージェントの出力を別のエージェントに検分させることは、本 ADR の承認とは別物であり、人間の承認の代替にはならない。

より強い分離が必要になったら、エージェントの実行環境をメンテナの認証情報から隔離する (別ホスト・別ユーザー) ことを別途検討する。

### 7. コミットの貢献を維持する

squash merge の author は **App になる**。しかし GitHub は、ブランチ側コミットの author を `Co-authored-by:` として squash コミットへ**自動で付ける**。したがってメンテナの貢献は、決定 1 の「コミットの author はメンテナのまま」を守っている限り**自動で保たれる**。手当ては要らない。

手で `Co-authored-by:` を PR 本文へ置く方式は採らない。実測したところ、GitHub が squash 本文を折り返して trailer の行が割れ、trailer として無効になった。書いた本人にも壊れたことが分からないため、機械で要求すれば「壊れた trailer を有効と判定する検査」になってしまう。

守るべきは trailer を書くことではなく、**ブランチのコミットの author をメンテナのままにすること**である。

## 影響

- ADR-0002 の決定 4 を本 ADR へ接続する形に改訂する。`review: approved` は「複数メンテナ化までの暫定」ではなく「identity 分離までの暫定」となり、分離の完了時に廃止する
- `scripts/review-gate.sh` から承認判定と重要パス判定を削除する。`CODEOWNERS` を新設する
- 「承認待ちを CI の赤以外で表現する」検討 ([#29](https://github.com/mokume-metal/mokume/issues/29)) は、本 ADR の適用によって不要になる
- エージェントの実行手順 (`GH_TOKEN` に installation token を載せる) を AGENTS.md に加える。秘密鍵はリポジトリにもログにも置かない
- 決定 1 の「エージェントが push し PR を開く主体を分離する」は実態と合っていなかった。[#106](https://github.com/mokume-metal/mokume/issues/106) で push を境界の外と定め、権限表の**理由列**を App が実際に行う操作へ付け替えた (**設定列は不変**なので、ADR-0006 決定 6 の「権限表は改訂しない」= `Administration` を足さない、はそのまま生きる)
- 移行の前に確証が取れなかった四点のうち三点は実測で解決した — installation token での `gh` の動作 (JWT は `Authorization: Bearer` で送る必要がある) / App が push したコミットの署名 (メンテナの鍵の署名は `verified` のまま) / squash コミットの author (App になるが co-author は自動で付く)。残る「承認数 0 と code owner review の組み合わせ」は CODEOWNERS の適用時に測る**はずだったが、測られないまま運用に入った**。効いていないことが分かったのは [#211](https://github.com/mokume-metal/mokume/issues/211) — CODEOWNERS を適用した 2026-08-26 ([#59](https://github.com/mokume-metal/mokume/pull/59)) から 2 日後で、その間ずっと全パスが承認不要だった (決定 4 の改訂)。**「適用時に測る」と書いただけでは測られない** — 未確証の項目は、測る手順そのものを Issue に残すべきだった
