<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# エージェントの開発環境

規約は [AGENTS.md](../AGENTS.md)。macOS / Apple Silicon 上で `make setup` を実行し、
不足する道具は出力に従って用意する。検証の入口は `make ci-check` (手元で回す範囲は AGENTS.md「コミット・PR の規約」)。

## スキル

Claude Code は従来どおり `.claude/skills/` を読む。Codex は `.agents/skills/` の相対リンク
から同じ3本を読む。root・サブディレクトリ・worktree のいずれでもリポジトリ内で完結する。
リンクを含めて checkout する。別のエージェントでは AGENTS.md の「場面別の入口」から本文を
読む。スキルを個人ディレクトリへコピーしない。

## 認証と証跡

エージェントを起動する環境から `gh auth status` を確認する。PR もその認証 (メンテナ自身) で
作る (AGENTS.md「コミット・PR の規約」)。証跡用の `MOKUME_GYAZO_TOKEN_CMD` は、
利用する秘密管理から取得するコマンドを起動環境で渡す。
値や秘密の在処をリポジトリに書かない。署名の自動検出が効かない環境は
`MOKUME_AGENT_NAME` (必要なら `MOKUME_AGENT_URL`) を明示する。

絵・動きの確認はローカルの Mac で行う。[visual-evidence](../.claude/skills/visual-evidence/SKILL.md)
の前提を確かめ、窓を撮る場合の画面収録権限は利用するアプリに付与する。
利用できる MCP やブラウザの道具は製品ごとに異なる。手順を読めることと、その道具が接続済み
であることは別である。

## フック

Claude Code の接続は `.claude/settings.json`。Codex の接続は `.codex/config.toml`。
どちらもコメントの同じスクリプトを呼ぶ。各製品の設定を読み替えない。

Codex はプロジェクトを信頼し、さらにフックを確認して信頼した場合にだけ動かす。
CLI では `/hooks` で読込元と信頼状態を確認する。変更後のフックも再確認が必要になる。
未信頼のプロジェクトの設定は読み込まれない。一時的な `projects.trust_level` の CLI 指定で
導入済みとは扱わず、製品の信頼操作を使う。個人設定をこのリポジトリから書き換えない。

Codex CLI 0.158.0-alpha.2.1 のシェル実行 (`exec_command`) とコード実行 (`exec` 内の
`tools.exec_command`) は `Bash` としてフックへ届く。入力は `tool_input.command` であり、
既存ガードを直接呼べる。MCP 経由の投稿や任意の外部 API 全体を覆うものではない。
コマンドの認識は Claude Code と同じスクリプトが持つので、判定の範囲も同じである。
`gh` の手前の予約語・リダイレクト・環境変数の代入・`env`・パスや引用・行継続
(`for …; do gh`・`PATH=… gh`・`/opt/homebrew/bin/gh`・`gh \`) も認識し、前置の
`GH_REPO` / `env -u` / `env -i` は宛先の判定に渡す (#1729)。`gh` より前に文としての
`cd`・`pushd`・`popd`、
`GH_REPO` を変える文 (`export GH_REPO=`・`unset GH_REPO`・`read GH_REPO`・`for GH_REPO in …` など)、
git がリポジトリを探し remote を読むのに効く変数 (`GIT_DIR`・`GIT_COMMON_DIR`・`GIT_CONFIG_GLOBAL`
など) があれば、宛先は値を追わずに「決められない」として止める側へ倒す (`builtin` / `command` の
後ろも読む。ループの本体では gh の後ろの文も効くものとして読む)。値が実行時に決まる `-R "$X"` も
同じく止める側である。逃げ道は `-R owner/repo` の明示である (#1823)。
`sudo` など別のコマンドを起動するコマンドの後ろの `gh` と、`$GH` のように実行時に
決まる語は追わない (範囲の線は `scripts/guard-lib.sh` の冒頭)。
別の版では読込と実際の発火を確かめる。
フックを提供しない環境でも、Issue へのプラン記録・コメントのラッパーは
AGENTS.md に従って実行する。フックが黙っていることを検証済みの印にしない。
個人のプラグイン・モデル・権限設定はこのリポジトリから変更しない。

## Desktop の CI モニタ (Auto-fix)

Claude の desktop アプリは、セッションに結び付いた PR の CI の失敗・main との衝突・
レビューコメントを受けて同じセッションを起こし、直して push させる (PR ごとの Auto-fix)。
これは [ADR-0017](decisions/0017-agent-support-locality.md) 決定 3 が言う「リポジトリの外の、
設計を知らない機構」に当たる。mokume は CI の見届けを要求しない。見届けが拾うべき赤は
merge queue と `stall-watch` で足りている (#377)。外の見張りが当時の承認待ちを異常と読んで
空回りした前例もある (#194)。使うかどうかは使う人が決める。

ON にするなら、次の赤と状態は**コードを直して push しても消えない** (#1994)。
直す先は右の列で、迂回はしない。

| 赤・状態 | 直す先 |
| --- | --- |
| `review-gate` (確認方法の対応表・反証の節・`CHANGES_REQUESTED`) | PR 本文と、レビュアーとのやりとり。判定は main の版のスクリプトで走るので、PR の中で判定を書き換えても消えない ([ADR-0031](decisions/0031-triage-as-the-single-gate.md) 決定 2)。直したあと、赤い run があれば `gh run rerun <run-id> --failed` で打ち直す (新しい run は判定を付け直すだけで、赤い run の `ci-gate` は残る — `ci.yml` の `ci-gate` の上のコメント) |
| `drawing-evidence` | 絵を PR に載せる。絵が変わりようのないときだけ `no-visual-change` を、PR の作成と同時に付ける。載せた (付けた) あと、赤い run があれば `gh run rerun <run-id> --failed` で打ち直す (同上) |
| `pr-title` | タイトルを直し、新しいコミットを push して run を作り直す。rerun しない (元のタイトルを読んで同じ赤を返す — `stall-watch.sh` の読み分け表の 6) |
| `render-pr` が見送られた・cancel された | 必須ではないので直すものは無い。rerun しない — 門番を通らずに専用機へ積まれ、merge queue の `render` と取り合う (#2062)。要るなら queue が空いてから push し直す |
| `render` の台帳の不一致 | 2 回描いても一致しないなら決定論が壊れている。台帳を書き換えて消さない ([ADR-0019](decisions/0019-drawing-verification.md) 決定 3) |
| `BEHIND` | 何もしない。"Update branch" を押すと auto-merge だけが外れる |

直してよいのは、check が 1 本も付かない本物の衝突 (AGENTS.md「マージの判断基準」) と、
コードの不具合による `ci-check` の赤である。後者は再実行の前に `.build/test-log.txt` を
退避する。

## プランの明示登録

Codex では、実装前に対象 Issue と完了条件の現況を含むプラン本文を一時ファイルへ書き、
次を実行する。`CODEX_THREAD_ID` が空なら実際のセッションIDを確認する。代用のIDを作らない。

```bash
bash scripts/plan-record.sh register --agent codex --session "$CODEX_THREAD_ID" --body-file /tmp/plan.md
```

説明を読み、表示された `scripts/comment.sh` で投稿する。終了コード2は投稿の指示にも
入力の差し戻しにも使うため、成功と決めつけない。投稿そのものをフックは代行しない。
有効な Stop フックは同じworktree・Codexセッションで登録された未投稿のプランを確認する。
未登録のプランは検出しない。Claude の ExitPlanMode と capture/guard は従来どおりである。

他のエージェントは `--agent` と `--session` を明示し、作業終了時に `check` を実行する。
Codex でもフック非対応・未信頼なら同じ確認を手で行う。

```bash
bash scripts/plan-record.sh check --agent codex --session "$CODEX_THREAD_ID"
```

記録はworktree・agent・sessionごとに分離する。再開は同じID、別のセッションへの引き継ぎは
GitHub の投稿を読む。入力・終了コードの詳細は `bash scripts/plan-record.sh --help` を参照する。

明示登録の投稿前の一時材料は `.build/mokume-plan-records/` に置く。`.git` の保護を緩める
必要はない。`.build` を消した場合は再登録する。経過の正典は投稿先の GitHub であり、
ローカルの記録だけを引き継ぎに使わない。

## 使い捨ての Draft PR (専用機の計測・CI の条件式の検証)

専用機には SSH で入れない (#1767)。専用機で測る手段は、使い捨ての Draft PR に計測の
ワークフロー (`runs-on: [self-hosted, mokume-render]`) を足し、CI で走らせて artifact を
取ることだけである。CI の条件式 (`if:`) も、本体の PR では確かめられない。作成後すぐ merge
queue に入り、base を変えると queue から外れるうえ、actionlint は式の構文と型しか見ない。
どちらも main から切った使い捨ての Draft PR で行う。前例は、専用機の計測が #1922
(`.github/workflows/cost-probe-1813.yml`)、別の枝の振る舞いを hosted の CI で見る検証が #1919、
条件式が #1861 (空コミットの Draft で base を切り替え、#1852 の `if` を確かめた)。

始める前に、専用機が空いているかを見る (runner の一覧はメンテナの権限が要る)。
`busy` が `true` か queue に entry があるなら、計測のジョブは待たされる。

```bash
gh api repos/mokume-metal/mokume/actions/runners --jq '.runners[] | [.name, .status, .busy] | @tsv'
gh api graphql -f query='{repository(owner:"mokume-metal",name:"mokume"){mergeQueue(branch:"main"){entries(first:10){totalCount}}}}' --jq '.data.repository.mergeQueue.entries.totalCount'
```

1. **Draft のまま置き、queue に入れない。** `git push -u origin HEAD` のあと
   `gh pr create --draft --label no-issue` で作る (ラベルは作成と同時に付ける)。本文の先頭に
   「使い捨て。マージしない・auto-merge を掛けない」と書く (#1922)。Ready にしない・
   `gh pr merge --auto` を打たない。入れると、計測のワークフローや検証用のコミットが main へ
   入る。AGENTS.md「マージの判断基準」の「queue に入れてよい」は、この PR には当てはまらない。
2. **起動した `render-pr` と `CI` を、作った直後と push のたびに取り消す。** hosted の `CI`
   (macOS の `ci-check`・`test-release`) は Draft でも起動する。`Render` の `render-pr` は
   Draft では skipped だが (render.yml の `!github.event.pull_request.draft`)、Ready の間は
   専用機に積まれ、計測が待たされる (#1922 では起動した `render-pr` を取り消した)。
   `gh run list --branch <枝>` で run を見つけ、`gh run cancel <run-id>` で取り消す。反映に
   30 秒ほどかかる。取り消すのは計測のワークフロー以外である。計測のワークフローには、
   render.yml と同じ `if: github.event.pull_request.head.repo.full_name == github.repository`
   と、push し直したら古い実行を捨てる `concurrency` (`cancel-in-progress: true`) を置く。
3. **計測は 1 本ずつ走らせる。** テストは `swift test --filter "Suite/test"` を 1 本ずつ
   順に回す (#1922 の `for` ループ)。Swift Testing は既定で並列に走り、同じプロセスの
   `getrusage` と符号化のプロセス (`VTEncoderXPCService`) の CPU は、機械上の他のテストや
   他のセッションの符号化と混ざる。M3 Max では同じ計測が日によって食い違った (RGB 乱数
   1920×1080 の CPU 比が 36 倍と 22 倍・#1813)。専用機は 1 台で merge queue の `render` と
   共有なので、計測の PR も同時に複数立てず、上の確認で空いてから始める。ジョブが 20〜40 分
   待たされることがあるので、結果を待つ側には期限を付ける。結果は
   `gh run download <run-id> -n <artifact 名>` で取る。
4. **base の切り替えは `gh api -X PATCH` で行う。** 条件式の検証では、空コミットだけの Draft
   (重要パスに触れない) を作り、main と同じ SHA の一時ブランチへ base を向け、main へ戻す。
   `gh pr edit --base` は GraphQL のエラーになる (#1861 で踏んだ)。切り替えのたびに `edited`
   の run ができる。`changes.base` が効いて `ci-check`・`test-release` が積まれる
   (skipped にならない) ことを、本文だけの編集 (対照・skipped になる) と並べて読む。
   読み終えた macOS のジョブは 2 と同じく取り消す。

   ```bash
   SHA=$(git rev-parse origin/main)
   git push origin "${SHA}:refs/heads/tmp/base-switch-<N>" # zsh では波括弧が要る ($SHA:refs の :r が修飾子になる)
   gh api -X PATCH repos/mokume-metal/mokume/pulls/<PR 番号> -f base=tmp/base-switch-<N>
   gh api -X PATCH repos/mokume-metal/mokume/pulls/<PR 番号> -f base=main
   gh run view <run-id> --json jobs --jq '.jobs[] | [.name, .conclusion] | @tsv'
   ```

5. **使い終えたら close して枝を消す。** 結果は置き場 (Issue か本体の PR) に載せ、この PR に
   閉じる旨を `bash scripts/comment.sh pr <番号> --body-file <ファイル>` で書いてから
   `gh pr close <番号>` で閉じる。**worktree から `gh pr close --delete-branch` を打たない。**
   gh が main へ切り替えようとして (main は別の worktree が使用中で) 失敗し、PR は閉じても
   枝が残る。枝は `git push origin --delete <枝>` で消す。一時ブランチ
   (`tmp/base-switch-<N>`) も同じである。消えたことは `git ls-remote --heads origin <枝>` が
   空なことで確かめる。
