#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 描画に触れる PR に、**絵が載っていること**を要求する (#306)。
#
# CI は絵を描けない (#180・ADR-0019 決定 7 で恒久の決定) ので、新しい絵が正しいかの
# 担い手は人間と AI の目である (ADR-0019 決定 1)。**目に見せるものが無ければ、その
# 担い手は働けない。** しかも squash merge でブランチが消えた後には絵を足せないので、
# 貼られなかった絵は永久に失われる。
#
# それまで担保していたのは PR テンプレートのコメント 1 行だけだった。#302 / #303 に
# 絵が載っているのは作法に従った自発であって、**抜けたときに気付く経路が無かった**。
#
# GPU は要らない — 変更ファイルの一覧と本文の文字列しか見ない。だから CI が絵を
# 描けないことと独立に置ける。
#
# ## 何を見て、何を見ないか
#
# **絵が正しいことは見ない。用意されていることだけを見る。** 正しさの判定は目の仕事で、
# ここが肩代わりできるものではない。防いでいるのは*貼り忘れ*であって、意図的な
# 迂回ではない (ADR-0008 決定 1 — 実害の出ていないものは対象にしない)。
#
# ## 使い方
#
#   bash scripts/check-drawing-evidence.sh [PR番号]   # 省略時は PR_NUMBER → 現ブランチ
#
# 終了コードは 2 つ。**赤くするのは「描画に触れているのに絵が無い」ときだけ**で、
# 判定できない事情 (PR がまだ無い・認証が無い) は理由を述べて 0 で抜ける。手元では
# PR を作る前に make ci-check を打つこともあり、そこで赤くすると入口が塞がる。
#
# **PR がまだ無いブランチでは、作る前に要否を知らせる** (#2153)。origin/main との差を
# 描画のパスに当て、触れるなら絵を本文に載せて作る (絵が変わらないならラベルを付けて
# 作る) よう案内する。これも 0 で抜ける — 案内であって判定ではない。
#
#   0  通過・判定できず・PR を作る前の案内
#   1  描画に触れているのに絵が無い
set -euo pipefail

# 「描画に触れているか」の判定は #304 と共有する (照合の実体は 1 つ・ADR-0001 原則 9)
# shellcheck source=scripts/drawing-paths.sh
. "$(dirname "${BASH_SOURCE[0]}")/drawing-paths.sh"
# 変更ファイルの取り方も 1 つに保つ。**照合の手前が割れていた** (#793) — gh pr view の
# files は上限のある口なので、大きな PR では描画のパスが一覧から落ち、絵の要求が外れる
# shellcheck source=scripts/pr-files.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-files.sh"

# 逃がしのラベル。描画のパスに居るが絵が変わらない変更 (コメントの修正・内部の
# リファクタ) のための例外印で、**読み手はこのスクリプトだけ**である
# (ADR-0005 決定 2 — 読み手のいないラベルは足さない)
readonly ESCAPE_LABEL=no-visual-change

REPO=${GITHUB_REPOSITORY:-}

say() { echo "drawing-evidence: $*"; }
give_up() { say "判定しない — $1"; exit 0; }

# 本文に絵の参照があるか (標準入力)。人間の経路 (入力欄へ落とすと GitHub が
# user-attachments の URL を返す) とエージェントの経路 (.claude/skills/
# visual-evidence — 本線の Gyazo と、退避路である同じ user-attachments) の
# 両方を通す。**広く取る** — 狭いと絵を貼った PR が赤くなり、
# 逃がしラベルで外す癖がついて機構ごと形骸化する
has_evidence() {
  grep -Eqi \
    -e '!\[[^]]*\]\([^)]+\)' \
    -e '<(img|video)[[:space:]>]' \
    -e 'https?://[^[:space:])"]+\.(png|jpe?g|gif|webp|avif|mp4|mov|webm)' \
    -e 'https?://(i\.)?gyazo\.com/' \
    -e 'https://github\.com/user-attachments/'
}

# PR がまだ無いブランチで、作る前に絵とラベルの要否を知らせる (#2153)。
#
# 以前はここで判定ごと放棄していた。描画に触れていると知らされるのが PR を作った後になり、
# no-visual-change を「作成と同時に」付ける規約 (AGENTS.md) を守る手段が無かった —
# 差し戻されてから後付けすると、作成時の run の ci-gate が赤で残る (#2134)。
#
# **照合は drawing-paths.sh の 1 つを使い、材料だけを git から取る。** PR の変更ファイルと
# 同じく分岐点からの差で、コミット前の手元 (追跡ファイルの変更と未追跡のファイル) まで
# 含める — PR を出す前の make ci-check はコミット前にも打たれる。一覧の冒頭が言う
# 「迷ったら広く取る」と同じ向きで、改名も旧新の両方を数える。
#
# git は呼ばれた場所のリポジトリで引き、パスは根からの素の形に揃える。未追跡の一覧は既定で
# 呼ばれた場所からの相対になるので、:/ と --full-name で根から取る。ASCII でない名前は既定で
# 引用符と 8 進に化けて前置きに一致しなくなるので、core.quotePath を切る。分岐点が引けなければ
# 放棄する
preview_without_pr() {
  local base files touched count
  base=$(git merge-base origin/main HEAD 2>/dev/null) \
    || give_up "このブランチに PR が無く、origin/main との分岐点も引けない (git fetch origin main の後か、PR を出した後にもう一度打つと分かる)"
  files=$({
    git -c core.quotePath=false diff --name-only --no-renames "$base" &&
      git -c core.quotePath=false ls-files --others --exclude-standard --full-name -- ':/'
  } 2>/dev/null) \
    || give_up "このブランチに PR が無く、origin/main との差を読めなかった"
  touched=$(printf '%s\n' "$files" | drawing_files)
  if [ -z "$touched" ]; then
    say "このブランチに PR はまだ無い。origin/main との差は描画に触れない — このまま出すなら絵もラベルも要らない"
    exit 0
  fi
  # 早く打ち切る書き方 (| head) は取らない — pipefail の下で SIGPIPE が落ちに化ける
  count=$(printf '%s\n' "$touched" | wc -l | tr -d ' ')
  say "このブランチに PR はまだ無い。origin/main との差のうち $count 件が描画に触れる:"
  sed -n '1,5s/^/  /p' <<<"$touched"
  if [ "$count" -gt 5 ]; then echo "  ほか $((count - 5)) 件"; fi
  cat <<EOF

PR の作成と同時に、before/after の絵を本文へ貼る (gh pr create --body-file に絵の URL を書く。
撮り方は .claude/skills/visual-evidence/SKILL.md)。絵が変わらないなら、作成と同時にラベルを付ける:

  gh pr create --label $ESCAPE_LABEL ...

作った後に貼る・付けると、作成時の run の ci-gate が赤で残ることがあり、そのときは打ち直しが要る。
EOF
  exit 0
}

# 対象の PR。引数 → PR_NUMBER → 現在のブランチ の順に解く
pr=${1:-${PR_NUMBER:-}}
command -v gh >/dev/null 2>&1 || give_up "gh が無い"
gh auth status >/dev/null 2>&1 || give_up "gh が認証されていない"

# **番号も取る。** 変更ファイルは別の口から引くので (#793)、その口に渡す番号が要る —
# 同じ応答から読めるので、リポジトリや PR の解決は増えない
args=(--json "body,labels,number")
# 素の && で足すと、REPO が空のときに全体が 1 を返して set -e が script ごと止める
if [ -n "$REPO" ]; then args+=(-R "$REPO"); fi
if [ -n "$pr" ]; then args=("$pr" "${args[@]}"); fi
# 現在のブランチに PR が無ければ gh は失敗する。それは作業の途中というだけなので、
# 赤くせず、作る前の案内を出して 0 で抜ける (判定は PR を出した後の実行から効く)。
#
# **番号を名指しされたときは差を当てない。** 手元の木がその PR の木とは限らない — CI の
# ジョブは既定ブランチを checkout して PR_NUMBER を渡すので、API が落ちたときに差を当てると
# 「描画に触れない」と答えてしまう。読めなかったとだけ言って放棄する
if ! pr_json=$(gh pr view "${args[@]}" 2>/dev/null); then
  if [ -n "$pr" ]; then give_up "PR #$pr を読めなかった"; fi
  preview_without_pr
fi

if jq -e --arg l "$ESCAPE_LABEL" '.labels[]? | select(.name == $l)' >/dev/null <<<"$pr_json"; then
  say "$ESCAPE_LABEL による例外 PR (絵は変わらないという申告)"
  exit 0
fi

number=$(jq -r '.number' <<<"$pr_json")
# REPO は手元では空 (GITHUB_REPOSITORY が無い)。pr_files が gh のプレースホルダへ倒す
pr_paths=$(pr_files "$REPO" "$number") \
  || give_up "PR #$number の変更ファイルを読めなかった"

if ! printf '%s\n' "$pr_paths" | touches_drawing; then
  say "描画に触れていない PR — 絵は要らない"
  exit 0
fi

if jq -r '.body // ""' <<<"$pr_json" | has_evidence; then
  say "ok: 描画に触れる PR に絵がある"
  exit 0
fi

# **差し戻しの文面が「CI が自動で再評価する」と約束してはならない** (#2134)。本文の編集や
# ラベルの付け外しで新しい run は走り、この検査は付け直される。しかし赤かった run の ci-gate
# は同じコミットに残って必須チェックを赤のままにする。新しい run が緑でも、古い赤が必須
# チェックを固定することがある (#259 の実測)。ラベルを数分以内に後付けする典型の場面では、
# 先の run の ci-gate は macOS の ci-check を待って終わり、labeled の run は ci-check を飛ばして
# 先に緑になる — 終わる順でも固定でも、赤が残る点は同じなので、機構は 1 つに断定しない。
# 「再評価される」と「必須チェックが緑になる」は別である。
#
# 作成と同時に付ければ**通常は**最初の run から通るので、その形を先に案内する。保証では
# ない — gh は PR を作ってからラベルを付けるので (ci.yml の ci-check のコメント)、まれに作成の
# run が先に API を読むと赤くなる。絵を貼る経路 (visual-evidence) は構造的に作成後の本文の
# 編集なので、貼った後も打ち直しが要る。この検査は実行のたびに API から本文とラベルを読む
# ので、打ち直せば通る。当番 (stall-watch) が打ち直すのは同じリポジトリの Draft でない PR だけで、
# fork の PR はメンテナが打つ
cat >&2 <<EOF
drawing-evidence: 差し戻し — 描画に触れる PR の本文に絵が無い

CI は絵を描けません (#180。理由: ADR-0019 決定 7)。**貼られた絵が描画の唯一の検証記録**で、
squash merge でブランチが消えた後には足せません。

次にすること:

  1. before/after を撮って PR 本文に貼る。動きが分からないと正誤を判定できないもの
     (アニメーション・遷移・インタラクション) は、動きの分かる形式で貼る
     - 人間: Issue / PR の入力欄へ画像や動画をそのまま落とす (何も用意が要りません)
     - エージェント: .claude/skills/visual-evidence/SKILL.md の手順で上げ URL を貼る
       (本線は Gyazo。落ちていれば GitHub の添付へ退避する — 切り替えは指示を待たない)
  2. リポジトリには**コミットしない** (生成物・バイナリは持ち込まない — AGENTS.md)
  3. 貼ったあと (本文を編集したあと) も、赤い run があれば、下の打ち直しが要ります

絵を出しようがない変更 (描画のパスに居るが絵は変わらないリファクタ・コメントの修正)
なら、$ESCAPE_LABEL ラベルを付けてください。**PR の作成と同時に付けます**:

  gh pr create --label $ESCAPE_LABEL ...   # 通常は最初の run から通る

gh は PR を作ってからラベルを付けるので、まれに作成の run が先にラベルを読んで赤くなります。
作ってしまった PR には、あとから付けます:

  gh pr edit <番号> --add-label $ESCAPE_LABEL   # または画面から

**打ち直し**: 本文の編集やラベルの付け外しでも新しい run が走って判定は付け直されますが、
赤くなった run の ci-gate (必須チェック) は残って、必須チェックを赤のままにします (古い赤が
新しい緑を固定する場合もあります — #259)。作成時の run の drawing-evidence は、そのとき API 上に
絵もラベルも無ければ赤くなり、ci-gate もそれを受けて赤で終わるためです。絵を貼った・ラベルを
付けたあと、赤い run が終わってから、その run を打ち直してください (赤い run が複数あればそれぞれ):

  gh run rerun ${GITHUB_RUN_ID:-<run-id>} --failed

drawing-evidence は実行のたびに本文とラベルを読み直すので、打ち直せば通ります。同じリポジトリの
PR は、打たなくても stall-watch の当番がいずれ打ち直します (数時間おき・Draft を除く)。
fork の PR は当番の対象外なので、メンテナが打ちます。
pr-title も赤い run は、打ち直すと元のタイトルを再生して同じ赤を返します (#699) — タイトルを
直したうえで、新しいコミットを push して run を作り直してください。
EOF
exit 1
