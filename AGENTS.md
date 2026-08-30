# AGENTS.md

このリポジトリで作業する AI エージェントと人間に等しく効く規約。規約の正典はこの文書に一本化している — 守ることの大半は読み手によらず同じで、分けると写しが生まれるためである ([ADR-0001](docs/decisions/0001-founding-principles.md) 原則 9)。人間の貢献者の入口は [CONTRIBUTING.md](CONTRIBUTING.md) だが、あちらは案内だけで規約の写しは持たない。

この文書は規律だけを書く。決定の根拠は ADR、経緯と実測は Issue / PR、機構の内部と手順はスクリプトの冒頭コメントと `--help` が持つ。

## プロジェクト

mokume は macOS / Apple Silicon 専用のクリエイティブコーディング環境 (Swift + Metal)。宣言的・フレームベースのスケッチ API を提供する。

この文書はフェーズも進捗も書かない。どこまで出来ているかはリポジトリ自身 (`Sources/`) と Issue / Roadmap が正典で、ここに写すと触る理由が無いまま古くなる ([#189](https://github.com/mokume-metal/mokume/issues/189))。

## 正典の在処

| 対象 | 正典 |
| --- | --- |
| プロジェクトの土台 | [ADR-0001 設計原則](docs/decisions/0001-founding-principles.md) |
| 設計判断 | `docs/decisions/` の ADR (状態 / 文脈 / 決定 / 影響 の 4 節・自己完結で書く) |
| プロセスの外とやりとりする JSON の形式 | `Schemas/` の JSON Schema。実装は従う側で、代表例との照合を `make ci-check` が見る ([ADR-0018](docs/decisions/0018-observation-and-control-surface.md)) |
| 作業の経過・発見・残タスク | GitHub Issues / PR (ローカルファイルやセッション記憶に残さない) |
| この文書がどこまで外のパッケージに効くか | [ADR-0026](docs/decisions/0026-plugin-repository-alignment.md) 決定 1 の 3 段。外のパッケージ側から読みに来た人はまずそこを読む |

ADR の帰属は ADR 自身の先頭に SPDX ヘッダ (HTML コメント) を置いて宣言し、`REUSE.toml` には足さない — 共有ファイルに帰属を集めると、無関係な ADR 同士が必ず conflict する ([#149](https://github.com/mokume-metal/mokume/issues/149))。

```markdown
<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->
```

### ADR の状態欄

**方針が変わったら、状態欄がそれを名乗る。** 本文で改訂を丁寧に追っていても状態欄が `採用` のままだと、「いま有効な決定はどれか」を本文の最後まで読まないと判定できない ([#545](https://github.com/mokume-metal/mokume/issues/545))。`採用 (日付)` に ` / ` で足す綴りは 3 つ:

| 綴り | 使うとき |
| --- | --- |
| `改訂 (YYYY-MM-DD): <何を>` | 決定の理由は動かず、手段だけ差し替えた |
| `一部置換 (→ ADR-00NN): <どの決定が>` | 決定の一部が別の ADR に取って代わられた |
| `置換済み (→ ADR-00NN)` | 全体が別の ADR に取って代わられた |

**番号を増やすか本文を書き換えるかは、理由が生きているかで決まる。** 理由が動かず手段だけ変わったなら同じ ADR を改訂し、理由そのものが覆ったなら新しい ADR を立てて古い側を `置換` にする。本文側の作法 — 改訂の見出しに日付を入れる・「**当初の決定**は〜だった」と捨てたものを理由ごと残す — は変えない。

改訂の見出しが持つ日付が状態欄に現れているかは `make adrs` が見る。**上書きされた側が `置換` を名乗っているかは見ていない** — 上書きは散文で宣言されるので、構造的な印が無い。ここは書く人とレビューが担う。

## 進め方

1. 変更は Issue 起票から始める。起票は雑でよい (書式不要・分類は機械がタイトルから下書きする)。複数工程は親 Issue + sub-issue で構成し、本文チェックリストは使わない
2. **着手できるのは `verify: triaged` が付いた Issue だけ。** ラベルが無ければ未トリアージなので着手しない — まず議論して「どうなれば解消か」を Issue 本文に固めてから付ける ([ADR-0002](docs/decisions/0002-issue-lifecycle-and-merge-approval.md) 決定 1・[ADR-0031](docs/decisions/0031-triage-as-the-single-gate.md) 決定 1)
3. **着手時に完了条件がまだ妥当かを確かめる。** ラベルは付いた時点の判断しか表さない — 各条件を現行のコードと突き合わせ、「まだ有効」「既に満たされている」「差し替えが要る」のどれかをプランに書く。ずれていれば Issue 本文のほうを先に更新する ([ADR-0031](docs/decisions/0031-triage-as-the-single-gate.md) 決定 4。[#457](https://github.com/mokume-metal/mokume/issues/457) は起票時の 3 条件が着手前に既に満たされていた)
4. その突き合わせを含むプラン (変更点・確認方法) を対象 Issue にコメントで残す。実装の過程で変わったら差分を残す (PR を出した後なら PR 側へ)。記憶がリセットされた次のセッションが、GitHub を読むだけで再開できる状態を保つため
5. `main` から `<type>/<短い説明>` ブランチを切る
6. PR を出す。本文は 目的 / 変更点 / 確認方法。**「確認方法」には閉じる Issue ごとに完了条件と、それを何でどう確かめたかの対応表を置く** (承認の代わりに残す記録 — [ADR-0031](docs/decisions/0031-triage-as-the-single-gate.md) 決定 2。`review-gate` は番号が現れることだけを見る)。Issue を閉じる `Closes #N` は PR 本文に書く (squash merge ではコミット側の記述は GitHub に届かない)。Issue を閉じない例外 PR には `no-issue` ラベルを付ける
7. マージは squash のみ。PR タイトルがそのままマージコミットになるので Conventional Commits で書く

Claude Code のセッションでは `scripts/plan-record.sh` がこれを見る — 完了条件の現況が書かれていないプランは差し戻し、書かれていればコメント投稿用に整えて投稿コマンドを示す。未投稿のままセッションを終えようとするのも差し戻す。投稿はエージェントが `scripts/comment.sh` で行う。

## Issue の分類

「この Issue は何の仕事か」は GitHub の Issue Type で表す ([ADR-0004](docs/decisions/0004-issue-classification-by-issue-type.md))。1 Issue 1 型で、org 単位の語彙:

| Issue Type | 意味 |
| --- | --- |
| `Bug` | 期待と違う挙動 |
| `Feature` | 新機能・拡張 |
| `Task` | 保守・整備・CI・リファクタ |
| `Design` | 設計判断・ADR |
| `Docs` | ドキュメント |

迷ったら `Bug` > `Design` > `Docs` > `Task` の順で、より具体的なほうを取る (`Task` は何にでも当てはまるので最後)。ラベルは型と直交する属性だけを表す — `status: *` (状態)・`verify: triaged` (完了条件が固まっている)。検索は `type:"Design"` と引用符を付ける (旧来の `type:issue` / `type:pr` と綴りが衝突するため)。

型の作成・改名はメンテナの操作で、エージェントの token では通らない (`admin:org` が要る)。既存の型を Issue に付けるのはエージェントでもできる。

## PR のラベル

PR には分類ラベルを付けない ([ADR-0005](docs/decisions/0005-pr-labels-as-machine-input.md))。型は PR タイトル、対象 Issue は `Closes #N`、完了条件は対象 Issue の本文と PR の「確認方法」の対応表、重要パスはルールセットの `required_reviewers`、進行状態は Draft / Review / merge queue が既に持っている。

付くのは CI の判定を変えるラベルだけで、現状は 3 種:

| ラベル | 意味 | 読む側 |
| --- | --- | --- |
| `no-issue` | Issue を閉じない例外 PR | `scripts/review-gate.sh` |
| `release:now` | merge したその場で版を出す | `.github/workflows/release.yml` |
| `no-visual-change` | 描画のパスに触れるが絵は変わらない | `scripts/check-drawing-evidence.sh` |

新しい PR ラベルを足すときは、それを読むスクリプトを同時に示す — 読み手のいないラベルは足さない。付け忘れは `review-gate` が赤で差し戻すので手付けのままでよい。bot の PR (dependabot) だけは `.github/dependabot.yml` の `labels` で自動付与する。

## マージの判断基準

PR 本文が揃っていて `ci-gate` が green なら、指示を待たず `gh pr merge --auto` で merge queue に投入してよい。queue が合流後の姿で `ci-gate` を再検証するため、人手で CI を見張って merge する運用はしない。main への直接 push・force push はルールセットが禁止している。マージ後は main に戻って pull する。

承認が要る PR でも先に `--auto` を有効化しておく。auto-merge はゲートを飛び越えず予約として振る舞うので、メンテナの操作が Approve 1 回で完結する。

**`BEHIND` でも "Update branch" は押さない。** 必須チェックは `strict` を切ってあり、queue が合流後の姿で再検証するので、追随しても得るものが無く auto-merge だけが外れる ([#110](https://github.com/mokume-metal/mokume/pull/110))。例外は描画 PR で `local-render` が failure になったときだけで、対処は「描画に影響する変更」節にある。

止まって見えるときの読み分け:

| 症状 | 原因 | 対処 |
| --- | --- | --- |
| `autoMerge: false` + `BLOCKED` | 承認待ち、または auto-merge が外れた ([#114](https://github.com/mokume-metal/mokume/issues/114) に出来事ごとの実測) | 承認を待つ / `gh pr merge <番号> --auto --squash` を打ち直す |
| 全 check が緑なのに進まない | 同じコミットに残る古い失敗 check run が判定を固定している ([#259](https://github.com/mokume-metal/mokume/issues/259)) | `gh run rerun <run-id> --failed` |
| `autoMerge: false` + `CLEAN` + 全 check 緑 | 描画 PR が merge queue から弾かれ、auto-merge も一緒に外れた (eject の副作用) | `make catch-up` |
| close して作り直した PR が、全 check 緑なのに赤い | close した側の run が付けた赤が**同じコミットに残っている** ([#513](https://github.com/mokume-metal/mokume/issues/513)) | **新しい PR の側**の run を rerun する。close した側を rerun すると同じ赤を再生産する — 上の行とは打つ先が逆 |

```bash
gh pr view <番号> --json autoMergeRequest,mergeStateStatus,latestReviews
```

承認の要否は `reviewDecision` には現れないので `mergeStateStatus` を見る (承認待ちなら `BLOCKED`・承認されると `CLEAN`)。理由は [ADR-0003](docs/decisions/0003-agent-identity-separation.md) 決定 4。**`CLEAN` だけでは「承認された」と読めない** — 承認の要らない PR も `CLEAN` なので、承認が付いたかどうかは `latestReviews` を見る ([#573](https://github.com/mokume-metal/mokume/issues/573) はここを取り違えて、承認済みの PR を「承認 0 で入った」と報告している)。

承認が要るのは **重要パス (`docs/decisions/`・`.github/`・`.claude/`) を触る PR だけ**で、要求もマージの停止も `.github/rulesets/main-protection.json` の `required_reviewers` が担う (team `maintainers` へ 1 承認を課す)。承認待ちの間も `ci-gate` は緑のままである。

かつては `verify: human` の Issue に紐づく PR にも Approve を要求していたが、263 件のマージで測ったら固有に承認を要求したのは 36 件・変更要求は 0 件・初承認までの中央値は 11 分で、止めてはいなかった ([ADR-0031](docs/decisions/0031-triage-as-the-single-gate.md) が畳んだ)。代わりに置いたのが PR 本文の対応表である。

承認は native の Approve レビューのみ。**承認が要る PR も要らない PR も App identity で作る** — author を承認者集合の外に置くのが不変条件で、要否は作成前に確定できない ([ADR-0007](docs/decisions/0007-approvability-invariant.md))。

## 版の出方

版はタグと [GitHub Release](https://github.com/mokume-metal/mokume/releases) だけで表し、リリースはリポジトリのファイルを 1 つも変えない (判断の詳細は `scripts/release.py` の冒頭)。

- 週に 1 度 (月曜 09:00 JST) 自動で出る。急ぐときは PR に `release:now` を付けて merge する
- 上げ幅は履歴が決める。1.0 未満では破壊的変更も minor で出す (0.x は形が動くことを織り込んだ区間のため)
- ノートは `changelog.d/` の断片から組む。断片は消さない
- 断片が 1 つも増えていなければリリースは出ない

## ブランチ保護の正本

保護の正本は `.github/rulesets/*.json` で、GitHub 側の状態はその写し ([ADR-0006](docs/decisions/0006-github-settings-as-code.md))。管理画面で直接いじらない — 変更は定義ファイルの PR から始める。

| したいこと | コマンド |
| --- | --- |
| 定義の形を見る (token 不要。`make ci-check` に含まれる) | `bash scripts/check-rulesets.sh --shape` |
| 実設定と照合する (認証が要る) | `bash scripts/check-rulesets.sh` |
| 適用の差分を見る | `bash scripts/apply-rulesets.sh` |
| 実際に適用する (メンテナのみ) | `bash scripts/apply-rulesets.sh --apply` |

適用はエージェントの token では通らない (ADR-0003 決定 1 により `Administration` 権限を持たない)。定義ファイルの PR までがエージェントの仕事で、merge 後の `--apply` はメンテナが打つ。

照合も適用も読むのは手元にチェックアウトされている定義なので、古い版のツリーから打つと嘘をつく。照合は手元が古ければそう名乗り ([#311](https://github.com/mokume-metal/mokume/issues/311))、適用は古ければ赤で止まる ([#425](https://github.com/mokume-metal/mokume/issues/425))。押し通すためのフラグは無い。

`bypass_actors` はルールセットへの write access がある認証にしか返らない。手元での照合は読めなければ赤にする (一番危ない項目を見ていない緑を作らないため)。CI にその鍵は置かないので、日次のドリフト検査 (`.github/workflows/ruleset-drift.yml`) は `--without-bypass-actors` で走り、見ていないことを出力が名乗る。**この項目を見張っているのは、メンテナが手元で `bash scripts/check-rulesets.sh` を打つときだけである** ([ADR-0006](docs/decisions/0006-github-settings-as-code.md) 決定 5)。機械で見張る仕組みは実害が出てから足す。

定義を merge した直後にも同じ検査が走る。`--apply` を打つまでは定義だけが先行するので、その赤は故障ではなく催促で、この契機では Issue は立たない ([#381](https://github.com/mokume-metal/mokume/issues/381))。

## sub-issue の使い方

- 複数工程の仕事は親 Issue + sub-issue で構成する (本文チェックリスト不使用)。作成は `scripts/sub-issue.sh <親番号> <タイトル>` で 1 コマンド (紐づけと親の Issue Type 継承まで行う。子が別の仕事なら `--type <名前>`)
- 検証・実験のための使い捨て Issue は、検証対象の Issue の sub-issue にする (`--test` で雛形ごと作れる)。存在理由がツリーに残る
- 階層は 2〜3 段まで。独立した Issue を無理にツリー化しない (ツリーは関係の表現であって収納棚ではない)
- open の子を残した親の completed close は Parent guard が reopen する。ツリーごと畳む意図なら not planned で close する
- 子 Issue の検索は `parent-issue:mokume-metal/mokume#N` 修飾子

## 進捗の公開ロードマップ

開発フェーズの見通しは Org の public Project「[mokume Roadmap](https://github.com/orgs/mokume-metal/projects/1)」で公開する。Project は Issue の投影で、状態の正典は従来どおり Issue。

- アイテムの出入りは GitHub 組み込みワークフローに任せる (7 種すべて有効)。手でキュレーションしない
- 人の手で入るのは date フィールド Start / Target の 2 本だけで、フェーズ親 Issue にだけ付ける ([#131](https://github.com/mokume-metal/mokume/issues/131))
- Iteration・Milestone・独自の status フィールドは足さない — 束ねと消化率は親 Issue + sub-issue が既に持つ ([#124](https://github.com/mokume-metal/mokume/issues/124))
- Status → Issue の逆流 (Auto-close issue) も有効のままでよい。無効にすると Project 側にしかない状態を許すことになる
- 組み込みワークフローの有効・無効は Project の管理画面から変える (GraphQL に切り替えの口が無く、定義ファイルも持たない)

## コメント

### 置き場

PR ができるまでは Issue、できてからは PR。例外は 3 つで、完了条件が動く話は Issue、完了報告は Issue に 1 通 (「条件 N は PR #M で満たされた」の対応表まで)、恒久的な決定は ADR。表と理由は [ADR-0002](docs/decisions/0002-issue-lifecycle-and-merge-approval.md) 決定 6 が持つ。

PR を作ったときに Issue へ「実装 PR は #N」とは書かない — `Closes #N` から GitHub が相互リンクを描く。

### 署名

同じ Issue / PR には人間も複数のエージェントも書き込むので、AI エージェントからのコメントは投稿ラッパー経由で投稿する。署名は実行環境から判定して自動で付く (`--dry-run` で投稿前に確認できる。名乗りを自動検出できない環境では `MOKUME_AGENT_NAME` で明示する):

```bash
bash scripts/comment.sh issue <番号> --body-file <ファイル>
bash scripts/comment.sh pr    <番号> --body "<本文>"
```

発言を伴う操作は `gh {issue,pr} comment` だけではない。`gh pr review` の本文オプションと `gh {issue,pr} {close,reopen}` の `--comment` も同じ扱いでフックが差し戻す ([#123](https://github.com/mokume-metal/mokume/issues/123))。close / reopen は 2 手に分ける — 発言をラッパーで投稿してから、状態の変更は発言なしで実行する。

`comment.sh` に close / reopen も `-R` も足さない。ラッパーの責務を「署名を付けて投稿する」1 つに保つため ([#188](https://github.com/mokume-metal/mokume/issues/188))。

この節が言うのはこのリポジトリ宛てのコメントで、他のリポジトリへは素の `gh` で書く (mokume-metal の外のパッケージについては [ADR-0026](docs/decisions/0026-plugin-repository-alignment.md) 決定 4 — 署名の 1 行は同じ形を付け、ラッパーは持ち込まない)。人間が直接 `gh` でコメントする分にはラッパーは不要。

## エージェント環境の設定

`.claude/settings.json` (プロジェクト設定) が頻用コマンドの許可リストと、リポジトリ同梱のフックの配線を持つ。個人環境のプラグインは宣言しない ([ADR-0017](docs/decisions/0017-agent-support-locality.md) 決定 2)。設定はあくまで補助で、作法の正典はこの文書。

mokume 向けのエージェント支援 (スキル・hooks・設定) はこのリポジトリの `.claude/` で管理し、個人環境のプラグインやマシン設定には置かない (ADR-0017)。入れている人にだけ効く支援を前提にすると、規約が環境によって変わるためである。

**外側に残るのは 2 類型だけで、どちらも「移し先が無い」のではなく「守る場面がここに無い」ことが理由である** ([ADR-0017](docs/decisions/0017-agent-support-locality.md) 決定 1 の改訂) — 仕様上、個人環境の設定にしか書けないもの / 守る場面がこのリポジトリの外にあるもの (clone する前・どのリポジトリにも属さない場所・公開面に置けないルールを持つもの)。**それ以外は実体ごとこちらが持つ。**

同種の機構が双方にあるときは、リポ側が担保して個人側を `env` で黙らせる (いま 3 本: `CLAUDE_PLAN_RECORD` / `RS_CI_WATCH` / `CLAUDE_GH_COMMENT_GUARD`)。リポ側に対応物が無いものは、受け取ってから黙らせる。

`PreToolUse` で止めているのは 3 本:

| フック | 何を止めるか |
| --- | --- |
| `scripts/agent-comment-guard.sh` | 素の `gh` でのコメント投稿 (署名の作法は「コメント」節) |
| `scripts/pr-identity-guard.sh` | メンテナ名義での PR 作成 (下の「エージェントの identity」節) |
| `scripts/worktree-path-guard.sh` | 同じリポジトリの**別 worktree** への書き込み。取り違えると変更がいまのブランチではなく別のツリーへ落ち、同名のファイルが両方にあるため差分を見るまで気付けない |

**3 本とも、このリポジトリを主として開いたセッションでしか効かない。** 理由と対処は次節の「フックが黙っていることを『安全である』と読まない」が持つ — あそこに書いてあることは 3 本すべてに当てはまる。

### エージェントの identity

エージェントは PR の作成を GitHub App の identity で行う ([ADR-0003](docs/decisions/0003-agent-identity-separation.md))。token は次で発行する:

```bash
GH_TOKEN="$(bash scripts/gh-app-token.sh)" && export GH_TOKEN && git push -u origin HEAD && gh pr create …
```

この 1 行の形が要求すること:

- **代入から始めて後続コマンドまで `&&` で繋ぐ。** `export GH_TOKEN="$(...)"` と書くと終了コードが `export` のもの (0) に化け、発行に失敗しても空の token でメンテナの認証へフォールバックする ([#122](https://github.com/mokume-metal/mokume/issues/122))。危険な形は `scripts/pr-identity-guard.sh` が差し戻す
- **フックが黙っていることを「安全である」と読まない。** `pr-identity-guard.sh` の配線は `.claude/settings.json` にあり、読まれるのは**そのセッションが主として開いたディレクトリ**のものだけである。別のリポジトリを主とするセッションがこのリポジトリの worktree で作業しても効かない (途中で `cd` しても後から有効にはならない)。塞ぐ手が無いことは [ADR-0007](docs/decisions/0007-approvability-invariant.md) 決定 3 が示しているので、その場合はこの節を自分で守る ([#513](https://github.com/mokume-metal/mokume/issues/513))
- push は `-u` を付ける。追跡先を持たないブランチは merge されても `[gone]` にならず手元に残り続ける ([#376](https://github.com/mokume-metal/mokume/issues/376))。`origin/main` を追跡している状態も同じなので、`git branch --unset-upstream` してから `-u` で押し直す

手で揃える設定は `MOKUME_APP_PRIVATE_KEY_CMD` (App の秘密鍵 PEM を標準出力に出すコマンド) の 1 つだけ。秘密鍵の中身も在処もリポジトリに書かない。token は有効期限 1 時間で、キャッシュしない。App ID とインストール ID は `scripts/gh-app-token.sh` が org から自力で引く。

未設定でも「鍵が無い」と即断しない — 手元の秘密管理の「自動化から読んでよい秘密の一覧」を引き、参照名が分かれば 1 行で組める (在処そのものを読む必要はない)。一覧にも無ければ PR を作らず、鍵の渡し方を人に尋ねる。

**承認が要る変更は、誰の手であれ App identity の PR で入れる。token を発行できないときは PR を作らない** ([ADR-0007](docs/decisions/0007-approvability-invariant.md))。メンテナも例外にしない — 自分の PR は自分で承認できないので、メンテナ名義で作れば誰も承認できない PR になる。承認の要否は作成前に確定できないため、`gh pr create` は一律に App identity を要求する。

コミットの author と署名はメンテナのままで、分離するのは PR 作成の主体だけ。push の主体は問わない (ADR-0003 決定 6)。

## 手元に残ったプロセス

セッションが終わってもスケッチ・検証プロセスは残る。出所つきで一覧する (何を見て何を見ないかはスクリプトの冒頭にある):

```bash
bash scripts/orphan-processes.sh
```

この一覧は何も殺さない。落とすかどうかは人間が決めるので、そのために PID を出す。持ち主の生死を判定できないものは「判定できず」と名乗って生きている側に倒す。

打たなくても気づけるよう、30 秒を越えて走り続けたスケッチはメニューバーで名乗る ([#473](https://github.com/mokume-metal/mokume/issues/473))。窓を開かない実行にも効く。印も何も殺さない。

## コミット・PR の規約

- Conventional Commits: `<type>(<scope>): <要約>`。type は feat / fix / docs / refactor / test / chore / ci / perf / build。type と scope は英語、要約は日本語でよい
- 1 コミット 1 関心。**1 PR は「1 つの説明で筋が通る範囲」** — 同じ親の sub-issue 群も、作業中に踏んで起票した障害もまとめて閉じてよい ([ADR-0031](docs/decisions/0031-triage-as-the-single-gate.md) 決定 3)。閉じる Issue ごとに「確認方法」へ対応表を置く
- **検証は `make ci-check` に集約する。push 前に通す — これは作法ではなく merge の条件である。** 全部が通ったときだけ `local-render` が commit status に打たれ、描画に触れる PR はそれが無いと merge できない (報告されないときは理由が出る。よくあるのは作業ツリーが汚れているまま打った場合)
- ユーザー影響のある変更は `changelog.d/` に断片を 1 ファイル置く (CHANGELOG を直接編集しない)
- **検査の「待たない」は待つ側が持つ。`.timeLimit` は使わない。** 上限は検査の走り出しからの時計で測られ、このパッケージの検査はすべて main actor に載っているので、どんな値を書いても「検査**全体**が何秒で終わるか」を要求することになる — 検査が増えた日に、無関係な変更が無関係な検査を赤くする ([#564](https://github.com/mokume-metal/mokume/issues/564) の実測: 905 件のうち 875 件が「60 秒超」を報告した)。固まりうる待ちには、待つ側が期限を持たせて越えたら殺す

## してはならないこと

- 生成物・バイナリ (画像・動画・モデル) をコミットしない。視覚的な証跡は外部ホスティングへ上げ URL で参照する
- 帰属 (著作権・ライセンス) の不明なファイルを持ち込まない。第三者素材は正確な帰属の宣言と同時にしか入れられない
- 想定だけの API を先回りで作らない。機能は実際の作品制作で踏まれた必要から正当化する (ADR-0001 原則 4)。作品はこのリポジトリの外で作り、依存は一方向で、このリポジトリは作品を参照しない (`Package.swift` にも CI にも入らない。[ADR-0022](docs/decisions/0022-production-track.md))。実需が入る口は `Feature` 型の Issue 1 本だけで、`Sketches/` で踏んだものは実需に数えない。作品で踏んだバグは `Bug` で普通に起票し実需を要求しないが、再現はこのリポジトリの中の最小のスケッチかテストに落とす。作品の側の運用はここでもあちらでも規約にしない (書けばドリフトする)
- 新しいゲート・検査・hook・ラベル・ワークフローを足す PR は、それが塞ぐ実害を Issue 番号で示す ([ADR-0008](docs/decisions/0008-mechanism-needs-demonstrated-harm.md))。「あると良さそう」では足さない — 思いついたら起票して待たせる (順序は 実害 → Issue → 機構)。消すほうには実害を要求しない
- 足すと決めた後も、まず既存で済まないかを見る — 既存の機構の責務を広げる / GitHub や既存ツールが native に持つもので済ませる / 置き換える、の順に検討し、選んだ段を PR 本文に書く (ADR-0008 決定 5)。理由を書けない重複は、どちらかが要らない

## 描画に影響する変更

描画結果・動きが変わる PR には before/after の視覚的証跡を載せる (動きは動きの分かる形式で)。リポジトリにはコミットせず、URL で参照する。CI は描画を走らせられないので、**緑は「描けている」を意味しない** — 貼られた絵が唯一の検証記録になり、squash merge でブランチが消えた後には足せない。

これは作法ではなく機械の要求で、`scripts/drawing-paths.txt` に載る場所を触った PR の本文に絵が 1 つも無ければ `drawing-evidence` が赤で差し戻す ([#306](https://github.com/mokume-metal/mokume/issues/306))。見るのは絵が用意されていることだけで、絵が正しいかは見ない — 正しさの担い手は人間と AI の目である ([ADR-0019](docs/decisions/0019-drawing-verification.md) 決定 1)。絵を出しようがない変更 (描画のパスに居るが絵は変わらないリファクタ・コメントの修正) は `no-visual-change` ラベルで外す (本文の編集でもラベルの付け外しでも CI は自動で再評価する)。

**一覧は 1 つだが、答える問いは 2 つある。** 証跡を要求するかの問いと、下の「覆い」の問いで、`evidence-only` の印が付いた行は前者にだけ効く — 「絵は動きうるが、台帳が描く絵は動かせない」場所である ([#497](https://github.com/mokume-metal/mokume/issues/497))。いま印が付いているのは `Sketches/` だけで、参照スケッチは独立した executable target なので台帳の絵を 1 画素も動かせない (合流後の木でビルドが破れれば merge queue の `ci-check` が見る)。

守っている不変条件は 1 行 — **main の絵に関わるファイルは、常に誰かが手元で実際に回して確かめた組み合わせのままである。** 手元の実行は合流前の枝でしか回らないので、`scripts/render-status.sh` が merge queue で 2 つを見る ([#435](https://github.com/mokume-metal/mokume/issues/435)・[#467](https://github.com/mokume-metal/mokume/issues/467)):

| 判定 | `local-render` | 対処 |
| --- | --- | --- |
| PR head と合流後で、描画に関わるファイルの中身が違う | failure (PR の head にも付く) | `make catch-up` |
| 覆いを壊す open な非 Draft PR が他にもあり、自分が最小番号でない | `#N の merge を待つ` で赤 | 先頭が merge されるまで待つ (待ちの間に打ち直しても無駄になる)。先頭が停滞しているならその PR を Draft に落とす |

順番は番号順なので、**まだ作業中の描画 PR は Draft にしておく** — Draft は順番の外なので、完成して承認まで済んだ後続を番号だけの理由で待たせずに済む ([#497](https://github.com/mokume-metal/mokume/issues/497))。

`make catch-up` は復旧の 5 手 — main を取り込む → `make ci-check` → push → `make render-status` → `--auto` を掛け直す — を 1 手にする ([#457](https://github.com/mokume-metal/mokume/issues/457))。**打つ意味が無いときは走らない**ので、上の表の 2 行目 (先に描画 PR が居る) では番号を名指しして断り、数分かかる検査を空費しない。手で 5 手を追ってもよいが、**1 手抜けても PR は全チェック緑・`CLEAN` のまま止まる**ので、それに気付く経路が無い。

壊れている絵は起票の時点でしか撮れないので、見た目・動きの事象を Issue に立てるときも証跡を添える。

上げ先は問わない — Issue / PR の入力欄へ画像や動画をそのまま落とせば GitHub が保管して URL を返す。人間の貢献者にはこれが最短で、何も用意しなくてよい。エージェントにはその経路が無いため、Gyazo を使う手順を [`.claude/skills/gyazo-evidence/`](.claude/skills/gyazo-evidence/SKILL.md) が持つ。この節が「何を載せるか」の正典で、スキルは「どう撮るか」だけを持つ。

## 言語

メンテナは日本語で作業する (このリポジトリの規約文書・コミット・PR・Issue は基本日本語)。ただしこれはメンテナの実践であって強制ではない — どの言語での Issue・コントリビューションも歓迎する。コードの識別子は英語。
