# AGENTS.md

このリポジトリで作業する AI エージェントと人間に等しく効く規約。**規約の正典はこの文書に一本化している** — 守ることの大半は読み手によらず同じで、分けると写しが生まれるためである ([ADR-0001](docs/decisions/0001-founding-principles.md) 原則 9)。人間の貢献者の入口は [CONTRIBUTING.md](CONTRIBUTING.md) だが、あちらは案内だけで規約の写しは持たない。

## プロジェクト

mokume は macOS / Apple Silicon 専用のクリエイティブコーディング環境 (Swift + Metal)。宣言的・フレームベースのスケッチ API を提供する。

**この文書はフェーズも進捗も書かない。** どこまで出来ているかはリポジトリ自身 (`Sources/`) と Issue / Roadmap (「進捗の公開ロードマップ」節) が正典で、ここに写すと**触る理由が無いまま古くなる** — 実際に「現在は設計フェーズ・ライブラリのコードはまだ無い」が、実装が始まった後の 2 度の改訂を素通りした ([#189](https://github.com/mokume-metal/mokume/issues/189))。[ADR-0001](docs/decisions/0001-founding-principles.md) 原則 9 の「同じ内容の二重管理を作らない」は、規約文書とプロジェクト状態の間にも効く。

## 正典の在処

- 設計判断: `docs/decisions/` の ADR (状態 / 文脈 / 決定 / 影響 の 4 節・自己完結で書く)。**帰属は ADR 自身の先頭に SPDX ヘッダ (HTML コメント) を置いて宣言し、`REUSE.toml` には足さない** — 共有ファイルに帰属を集めると、中身の無関係な ADR 同士が必ず conflict する ([#149](https://github.com/mokume-metal/mokume/issues/149))

  ```markdown
  <!--
  SPDX-FileCopyrightText: 2026 mokume-metal
  SPDX-License-Identifier: MIT
  -->
  ```

- プロセスの外とやりとりする JSON の形式: `Schemas/` の JSON Schema。**実装は従う側**で、代表例との照合を `make ci-check` が見る ([ADR-0018](docs/decisions/0018-observation-and-control-surface.md))
- 作業の経過・発見・残タスク: GitHub Issues / PR (ローカルファイルやセッション記憶に残さない)
- プロジェクトの土台: [ADR-0001 設計原則](docs/decisions/0001-founding-principles.md)

## 進め方

1. 変更は **Issue 起票から始める**。起票は雑でよい (書式不要・分類は機械がタイトルから下書きする)。複数工程は親 Issue + sub-issue で構成し、本文チェックリストは使わない
2. **着手できるのは `verify:` ラベルが付いた Issue だけ** — ラベルが無ければ未トリアージなので着手しない。まず議論して「どうなれば解消か」を Issue 本文に固め、`verify: machine` / `verify: human` を付ける ([ADR-0002](docs/decisions/0002-issue-lifecycle-and-merge-approval.md))
3. **着手時に、合意済みの完了条件を引用したプラン (変更点・確認方法) を対象 Issue にコメントで残す**。実装の過程でプランが変わったら差分を残す — **PR を出した後なら PR 側へ書く** (置き場の決め方は「コメント」節)。記憶がリセットされた次のセッションが、GitHub を読むだけで再開できる状態を保つため。Claude Code のセッションではフック (`scripts/plan-record.sh`) がプランを投稿用に整え (絶対パス・ホームは畳み、秘密らしき文字列があれば止める) 投稿コマンドを提示し、**未投稿のままセッションを終えようとすると差し戻す**。投稿はエージェントが `scripts/comment.sh` で行う — 公開操作の前に人間の目が一度入る形にしている
4. `main` から `<type>/<短い説明>` ブランチを切る
5. PR を出す。本文は 目的 / 変更点 / 確認方法、Issue を閉じる `Closes #N` は PR 本文に書く (squash merge ではコミット側の記述は GitHub に届かない)。Issue を閉じない例外 PR は `no-issue` ラベルを付ける (PR に付けるラベルはこれだけ — 「PR のラベル」節)
6. マージは squash のみ。**PR タイトルがそのままマージコミットになる**ので Conventional Commits で書く

## Issue の分類

「この Issue は**何の仕事か**」は GitHub の **Issue Type** で表す ([ADR-0004](docs/decisions/0004-issue-classification-by-issue-type.md))。1 Issue 1 型で、org 単位の語彙:

| Issue Type | 意味 |
| --- | --- |
| `Bug` | 期待と違う挙動 |
| `Feature` | 新機能・拡張 |
| `Task` | 保守・整備・CI・リファクタ |
| `Design` | 設計判断・ADR |
| `Docs` | ドキュメント |

迷ったら **`Bug` > `Design` > `Docs` > `Task`** の順で、より具体的なほうを取る (`Task` は何にでも当てはまるので最後)。**ラベルは型と直交する属性だけを表す** — `status: *` (状態)・`verify: *` (完了条件の性質)。`no-issue` だけは Issue ではなく PR に付く (「PR のラベル」節)。検索は `type:"Design"` (引用符を付ける — 旧来の `type:issue` / `type:pr` と綴りが衝突するため)。

型の**作成・改名はメンテナの操作**で、エージェントの token では通らない (`admin:org` が要る)。既存の型を Issue に付けるのはエージェントでもできる。

移行は完了している。自動付与 (テンプレート・triage・`sub-issue.sh`) は Issue Type を付け、closed を含む既存 Issue にも型が遡及適用され、旧 `type: *` ラベル 6 種は削除された (#79)。

## PR のラベル

**PR には分類ラベルを付けない** ([ADR-0005](docs/decisions/0005-pr-labels-as-machine-input.md))。PR が持つ属性はすべて既に正典を持つ — 型は PR タイトル (Conventional Commits・`pr-title` ジョブが検査)、対象 Issue は本文の `Closes #N`、完了条件の性質は対象 Issue の `verify: *`、重要パスは CODEOWNERS、進行状態は Draft / Review / merge queue。ラベルで重ねると写しが増えるだけになる (Issue Type は Issue 専用で、そもそも PR には付かない)。

PR に付くのは **CI の判定を変えるラベルだけ**で、現状は 3 種 — `no-issue` (Issue を閉じない例外 PR の印・`scripts/review-gate.sh` が読む)、`release:now` (merge したその場で版を出す印・`.github/workflows/release.yml` が読む)、`no-visual-change` (描画のパスに触れるが絵は変わらない印・`scripts/check-drawing-evidence.sh` が読む)。新しい PR ラベルを足すときは、それを読むスクリプトを同時に示す — 読み手のいないラベルは足さない。付け忘れは `review-gate` が赤で差し戻すので、手付けのままでよい。人が介在しない bot の PR (dependabot) だけは `.github/dependabot.yml` の `labels` で自動付与する。

## マージの判断基準

PR 本文 (目的 / 変更点 / 確認方法) が揃っていて `ci-gate` が green なら、指示を待たず `gh pr merge --auto` で **merge queue に投入してよい**。queue が「合流後の姿」で `ci-gate` を再検証してから main に入れるため、人手で CI を見張って merge する運用はしない。main への直接 push・force push はルールセットが禁止している。マージ後は main に戻って pull する。

**承認が要る PR でも、先に `gh pr merge --auto` を有効化しておく。** auto-merge はゲートを飛び越えない — 承認が要る PR では予約として振る舞い、承認された瞬間に queue へ入る。こうするとメンテナの操作が **Approve 1 回で完結**し、マージのために戻ってくる必要がなくなる。

**`BEHIND` でも "Update branch" は押さない。** 必須チェックは `strict` を切ってあるので追随しなくても merge でき、その上 queue が合流後の姿で `ci-gate` を再検証する — 追随は **queue がこれからやることの前借り**にしかならない。得るものが無いのに **auto-merge だけが外れて PR が止まる** ([#110](https://github.com/mokume-metal/mokume/pull/110))。文字の衝突は GitHub が `DIRTY` で止め、意味的な衝突は合流後の main の CI が拾うので、追随しないことで壊れる経路は塞がっている。

**承認と auto-merge は別々に外れる。** どちらが外れるかは出来事で違い、しかも **"Update branch" だけはタイムラインに何も残さない** — だから画面上は「承認済み・全チェック緑」に見えたまま止まり、原因に辿り着けない ([#114](https://github.com/mokume-metal/mokume/issues/114) で実測):

| 出来事 | 承認 | auto-merge | タイムラインに残るもの |
| --- | --- | --- | --- |
| 実装コミットを push | **外れる** (`dismiss_stale_reviews_on_push`) | 残る (承認待ちに戻る) | `ReviewDismissedEvent` |
| base ブランチが変わる | **外れる** | 残る | `ReviewDismissedEvent` (`The base branch was changed.`) |
| "Update branch" で main を取り込む | 残る | **外れる** | **何も残らない** |
| merge queue へ入る | — | `false` に見える (queue へ移った正常な表示) | — |

実測の出所は上から [#279](https://github.com/mokume-metal/mokume/pull/279)・[#281](https://github.com/mokume-metal/mokume/pull/281)・[#110](https://github.com/mokume-metal/mokume/pull/110)・[#94](https://github.com/mokume-metal/mokume/pull/94)。

**下 2 行はどちらも `autoMerge: false` に見える**ので、`mergeStateStatus` と組で読んで見分ける (承認待ちなら `BLOCKED`):

```bash
gh pr view <番号> --json autoMergeRequest,mergeStateStatus,latestReviews
```

queue に入っているかはこの経路では見えない (`gh pr view --json` に欄が無い)。要るときだけ GraphQL を引く:

```bash
gh api graphql -f query='{repository(owner:"mokume-metal",name:"mokume"){pullRequest(number:110){isInMergeQueue mergeStateStatus autoMergeRequest{enabledAt}}}}'
```

外れていたら `gh pr merge <番号> --auto --squash` を打ち直すだけでよい。

**承認が要るかは 2 つの機構が決める** ([ADR-0002](docs/decisions/0002-issue-lifecycle-and-merge-approval.md) / [ADR-0003](docs/decisions/0003-agent-identity-separation.md)):

- **重要パス** (`docs/decisions/`・`.github/`・`.claude/`) を触る PR は、承認が無いとマージできない (`ci-gate` は緑のまま)。**要求と必須化は別の機構が担う** — 誰に要求するかは `.github/CODEOWNERS`、マージを止めるのは `.github/rulesets/main-protection.json` の `required_reviewers` (同じ 3 パスに `minimum_approvals: 1`) である。当初は CODEOWNERS だけで必須化できるつもりでいたが、`required_approving_review_count: 0` は「0 件の承認で足りる」と読まれて code owner の要求ごと非ブロックになっていた ([#211](https://github.com/mokume-metal/mokume/issues/211))

  **承認が要ることは `reviewDecision` には現れない。** `required_reviewers` ルールの要求はこの API に映らず、承認の前も後も空で返る ([#249](https://github.com/mokume-metal/mokume/issues/249) で実測)。機械で読むなら **`mergeStateStatus`** を見る — 全 check が緑でも `BLOCKED` なら承認待ちで、承認されると `CLEAN` に変わる:

  ```bash
  gh pr view <番号> --json mergeStateStatus,statusCheckRollup
  ```

- **`verify: human`** の Issue に紐づく PR は、`review-gate` が Approve レビューを要求する (この分類はパスで表現できないので CODEOWNERS にも `required_reviewers` にも書けない)

  承認待ちは **`human-approval` という 2 本目の必須チェック**が `pending` (保留中) で表す。**`ci-gate` は緑のまま**なので、赤は本物の故障だけを意味する — 承認待ちを `failure` で表していた頃は監視が故障と誤検出し ([#111](https://github.com/mokume-metal/mokume/issues/111))、承認しても古い失敗 run が判定を固定して自動では進まなかった ([#256](https://github.com/mokume-metal/mokume/issues/256))。**check run ではなく commit status で報告する** — check run は最初に作った run の check suite に居続けるので、後から届く承認が最新の suite に現れず、承認しても永久に解けなくなる ([#282](https://github.com/mokume-metal/mokume/issues/282))

どちらに当たる PR も **App identity で作る** — メンテナ自身が作っても自己承認になって詰むため、author を承認者集合の外に置くのが不変条件である ([ADR-0007](docs/decisions/0007-approvability-invariant.md))。

承認は **native の Approve レビュー**のみ。暫定だった `review: approved` ラベルは廃止した — エージェント自身も付けられるため、ゲートとして成立していなかった。

**auto-merge が外れていない**のに止まって見えるときは、**同じコミットに残っている古い失敗した check run** が判定を固定していることがある。最新の run が全て緑でも解けない — [#259](https://github.com/mokume-metal/mokume/issues/259) では 2 本目の run の完了から 5 分 35 秒 `BLOCKED` のままだった。失敗した run を再実行して上書きする (`--failed` は check run を作り足さず既存を上書きするので、これで解ける):

```bash
gh run rerun <run-id> --failed
```

## 版の出方

版はタグと [GitHub Release](https://github.com/mokume-metal/mokume/releases) だけで表す。**リリースはリポジトリのファイルを 1 つも変えない** — 変更履歴をファイルへまとめると Releases との二重管理になり ([ADR-0001](docs/decisions/0001-founding-principles.md) 原則 9)、それを `main` へ入れるための PR と、必須チェックを走らせる迂回が要るためである (判断の詳細は `scripts/release.py` の冒頭)。

- **週に 1 度** (月曜 09:00 JST) 自動で出る。急ぐときは PR に `release:now` を付けて merge する (`.github/workflows/release.yml`)
- **上げ幅は履歴が決める**。1.0 未満では破壊的変更も minor で出す — 0.x は形が動くことを織り込んだ区間で、そこで major を上げ始めると 1.0 の意味が薄れる

  | 履歴にあるもの | 1.0 未満 | 1.0 以降 |
  | --- | --- | --- |
  | `!` 付き / `BREAKING CHANGE` | minor | major |
  | `feat` | minor | minor |
  | それ以外 | patch | patch |

- **ノートは `changelog.d/` の断片から組む**。前回のタグ以降に追加されたものだけが載り、**断片は消さない** (どれが今回ぶんかは履歴が知っている)
- **断片が 1 つも増えていなければリリースは出ない**。中身の無い版を出さないため

## ブランチ保護の正本

保護の正本は **`.github/rulesets/*.json`** で、GitHub 側の状態はその写し ([ADR-0006](docs/decisions/0006-github-settings-as-code.md))。管理画面で直接いじらない — 変更は定義ファイルの PR から始める。

| したいこと | コマンド |
| --- | --- |
| 定義の形を見る (token 不要。`make ci-check` に含まれる) | `bash scripts/check-rulesets.sh --shape` |
| 実設定と照合する (認証が要る) | `bash scripts/check-rulesets.sh` |
| 適用の差分を見る | `bash scripts/apply-rulesets.sh` |
| 実際に適用する (**メンテナのみ**) | `bash scripts/apply-rulesets.sh --apply` |

**適用はエージェントの token では通らない。** ADR-0003 決定 1 によりエージェントの App は `Administration` 権限を持たない (与えると自分を縛るルールセットを外せてしまう)。定義ファイルの PR までがエージェントの仕事で、merge 後の `--apply` はメンテナが打つ。

実設定との照合には認証が要る — public repo のルールセットは匿名でも読めるが、**`bypass_actors` だけは認証が無いと応答に現れない**。読めないまま「一致」とは言わず赤にする (一番危ない項目を見ていない緑を作らないため)。

### ドリフト検査

管理画面から直接 1 項目変えられても気付けるよう、**日次で定義と実設定を照合する** (`.github/workflows/ruleset-drift.yml`)。ずれていたら Issue が自動で立ち、run も赤くなる。手で回すときは Actions から `Ruleset drift` を `workflow_dispatch` する。

**この検査は `bypass_actors` を見ていない。** `bypass_actors` は ruleset への **write access** がある認証にしか返らず ([#99](https://github.com/mokume-metal/mokume/issues/99) で実測)、`Administration: Read` の App でも匿名でも見えない。CI にその鍵を置くことは「ルールセットを外せる鍵」を常設することなので、置かない。何を見ていないかは照合の出力自身が名乗る。

したがって照合には 2 つの入口がある:

| 打ち方 | 認証 | `bypass_actors` |
| --- | --- | --- |
| `bash scripts/check-rulesets.sh` (手元・既定) | メンテナの `gh` | **見る**。読めなければ赤 |
| `bash scripts/check-rulesets.sh --without-bypass-actors` (CI) | `GITHUB_TOKEN` | 見ない。見ていないことを出力で名乗る |

`--without-bypass-actors` は「**読めなかったときに許す**」であって「常に無視する」ではない。読める認証で付けても、bypass の追加はそのまま赤になる。

**`bypass_actors` を機械で見張る仕組みは、いまは無い。** メンテナが手元で `bash scripts/check-rulesets.sh` を打つときに見る運用で、[ADR-0003](docs/decisions/0003-agent-identity-separation.md) 決定 1 が最も守っている項目だけは人の手に残っている。塞ぐなら `repository_ruleset` webhook を受ける先が要る — 実害が出てから足す ([ADR-0008](docs/decisions/0008-mechanism-needs-demonstrated-harm.md))。

## sub-issue の使い方

- 複数工程の仕事は親 Issue + sub-issue で構成する (本文チェックリスト不使用)。**作成は `scripts/sub-issue.sh <親番号> <タイトル>` で 1 コマンド** (紐づけと親の Issue Type 継承まで行う。子が別の仕事なら `--type <名前>` で上書きする)
- **検証・実験のための使い捨て Issue は、検証対象の Issue の sub-issue にする** (`--test` フラグで雛形ごと作れる)。存在理由がツリーに残る
- 階層は 2〜3 段まで。独立した Issue を無理にツリー化しない (ツリーは関係の表現であって収納棚ではない)
- open の子を残した親の completed close は Parent guard が reopen する。ツリーごと畳む意図なら **not planned** で close する
- 子 Issue の検索は `parent-issue:mokume-metal/mokume#N` 修飾子

## 進捗の公開ロードマップ

開発フェーズの見通しは Org の public Project「[mokume Roadmap](https://github.com/orgs/mokume-metal/projects/1)」(Roadmap レイアウト) で公開する。**Project は Issue の投影**で、状態の正典は従来どおり Issue ([ADR-0002](docs/decisions/0002-issue-lifecycle-and-merge-approval.md))。人の手数は最小に固定する:

- **アイテムの出入りは GitHub 組み込みワークフローに任せる** (Auto-add to project / Auto-add sub-issues to project ほか、7 種すべて有効)。Issue も PR も sub-issue も自動でアイテム化されるので、**手でキュレーションしない** — 板が雑然とする代わりに、載せ忘れが起きない側を取っている
- **日付だけが人の手で入る**。date フィールド **Start / Target の 2 本**を、**フェーズ親 Issue にだけ**付ける。Roadmap の帯は日付を持つアイテムにしか描かれないので、自動で増える子タスク・PR は帯の視覚を汚さない ([#131](https://github.com/mokume-metal/mokume/issues/131) で確認済み)
- **手で足すフィールドはこの 2 本だけ**。Iteration・Milestone・独自の status フィールドは足さない — 束ねと消化率は親 Issue + sub-issue が既に持っており、重ねると所属の二重管理になる ([#124](https://github.com/mokume-metal/mokume/issues/124))
- **Status → Issue の逆流 (Auto-close issue) も有効のままでよい**。Status を Done にすると Issue が閉じる = 板の上の状態は必ず Issue に落ちる。無効化すると「Status は Done なのに Issue は open」という **Project 側にしかない状態**を許すことになり、かえって正典が二重になる
- 自動化の機構をこれ以上足すのは実害が出てから ([ADR-0008](docs/decisions/0008-mechanism-needs-demonstrated-harm.md))。**組み込みワークフローの有効・無効は Project の管理画面から変える** — GraphQL に切り替えの口が無く (`deleteProjectV2Workflow` しかない)、ブランチ保護のような定義ファイル ([ADR-0006](docs/decisions/0006-github-settings-as-code.md)) も持たないので、`.github/` を探しても正本は見つからない

## コメント

### 置き場 — 情報の寿命で決める

Issue と PR のどちらに書くかは、**「この PR が merge された後も読まれるか」**で決める ([ADR-0002](docs/decisions/0002-issue-lifecycle-and-merge-approval.md) 決定 6)。

| 内容 | 置き場 |
| --- | --- |
| 問題の分析・トリアージ・完了条件の議論 | **Issue** |
| 着手時プラン | **Issue** (まだ PR が無いため) |
| 実装判断・プランからの差分・作業中の発見 | **PR** |
| CI の状況・作り直しの経緯・レビュー | **PR** |
| 完了条件そのものが動く話 | **Issue** (完了条件は Issue 本文が正典) |
| 完了報告 | **Issue に 1 通** (対応表まで・詳細は PR へリンク) |
| 恒久的な決定 | **ADR** |

覚えるのは 1 行でよい — **PR ができるまでは Issue、できてからは PR**。例外は表の下 3 行だけ。

**完了報告は「条件 N は PR #M で満たされた」の対応表に留める。** 条件ごとの経緯を Issue に書き下すと Issue が実装ログになる (実際にそうなっていた: [#148](https://github.com/mokume-metal/mokume/issues/148))。かといって本文の完了条件に印を付けるだけで済ませると、本文の編集履歴は実質読めないので close の根拠がタイムラインから消える。

**PR を作ったときに Issue へ「実装 PR は #N」とは書かない。** `Closes #N` から GitHub が双方へ相互リンクを描くので、写しが増えるだけ。

### 署名

同じ Issue / PR には人間も複数のエージェントも書き込む。発言の出どころが後から判別できるよう、**AI エージェントからのコメントは投稿ラッパー経由で投稿する**。署名は実行環境から判定して自動で付くので、自分で書き足さなくてよい:

```bash
bash scripts/comment.sh issue <番号> --body-file <ファイル>
bash scripts/comment.sh pr    <番号> --body "<本文>"
```

投稿前に本文を確かめたいときは `--dry-run` を付ける。名乗りを自動検出できない環境では総称の署名になるので、`MOKUME_AGENT_NAME` (必要なら `MOKUME_AGENT_URL`) で明示する。

**発言を伴う操作は `gh {issue,pr} comment` だけではない。** `gh pr review` の本文オプションと、`gh {issue,pr} {close,reopen}` の `--comment` も同じ扱いで、フックが差し戻す ([#123](https://github.com/mokume-metal/mokume/issues/123) — 未署名のコメントが実際にメンテナ名義で残った)。close / reopen は **2 手に分ける** — 発言をラッパーで投稿してから、状態の変更は発言なしで実行する:

```bash
bash scripts/comment.sh pr <番号> --body "<本文>"
gh pr close <番号>
```

`comment.sh` に close / reopen の機能は足さない。ラッパーの責務を「署名を付けて投稿する」1 つに保つため (状態遷移を持たせると `--reason` `--delete-branch` と `gh` の写しが増えていく)。説明を先に投稿してから閉じる順序は、タイムラインの読み順としてもむしろ自然になる。

**この節が言うのはこのリポジトリ宛てのコメント**で、他のリポジトリの Issue / PR へは素の `gh` で書く (あちらの署名の作法は別に決まっている。フックも `-R` で他リポを指したコメントは素通しする)。同じ理由で `comment.sh` に `-R` も足さない ([#188](https://github.com/mokume-metal/mokume/issues/188))。

**人間が直接 `gh` でコメントする分にはラッパーは不要**。Claude Code のセッションでは `.claude/settings.json` のフックが素の `gh issue comment` / `gh pr comment` を差し戻してラッパーへ誘導する。同等のフック機構を持たないエージェント (現状の Codex CLI など) では機械的には強制できないため、この節が拠りどころになる — ラッパーはどの環境からでも呼べる。

## エージェント環境の設定

`.claude/settings.json` (プロジェクト設定) が頻用コマンドの許可リストと、リポジトリ同梱のフックの配線を持つ。**個人環境のプラグインは宣言しない** ([ADR-0017](docs/decisions/0017-agent-support-locality.md) 決定 2)。設定はあくまで補助で、**作法の正典はこの文書**。

### エージェントの identity

[ADR-0003](docs/decisions/0003-agent-identity-separation.md) により、エージェントは **PR の作成**を **GitHub App の identity** で行う (承認を native の Approve へ戻し、自分の PR を自分で通す経路を塞ぐため)。token は次で発行する:

```bash
GH_TOKEN="$(bash scripts/gh-app-token.sh)" && export GH_TOKEN && gh pr create …
```

**代入から始めて後続コマンドまで `&&` で繋ぐ。** エージェントのシェル呼び出しをまたいで環境変数は持続しないので、発行と使用は必ず同じ行に乗る。このとき `export GH_TOKEN="$(...)"` と書くと**終了コードが `export` のもの (0) に化け**、発行に失敗しても `&&` が切れず、空の token で `gh` がメンテナの認証へフォールバックする — 実際に [#120](https://github.com/mokume-metal/mokume/pull/120) がこれで「誰も承認できない PR」になった ([#122](https://github.com/mokume-metal/mokume/issues/122))。`set -e` は救わない。素の代入なら右辺の終了コードがそのまま出るので `&&` が正しく切れる。危険な形は `scripts/pr-identity-guard.sh` が差し戻す。

**手で揃える設定は 1 つだけ** — `MOKUME_APP_PRIVATE_KEY_CMD` に「App の秘密鍵 (PEM) を標準出力に出すコマンド」を渡し、手元の秘密管理から読ませる。**秘密鍵の中身も、その在処もリポジトリに書かない** (ADR-0003)。token は有効期限 1 時間で、キャッシュしない (切れたら発行し直す)。

**未設定でも「鍵が無い」と即断しない。** 手元の秘密管理には「自動化から読んでよい秘密の一覧」があるのが普通なので、まずその一覧を引いて mokume の App の鍵が載っていないかを見る。参照名が分かれば `MOKUME_APP_PRIVATE_KEY_CMD` は 1 行で組める — **在処そのものを読む必要はない**。一覧にも無ければ PR を作らず、鍵の渡し方を人に尋ねる ([ADR-0007](docs/decisions/0007-approvability-invariant.md) 決定 5)。

App ID とインストール ID は秘密ではない識別子で、**インストール先の org に問い合わせれば引ける**ので、どこかに書き留める必要はない — 未設定なら `scripts/gh-app-token.sh` が自分で引く。引けなかったときは手で引くコマンドを stderr に出すので、それを実行して `MOKUME_APP_ID` / `MOKUME_APP_INSTALLATION_ID` に渡す:

```bash
gh api orgs/<org>/installations --jq '.installations[] | select(.app_slug=="mokume-agent") | {app_id, id}'
```

この API は **org を読める人間の gh 認証** (`read:org`) を要求する。App の installation token では引けないので、自動解決は「まだ App の token を持っていないセッション」でだけ効く (それが必要な場面なので噛み合う)。別の App を使うときは `MOKUME_APP_SLUG` で slug を上書きする。

**承認が要る変更は、誰の手であれ App identity の PR で入れる** ([ADR-0007](docs/decisions/0007-approvability-invariant.md))。メンテナも例外にしない — GitHub は自分の PR を自分で承認できないので、メンテナ名義で作れば**誰も承認できない PR** になる。token を発行できないときは **PR を作らない**。承認が要らない PR (CODEOWNERS 対象外かつ `verify: machine`) は不変条件の対象外だが、**フックは経路を分けない** — 承認の要否は作成前に確定できないため、`gh pr create` は一律に App identity を要求する。

Claude Code のセッションでは `.claude/settings.json` のフック (`scripts/pr-identity-guard.sh`) が素の `gh pr create` を差し戻し、token の発行と**鍵の探し方**を示す。同等のフック機構を持たないエージェント (現状の Codex CLI など) では機械的には強制できないため、経路を問わない検知は `review-gate` が担う — 承認が要る PR の author が唯一の承認者になっていれば CI が赤で差し戻す ([#104](https://github.com/mokume-metal/mokume/issues/104))。

コミットの author と署名は**メンテナのまま**で、分離するのは **PR 作成の主体だけ**。**push の主体は問わない** — remote が SSH のクローンならメンテナの鍵で通り、それで構わない。同じマシンに両方の認証がある以上 push の帰属は選べてしまい、監査信号にならないためである ([ADR-0003](docs/decisions/0003-agent-identity-separation.md) 決定 6)。

**mokume 向けのエージェント支援 (スキル・hooks・設定) はこのリポジトリの `.claude/` で管理する** ([ADR-0017](docs/decisions/0017-agent-support-locality.md)) — 個人環境のプラグインやマシン設定に置かない。このリポジトリで作業する誰の環境でも同じ支援が効くこと、支援機構自体が Issue → PR の通常ループで育てられることが理由。**例外は設けない** — マーケットプレイス経由の汎用プラグインも宣言しない。入れている人にだけ効く支援を前提にすると、規約が環境によって変わるためである (個人が自分の `~/.claude/` に何を入れるかは自由で、そこには踏み込まない)。

同種の機構がリポ側と個人環境の双方にあるときは、**リポ側が担保して個人側を黙らせる**。黙らせる宣言の置き場は `.claude/settings.json` の `env` で、何をなぜ黙らせているかは `scripts/tests/plan_record_test.py` の `SelfContainedTest` が検査ごとのコメントに持つ (前例は `CLAUDE_PLAN_RECORD: 0`)。逆向きは採らない — 個人環境の機構はこのリポジトリの設計を知らないので、正常を異常と判定する。リポ固有スキルの置き場は `.claude/skills/`。何を置くかは [ADR-0008](docs/decisions/0008-mechanism-needs-demonstrated-harm.md) の順序に従う (実害 → Issue → 機構)。

## コミット・PR の規約

- Conventional Commits: `<type>(<scope>): <要約>`。type は feat / fix / docs / refactor / test / chore / ci / perf / build。type と scope は英語、要約は日本語でよい
- 1 コミット 1 関心・1 PR 1 関心
- 検証は `make ci-check` に集約する (CI はそれを呼ぶだけ)。push 前に通す — **これは作法ではなく merge の条件**である。絵を作る検査は CI では 1 本も走らない ([ADR-0019](docs/decisions/0019-drawing-verification.md) 決定 7) ので、全部が通ったときだけ `make ci-check` が `local-render` を commit status に打ち、描画に触れる PR はそれが無いと merge できない。報告されないときは理由が出るので、それを読んで直す (よくあるのは作業ツリーが汚れているまま打った場合)
- ユーザー影響のある変更は `changelog.d/` に断片を 1 ファイル置く (CHANGELOG を直接編集しない)

## してはならないこと

- 生成物・バイナリ (画像・動画・モデル) をコミットしない。視覚的な証跡は外部ホスティングへ上げ URL で参照する
- 帰属 (著作権・ライセンス) の不明なファイルを持ち込まない。第三者素材は正確な帰属の宣言と同時にしか入れられない
- 想定だけの API を先回りで作らない。機能は実際の作品制作で踏まれた必要から正当化する (ADR-0001 原則 4)。**作品はこのリポジトリの外で作る** ([ADR-0022](docs/decisions/0022-production-track.md))。依存は一方向で、**このリポジトリは作品を参照しない** (`Package.swift` にも CI にも入らない)。実需が入る口は **`Feature` 型の Issue 1 本だけ** — どの作品で何を作ろうとして何ができなかったかを本文に書き、作品の側へリンクを 1 本張る (ラベルは足さない)。フェーズはその Issue が 1 本以上立ってから着手する。認めるのは「書けなかった / 書けたが歪んだ」と「既にある規範が要求する一貫性の欠け」で、**`Sketches/` で踏んだものは実需に数えない** (面から逆算して書かれるので循環する)。**作品の側の運用はここでもあちらでも規約にしない** — 書けばドリフトする
- **同じ基準を機構にも当てる** — 新しいゲート・検査・hook・ラベル・ワークフローを足す PR は、それが塞ぐ実害を Issue 番号で示す ([ADR-0008](docs/decisions/0008-mechanism-needs-demonstrated-harm.md))。「あると良さそう」「業界の標準だから」では足さない。思いついたら Issue に起票して待たせる (順序は 実害 → Issue → 機構)。**消すほうには実害を要求しない** — 役目を終えた機構は待たずに消してよい
- **足すと決めた後も、まず既存で済まないかを見る** — 既存の機構の責務を広げる / GitHub や既存ツールが native に持つもので済ませる / 置き換える、の順に検討し、**選んだ段を PR 本文に書く** ([ADR-0008](docs/decisions/0008-mechanism-needs-demonstrated-harm.md) 決定 5)。重ねるときは**なぜ重複が必要か**を明記する — 理由を書けない重複は、どちらかが要らない

## 描画に影響する変更

描画結果・動きが変わる PR には before/after の視覚的証跡を載せる (動きは動きの分かる形式で)。証跡はリポジトリにコミットせず、外部ホスティングの URL で参照する。

CI は描画を走らせられない ([#180](https://github.com/mokume-metal/mokume/issues/180)) ので、**緑は「描けている」を意味しない**。貼られた絵が描画の唯一の検証記録になり、squash merge でブランチが消えた後には足せない。

**これは作法ではなく機械の要求である** ([#306](https://github.com/mokume-metal/mokume/issues/306))。`scripts/drawing-paths.txt` に載る場所を触った PR の本文に絵が 1 つも無ければ、`drawing-evidence` が赤で差し戻す (`make ci-check` と CI のジョブの両方から走る。GPU は要らない — 変更ファイルの一覧と本文の文字列しか見ないので、`local-render` の待ち (「マージの判断基準」節) とは独立に効く)。**見るのは絵が用意されていることだけで、絵が正しいかは見ない** — 正しさの担い手は人間と AI の目である ([ADR-0019](docs/decisions/0019-drawing-verification.md) 決定 1)。

絵を出しようがない変更 (描画のパスに居るが絵は変わらないリファクタ・コメントの修正) は **`no-visual-change` ラベル**で外す。本文の編集でもラベルの付け外しでも CI は自動で再評価する。

**壊れている絵は起票の時点でしか撮れない。** 見た目・動きの事象を Issue に立てるときも、同じように証跡を添える。

**上げ先は問わない。** Issue / PR の入力欄へ画像や動画をそのまま落とせば GitHub が保管して URL を返すので、外部サービスのアカウントを持っていなくても証跡は出せる。**人間の貢献者にはこれが最短で、何も用意しなくてよい。**

エージェントにはその経路が無い (直接アップロードに API が無い) ため、代わりに Gyazo を使う手順を [`.claude/skills/gyazo-evidence/`](.claude/skills/gyazo-evidence/SKILL.md) が持つ。**この節が「何を載せるか」の正典で、スキルは「どう撮るか」だけを持つ** — 規律を二重に書かない。

## 言語

メンテナは日本語で作業する (このリポジトリの規約文書・コミット・PR・Issue は基本日本語)。ただしこれはメンテナの実践であって強制ではない — どの言語での Issue・コントリビューションも歓迎する。コードの識別子は英語。
