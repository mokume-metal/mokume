# ADR-0003: エージェントの identity 分離と承認機構

## 状態

採用 (2026-08-26)

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

エージェントが push し PR を開く主体を、メンテナのアカウントから `mokume-metal` org 所有の GitHub App に分離する。App の権限は次に限り、**ルールセットの bypass list には加えない**。

| 権限 | 設定 | 理由 |
| --- | --- | --- |
| Contents | Read and write | ブランチへの push |
| Pull requests | Read and write | PR の作成・更新 |
| Issues | Read and write | コメント・ラベル |
| Workflows | Read and write | GitHub は `.github/workflows/` 配下を変更する push を、`workflows` 権限の無いトークンに対して**サーバ側で拒否する** |
| Metadata | Read-only | 必須 |
| **Administration** | **No access** | 与えるとエージェントが自分を縛るルールセットを外せてしまい、本 ADR の目的が崩れる |

`Administration` を持たない結果として、ルールセットの変更はメンテナ側の作業になる。一度きりの設定変更なので運用上の負担は小さい。

**bypass を与えることになった場合は、種類を選ぶ。** ルールセットの bypass には二種類あり、exemption 型は enforcement を**黙って**飛ばす (監査記録が残らない)。将来どうしても必要になったら、痕跡が PR と audit log に残る "for pull requests only" 型を選ぶ。便利さのために監査記録を捨てない。

**コミットの author と署名はメンテナのまま**とする。分離するのは push と PR 作成の主体であって、著作の主体ではない。署名の検証は鍵に対して行われるため、`signed-commits` ルールセットとも両立する (App のトークンで push したメンテナ署名のコミットが `verified: true` になることを実測した)。

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

重要パスの承認要求は **CODEOWNERS** で表現する。CODEOWNERS にはユーザーとチームしか書けないため、App の承認では code owner 要件を満たせない。制約が二重にかかる。

### 4. `required_approving_review_count` は 0 のままにする

ルールセットの承認数を 1 に上げると、機械検査だけで完了を判定できる PR (`verify: machine`) まで人間の操作を待つことになり、ADR-0002 決定 1 の「機械クラスは無人で通す」が壊れる。

承認数は 0 のままにし、`require_code_owner_review` を有効にする。こうすると **CODEOWNERS 対象パスに触れる PR だけ**が承認を要求される。ADR-0002 決定 3 の「重要パスは常に human 扱い」が、自前ロジックから GitHub 標準へそのまま移る。あわせて `dismiss_stale_reviews_on_push` を有効にし、弱点 2 を塞ぐ。

### 5. 承認を CI から追い出す

承認待ちは required check の赤ではなく、GitHub の **Review required** という PR の状態で表現される。これは failing check ではないため、`ci-gate` の赤は本物の故障だけを意味するようになる (弱点 3 の解消)。

`review-gate` は重要パス判定とラベル fallback を失い、mokume 固有の三点だけを見る短いスクリプトに縮む。

- PR が Issue に紐づいているか (`Closes #N`、例外は `no-issue` ラベル)
- 対象 Issue に `verify:` ラベルがあるか (完了条件が固まっているか)
- 対象 Issue が `verify: human` なら、Approve レビューがあるか

三点目を残すのは、**`verify: human` を CODEOWNERS で表現できない**ためである。CODEOWNERS が判定できるのは変更パスであって、Issue の性質ではない。ここを外すと「完了条件を機械で判定できないと宣言した変更」が誰にも見られずマージされうる。代償として、この分類の PR だけは承認待ちの間 `ci-gate` が赤いままになる。重要パスの PR は native の Review required で止まるようになったので、赤が出る頻度自体は大きく下がる。

**自作の仕組みは GitHub にできないことだけをやる。**

### 6. 分離しても残る制約を明記する

これは暗号的な分離ではない。同じマシンにメンテナの認証が残っている限り、エージェントが認証を切り替えて承認する経路は理屈上残る。得られるのは次の二つであり、それ以上を主張しない。

- **意図しない自己承認が構造的に消える** (設定の既定として不可能になる)
- **監査可能性** — 誰が開き誰が承認したかがタイムラインに残る

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
- 移行の前に確証が取れなかった四点のうち三点は実測で解決した — installation token での `gh` の動作 (JWT は `Authorization: Bearer` で送る必要がある) / App が push したコミットの署名 (メンテナの鍵の署名は `verified` のまま) / squash コミットの author (App になるが co-author は自動で付く)。残る「承認数 0 と code owner review の組み合わせ」は CODEOWNERS の適用時に測る
