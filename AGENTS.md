# AGENTS.md

このリポジトリで作業する AI エージェントと人間に等しく効く規約の正典 (ADR-0001 原則 9)。ADR の書き方だけは `docs/decisions/AGENTS.md` が持つ。決定の根拠は ADR、経緯と実測は Issue / PR、機構の内部と手順はスクリプトの冒頭コメントと `--help` にある。

## プロジェクト

mokume は macOS / Apple Silicon 専用のクリエイティブコーディング環境 (Swift + Metal)。宣言的・フレームベースのスケッチ API を提供する。

## 正典の在処

| 対象 | 正典 |
| --- | --- |
| 設計判断 | [`docs/decisions/`](docs/decisions/) の ADR (土台は ADR-0001)。書く・直す前に同じディレクトリの `AGENTS.md` を読む |
| プロセスの外とやりとりする JSON の形式 | `Schemas/` の JSON Schema。実装が従い、代表例との照合を `make ci-check` が見る (ADR-0018) |
| 作業の経過・発見・残タスク | GitHub の Issue / PR (ローカルファイルやセッションの記憶に残さない) |

## 進め方

1. 変更は Issue の起票から始める。起票は雑でよい (書式不要・型は機械がタイトルから下書きする)。複数工程は親 Issue + sub-issue にし、本文のチェックリストは使わない。未トリアージの Issue の完了条件を調べて本文に書くところまでは、着手を待たずにしてよい (ラベルは付けない。手順は `.claude/skills/stock-triage/`)
2. **着手できるのは `verify: triaged` が付いた Issue だけ。** 付いていなければ、議論して「どうなれば解消か」を本文に固めるところから始める。ラベルを付けられるのは完了条件を知っている起票者だけで、他人が書いた Issue には付けない。エージェントも、自分で起票して完了条件を書いた Issue には付けてよい (ADR-0002 決定 1 の追補・ADR-0031 決定 1)
3. 着手時に各完了条件を現行のコードと突き合わせ、「まだ有効」「既に満たされている」「差し替えが要る」のどれかをプランに書く。ずれていれば先に Issue 本文を直す (ADR-0031 決定 4)
4. そのプラン (変更点・確認方法) を対象 Issue にコメントする。実装中に変わったら差分をコメントする (PR を出した後なら PR 側へ)
5. `main` から `<type>/<短い説明>` ブランチを切る
6. PR を出す。本文は 目的 / 変更点 / 確認方法。「確認方法」には、閉じる Issue ごとに完了条件と、それを何でどう確かめたかの対応表を置く (ADR-0031 決定 2)。`Closes #N` は PR 本文に書く (squash merge ではコミット側の記述が GitHub に届かない)。Issue を閉じない例外 PR には `no-issue` を付ける
7. マージは squash だけ (「コミット・PR の規約」)

Claude Code のセッションでは、手順 3・4 を `scripts/plan-record.sh` が見る。

作業中に踏んだ問題は、起票の時点で行き先まで決める (ADR-0036 決定 6)。分けるのは完了条件を自分で書けるかどうかだけ:

| 踏んだもの | 行き先 |
| --- | --- |
| その PR の説明で筋が通る | 起票して、その PR で閉じる (既定) |
| 筋は通らないが、完了条件は書ける | 起票し、完了条件を本文に書いて `verify: triaged` まで付ける |
| 完了条件を書けない (設計・判断が要る) | ラベルなしで置き、メンテナの判断を待つ |

ラベルは起票と同時に付ける。エージェントの起票も後からはメンテナ名義に見えるので、後回しにすると誰も着手できない Issue になる。

## Issue の分類

何の仕事かは GitHub の Issue Type で表し、1 Issue に 1 型 (ADR-0004): `Bug` (期待と違う挙動) / `Feature` (新機能・拡張) / `Task` (保守・整備・CI・リファクタ) / `Design` (設計判断・ADR) / `Docs` (ドキュメント)。迷ったら `Bug` > `Design` > `Docs` > `Task` の順で、より具体的なほうを取る。ラベルは型と直交する属性 (`status: *`・`verify: triaged`) だけを表す。検索は `type:"Design"` と引用符を付ける (旧来の `type:issue` と衝突する)。

## PR のラベル

PR には分類ラベルを付けない (ADR-0005)。付くのは CI の判定を変える 3 種だけ:

| ラベル | 意味 | 読む側 |
| --- | --- | --- |
| `no-issue` | Issue を閉じない例外 PR | `scripts/review-gate.sh` |
| `release:now` | 壊れた配布物をその場で出し直す | `.github/workflows/release.yml` |
| `no-visual-change` | 描画のパスに触れるが絵は変わらない | `scripts/check-drawing-evidence.sh` |

新しい PR ラベルは、それを読むスクリプトと同時にしか足さない。

## マージの判断基準

PR 本文が揃い `ci-gate` が green なら、指示を待たず `gh pr merge --auto --squash` で merge queue に入れてよい。queue が合流後の姿で再検証するので、CI を見張って手で merge しない。マージ後は main に戻って pull する。

承認が要るのは重要パス (`docs/decisions/`・`.github/`・`.claude/`) を触る PR だけで、`.github/rulesets/main-protection.json` が maintainers への 1 承認を求める。承認が要る PR でも先に `--auto` を掛けておく (予約はゲートを越えないので、メンテナの操作が Approve 1 回で済む)。承認は native の Approve レビューだけ。

- **`BEHIND` でも "Update branch" は押さない。** 追随しても得るものが無く、auto-merge だけが外れる。例外は描画 PR の `local-render` が failure のとき (「描画に影響する変更」)
- check が 1 本も付かないのは、まだ来ていないのではなく main と衝突している。`git merge-tree --write-tree origin/main HEAD` で確かめ、手元で解いて push する

## コメント

置き場は、PR ができるまでは Issue、できてからは PR。例外は 3 つで、完了条件が動く話は Issue、完了報告は Issue に 1 通 (「条件 N は PR #M で満たされた」の対応表まで)、恒久的な決定は ADR (ADR-0002 決定 6)。PR を作ったときに Issue へ「実装 PR は #N」とは書かない (`Closes #N` から GitHub が相互リンクを描く)。

AI エージェントのコメントは、署名を自動で付けるラッパーで投稿する (署名を判定できない環境では `MOKUME_AGENT_NAME` で指定する):

```bash
bash scripts/comment.sh issue <番号> --body-file <ファイル>
bash scripts/comment.sh pr    <番号> --body "<本文>"
```

`gh pr review` の本文と、close / reopen の `--comment` も同じ扱いにする。close / reopen は 2 手に分け、発言をラッパーで投稿してから、状態だけを発言なしで変える。他のリポジトリへは素の `gh` で書く。同じ org の外のパッケージへは、署名の 1 行を同じ形で付ける (ADR-0026 決定 4)。人間が直接書く分にはラッパーは要らない。

## エージェントの identity

maintainers team の人とその人が動かすエージェントは、PR を GitHub App の identity で作る (ADR-0003)。token は次の形で発行する:

```bash
GH_TOKEN="$(bash scripts/gh-app-token.sh)" && export GH_TOKEN && git push -u origin HEAD && gh pr create …
```

- 代入から始め、後続まで `&&` で繋ぐ。`export GH_TOKEN="$(...)"` の形は発行の失敗を握り潰す
- push は `-u` を付ける。`origin/main` を追跡しているブランチは `git branch --unset-upstream` してから押し直す
- 手で揃える設定は `MOKUME_APP_PRIVATE_KEY_CMD` (App の秘密鍵 PEM を標準出力に出すコマンド) だけ。秘密鍵の中身も在処もリポジトリに書かない。未設定でも「鍵が無い」と即断せず、手元の秘密管理の「自動化から読んでよい秘密の一覧」をまず引く (ADR-0007 決定 5)。一覧にも無ければ PR を作らず、鍵の渡し方を人に尋ねる
- **承認が要る変更は App identity の PR で入れ、token を発行できないときは PR を作らない。** メンテナも例外にしない。自分の PR は自分で承認できないので、メンテナ名義の PR は誰も承認できなくなる。要否は作成前に決まらないので一律に使う (ADR-0007 決定 2)。外部の人は自分の名義で作ってよい
- コミットの author と署名はメンテナのまま。分けるのは PR を作る主体だけで、push の主体は問わない

**フックが黙っていることを安全と読まない。** 素の `gh` でのコメント (`scripts/agent-comment-guard.sh`) と、この形を外れた PR 作成 (`scripts/pr-identity-guard.sh`) はフックが差し戻すが、フックはこのリポジトリを主として開いた Claude Code のセッションでしか効かない。それ以外では、この節と「コメント」を自分で守る (ADR-0007 決定 3)。

## コミット・PR の規約

- Conventional Commits: `<type>(<scope>): <要約>`。type は feat / fix / docs / refactor / test / chore / ci / perf / build。type と scope は英語、要約は日本語でよい。PR タイトルがそのまま squash のマージコミットになるので、同じ形で書く
- 1 コミット 1 関心。1 PR は「1 つの説明で筋が通る範囲」で、同じ親の sub-issue 群や、作業中に踏んで起票した障害もまとめて閉じてよい (ADR-0031 決定 3)
- **検証は `make ci-check` に集約し、push 前に通す。これは merge の条件である。** 全部通ったときだけ `local-render` が commit status に報告され、描画に触れる PR はそれが無いと merge できない (報告されないときは理由が出る。多いのは作業ツリーが汚れたまま実行した場合)
- 何が走ったかの正本は `.build/test-results-swift-testing.xml` で、端末出力ではない (行を落とす)。赤を見たら、実行し直す前に `.build/test-log.txt` を退避する (実行し直すと記録が切り詰められる)
- 性能は release で測る。debug の数字を性能の根拠にしない。入口は `make test-release` の 1 つ
- ユーザー影響のある変更は `changelog.d/` に断片を 1 つ置く (CHANGELOG を直接編集しない)
- 検査の「待たない」は待つ側が持つ。`.timeLimit` は使わない。検査はすべて main actor に載るので、どんな値も検査全体が何秒で終わるかを要求してしまう。固まりうる待ちには、待つ側が期限を持たせて越えたら殺す

## してはならないこと

- 生成物・バイナリ (画像・動画・モデル) をコミットしない。視覚的な証跡は外部に上げて URL で参照する
- 帰属 (著作権・ライセンス) の不明なファイルを持ち込まない。第三者素材は正確な帰属の宣言と同時にだけ入れる
- 想定だけの API を先回りで作らない。機能は、このリポジトリの外で作る作品で実際に踏んだ必要から正当化し、その入口は `Feature` 型の Issue だけ (`Sketches/` で踏んだものは数えない)。このリポジトリは作品を参照しない。作品で踏んだバグは `Bug` で起票し、再現はこのリポジトリの中の最小のスケッチかテストに落とす (ADR-0001 原則 4・ADR-0022)
- 新しいゲート・検査・hook・ラベル・ワークフローは、塞ぐ実害を Issue 番号で示せるときだけ足す。「あると良さそう」なら起票して待たせる (消すほうには実害を求めない)。足すと決めても、既存の責務を広げる / native の機能で済ませる / 置き換える、の順に検討し、選んだ段を PR 本文に書く。コードの写しを畳むのも部品を足すことに数える (ADR-0008 決定 1・5・6)

## 描画に影響する変更

描画結果・動きが変わる PR には before/after の視覚的証跡を載せる (動きは動きの分かる形式で)。**CI は描画を走らせられないので、緑は「描けている」を意味しない。** 貼られた絵が唯一の検証記録で、squash merge の後には足せない。`scripts/drawing-paths.txt` に載る場所を触った PR に絵が無ければ `drawing-evidence` が赤になる (見るのは絵があることだけ — ADR-0019 決定 1)。絵が変わりようのない変更には `no-visual-change` を付ける。

**main の絵に関わるファイルは、常に誰かが手元で実際に回して確かめた組み合わせのままに保つ** (merge queue での判定は `scripts/render-status.sh` の冒頭)。書き手が守ること:

- 作業中の描画 PR は Draft にする。描画 PR は 1 本ずつ (queue の外では番号順に) 入るので、作業中の PR が完成した後続を待たせる
- queue から弾かれたら `make catch-up` を実行する (main の取り込み → `make ci-check` → `--auto` の掛け直しを 1 手にしたもの。手順は `scripts/catch-up.sh` の冒頭)。実行する前に、queue に居るかを `isInMergeQueue` で見る (`autoMerge: false` は queue に入った後も出る)
- 取り込みは手元だけで済ませ、push しない。push は承認を落とす (#612)。例外は衝突を解いた合流だけ

見た目・動きの事象を Issue に立てるときも証跡を添える (壊れた絵は起票の時点でしか撮れない)。上げ先は問わず、Issue / PR の入力欄へ画像や動画を落とせば GitHub が保管する。エージェントの撮り方と上げ先は `.claude/skills/visual-evidence/` が持つ。

## 場面別の入口

毎回は要らない規律。その場面で読む:

| 場面 | 規律と読む先 |
| --- | --- |
| 止まって見えるときの読み分け | `bash scripts/stall-watch.sh` (読み取りのみ・冒頭に症状と対処の表)。数時間おきに定期実行もされ、機械で直せるものは直す。対象から外すなら Draft にする |
| 版の出方 | 版は日に 1 度自動で出る (タグと GitHub Release だけで表す)。壊れた配布物を出し直すときだけ PR に `release:now` を付ける。上げ幅は `scripts/release.py` の冒頭 |
| ブランチ保護の正本 | 正本は `.github/rulesets/*.json` (ADR-0006)。管理画面ではなく定義ファイルの PR で変え、merge 後の適用 (`scripts/apply-rulesets.sh --apply`) はメンテナが行う。必須チェックを消すときだけ適用を merge より先にする (消す PR 自身がそのチェックを満たせなくなる) |
| sub-issue の使い方 | `scripts/sub-issue.sh <親番号> <タイトル>` で作る。階層は 2〜3 段までにし、独立した Issue を無理にツリーにしない。open の子を残して親を畳むなら not planned で close する (completed だと Parent guard が開き直す) |
| 進捗の公開ロードマップ | Org の Project「mokume Roadmap」は Issue の投影で、項目の出し入れは手でしない。人が触るのはフェーズ親 Issue の Start / Target だけで、Iteration・Milestone・独自の status は足さない |
| 手元に残ったプロセス | `bash scripts/orphan-processes.sh` が出所つきで一覧する。止めるかどうかは人が決める |
| エージェント環境の設定 | `.claude/` の支援 (スキル・hooks・設定) を足す・外すときは ADR-0017 を読む |
| 無人セッションの起動 | 起動する側が `MOKUME_UNATTENDED=1` を立てる (ADR-0036 決定 2。何が変わるかは `scripts/plan-record.sh` の冒頭) |
| 外のパッケージ | この文書がどこまで効くかは ADR-0026 決定 1 |

## 言語

メンテナは日本語で作業する (規約文書・コミット・PR・Issue)。強制ではなく、どの言語の Issue・コントリビューションも歓迎する。コードの識別子は英語。
