#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 親 Issue の completed close を、ツリーの不変条件で見張る (#23)。
#
#   parent-guard.sh <Issue 番号>
#
# open の sub-issue を残したまま親を completed で close したら reopen して警告する
# (親の close = 全作業完了。ADR-0002)。not planned での close は対象外 — ツリーごと
# 畳む意図を妨げないためで、その切り分けは呼び出し側が state_reason で行う。
#
# 呼び出しは .github/workflows/parent-guard.yml、検査は scripts/tests/parent_guard_test.py。
# ロジックを YAML に埋めないのは、issues イベントの workflow が既定ブランチのものしか
# 走らず、ブランチ上では誰も確かめられないため (#66 で確認した性質)。**その性質を最初に
# 踏んだのがこの判定である** — scripts/check-workflows.sh:8-11 が実害の例に #23 を挙げて
# いる。規律を作るきっかけになったファイルだけが規律の外に残っていた (#798)。
set -euo pipefail

# リポジトリの owner/repo。**literal は scripts/repo-slug.sh の 1 箇所だけ** (#818)
# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"
REPO="$(this_repo)"

NUM="${1:?Issue 番号が必要}"

# **--paginate を付ける。** 既定は 1 ページ 30 件で、それを超える子を持つ親では open の
# 子を取りこぼす。取りこぼしはこの見張りでは「ok」に化けるので、不変条件が黙って破れる
# (PR の変更ファイルで同じ穴を踏んでいる — #793)。
#
# **引けなかったことを「子が居ない」に混ぜない** (#865 が宣言した向き)。以前は
# `2>/dev/null || true` で握り潰しており、API が落ちても rate limit に当たっても
# 「ok: open の sub-issue なし」と名乗って通していた。reopen もしない — 人の Issue を
# 憶測で開け直すより、見張りが働かなかったことを名乗って赤で止まるほうが取り返せる。
if ! children=$(gh api --paginate "repos/$REPO/issues/$NUM/sub_issues" \
  --jq '.[] | select(.state == "open") | "- #\(.number) \(.title)"' 2>&1); then
  echo "parent-guard: #$NUM の sub-issue を引けなかった: $children" >&2
  echo "次にすること: gh api \"repos/$REPO/issues/$NUM/sub_issues\" を手で打って応答を確かめる。引けるなら API の一時的な不調だったので、この run を rerun する" >&2
  exit 1
fi

if [ -z "$children" ]; then
  echo "parent-guard: open の sub-issue なし"
  exit 0
fi

# 発言と状態の変更は 2 手に分ける (AGENTS.md「コメント」節)。
#
# **投稿は scripts/comment.sh を通さない。** あちらは「どの AI が書いたか」を名乗らせる
# ラッパーで、ここは AI ではなく決定論的な機械である。github.token での投稿は GitHub が
# bot として出所を描くので、ラッパーが埋める穴 (本人のトークンでの投稿に出所の表示が
# 出ない) がそもそも空いていない。理由は scripts/comment.sh の冒頭にも置いてある。
gh issue reopen "$NUM" -R "$REPO"
gh issue comment "$NUM" -R "$REPO" --body "open の sub-issue が残っているため reopen した (親の close = 全作業完了がツリーの不変条件):

$children

ツリーごと畳む意図なら、先に子を閉じるか、親を **not planned** で close する。"
