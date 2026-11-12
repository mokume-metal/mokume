#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 専用機の前検査が名乗った「job の置き場の外の重い負荷」(注意) が、同じプロセス名で何回続いて
# いるかを数える (#3633)。読むだけで、何も書かない。
#
#   count-runner-notice.sh <注意の名前 (| 区切り)>
#
# 名前は scripts/runner-preflight.sh が $GITHUB_OUTPUT へ書いた `notice` で、render.yml が
# job の出力として渡す。数えた結果は $GITHUB_OUTPUT に書く:
#
#   due=<名前 (連続 N 回)|…>   今回書く名前。空なら書く回ではない
#   unreadable=1               前の run の記録を読めなかった (読めたら空)
#
# 書くのは scripts/report-runner-notice.sh。**数えと書き込みは別の job** (render.yml の
# render-notice-count と render-notice-report) — 数えは前の run の記録を読む actions: read・
# checks: read だけを持ち、書き込みは issues: write だけで記録を読む権限を持たない。render.yml の
# 「actions: read を持つのは読むだけの job」の決まりを崩さない分け方 (workflow_permissions_test.py が
# スクリプトごとに権限を割り当てるので、ファイルも分けてある)。
#
# **塞ぐのは「置き場の外の負荷が render を黙って遅くしても、誰にも届かない」である** (#3633・
# #3631 の反証)。前検査は注意を annotation と job の要約に出すだけで、人に届ける
# render-environment-report は前検査が落ちた回にしか走らなかった。
#
# ## 数え
#
# **鍵はプロセス名で、pid ではない。** 実際の注意は run ごとに pid もプロセスも変わる
# (2026-11-03 は StorageManagementService・11-06 は mediaanalysisd)。pid で数えると再起動の
# たびに数え直しになり、「続いた」と数えられない。
#
# **数えの状態は前の run の annotation から読み戻す** (別の置き場を持たない)。前検査が注意の末尾に
# 〔注意の名前: a|b〕 を付けるので、直近の merge_group の render の job の annotation から、
# 同じ名前が何回続いたかを数える。この run を 1 回目として、前へ遡る。
#
#   ・N (既定 3・NOTICE_STREAK) 回目の run でだけ書く。4 回目以降は書かない (続く間は重ねない)
#   ・注意が 1 回途切れた (前検査が走ったのにその名前が無い) 後にまた N 回続けば、新しく 1 度書く
#   ・名前が変われば数え直す (新しい名前が N 回続くまで書かない)
#   ・render の job が成功でも失敗でもない run (cancelled・skipped) は数えない。前検査が走って
#     いないので、途切れとも続きとも言えない
#   ・**記録を読めなかったときは、1 度書く** (黙って止まらない)。読めない回が続けば毎回書くが、
#     それは API が壊れているという知らせでもある
#
# 検査は scripts/tests/report_runner_notice_test.py。
set -euo pipefail

# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"
REPO="$(this_repo)"

readonly WORKFLOW="render.yml"
readonly JOB_NAME="render"
readonly NOTICE_TAG='〔注意の名前: '

[ $# -eq 1 ] && [ -n "$1" ] && [[ "$1" != -* ]] || {
  echo "使い方: count-runner-notice.sh <注意の名前 (| 区切り)>" >&2
  exit 64
}
NAMES="$1"
STREAK_N="${NOTICE_STREAK:-3}"
case "$STREAK_N" in '' | *[!0-9]* | 0) echo "NOTICE_STREAK は 1 以上の整数: $STREAK_N" >&2; exit 64 ;; esac
CURRENT_RUN="${GITHUB_RUN_ID:-}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# 名前の集合 (1 行 1 名)
printf '%s\n' "$NAMES" | tr '|' '\n' | sed '/^$/d' | sort -u > "$work/current"

# --- 前の run の注意の名前を、新しい順に読む -----------------------------------------
# $work/history の 1 行 = 1 回の run の注意の名前の集合 (`|` 区切り・空なら注意なし)。
# 読めなかったら unreadable を立てる
unreadable=""
: > "$work/history"
if runs=$(gh api "repos/$REPO/actions/workflows/$WORKFLOW/runs?event=merge_group&status=completed&per_page=20" \
  --jq '.workflow_runs[].id' 2>/dev/null); then
  while IFS= read -r run; do
    [ -n "$run" ] || continue
    [ "$run" != "$CURRENT_RUN" ] || continue
    if ! job=$(gh api "repos/$REPO/actions/runs/$run/jobs?per_page=100" \
      --jq ".jobs[] | select(.name == \"$JOB_NAME\") | \"\(.id) \(.conclusion)\"" 2>/dev/null); then
      unreadable=1
      break
    fi
    job_id="${job%% *}"
    conclusion="${job#* }"
    case "$conclusion" in
      success | failure) ;;
      *) continue ;; # 前検査が走っていない (cancelled・skipped・job が無い)。数えない
    esac
    if ! messages=$(gh api "repos/$REPO/check-runs/$job_id/annotations?per_page=100" \
      --jq '.[].message' 2>/dev/null); then
      unreadable=1
      break
    fi
    # 注意の無い run も 1 行 (空行) として残す — それが途切れである
    names_line=""
    while IFS= read -r message; do
      if [[ "$message" == *"$NOTICE_TAG"* ]]; then
        rest="${message#*"$NOTICE_TAG"}"
        names_line="${rest%%〕*}"
        break
      fi
    done <<<"$messages"
    printf '%s\n' "$names_line" >> "$work/history"
  done <<<"$runs"
else
  unreadable=1
fi

# --- 名前ごとの連続回数 -----------------------------------------------------------
# この run が 1 回目。前の run へ遡り、含まれていれば +1、含まれていなければ止める。
# N を超えたら (N+1 回目) 書かない。履歴を使い切って N に満たなければ、まだ書かない
due=""
while IFS= read -r name; do
  [ -n "$name" ] || continue
  streak=1
  while IFS= read -r line; do
    [ "$streak" -le "$STREAK_N" ] || break
    if grep -qxF -- "$name" <<<"${line//|/$'\n'}"; then
      streak=$((streak + 1))
    else
      break
    fi
  done < "$work/history"
  if [ "$streak" -eq "$STREAK_N" ] || [ -n "$unreadable" ]; then
    due+="${name} (連続 ${streak} 回)"$'\n'
  fi
done < "$work/current"

if [ -z "$due" ]; then
  echo "count-runner-notice: 書く回ではない (注意の名前: ${NAMES}・N=${STREAK_N})"
else
  echo "count-runner-notice: 書く回 (注意の名前: ${NAMES}・N=${STREAK_N}): $(printf '%s' "$due" | paste -sd ',' -)"
fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'due=%s\n' "$(printf '%s' "$due" | paste -sd '|' -)" >> "$GITHUB_OUTPUT"
  printf 'unreadable=%s\n' "$unreadable" >> "$GITHUB_OUTPUT"
fi
