#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 専用機の前検査が名乗った「job の置き場の外の重い負荷」(注意) が、同じプロセス名で何回続いて
# いるかを数える (#3633)。読むだけで、何も書かない。
#
#   NOTICE=<注意の名前 (| 区切り)> count-runner-notice.sh
#
# 名前は scripts/runner-preflight.sh が $GITHUB_OUTPUT へ書いた `notice` で、render.yml が
# job の出力として環境変数で渡す。**引数では受けない** — `-zsh` のような `-` で始まるプロセス名を
# 選択肢と読み違えて止まらないため (反証の指摘 4)。数えた結果は $GITHUB_OUTPUT に書く:
#
#   due=<回数> <途切れの run> <名前>|…   N 回以上続いている名前。空なら書く回ではない
#   unreadable=1                         前の run の記録を読めなかった (読めたら空)
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
# 〔注意の名前: a|b〕 を付けるので、この run より前に作られた merge_group の run の render の
# job の annotation から、同じ名前が何回続いたかを数える。この run を 1 回目として、前へ遡る。
#
# **「いつ書くか」はここで決めない。** ここが出すのは、名前ごとの「いま何回続いているか」と
# 「続きの手前で途切れた run (途切れ)」だけで、N 回以上なら due に載せる。「この続きについて
# 既に書いたか」は、書く側が注意の Issue の印から読む (report-runner-notice.sh)。数えだけで
# 「ちょうど N 回目」に書くと、runner 2 本の並行 (前の run がまだ終わっていない)・再実行 (同じ
# run の ID)・読めない回で数えが揺れ、ちょうど N 回目の run が無くて書かない / 2 度書く
# (反証の指摘 1〜3)。
#
#   ・前の run の render がまだ終わっていない (並行)・成功でも失敗でもない (cancelled・skipped)・
#     前検査の step が走っていない (checkout などで落ちた) run は「分からない」として飛ばす。
#     途切れとも続きとも数えない (指摘 5)
#   ・前検査が走ったのにその名前が無い run が「途切れ」。その run の ID を書く側へ渡す。履歴を
#     読み切っても途切れが無ければ 0
#   ・API の呼び出しは、短い待ちを挟んで 3 回まで試す。一時的な失敗 (レート制限・502) は「読めない」に
#     しない
#   ・**記録を読めなかったときは、名前を全部 due に載せて unreadable を立てる** (黙って止まらない)。
#     読めない回を重ねて書かないのは書く側 (Issue の最後の印が「読めない」なら重ねない)
#
# 遡るのは NOTICE_PER_PAGE (既定 20) 本ずつ NOTICE_MAX_PAGES (既定 2) ページまで。続きが
# それより長ければ途切れは 0 (書く側は、その名前の印が 1 つでもあれば書かない)。
#
# 前検査の step は名前で見分ける。render.yml の前検査の step は `name:` を持たないので、
# GitHub が付ける名前は `Run bash scripts/runner-preflight.sh` になる。下の PREFLIGHT_STEP との
# 食い違いは render_workflow_test.py が赤にする。
#
# 検査は scripts/tests/report_runner_notice_test.py。
set -euo pipefail
# 照合順・バイトの扱いを GNU (CI の ubuntu) と BSD (手元の macOS) で揃える
export LC_ALL=C

# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"
REPO="$(this_repo)"

readonly WORKFLOW="render.yml"
readonly JOB_NAME="render"
readonly PREFLIGHT_STEP="runner-preflight.sh"
readonly NOTICE_TAG='〔注意の名前: '
# run の jobs から、render の job の `<id> <状態> <結論> <前検査の step の結論>` の 1 行 (job が無ければ空)
JOB_QUERY="[.jobs[] | select(.name == \"$JOB_NAME\")][0] // empty"
JOB_QUERY+=" | [.id, .status, (.conclusion // \"none\"),"
JOB_QUERY+=" ([.steps[]? | select(.name | contains(\"$PREFLIGHT_STEP\")) | .conclusion // \"none\"][0] // \"none\")]"
JOB_QUERY+=" | map(tostring) | join(\" \")"
readonly JOB_QUERY

# gh api を、短い待ちを挟んで RETRY_TRIES 回まで試す (一時的なレート制限・502 で「読めない」に
# しない・#3633 の 2 回目の反証)。待ちは既定 5 秒・2 回で、全部落ちても 10 秒 (job の
# timeout-minutes: 5 に収まる)。全部落ちたら非 0
readonly RETRY_TRIES=3
RETRY_WAIT="${NOTICE_RETRY_WAIT:-5}"
case "$RETRY_WAIT" in '' | *[!0-9]*) echo "NOTICE_RETRY_WAIT は 0 以上の整数: $RETRY_WAIT" >&2; exit 64 ;; esac
api() {
  local try=1 out
  while :; do
    if out=$(gh api "$@" 2>/dev/null); then
      printf '%s\n' "$out"
      return 0
    fi
    [ "$try" -lt "$RETRY_TRIES" ] || return 1
    try=$((try + 1))
    sleep "$RETRY_WAIT"
  done
}

# 行の並び ($1) を $2 で区切った 1 行に (paste -sd は空の入力の扱いが GNU と BSD で違う)
join_lines() {
  local out="" line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    out+="${out:+$2}${line}"
  done <<<"$1"
  printf '%s' "$out"
}

usage() {
  echo "使い方: NOTICE=<注意の名前 (| 区切り)> count-runner-notice.sh" >&2
  exit 64
}
[ $# -eq 0 ] || usage
NAMES="${NOTICE:-}"
[ -n "$NAMES" ] || usage
STREAK_N="${NOTICE_STREAK:-3}"
PER_PAGE="${NOTICE_PER_PAGE:-20}"
MAX_PAGES="${NOTICE_MAX_PAGES:-2}"
for v in "$STREAK_N" "$PER_PAGE" "$MAX_PAGES"; do
  case "$v" in '' | *[!0-9]* | 0) echo "NOTICE_STREAK・NOTICE_PER_PAGE・NOTICE_MAX_PAGES は 1 以上の整数: $v" >&2; exit 64 ;; esac
done
CURRENT_RUN="${GITHUB_RUN_ID:-}"
case "$CURRENT_RUN" in *[!0-9]*) CURRENT_RUN="" ;; esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# 名前ごとの数え (macOS の /bin/bash 3.2 でも動くよう、連想配列でなく添字の揃った配列で持つ)。
# streak はこの run を含む回数、after は途切れの run (まだ見つかっていなければ空)
names=() streak=() after=()
while IFS= read -r name; do
  [ -n "$name" ] || continue
  names+=("$name")
  streak+=(1)
  after+=("")
done < <(printf '%s\n' "$NAMES" | tr '|' '\n' | sed '/^$/d' | sort -u)
[ "${#names[@]}" -gt 0 ] || usage
open_count=${#names[@]}

# 前検査が走った前の run 1 本の注意の名前 ($2・1 行 1 名) で、続いている名前を数え進める
advance() { # $1=run の ID $2=その run の名前の一覧のファイル
  local i
  for i in "${!names[@]}"; do
    [ -z "${after[$i]}" ] || continue
    if grep -qxF -- "${names[$i]}" "$2"; then
      streak[i]=$((streak[i] + 1))
    else
      after[i]="$1"
      open_count=$((open_count - 1))
    fi
  done
}

# --- 前の run を新しい順に読む ---------------------------------------------------
unreadable=""
page=1
while [ "$open_count" -gt 0 ] && [ "$page" -le "$MAX_PAGES" ]; do
  if ! runs=$(api "repos/$REPO/actions/workflows/$WORKFLOW/runs?event=merge_group&per_page=$PER_PAGE&page=$page" \
    --jq '.workflow_runs[].id'); then
    unreadable=1
    break
  fi
  [ -n "$runs" ] || break
  while IFS= read -r run; do
    [ "$open_count" -gt 0 ] || break
    case "$run" in '' | *[!0-9]*) continue ;; esac
    # この run 自身と、この run より後に作られた run は前の run ではない (再実行でも同じ履歴を見る)
    if [ -n "$CURRENT_RUN" ] && [ "$run" -ge "$CURRENT_RUN" ]; then continue; fi
    # render の job の状態・結論・前検査の step の結論を 1 行で (job が無ければ空)
    if ! job=$(api "repos/$REPO/actions/runs/$run/jobs?per_page=100" --jq "$JOB_QUERY"); then
      unreadable=1
      break 2
    fi
    read -r job_id status conclusion preflight <<<"$job" || true
    # 分からない run は飛ばす: job が無い・まだ終わっていない (並行)・cancelled や skipped・
    # 前検査の step が走っていない (それより前で落ちた)
    [ -n "${job_id:-}" ] && [ "$status" = completed ] || continue
    case "$conclusion" in success | failure) ;; *) continue ;; esac
    case "$preflight" in success | failure) ;; *) continue ;; esac
    if ! messages=$(api "repos/$REPO/check-runs/$job_id/annotations?per_page=100" \
      --jq ".[] | (.message // \"\") | select(contains(\"$NOTICE_TAG\"))" 2>/dev/null); then
      unreadable=1
      break 2
    fi
    # 注意の無い run は空の一覧 — それが途切れである
    : > "$work/run-names"
    if [ -n "$messages" ]; then
      rest="${messages%%$'\n'*}"
      rest="${rest#*"$NOTICE_TAG"}"
      printf '%s\n' "${rest%%〕*}" | tr '|' '\n' | sed '/^$/d' > "$work/run-names"
    fi
    advance "$run" "$work/run-names"
  done <<<"$runs"
  page=$((page + 1))
done

# --- 出力 ---------------------------------------------------------------------
due=""
for i in "${!names[@]}"; do
  if [ -n "$unreadable" ]; then
    due+="0 0 ${names[$i]}"$'\n'
  elif [ "${streak[$i]}" -ge "$STREAK_N" ]; then
    due+="${streak[$i]} ${after[$i]:-0} ${names[$i]}"$'\n'
  fi
done

if [ -n "$unreadable" ]; then
  echo "count-runner-notice: 前の run の記録を読めなかった — 書く側へ渡す (注意の名前: ${NAMES})"
elif [ -z "$due" ]; then
  echo "count-runner-notice: N=${STREAK_N} 回に満たない (注意の名前: ${NAMES})"
else
  echo "count-runner-notice: N=${STREAK_N} 回以上続いている (回数 途切れの run 名前): $(join_lines "$due" ',')"
fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'due=%s\n' "$(join_lines "$due" '|')" >> "$GITHUB_OUTPUT"
  printf 'unreadable=%s\n' "$unreadable" >> "$GITHUB_OUTPUT"
fi
