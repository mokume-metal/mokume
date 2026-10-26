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
#   bash scripts/check-drawing-evidence.sh --issue-body <本文のファイル>   # Issue の本文 (#2195)
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
# 本文のコードブロックの中の行を生きた行と読まない規則も 1 つに保つ (#2816)
# shellcheck source=scripts/markdown-live.sh
. "$(dirname "${BASH_SOURCE[0]}")/markdown-live.sh"

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
#
# **コードブロックの中は数えない** (#2816)。書式の見本として載せた `![](…)` や URL は GitHub が
# 絵として描かないので、絵を貼ったことにならない。変数へ受けてから読むのは、grep -q が先に
# 抜けて書き手が SIGPIPE で止まり、判定が裏返るのを避けるため (#1900)
has_evidence() {
  local live
  live=$(markdown_live_lines)
  grep -Eqi \
    -e '!\[[^]]*\]\([^)]+\)' \
    -e '<(img|video)[[:space:]>]' \
    -e 'https?://[^[:space:])"]+\.(png|jpe?g|gif|webp|avif|mp4|mov|webm)' \
    -e 'https?://(i\.)?gyazo\.com/' \
    -e 'https://github\.com/user-attachments/' <<<"$live"
}

# PR がまだ無いブランチで、作る前に絵とラベルの要否を知らせる (#2153)。
#
# 以前はここで判定ごと放棄していた。描画に触れていると知らされるのが PR を作った後になり、
# no-visual-change を「作成と同時に」付ける規約 (AGENTS.md) を守る手段が無かった —
# 当時は、差し戻されてから後付けすると作成時の run の ci-gate が赤で残った (#2134)。作法の
# 検査が ci-gate を離れた (#2669) 後は、後付けでも pr-gate が付け直す。作る前に分かれば、赤を
# 一度も出さずに済む。
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

作った後に貼る・付けても pr-gate が付け直す (必須は新しい run の結論を読むので、打ち直しは要らない)。
作成と同時なら赤が一度も出ない。
EOF
  exit 0
}

# Issue の本文を見る (#2195)。PR の判定と違って変更ファイルが無いので、**本文が描画の
# ファイルを名指ししているか**で「見た目・動きの Issue か」を決める。名指しは 2 つの形を数える:
#
#   - 描画のパスの前置きを持つパス (Sources/MokumeCore/Drawing/Canvas.swift)
#   - 描画のパスの下で追跡しているファイルの名前 (Shapes.metal・Canvas+Shape.swift)。
#     描画の外にも同じ名前がある名前 (main.swift など) は数えない
#
# 実測 (#2195) では、絵の無い見た目・動きの Issue 19 件のうち 16 件がこれで拾え、
# それ以外の 60 件で拾ったのは 9 件だった。拾ったのに絵が変わらない Issue は、宣言の
# 1 行 `絵: なし — <理由>` で通す (PR の no-visual-change に当たる)。行の形を固定して
# いるのは、宣言が例外の域を出ていないかを grep で数えられるようにするため。
#
# 読み手は scripts/issue-evidence-guard.sh (エージェントの gh issue create / edit)。
#   0  通過 (絵がある・宣言がある・描画のファイルを名指ししていない)
#   1  描画のファイルを名指ししているのに、絵も宣言も無い (理由の空の宣言を含む)
readonly DECLARATION='絵: なし'

mentioned_drawing_files() { # 標準入力 = 本文
  local body root tracked inside names
  body=$(cat)
  root=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null) || return 0
  tracked=$(mktemp) inside=$(mktemp) names=$(mktemp)
  git -C "$root" -c core.quotePath=false ls-files > "$tracked"
  drawing_files < "$tracked" > "$inside"
  # 名前ごとに「描画の下に居る」「外に居る」を数え、下にだけ居る名前を残す
  awk 'FNR == NR { inside[$0] = 1; next }
       { name = $0; sub(/.*\//, "", name); if ($0 in inside) yes[name] = 1; else no[name] = 1 }
       END { for (name in yes) if (!(name in no)) print name }' "$inside" "$tracked" > "$names"
  {
    # パスの形 (前置き) は本文の語を drawing_files に通す
    grep -oE '[A-Za-z0-9_./+-]+/[A-Za-z0-9_./+-]+' <<<"$body" | drawing_files
    grep -oFf "$names" <<<"$body"
  } | sort -u
  rm -f "$tracked" "$inside" "$names"
}

check_issue_body() { # $1=本文のファイル
  local body live mentioned
  body=$(cat "$1" 2>/dev/null) || give_up "本文 $1 を読めなかった"
  if has_evidence <<<"$body"; then
    say "ok: Issue の本文に絵がある"
    exit 0
  fi
  # 宣言もコードブロックの中の見本は数えない (#2816)。名指しの拾い (mentioned) は広く取る側
  # なので、コードブロックの中のファイル名も拾ったままにする
  live=$(markdown_live_lines <<<"$body")
  if grep -Eq "(^|[[:space:]])${DECLARATION}([[:space:]]|$)" <<<"$live"; then
    if grep -Eq "(^|[[:space:]])${DECLARATION}[[:space:]]*(—|--?)[[:space:]]*[^[:space:]]" <<<"$live"; then
      say "ok: 絵は無いという宣言がある"
      exit 0
    fi
    cat >&2 <<EOF
drawing-evidence: 差し戻し — 「${DECLARATION}」の宣言に理由が無い

宣言は 1 行で理由を添えます: ${DECLARATION} — <絵にして示せない理由>
EOF
    exit 1
  fi
  mentioned=$(mentioned_drawing_files <<<"$body")
  if [ -z "$mentioned" ]; then
    say "描画のファイルを名指ししていない Issue — 絵は要らない"
    exit 0
  fi
  cat >&2 <<EOF
drawing-evidence: 差し戻し — 描画のファイルを名指しする Issue の本文に絵が無い

名指ししているもの:
$(sed -n '1,5s/^/  /p' <<<"$mentioned")

見た目・動きの Issue は、絵があるとぱっと見で分かります (AGENTS.md「描画に影響する変更」)。
数値の表だけでは、読み手が頭の中で絵を組み立てることになります。

  - 再現を draw() の本体に書けるなら、1 コマンドで撮って貼れる Markdown が出ます:
      python3 scripts/example-shots.py --snippet repro.swift --size 160x120 --zoom 4 --upload \\
        --token-command "\$MOKUME_GYAZO_TOKEN_CMD"
    (1 画素の継ぎ目・透けは --zoom で最近傍に拡大する。動きは --frames)
  - 窓・GUI を見せるなら .claude/skills/visual-evidence/SKILL.md の経路 B

絵にしようがない (クラッシュ・数値の取り扱い・コードを読んだだけで再現の形が未定 など) なら、
本文に 1 行を足して通します:

  ${DECLARATION} — <理由>
EOF
  exit 1
}

if [ "${1:-}" = --issue-body ]; then
  [ -n "${2:-}" ] || { echo "usage: $0 --issue-body <本文のファイル>" >&2; exit 2; }
  check_issue_body "$2"
fi

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
#
# **読めなかった理由 (gh の stderr) は捨てずに添える** (#2614)。放棄して 0 で抜ける振る舞いは同じ
#
# **番号を名指しされたときは、pr-gate の先頭が取った事前取得を読める** (#3261。無ければ
# gh pr view と同じ)。名指しが無い (手元) 経路は今までどおり gh を直に呼ぶ
pr_err=$(mktemp)
if [ -n "$pr" ]; then
  fetch_pr_json() { pr_view_json "$REPO" "$pr" "body,labels,number"; }
else
  fetch_pr_json() { gh pr view "${args[@]}"; }
fi
if ! pr_json=$(fetch_pr_json 2>"$pr_err"); then
  why=$(tr '\n' ' ' <"$pr_err" | sed -e 's/[[:space:]][[:space:]]*/ /g' -e 's/ $//')
  rm -f "$pr_err"
  if [ -n "$pr" ]; then give_up "PR #$pr を読めなかった (${why:-gh は理由を出さなかった})"; fi
  preview_without_pr
fi
rm -f "$pr_err"

if jq -e --arg l "$ESCAPE_LABEL" '.labels[]? | select(.name == $l)' >/dev/null <<<"$pr_json"; then
  say "$ESCAPE_LABEL による例外 PR (絵は変わらないという申告)"
  # 絵は求めない。ただ「変わらない」は「見せるものが無い」ではないので促す (#2195)
  if ! jq -r '.body // ""' <<<"$pr_json" | has_evidence; then
    say "絵が変わらなくても、見て分かるもの (窓の振る舞い・出力・いまの絵) があれば本文に載せると伝わりやすい"
  fi
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

# 差し戻しの文面。この検査は pr-gate (.github/workflows/pr-gate.yml) の中で走る。絵を貼る
# (本文の編集)・ラベルを付けると pr-gate の新しい run が作られ、必須は作成順で最新の run (check
# suite) の結論を読む (規則は scripts/ci-gate.sh 冒頭の「必須の判定が読む check run」・#2577)。直した
# 後の run はその出来事の後に PR を読むので、打ち直しは要らない (#2668 の probe)。pr-gate は
# concurrency を持たないので run は打ち切られない (#2716)。例外は手で cancel した run が最新の suite に
# 残ったときで、stall-watch が stale-gate と名乗り、打ち直す run を出す。打ち切られた run は文面を
# 出さないので、差し戻しの文面には書かない。
#
# かつて (#2134〜#2669) は ci.yml の ci-gate の needs に居て、後付けのラベルや貼った絵では赤かった
# run の ci-gate が同じコミットに残り、必須チェックを赤のままにした (#259)。文面は打ち直しまで
# 案内していた。作法の検査が ci-gate を離れた (#2669) ので、その案内を畳んだ。
#
# 作成と同時に付ければ**通常は**最初の run から通るので、その形を先に案内する。保証では
# ない — gh は PR を作ってからラベルを付けるので、まれに作成の run が先に API を読むと赤くなる
# (必須は後から作られるラベルの run の結論を読む)
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
  3. 貼る (本文を編集する) と、下のとおり付け直されます

絵を出しようがない変更 (描画のパスに居るが絵は変わらないリファクタ・コメントの修正)
なら、$ESCAPE_LABEL ラベルを付けてください。**PR の作成と同時に付けます**:

  gh pr create --label $ESCAPE_LABEL ...   # 通常は最初の run から通る

gh は PR を作ってからラベルを付けるので、まれに作成の run がラベルの付く前を読んで赤くなりますが、
必須は後から作られるラベルの run の結論を読みます。作ってしまった PR には、あとから付けます:

  gh pr edit <番号> --add-label $ESCAPE_LABEL   # または画面から

**直せば付け直されます (打ち直しは要りません)**: 絵を貼る・ラベルを付けると pr-gate の新しい
run が作られ、必須はその (作成順で最新の) run の結論を読みます。
EOF
exit 1
