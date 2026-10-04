<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# ADR-0003: エージェントの identity 分離と承認機構

## 状態

採用 (2026-08-26) / 改訂 (2026-08-28): 決定 4 の必須化の手段と決定 5 の報告先 / 改訂 (2026-08-30): 決定 4 が CODEOWNERS を畳む / 改訂 (2026-08-30): 決定 4 のラベル由来の要求を user 宛へ戻す / 一部置換 (→ [ADR-0031](0031-triage-as-the-single-gate.md)): 決定 5 の承認 2 経路 / 改訂 (2026-10-04): 決定 4 が `require_extra_approval_for_unattributed_changes` の意味と、`true` のまま残す理由を書く / 改訂あり (本文の「改訂 (日付)」見出し)

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

エージェントが **PR を開く**主体を、メンテナのアカウントから `mokume-metal` org 所有の GitHub App に分離する。**push の主体は分離の対象に含めない** — 理由は決定 6 に書く。App の権限は次に限り、**ルールセットの bypass list には加えない**。

| 権限 | 設定 | 理由 |
| --- | --- | --- |
| Contents | Read and write | PR の merge と auto-merge の予約・merge 後のリモートブランチ削除・App のトークンで push する経路を通ったときのブランチ push |
| Pull requests | Read and write | PR の作成・更新 |
| Issues | Read and write | コメント・ラベル |
| Workflows | Read and write | App のトークンで push する経路では効いてくる — GitHub は `.github/workflows/` 配下を変更する push を、`workflows` 権限の無いトークンに対して**サーバ側で拒否する** |
| Metadata | Read-only | 必須 |
| **Administration** | **No access** | 与えるとエージェントが自分を縛るルールセットを外せてしまい、本 ADR の目的が崩れる |

`Administration` を持たない結果として、ルールセットの変更はメンテナ側の作業になる。一度きりの設定変更なので運用上の負担は小さい。

**bypass を与えることになった場合は、種類を選ぶ。** ルールセットの bypass には二種類あり、exemption 型は enforcement を**黙って**飛ばす (監査記録が残らない)。将来どうしても必要になったら、痕跡が PR と audit log に残る "for pull requests only" 型を選ぶ。便利さのために監査記録を捨てない。

**コミットの author と署名はメンテナのまま**とする。分離するのは PR 作成の主体であって、著作の主体ではない。署名の検証は鍵に対して行われるため、`signed-commits` ルールセットとも両立する (App のトークンで push したメンテナ署名のコミットが `verified: true` になることを実測した)。

### 2. machine user ではなく App を選ぶ

| | machine user (別アカウント) | GitHub App |
| --- | --- | --- |
| 認証情報の性格 | アカウント認証 (PAT) | 単一用途の秘密鍵。対象リポジトリ限定・即時失効可能 |
| 権限の粒度 | アカウント単位 | 機能単位 |
| 手数 | 少ない | installation token の発行が要る (有効期限 1 時間) |

決め手は**認証情報の性格**である。メンテナの秘密管理方針は「アカウント認証はキャッシュせず、承認プロンプトが出ること自体を防御とする」であり、machine user の PAT はこれと正面衝突する (無人セッションが止まる)。App の秘密鍵は単一用途で失効が容易なため、方針を曲げずに扱える。

### 3. 承認は native の Approve に戻し、`review: approved` を廃止する

PR の作成者は自分の PR を承認できない。これは GitHub のプラットフォーム制約で、ブランチ保護の設定では上書きできず、bot にも同じく適用される。identity が分かれた瞬間に、承認は演技ではなく仕組みになる。

この制約は逆向きにも効く — **author が唯一の承認者候補になっている PR は、誰にも承認できない**。本 ADR はその可能性を扱っておらず、[#88](https://github.com/mokume-metal/mokume/issues/88) で実際に詰んだ。[ADR-0007](0007-approvability-invariant.md) が承認可能性を明文の不変条件として置き、機構で守る形に補っている。

重要パスの承認要求は **CODEOWNERS** で表現する。CODEOWNERS にはユーザーとチームしか書けないため、App の承認では code owner 要件を満たせない。制約が二重にかかる。(**必須化の手段は決定 4 の改訂で `required_reviewers` へ移り、2026-08-30 の改訂で CODEOWNERS 自体を畳んだ** — CODEOWNERS だけでは merge を止められず、`required_reviewers` を入れた後は要求を二重に飛ばすだけの写しになっていた。App が承認者になれない点は `required_reviewers` でも同じで、こちらも Team しか書けない。)

### 4. `required_approving_review_count` は 0 のままにする (2026-08-28 改訂)

ルールセットの承認数を 1 に上げると、機械検査だけで完了を判定できる PR (`verify: machine`) まで人間の操作を待つことになり、ADR-0002 決定 1 の「機械クラスは無人で通す」が壊れる。**承認数を 0 に据え置くという決定そのものは変わらない。** 承認数 0 は、同じルールの `require_extra_approval_for_unattributed_changes` が効かないと読む根拠でもある (意味・根拠・未確認点は下の「改訂 (2026-10-04)」)。

**当初の決定**は「承認数は 0 のままにし、`require_code_owner_review` を有効にする。こうすると CODEOWNERS 対象パスに触れる PR だけが承認を要求される」だった。**この読みが誤りだった**ので、必須化の手段だけを差し替える。

**実測 — 承認数 0 は code owner の承認要求ごと非ブロックにする。** GitHub のドキュメントに明記がある: 「Requiring zero approvals means that the team will be added for visibility, but the team does not need to approve the request」。承認数 0 は「0 件の承認で足りる」と読まれ、`require_code_owner_review` を有効にしても merge の条件にならない。**レビュー要求は飛ぶ** — `docs/decisions/` を触った [#244](https://github.com/mokume-metal/mokume/pull/244) ・ [#229](https://github.com/mokume-metal/mokume/pull/229) ・ [#208](https://github.com/mokume-metal/mokume/pull/208) のタイムラインにはいずれも `review_requested → shinyaoguri` が残っている — が、`reviewDecision` はどれも空で `REVIEW_REQUIRED` にならない。守られていたのはメンテナが慣行で Approve していたからで、[ADR-0001](0001-founding-principles.md) 原則 8 (検証は規約でなく構造で) から外れていた ([#211](https://github.com/mokume-metal/mokume/issues/211))。

必須化は **ルールセットの `required_reviewers`** が担う。`pull_request` ルールのこのパラメータは、**ファイルパターンごとに `minimum_approvals` を持つ**。

```jsonc
"required_reviewers": [
  { "file_patterns": ["docs/decisions/**", ".github/**", ".claude/**"],
    "minimum_approvals": 1,
    "reviewer": { "id": <team id>, "type": "Team" } }
]
```

承認数は 0 のまま、重要パスにだけ 1 承認が課る。**決定の意図は一字も変わらず、それを実現する機構だけが変わる。**

**実測 ([#249](https://github.com/mokume-metal/mokume/issues/249))** — 触ったパス以外を揃えた使い捨て PR 2 本で確かめた。重要パスに触れる側は全 check が緑でも `mergeStateStatus` が `BLOCKED` で、Approve すると `CLEAN` に変わる。触れない側は承認なしで `CLEAN`。**承認すれば通るブロック**であり、[ADR-0007](0007-approvability-invariant.md) の不変条件は保たれている。

**ただし `reviewDecision` には現れない。** この API が映すのは `required_approving_review_count` 側の要件だけで、`required_reviewers` ルールの要求は承認の前も後も空 (null) で返る。承認の要否・充足を機械で読むなら **`mergeStateStatus`** を見る。#211 の誤診も `reviewRequests` の空を「要求が飛んでいない」と読んだものだった — **レビュー系の API は、機構ごとに何を映すかが違う**。

`reviewer` に書けるのは **Team だけ** (User 不可) なので、org に `maintainers` チームを置く。CODEOWNERS は残す — 「誰に要求するか」と、[ADR-0007](0007-approvability-invariant.md) 決定 3 が承認者集合を読むための代理を担う。`require_code_owner_review` も有効のままでよい (ブロックはしないが、自動要求はこれで飛ぶ)。**新しい機構は 1 つも足していない** — `main-protection.json` の空配列を埋めただけである ([ADR-0008](0008-mechanism-needs-demonstrated-harm.md) 決定 5)。

あわせて `dismiss_stale_reviews_on_push` を有効にし、弱点 2 を塞ぐ。

#### 改訂 (2026-08-30) — CODEOWNERS を畳み、要求も強制もルールセット一本にする

**CODEOWNERS を残した判断が誤りだった。** 上で挙げた 2 つの役割のうち、「誰に要求するか」は `required_reviewers` が既に担っていた。実測 ([#530](https://github.com/mokume-metal/mokume/issues/530)) — 重要パスに触れる PR には**同じ人へ 1 秒差で 2 通**のレビュー要求が飛んでいた。

```
#529  review_requested → team: maintainers   2026-08-30T04:53:51Z
#529  review_requested → user: shinyaoguri   2026-08-30T04:53:52Z
```

**`require_code_owner_review` を false にしても止まらない。** GitHub の自動要求はブランチ保護の設定と独立している — 「Code owners are automatically requested for review when someone opens a pull request that modifies code that they own」([About code owners](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners))。止める設定は無い。**認識される場所に CODEOWNERS がある限り、要求は必ず飛ぶ。**

GitHub 自身は両者の併用を勧めている — required reviewer rule は方針の強制、CODEOWNERS は所有の宣言と要求 ([GA changelog](https://github.blog/changelog/2026-02-17-required-reviewer-rule-is-now-generally-available/))。**その分業が成立するのは、両者が別の相手を指すときである。** このリポジトリでは `maintainers` チームのメンバーが `shinyaoguri` 1 人で、CODEOWNERS も同じ 1 人を指していた。足していたのは通知 1 通だけで、代わりに同じ 3 パスの写し (綴りも違った) と、それを読む glob 照合を抱えていた。

残るもう 1 つの役割 (ADR-0007 決定 3 の代理) も、**GitHub native の signal で置き換えられる**。REST の PR オブジェクトが返す `author_association` は、追加の権限なしに org の中の人か外の人かを答える。

| PR | author | `author_association` |
| --- | --- | --- |
| [#529](https://github.com/mokume-metal/mokume/pull/529) | `mokume-agent[bot]` | `CONTRIBUTOR` |
| [#88](https://github.com/mokume-metal/mokume/pull/88) (詰んだ PR) | `shinyaoguri` | `MEMBER` |

ファイルに書いた名前より**実際の所属のほうが正確**で、写しも消える。よって:

- `.github/CODEOWNERS` を削除する
- `require_code_owner_review` は `false` にする (CODEOWNERS が無ければ無意味であり、承認数 0 との組み合わせでは元から何も強制していない)
- 承認が要るパスの正本は `required_reviewers` の `file_patterns` 1 か所になる。`review-gate` はそこを読み、代理には `author_association` を使う (ADR-0007 決定 3 の改訂)
- ラベル由来のレビュー要求 (`scripts/request-review.sh`・[#498](https://github.com/mokume-metal/mokume/issues/498)) も **team 宛**へ揃える。宛先が 1 つになり、パス由来と重なった PR で 2 通目を作らない (**この 1 項だけ、下の再改訂で覆った**)

`required_reviewers` と `required_approving_review_count: 0` は一字も動かさない。**この改訂が動かすのは要求経路だけで、ブロックの正本は上の決定のままである。**

**畳んだ後も止まることを実測した ([#593](https://github.com/mokume-metal/mokume/issues/593))。** `docs/decisions/` に触れる使い捨て PR ([#594](https://github.com/mokume-metal/mokume/pull/594)) を `verify: machine` の Issue へ紐づけ (= `human-approval` は success になり、**残るブロック要因は `required_reviewers` だけ**)、必須チェック 3 本を含む 9 本すべてを緑にしたうえで Approve を 0 件のままにしたところ、`mergeStateStatus` は `BLOCKED`・REST の `mergeable_state` は `blocked` だった。

**この段落が無い間、上の 1 行は測られていない主張だった。** [#249](https://github.com/mokume-metal/mokume/issues/249) の実測は CODEOWNERS が併存する構成で行われており、`reviewRequests` に team と user の両方が入っていたので `BLOCKED` の出どころを分離できていない。実際 [#573](https://github.com/mokume-metal/mokume/issues/573) はそこを突いて「重要パスの PR が承認 0 で通る」と結論している (前提の PR には Approve が付いていたので結論も誤りだったが、**測っていないこと自体は当たっていた**)。

#### 再改訂 (2026-08-30) — ラベル由来の要求は user 宛に戻す

**当初の決定**は、上の 4 つ目のとおり「ラベル由来のレビュー要求も team 宛へ揃える」だった。宛先を 1 つにすれば、パス由来と重なった PR で 2 通目を作らずに済むと考えたためである。

**この手段は成立しない。** `GITHUB_TOKEN` は org スコープを持たないので、`POST /repos/{repo}/pulls/{n}/requested_reviewers` に `team_reviewers[]` を渡すと 422 で落ちる ([#576](https://github.com/mokume-metal/mokume/issues/576) — [#575](https://github.com/mokume-metal/mokume/pull/575) の CI で実測)。

```
gh: Validation Failed (HTTP 422)
request-review: レビュー要求に失敗した — @maintainers
```

**ルールセットの `required_reviewers` が team へ飛ばせるのは、GitHub 自身が投げているからである。** API 経由で同じ宛先へ投げられることを意味しない — ここを同一視したのが誤りだった。team のメンバーを引いて宛先を作る道も `read:org` が要るので通らず、CI へ App の鍵を置けば通るが、Actions secret 0 件を保つ方針 (決定 1) に対して通知 1 通は釣り合わない。

**気付かれずに入ったのは、team 宛が一度も実際に投げられなかったからである。** この改訂を入れた [#536](https://github.com/mokume-metal/mokume/pull/536) 自身は `.github/` を触るのでパス由来の要求が先に飛び、`request-review.sh` は「既に team へ要求済み」として正しくスキップした。偽 `gh` を使う検査も API を叩かない。**実際に投げる経路を通る PR は、ラベル由来だけの PR しかない。**

よって宛先は user (`shinyaoguri`) へ戻す。承認を課している集合の正典は `required_reviewers` の team `maintainers` のままで、変わるのは**要求を届ける手段**だけである。

**宛先が割れることは受け入れる。** パス由来が飛んでいる PR ではラベル由来がスキップするので、user 宛が飛ぶのはラベル由来だけの PR に限られる — [#530](https://github.com/mokume-metal/mokume/issues/530) が畳んだ「同じ人へ 2 通」は戻らない。team のメンバーが増えたときに宛先が追随しない点は、綴りを `scripts/request-review.sh` 1 か所で持つことで受け止める (メンバーを引く権限が無い以上、他に置き場が無い)。

#### 改訂 (2026-10-04) — `require_extra_approval_for_unattributed_changes` は `true` のまま残す

決定 4 が据え置く承認数 0 は、同じ `pull_request` ルールが持つもう 1 つの承認の鍵とも関わる。`.github/rulesets/main-protection.json` の `require_extra_approval_for_unattributed_changes` は `true` で、**当初の決定はこの鍵を一度も扱っていなかった**。何を要求するのか・効いているのかが ADR にもスクリプトにも書かれないまま、説明のない承認の設定として残っていた ([#1955](https://github.com/mokume-metal/mokume/issues/1955))。調べた結果、**`true` のまま残す**。決定 4 の中身 (承認数 0・重要パスだけ `required_reviewers` で 1 承認) は動かさず、足すのは意味・経緯・根拠の記録である。

**GitHub がこの鍵で要求するもの。** [Available rules for rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets) の「Require an additional approval for unattributed Copilot pull requests」の項は、次の趣旨である (2026-10-04 に読んだ)。

- Copilot が、人の代理ではなく自身の identity で PR を開いたとき、設定した承認数より 1 つ多い承認を、書き込み権限を持つ人に求める
- 承認数 0 のルールセットでは効果が無い。PR を承認の関門でなく変更の記録として使うリポジトリは影響を受けない
- public preview で、新規・既存のルールセットとも既定で有効

**ドキュメントは API の鍵の名前を挙げていない。** この項目と `require_extra_approval_for_unattributed_changes` の対応は、名前と挙動からの読みである (鍵の名は Copilot に限らず「unattributed changes」と言う — 下の未確認点 2)。

**定義に入った経緯。** この鍵は [#100](https://github.com/mokume-metal/mokume/pull/100) (c658bbec) の初期定義から入っている。#100 は定義を rulesets API の GET の応答から `id` などを落とした正規形で作った ([ADR-0006](0006-github-settings-as-code.md)) ので、GitHub が既定で埋めて返した値の写しと読める。意図して選んだ値ではなく、選んだ理由を書いた記述も無かった。実設定 (`gh api repos/mokume-metal/mokume/rulesets/21453049`) も `true` で、定義と一致している。

**このリポジトリの流れで発火しない根拠。**

- PR を開くのは `mokume-agent` (決定 1・自前の GitHub App) で、Copilot ではない。Copilot が author の PR は 0 件である (`gh pr list --author app/copilot-swe-agent --state all`)
- 承認数は 0 で、上の「効果が無い」に当たる (ただし未確認点 1)
- 2026-10-03 に merge された `mokume-agent` の PR に、承認が 1 つ増えた形跡は無い。commit の author はどれも `shinyaoguri` で PR の author と食い違う (決定 1) が、止まっていない

| PR | `required_reviewers` の対象のパス | merge 時の Approve |
| --- | --- | --- |
| [#2008](https://github.com/mokume-metal/mokume/pull/2008) / [#1997](https://github.com/mokume-metal/mokume/pull/1997) / [#1995](https://github.com/mokume-metal/mokume/pull/1995) | 触れない | 0 |
| [#2005](https://github.com/mokume-metal/mokume/pull/2005) / [#1953](https://github.com/mokume-metal/mokume/pull/1953) | 触れる (`.github/**`) | 1 (`shinyaoguri`) |

- `rulesets/rule-suites` (ref=main・過去 1 か月) に、`fail` も `bypass` も 0 件である

**何を守っているか。** ドキュメントの読みでは、誰の依頼でもない Copilot の PR に承認を 1 つ余分に課す柵である。このリポジトリは Copilot をその形で使っておらず、**いま実際に守っているものは無い**。

**`true` のまま残す理由。**

- **外しても得るものが無い。** いまの流れで発火していない柵で、GitHub の既定のままなので、保つために足すものも無い
- **外すのは、人に帰属しない Copilot の PR に対する柵を自分で選んで捨てることになる。** 検査の保証範囲を新たに選ぶ判断なので、人が先に決める側にある ([ADR-0036](0036-unattended-issue-processing.md) 決定 8)。残すのは現状維持で、その判断を要しない
- **発火したとしても、柵として働く側に倒れる。** 未確認点 1 が当たると、Copilot が人に帰属しない形で重要パスに触れる PR は、書き込み権限を持つ人が 1 人しかいないので誰も通せない。それは「その経路で、エージェントの制約 (重要パス) を動かす PR を入れない」ことと同じで、文脈 1 の目的 (エージェントが自分の制約を書き換えて自分で通す経路を塞ぐ) に沿う。ただし [ADR-0007](0007-approvability-invariant.md) は「承認できる人が author 以外に存在すること」を前提にしており、必要な承認の数が承認者の数を超える形は想定していない。Copilot をその形で使うなら、この前提と合わせて先に判断する

**未確認の点。** どれも実測していない。

1. **`required_reviewers` だけが承認を課しているとき、+1 が掛かるか。** ルールセット全体の承認数 (`required_approving_review_count`) は 0 で、重要パスにだけ `required_reviewers` が `minimum_approvals: 1` を課している。ドキュメントの「承認数 0 では効果が無い」が前者だけを見るのか、`required_reviewers` の承認数も数えるのかは書かれていない。後者なら、重要パスに触れる PR は承認数が 0 でなくなり、人に帰属しない Copilot の PR には 2 承認が要る。書き込み権限を持つのは `shinyaoguri` 1 人 (`maintainers` チームも同じ) なので満たせない
2. **Copilot 以外の App への効き。** 鍵の名は「unattributed changes」で、Copilot 以外の App が開いた PR も、この鍵のために承認待ちで止まったという報告が他のリポジトリにある ([cbusillo/codex-skills#791](https://github.com/cbusillo/codex-skills/issues/791)・[rjmurillo/ai-agents#6144](https://github.com/rjmurillo/ai-agents/issues/6144))。原因の読み (commit・push の identity と App の食い違い) は報告者の推定で、確かめていない。このリポジトリでは上の表のとおり、同じ現象は見えていない
3. **鍵を定義から消したとき、GitHub が `true` を埋め直すか。** ドキュメントの「既定で有効」からはそう読めるが、試していない。埋め直すなら `scripts/check-rulesets.sh` の照合が差分を出す
4. **`gh agent-task create` は「人に帰属しない」に当たるか。** Copilot が PR を作る口として `scripts/pr-identity-guard.sh` が挙げる形で、人が頼む操作なので当たらないと読んでいる

**止めたくなったら、鍵を消さずに `false` を書く** (未確認点 3 のため、消しても既定で戻りうる)。重要パスの変更なので、App identity の PR・承認 1・merge 後の `scripts/apply-rulesets.sh --apply` で入れる ([ADR-0006](0006-github-settings-as-code.md))。外すかどうかは、未確認点 1・2 が実際に当たったとき (この鍵のために承認待ちで止まる PR が出たとき) に、その実測を添えて決める。

### 5. 承認を CI から追い出す (2026-08-28 改訂)

承認待ちは required check の赤ではなく、**PR の状態** (`mergeStateStatus` が `BLOCKED`) で表現される。これは failing check ではないため、`ci-gate` の赤は本物の故障だけを意味するようになる (弱点 3 の解消)。

`review-gate` は重要パス判定とラベル fallback を失い、mokume 固有の三点だけを見る短いスクリプトに縮む。

- PR が Issue に紐づいているか (`Closes #N`、例外は `no-issue` ラベル)
- 対象 Issue に `verify:` ラベルがあるか (完了条件が固まっているか)
- 対象 Issue が `verify: human` なら、Approve レビューがあるか

三点目を残すのは、**`verify: human` をパス照合で表現できない**ためである。ルールセットの `required_reviewers` が判定できるのは変更パスであって、Issue の性質ではない (決定 4 の改訂まで代わりに置いていた CODEOWNERS も同じ制約を受けていた)。ここを外すと「完了条件を機械で判定できないと宣言した変更」が誰にも見られずマージされうる。

**当初の決定**はここに代償を置いていた — 「この分類の PR だけは承認待ちの間 `ci-gate` が赤いままになる」。**この代償は払わなくてよかった**ので撤回する。

**実測 ([#259](https://github.com/mokume-metal/mokume/issues/259))** — 承認待ちを `failure` で表すことは、想定していた「監視の誤検出」([#111](https://github.com/mokume-metal/mokume/issues/111)・[#110](https://github.com/mokume-metal/mokume/pull/110) で発生) だけでなく、**承認しても PR が自動で進まない**という別の害を生んでいた ([#256](https://github.com/mokume-metal/mokume/issues/256))。同じコミットに残る古い `failure` の check run は、同名の新しい `success` があっても必須チェックの判定を固定する — 2 本目の run の完了から 5 分 35 秒、何もせず `BLOCKED` のままで、`gh run rerun --failed` の 19 秒後に `CLEAN` になった。**承認のたびに人手が要り、見ていない時間帯に承認されると PR は静かに止まったまま残る。**

**承認待ちは `human-approval` という 2 本目の必須チェックで表す。** GitHub の必須ステータスチェックは `success` / `skipped` / `neutral` を通過として扱い、`pending` / `action_required` / `cancelled` / `failure` / `stale` / `timed_out` でブロックする。この中で「ブロックするが failure ではない」を満たすのは `action_required` と `pending` の 2 つである。

| 必須チェック | 表すもの | 承認待ちのとき |
| --- | --- | --- |
| `ci-gate` | 検査が壊れていないか | **緑のまま** |
| `human-approval` | 人の操作を待っているか | `pending` |

`review-gate` は承認待ちを**終了コード 20** で返し (差し戻しの 1 と区別する)、ci.yml の `approval-signal` ジョブがそれを `human-approval` へ翻訳する。Actions の job の結論は終了コード由来に限られて待ちを表せないため、報告は API から行う。

#### 改訂 (2026-08-28) — check run ではなく commit status で報告する

**当初は Checks API を使い、`action_required` で待ちを表していた。これを commit status の `pending` に替える。**

check run で表そうとすると、**作り足しても上書きしても詰む**ことが分かった ([#282](https://github.com/mokume-metal/mokume/issues/282))。

- **作り足す**と、同じ SHA に同名の check run が 2 つ並び、古いほうが判定を固定する ([#259](https://github.com/mokume-metal/mokume/issues/259))
- **上書きする**と、check run は最初に作った run の check suite に居続ける。承認は必ず後の run で届くので、**最新の suite にはこの名前が現れない**。マージボックスは `Expected — Waiting for status to be reported` のまま止まる

後者を [#279](https://github.com/mokume-metal/mokume/pull/279) で踏んだ。Checks API は `success` と答えるのに画面は待ち続け、**承認を 3 度押しても解けなかった**。API と画面で言うことが食い違うので、原因に辿り着くまでに時間がかかる。

commit status には check suite が無く、**同じ context の最新が常に勝つ**。上書きがそのまま最新の判定になるので、この食い違いが起きない。`action_required` は使えないが、待ちは `pending` で表せる — これも failure ではないので #111 の要求 (承認待ちを故障として数えない) はそのまま満たせる。**「保留中」のほうが実態にも合う。**

*失われるもの*: check run が持てる `output.title` / `summary` の詳しい説明。commit status は 1 行の `description` しか持てないので、理由は短くなる。詰みを避ける値のほうが重い。

**新しい機構は足していない** ([ADR-0008](0008-mechanism-needs-demonstrated-harm.md) 決定 5 の第 1 段 + 第 2 段) — 既存の `review-gate` が出す信号の形を変え、GitHub が native に持つ結論を使っただけである。

**自作の仕組みは GitHub にできないことだけをやる。**

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
