# AGENTS.md

このリポジトリで作業する AI エージェントと人間に等しく効く規約。規約の正典はこの文書に一本化している — 守ることの大半は読み手によらず同じで、分けると写しが生まれるためである ([ADR-0001](docs/decisions/0001-founding-principles.md) 原則 9)。人間の貢献者の入口は [CONTRIBUTING.md](CONTRIBUTING.md) だが、あちらは案内だけで規約の写しは持たない。

この文書は規律だけを書く。決定の根拠は ADR、経緯と実測は Issue / PR、機構の内部と手順はスクリプトの冒頭コメントと `--help` が持つ。

## プロジェクト

mokume は macOS / Apple Silicon 専用のクリエイティブコーディング環境 (Swift + Metal)。宣言的・フレームベースのスケッチ API を提供する。

この文書はフェーズも進捗も書かない。どこまで出来ているかはリポジトリ自身 (`Sources/`) と Issue / Roadmap が正典で、ここに写すと触る理由が無いまま古くなる。

## 正典の在処

| 対象 | 正典 |
| --- | --- |
| プロジェクトの土台 | [ADR-0001 設計原則](docs/decisions/0001-founding-principles.md) |
| 設計判断 | `docs/decisions/` の ADR (状態 / 文脈 / 決定 / 影響 の 4 節・自己完結で書く) |
| プロセスの外とやりとりする JSON の形式 | `Schemas/` の JSON Schema。実装は従う側で、代表例との照合を `make ci-check` が見る ([ADR-0018](docs/decisions/0018-observation-and-control-surface.md)) |
| 作業の経過・発見・残タスク | GitHub Issues / PR (ローカルファイルやセッション記憶に残さない) |
| この文書がどこまで外のパッケージに効くか | [ADR-0026](docs/decisions/0026-plugin-repository-alignment.md) 決定 1 の 3 段 |

ADR の帰属は ADR 自身の先頭に SPDX ヘッダ (HTML コメント) を置いて宣言し、`REUSE.toml` には足さない。

```markdown
<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->
```

### ADR の状態欄

**方針が変わったら、状態欄がそれを名乗る。**`採用 (日付)` に ` / ` で足す綴りは 3 つ:

| 綴り | 使うとき |
| --- | --- |
| `改訂 (YYYY-MM-DD): <何を>` | 決定の理由は動かず、手段を差し替えた・足した |
| `一部置換 (→ ADR-00NN): <どの決定が>` | 決定の一部が別の ADR に取って代わられた |
| `置換済み (→ ADR-00NN)` | 全体が別の ADR に取って代わられた |

**番号を増やすか本文を書き換えるかは、理由が生きているかで決まる。** 理由が動かず手段だけ変わったなら同じ ADR を改訂し、理由そのものが覆ったなら新しい ADR を立てて古い側を `置換` にする。本文側の作法 — 改訂の見出しに日付を入れる・「**当初の決定**は〜だった」と捨てたものを理由ごと残す — は変えない。

改訂の日付が状態欄にあるかは `make adrs` が見るが、**上書きされた側が `置換` を名乗っているかは見ない** — そこは書く人とレビューが担う。

## 進め方

1. 変更は Issue 起票から始める。起票は雑でよい (書式不要・分類は機械がタイトルから下書きする)。複数工程は親 Issue + sub-issue で構成し、本文チェックリストは使わない。**印を付けられるのは完了条件を知っている起票者だけ**で、エージェントも自分が起票して本文に完了条件を書けた Issue には自分で付けてよい ([ADR-0002](docs/decisions/0002-issue-lifecycle-and-merge-approval.md) 決定 1 の追補)。他人が書いた Issue には付けない。**在庫は着手を待たずに作ってよい** (調べて在庫にする手順は [`.claude/skills/stock-triage/`](.claude/skills/stock-triage/SKILL.md))
2. **着手できるのは `verify: triaged` が付いた Issue だけ。** ラベルが無ければ未トリアージなので着手しない — まず議論して「どうなれば解消か」を Issue 本文に固めてから付ける ([ADR-0002](docs/decisions/0002-issue-lifecycle-and-merge-approval.md) 決定 1・[ADR-0031](docs/decisions/0031-triage-as-the-single-gate.md) 決定 1)
3. **着手時に完了条件がまだ妥当かを確かめる。** ラベルは付いた時点の判断しか表さない — 各条件を現行のコードと突き合わせ、「まだ有効」「既に満たされている」「差し替えが要る」のどれかをプランに書く。ずれていれば Issue 本文のほうを先に更新する ([ADR-0031](docs/decisions/0031-triage-as-the-single-gate.md) 決定 4)
4. その突き合わせを含むプラン (変更点・確認方法) を対象 Issue にコメントで残す。実装の過程で変わったら差分を残す (PR を出した後なら PR 側へ)。記憶がリセットされた次のセッションが、GitHub を読むだけで再開できる状態を保つため
5. `main` から `<type>/<短い説明>` ブランチを切る
6. PR を出す。本文は 目的 / 変更点 / 確認方法。**「確認方法」には閉じる Issue ごとに完了条件と、それを何でどう確かめたかの対応表を置く** (承認の代わりに残す記録 — [ADR-0031](docs/decisions/0031-triage-as-the-single-gate.md) 決定 2。`review-gate` は番号が現れることだけを見る)。Issue を閉じる `Closes #N` は PR 本文に書く (squash merge ではコミット側の記述は GitHub に届かない)。Issue を閉じない例外 PR には `no-issue` ラベルを付ける
7. マージは squash のみ。PR タイトルがそのままマージコミットになるので Conventional Commits で書く

**作業中に踏んだ問題は、起票して終わりにしない。** 起票の時点で行き先まで決める ([ADR-0036](docs/decisions/0036-unattended-issue-processing.md) 決定 6)。分けるのは**完了条件を自分で書けるかどうか**だけで、別の物差しは持ち込まない:

| 踏んだもの | 行き先 |
| --- | --- |
| その PR の説明で筋が通る大きさ | **起票して、その PR で閉じる** (既定。上限は「1 つの説明で筋が通る範囲」) |
| 筋が通らないが、完了条件は書ける | 起票し、**完了条件を本文へ書いて `verify: triaged` まで自分で付ける** |
| 完了条件を自分で書けない (設計・判断が要る) | **無印で置く** — メンテナの判断を待つ |

**印は起票の瞬間に付ける** — エージェントの起票も次のセッションからはメンテナ名義に見えるので、後回しにすると誰も着手できない Issue になる。

Claude Code のセッションでは、手順 3・4 を `scripts/plan-record.sh` が見る (現況の無いプランと、未投稿のままの終了を差し戻す)。

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

## PR のラベル

PR には分類ラベルを付けない ([ADR-0005](docs/decisions/0005-pr-labels-as-machine-input.md))。型は PR タイトル、対象 Issue は `Closes #N`、完了条件は対象 Issue の本文と PR の「確認方法」の対応表、重要パスはルールセットの `required_reviewers`、進行状態は Draft / Review / merge queue が既に持っている。

付くのは CI の判定を変えるラベルだけで、現状は 3 種:

| ラベル | 意味 | 読む側 |
| --- | --- | --- |
| `no-issue` | Issue を閉じない例外 PR | `scripts/review-gate.sh` |
| `release:now` | 壊れた配布物をその場で出し直す | `.github/workflows/release.yml` |
| `no-visual-change` | 描画のパスに触れるが絵は変わらない | `scripts/check-drawing-evidence.sh` |

新しい PR ラベルを足すときは、それを読むスクリプトを同時に示す — 読み手のいないラベルは足さない。付け忘れは `review-gate` が赤で差し戻すので手付けのままでよい。

## マージの判断基準

PR 本文が揃っていて `ci-gate` が green なら、指示を待たず `gh pr merge --auto --squash` で merge queue に投入してよい。queue が合流後の姿で `ci-gate` を再検証するので、人手で CI を見張って merge しない。main への直接 push・force push はルールセットが禁止している。マージ後は main に戻って pull する。

承認が要るのは **重要パス (`docs/decisions/`・`.github/`・`.claude/`) を触る PR だけ**で、要求もマージの停止も `.github/rulesets/main-protection.json` の `required_reviewers` が担う (team `maintainers` へ 1 承認)。承認が要る PR でも先に `--auto` を掛けておく — 予約はゲートを飛び越えないので、メンテナの操作が Approve 1 回で済む。承認は native の Approve レビューのみ。

**`BEHIND` でも "Update branch" は押さない。** queue が合流後の姿で再検証するので、追随しても得るものが無く auto-merge だけが外れる。例外は描画 PR で `local-render` が failure になったときだけで、対処は「描画に影響する変更」節にある。

## 止まって見えるときの読み分け

止まって見える PR の症状と対処は、`scripts/stall-watch.sh` の冒頭の読み分け表が持つ。同じスクリプトが当番として定期に判定し、機械が打てる行 (auto-merge の掛け直し・古い失敗ジョブの rerun) は打ち、人手が要る行だけを run の赤で名乗る。当番は数時間おきにしか回らないので、**急ぐときは `bash scripts/stall-watch.sh` を自分で打つ** (読み取りのみ)。**当番の対象外にしたい PR は Draft にする。**

特に踏みやすい 3 つ:

- **`pr-title` の失敗は rerun しない。** rerun は元のイベントを再生するので古いタイトルで判定し、打つ前より悪くなる ([#699](https://github.com/mokume-metal/mokume/issues/699))。タイトルを直せば新しい run が走る。`design` は Issue Type であって型ではない
- **check が 1 本も付かないのは「まだ来ていない」ではなく「来ない」。** main と衝突している。`git merge-tree --write-tree origin/main HEAD` で確かめ、手元で解いて push する
- **`autoMerge: false` は「外れた」と「queue に入った」の両方を指す。** `make catch-up` を打つ前に `isInMergeQueue` を見る (引き方は同じ表の下にある)

## 版の出方

版はタグと [GitHub Release](https://github.com/mokume-metal/mokume/releases) だけで表し、日に 1 度自動で出る。ノートは `changelog.d/` の断片から組む (断片は消さない)。壊れた配布物を出し直すときだけ PR に `release:now` を付けて merge する。上げ幅と判断の詳細は `scripts/release.py` の冒頭にある。

## ブランチ保護の正本

保護の正本は `.github/rulesets/*.json` で、GitHub 側の状態はその写し ([ADR-0006](docs/decisions/0006-github-settings-as-code.md))。管理画面で直接いじらず、定義ファイルの PR から始める。merge 後の適用 (`bash scripts/apply-rulesets.sh --apply`) はメンテナが打つ — エージェントの token は `Administration` 権限を持たない。

**必須チェックを消すときだけ、適用が先である** — 消す PR 自身が、消そうとしている必須チェックを満たせなくなる。照合と適用の使い方・手元の鮮度・`bypass_actors` の扱いは `scripts/check-rulesets.sh` と `scripts/apply-rulesets.sh` の冒頭にある。

## sub-issue の使い方

複数工程の仕事は親 Issue + sub-issue で構成し、`scripts/sub-issue.sh <親番号> <タイトル>` で作る (紐づけと Issue Type の継承まで行う。検証用の使い捨ては `--test`)。階層は 2〜3 段までにし、独立した Issue を無理にツリー化しない。open の子を残した親を completed で close すると Parent guard が reopen するので、ツリーごと畳むなら not planned で close する。子の検索は `parent-issue:mokume-metal/mokume#N`。

## 進捗の公開ロードマップ

見通しは Org の public Project「[mokume Roadmap](https://github.com/orgs/mokume-metal/projects/1)」で公開する。Project は Issue の投影で、状態の正典は Issue のまま。アイテムの出入りは GitHub の組み込みワークフローに任せ、手でキュレーションしない。人が触るのはフェーズ親 Issue の Start / Target の 2 フィールドだけで、Iteration・Milestone・独自の status は足さない (束ねと消化率は親 Issue + sub-issue が持つ)。

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

発言を伴う操作は `gh {issue,pr} comment` だけではない。`gh pr review` の本文オプションと `gh {issue,pr} {close,reopen}` の `--comment` も同じ扱いでフックが差し戻す。close / reopen は 2 手に分ける — 発言をラッパーで投稿してから、状態の変更は発言なしで実行する。

`comment.sh` の責務は「署名を付けて投稿する」1 つに保ち、close / reopen も `-R` も足さない。

この節が言うのはこのリポジトリ宛てのコメントで、他のリポジトリへは素の `gh` で書く (mokume-metal の外のパッケージについては [ADR-0026](docs/decisions/0026-plugin-repository-alignment.md) 決定 4 — 署名の 1 行は同じ形を付け、ラッパーは持ち込まない)。人間が直接 `gh` でコメントする分にはラッパーは不要。

## エージェント環境の設定

`.claude/settings.json` が頻用コマンドの許可リストと、リポジトリ同梱のフックの配線を持つ。設定は補助で、作法の正典はこの文書。

mokume 向けのエージェント支援 (スキル・hooks・設定) はこのリポジトリの `.claude/` で管理し、個人環境のプラグインは宣言しない ([ADR-0017](docs/decisions/0017-agent-support-locality.md) 決定 2) — 入れている人にだけ効く支援を前提にすると、規約が環境によって変わる。

外側に残るのは 2 類型だけ — 仕様上、個人環境の設定にしか書けないもの / 守る場面がこのリポジトリの外にあるもの ([ADR-0017](docs/decisions/0017-agent-support-locality.md) 決定 1)。**それ以外は実体ごとこちらが持つ。**

同種の機構が双方にあるときは、リポ側が担保して個人側を `env` で黙らせる (いま 3 本: `CLAUDE_PLAN_RECORD` / `RS_CI_WATCH` / `CLAUDE_GH_COMMENT_GUARD`)。リポ側に対応物が無いものは、受け取ってから黙らせる。

**無人セッションの名乗りは `MOKUME_UNATTENDED=1` で、立てるのは外に居る起動側である** ([ADR-0036](docs/decisions/0036-unattended-issue-processing.md) 決定 2)。`env` には書けない (全セッションに効いてしまう)。読むのは `scripts/plan-record.sh` で、何が変わるかはその冒頭にある。

`PreToolUse` で止めているのは 3 本:

| フック | 何を止めるか |
| --- | --- |
| `scripts/agent-comment-guard.sh` | 素の `gh` でのコメント投稿 (署名の作法は「コメント」節) |
| `scripts/pr-identity-guard.sh` | メンテナ名義での PR 作成 (下の「エージェントの identity」節) |
| `scripts/worktree-path-guard.sh` | 同じリポジトリの**別 worktree** への書き込み。取り違えると変更がいまのブランチではなく別のツリーへ落ち、同名のファイルが両方にあるため差分を見るまで気付けない |

**3 本とも、このリポジトリを主として開いたセッションでしか効かない。** 理由と対処は次節の「フックが黙っていることを『安全である』と読まない」が持つ — あそこに書いてあることは 3 本すべてに当てはまる。

### エージェントの identity

maintainers team の人と、その人が動かすエージェントは、PR の作成を GitHub App の identity で行う ([ADR-0003](docs/decisions/0003-agent-identity-separation.md))。token は次で発行する:

```bash
GH_TOKEN="$(bash scripts/gh-app-token.sh)" && export GH_TOKEN && git push -u origin HEAD && gh pr create …
```

この 1 行の形が要求すること:

- **代入から始めて後続コマンドまで `&&` で繋ぐ。** `export GH_TOKEN="$(...)"` の形は発行の失敗を握り潰す。危険な形は `scripts/pr-identity-guard.sh` が差し戻す
- **フックが黙っていることを「安全である」と読まない。** 配線が読まれるのは、そのセッションが主として開いたディレクトリの `.claude/settings.json` だけである — 別のリポジトリを主とするセッションでは効かないので、この節を自分で守る ([ADR-0007](docs/decisions/0007-approvability-invariant.md) 決定 3)
- push は `-u` を付ける。`origin/main` を追跡している枝は `git branch --unset-upstream` してから `-u` で押し直す

手で揃える設定は `MOKUME_APP_PRIVATE_KEY_CMD` (App の秘密鍵 PEM を標準出力に出すコマンド) の 1 つだけで、秘密鍵の中身も在処もリポジトリに書かない。組めなければ PR を作らず、鍵の渡し方を人に尋ねる。

**maintainers team の側では、承認が要る変更は App identity の PR で入れる。token を発行できないときは PR を作らない** ([ADR-0007](docs/decisions/0007-approvability-invariant.md))。メンテナも例外にしない — 自分の PR は自分で承認できないので、メンテナ名義で作れば誰も承認できない PR になる。承認の要否は作成前に確定できないため、一律に App identity を使う。**外部の人は自分の名義で作ってよい** — author が承認者の外に居るので不変条件は破れない。

コミットの author と署名はメンテナのままで、分離するのは PR 作成の主体だけ。push の主体は問わない (ADR-0003 決定 6)。

## 手元に残ったプロセス

セッションが終わってもスケッチ・検証プロセスは残る。`bash scripts/orphan-processes.sh` が出所つきで一覧するが、**何も殺さない** — 落とすかどうかは人間が決める。30 秒を越えて走り続けたスケッチはメニューバーでも名乗る。

## コミット・PR の規約

- Conventional Commits: `<type>(<scope>): <要約>`。type は feat / fix / docs / refactor / test / chore / ci / perf / build。type と scope は英語、要約は日本語でよい
- 1 コミット 1 関心。**1 PR は「1 つの説明で筋が通る範囲」** — 同じ親の sub-issue 群も、作業中に踏んで起票した障害もまとめて閉じてよい ([ADR-0031](docs/decisions/0031-triage-as-the-single-gate.md) 決定 3)。閉じる Issue ごとに「確認方法」へ対応表を置く
- **検証は `make ci-check` に集約する。push 前に通す — これは作法ではなく merge の条件である。** 全部が通ったときだけ `local-render` が commit status に打たれ、描画に触れる PR はそれが無いと merge できない (報告されないときは理由が出る。よくあるのは作業ツリーが汚れているまま打った場合)
- **何が走ったかの正本は `.build/test-results-swift-testing.xml` で、端末に流れる文字ではない** (端末出力は行を落とす)。**赤を見たら、打ち直す前に `.build/test-log.txt` を退避する** — 打ち直しが記録を切り詰める
- **性能は release で測る。** debug の数字を性能の根拠にしない。入口は `make test-release` の 1 つ
- ユーザー影響のある変更は `changelog.d/` に断片を 1 ファイル置く (CHANGELOG を直接編集しない)
- **検査の「待たない」は待つ側が持つ。`.timeLimit` は使わない** — 検査はすべて main actor に載るので、どんな値も「検査**全体**が何秒で終わるか」を要求してしまう。固まりうる待ちには、待つ側が期限を持たせて越えたら殺す

## してはならないこと

- 生成物・バイナリ (画像・動画・モデル) をコミットしない。視覚的な証跡は外部ホスティングへ上げ URL で参照する
- 帰属 (著作権・ライセンス) の不明なファイルを持ち込まない。第三者素材は正確な帰属の宣言と同時にしか入れられない
- 想定だけの API を先回りで作らない。機能は実際の作品制作で踏まれた必要から正当化する (ADR-0001 原則 4・[ADR-0022](docs/decisions/0022-production-track.md))。作品はこのリポジトリの外で作り、このリポジトリは作品を参照しない。実需が入る口は `Feature` 型の Issue だけで、`Sketches/` で踏んだものは数えない。作品で踏んだバグは `Bug` で起票し、再現はこのリポジトリの中の最小のスケッチかテストに落とす
- 新しいゲート・検査・hook・ラベル・ワークフローを足す PR は、それが塞ぐ実害を Issue 番号で示す。「あると良さそう」では足さず、起票して待たせる。消すほうには実害を要求しない。足すと決めた後も、既存の責務を広げる / native の機能で済ませる / 置き換える、の順に検討し、選んだ段を PR 本文に書く。コードの写しを畳むのも部品を足すことに数える ([ADR-0008](docs/decisions/0008-mechanism-needs-demonstrated-harm.md) 決定 1・5・6)

## 描画に影響する変更

描画結果・動きが変わる PR には before/after の視覚的証跡を載せる (動きは動きの分かる形式で)。リポジトリにはコミットせず、URL で参照する。CI は描画を走らせられないので、**緑は「描けている」を意味しない** — 貼られた絵が唯一の検証記録になり、squash merge でブランチが消えた後には足せない。

`scripts/drawing-paths.txt` に載る場所を触った PR の本文に絵が 1 つも無ければ、`drawing-evidence` が赤で差し戻す。見るのは絵が用意されていることだけで、正しさの担い手は人間と AI の目である ([ADR-0019](docs/decisions/0019-drawing-verification.md) 決定 1)。絵を出しようがない変更 (絵の変わらないリファクタ・コメントの修正) は `no-visual-change` ラベルで外す。

**main の絵に関わるファイルは、常に誰かが手元で実際に回して確かめた組み合わせのままに保つ。** merge queue でそれを見るのは `scripts/render-status.sh` で、判定と対処は冒頭にある。書き手が守るのは 3 つ:

- **作業中の描画 PR は Draft にしておく。** 描画 PR は 1 本ずつ (queue の外では番号順に) 入るので、Draft でない作業中の PR は完成した後続を待たせる
- queue から弾かれたら **`make catch-up`** を打つ。main の取り込み → `make ci-check` → `--auto` の掛け直しを 1 手にしたもので、手で追うと 1 手抜けても全チェック緑のまま止まる。持ち主のセッションが居ない PR は別のセッションが代わりに打てる (手順は `scripts/catch-up.sh` の冒頭)
- **取り込みは手元だけで済ませ、push しない** — push は承認を落とす ([#612](https://github.com/mokume-metal/mokume/issues/612))。例外は衝突を解いた合流で、そのときだけ push する

壊れている絵は起票の時点でしか撮れないので、見た目・動きの事象を Issue に立てるときも証跡を添える。

上げ先は問わない — Issue / PR の入力欄へ画像や動画をそのまま落とせば GitHub が保管して URL を返す。人間の貢献者にはこれが最短で、何も用意しなくてよい。エージェントの撮り方と上げ先 (本線と退避路) は [`.claude/skills/visual-evidence/`](.claude/skills/visual-evidence/SKILL.md) が持つ。無人で上げ先が両方塞がったら、そう書いて Draft に落として返す。

## 言語

メンテナは日本語で作業する (このリポジトリの規約文書・コミット・PR・Issue は基本日本語)。ただしこれはメンテナの実践であって強制ではない — どの言語での Issue・コントリビューションも歓迎する。コードの識別子は英語。
