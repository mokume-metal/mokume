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
# PR を作る前に make ci-check を打つのが普通で、そこで赤くすると入口が塞がる。
#
#   0  通過・判定できず
#   1  描画に触れているのに絵が無い
set -euo pipefail

# 「描画に触れているか」の判定は #304 と共有する (照合の実体は 1 つ・ADR-0001 原則 9)
# shellcheck source=scripts/drawing-paths.sh
. "$(dirname "${BASH_SOURCE[0]}")/drawing-paths.sh"

# 逃がしのラベル。描画のパスに居るが絵が変わらない変更 (コメントの修正・内部の
# リファクタ) のための例外印で、**読み手はこのスクリプトだけ**である
# (ADR-0005 決定 2 — 読み手のいないラベルは足さない)
readonly ESCAPE_LABEL=no-visual-change

REPO=${GITHUB_REPOSITORY:-}

say() { echo "drawing-evidence: $*"; }
give_up() { say "判定しない — $1"; exit 0; }

# 本文に絵の参照があるか (標準入力)。人間の経路 (入力欄へ落とすと GitHub が
# user-attachments の URL を返す) とエージェントの経路 (Gyazo・.claude/skills/
# gyazo-evidence) の両方を通す。**広く取る** — 狭いと絵を貼った PR が赤くなり、
# 逃がしラベルで外す癖がついて機構ごと形骸化する
has_evidence() {
  grep -Eqi \
    -e '!\[[^]]*\]\([^)]+\)' \
    -e '<(img|video)[[:space:]>]' \
    -e 'https?://[^[:space:])"]+\.(png|jpe?g|gif|webp|avif|mp4|mov|webm)' \
    -e 'https?://(i\.)?gyazo\.com/' \
    -e 'https://github\.com/user-attachments/'
}

# 対象の PR。引数 → PR_NUMBER → 現在のブランチ の順に解く
pr=${1:-${PR_NUMBER:-}}
command -v gh >/dev/null 2>&1 || give_up "gh が無い"
gh auth status >/dev/null 2>&1 || give_up "gh が認証されていない"

args=(--json "body,labels,files")
# 素の && で足すと、REPO が空のときに全体が 1 を返して set -e が script ごと止める
if [ -n "$REPO" ]; then args+=(-R "$REPO"); fi
if [ -n "$pr" ]; then args=("$pr" "${args[@]}"); fi
# 現在のブランチに PR が無ければ gh は失敗する。それは作業の途中というだけなので、
# 理由を述べて 0 で抜ける (PR を出した後の make ci-check で判定が効くようになる)
pr_json=$(gh pr view "${args[@]}" 2>/dev/null) \
  || give_up "このブランチに PR が無い (PR を出した後にもう一度打つと判定できる)"

if jq -e --arg l "$ESCAPE_LABEL" '.labels[]? | select(.name == $l)' >/dev/null <<<"$pr_json"; then
  say "$ESCAPE_LABEL による例外 PR (絵は変わらないという申告)"
  exit 0
fi

if ! jq -r '.files[]?.path // empty' <<<"$pr_json" | touches_drawing evidence; then
  say "描画に触れていない PR — 絵は要らない"
  exit 0
fi

if jq -r '.body // ""' <<<"$pr_json" | has_evidence; then
  say "ok: 描画に触れる PR に絵がある"
  exit 0
fi

cat >&2 <<EOF
drawing-evidence: 差し戻し — 描画に触れる PR の本文に絵が無い

CI は絵を描けません (#180・ADR-0019 決定 7)。**貼られた絵が描画の唯一の検証記録**で、
squash merge でブランチが消えた後には足せません。

次にすること:

  1. before/after を撮って PR 本文に貼る。動きが分からないと正誤を判定できないもの
     (アニメーション・遷移・インタラクション) は、動きの分かる形式で貼る
     - 人間: Issue / PR の入力欄へ画像や動画をそのまま落とす (何も用意が要りません)
     - エージェント: .claude/skills/gyazo-evidence/SKILL.md の手順で Gyazo へ上げ URL を貼る
  2. リポジトリには**コミットしない** (生成物・バイナリは持ち込まない — AGENTS.md)

絵を出しようがない変更 (描画のパスに居るが絵は変わらないリファクタ・コメントの修正)
なら、$ESCAPE_LABEL ラベルを付けてください:

  gh pr edit <番号> --add-label $ESCAPE_LABEL   # または画面から

本文を編集してもラベルを付け外ししても、CI は自動で再評価します。
EOF
exit 1
