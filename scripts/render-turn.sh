#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 専用機へ job を積む順番を決める門番 (#2062)。
#
#   render-turn.sh merge_group <base sha> [<base ref>]
#   render-turn.sh yield
#   render-turn.sh wait
#
# 専用機は 1 台で、必須の render (merge_group)・情報の render-pr (pull_request)・定期の
# scheduled-* (schedule) が取り合う。**runner は queued の job を先着順に拾わない。**
# 2026-10-04 の実測では、queue の先頭の render が待つ間に、専用機は後から積まれた job を
# 6 本 (render-pr 4・後ろの group の render 2) と 7 本 (render-pr 2・後ろの group の
# render 5) 拾い、先頭の render は一度も拾われないまま queue の期限 (60 分) を越えて
# 弾かれた (#2038・#2040)。弾かれると後ろの group がまとめて組み直しになる。
#
# 拾う順は GitHub が決めるので変えられない。そこで、**専用機の queue に同時に積む job を
# 絞る**。render.yml の各専用機 job の前に GitHub ホストの job としてこれを置き、番が
# 来るまで専用機に job を積ませない。
#
# ## mode
#
#   merge_group  自分の base sha を head に持つ merge_group の run (1 つ前の group) が
#                終わるまで待つ。base sha が base ref (既定 refs/heads/main) の先端なら、
#                自分が先頭なので待たない。group は queue の順に 1 本ずつ専用機に積まれる
#   yield        merge_group の run が 1 本でも終わっていなければ go=false を出して抜ける
#                (render-pr は見送る。必須ではないので merge の可否は変わらない)
#   wait         merge_group の run が 1 本でも終わっていなければ、終わるまで待つ
#                (scheduled-* は見送らずに後ろへ回す)
#
# 待つ相手は render job ではなく **run** で見る。group の run は門番で待っている間も
# in_progress なので、「専用機に積まれる予定の render」まで数えられる。job で見ると、
# 前の render が終わってから次の門番が気付くまでの隙間に render-pr が入り込む。
#
# ## 前の group の run が見つからないとき
#
# 先頭でないのに前の group の run が見つからないのは、queue が group をまとめて作り直した
# 直後で、前の group の run がまだ作られていないときである。**先頭と取り違えて通すと、
# 組み直しの場面そのもので順番が崩れる** ので、base ref の先端と比べて分ける。先頭でなく
# run も無いままなら、作られるのを猶予 (5 分) だけ待ってから通す。
#
# ## 上限
#
# **merge_group は上限で放さない。** 前の group が終わらないまま待ちが長引くのは、専用機が
# 他の job (最大 30 分) を走らせているときで、そこで放すと後ろの group がそろって専用機に
# 積まれ、期限に近い前の group と取り合う — 元の症状に戻る。前の group の run は、自分の
# render が 30 分で切れ、queue から外れれば queue-sweep が cancel するので、待ちには終わりが
# ある。最後の歯止めは render.yml の門番の timeout-minutes である。
#
# wait (定期の検査) は 60 分 (RENDER_TURN_LIMIT で差し替え) で通す。定期の検査は queue の
# 期限を持たないが、走らないまま日をまたぐほうが重い。
#
# 待った時間は壁時計 ($SECONDS) で測る。sleep の合計で数えると API の待ちが入らない。
#
# ## 判定できないときは通す
#
# API が読めなければ go=true で通し、::warning:: を出す。門番の失敗で検査が走らない
# ほうが、順番が乱れるより重い。終了コードは使い方の誤りでだけ非 0 にする。
#
# ## 出力
#
# $GITHUB_OUTPUT があれば go=true|false を書く。$GITHUB_STEP_SUMMARY があれば、待った
# 相手と時間 (または見送った理由) を書く。標準出力にも同じ行を出す。
#
# 呼び出しは .github/workflows/render.yml、検査は scripts/tests/render_turn_test.py。
set -euo pipefail

# リポジトリの owner/repo。**literal は scripts/repo-slug.sh の 1 箇所だけ** (#818)
# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"

usage() {
  sed -n '7,9p' "${BASH_SOURCE[0]}" | sed 's/^# *//' >&2
}

case "${1:-}" in
  -h | --help)
    sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  merge_group)
    { [ $# -eq 2 ] || [ $# -eq 3 ]; } && [ -n "$2" ] || {
      usage
      exit 2
    }
    mode=merge_group base=$2 base_ref=${3:-refs/heads/main} limit_default=""
    ;;
  yield)
    [ $# -eq 1 ] || {
      usage
      exit 2
    }
    mode=yield limit_default=0
    ;;
  wait)
    [ $# -eq 1 ] || {
      usage
      exit 2
    }
    mode=wait limit_default=60
    ;;
  *)
    usage
    exit 2
    ;;
esac

REPO="$(this_repo)"
RUNS="repos/$REPO/actions/workflows/render.yml/runs"
INTERVAL="${RENDER_TURN_INTERVAL:-30}"
# merge_group は上限を持たない (上の「上限」)
if [ "$mode" = merge_group ]; then
  LIMIT_SECONDS=""
else
  LIMIT_SECONDS=$((${RENDER_TURN_LIMIT:-$limit_default} * 60))
fi
# 先頭でないのに前の group の run が無いとき、作られるのを待つ猶予 (秒)
MISSING_GRACE="${RENDER_TURN_MISSING_GRACE:-300}"

# 「まだ終わっていない」run の status。一覧 API の status は 1 つしか取らないので並べて引く
# (queue-sweep.sh と同じ)
ACTIVE_STATUSES="queued in_progress waiting pending requested"

say() {
  echo "$1"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$1" >> "$GITHUB_STEP_SUMMARY"; fi
}

finish() { # $1=go の値
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "go=$1" >> "$GITHUB_OUTPUT"; fi
  exit 0
}

unreadable() { # $1=何を読めなかったか
  echo "::warning::$1を読めなかったので、順番を待たずに通す (#2062)"
  say "$1を読めなかったので、順番を待たずに通した"
  finish true
}

# 待つ相手を 1 行ずつ「<id> <head_branch>」で出す。読めなければ非 0
blocking_runs() {
  local active got out="" tip
  case "$mode" in
    merge_group)
      got=$(gh api "$RUNS?event=merge_group&head_sha=$base&per_page=100" \
        --jq '.workflow_runs[] | "\(.id) \(.status) \(.head_branch)"') || return 1
      if [ -z "$got" ]; then
        # 前の group の run が無い。先頭か、まだ作られていないかを base ref の先端で分ける
        tip=$(gh api "repos/$REPO/git/matching-refs/${base_ref#refs/}" \
          --jq ".[] | select(.ref == \"$base_ref\") | .object.sha") || return 1
        if [ "$tip" != "$base" ] && [ "$SECONDS" -lt "$MISSING_GRACE" ]; then
          echo "- (前の group の run がまだ作られていない: head_sha=${base:0:8})"
        fi
        return 0
      fi
      out=$(awk '$2 != "completed" { print $1, $3 }' <<<"$got")
      ;;
    *)
      for active in $ACTIVE_STATUSES; do
        got=$(gh api "$RUNS?event=merge_group&status=$active&per_page=100" \
          --jq '.workflow_runs[] | "\(.id) \(.head_branch)"') || return 1
        out+="$got"$'\n'
      done
      ;;
  esac
  printf '%s' "$out" | sed '/^$/d' | sort -u
}

while :; do
  blockers=$(blocking_runs) || unreadable "merge queue の render の run"

  if [ -z "$blockers" ]; then
    case "$mode" in
      merge_group) say "前の group の render は終わっている (または自分が先頭)。$((SECONDS / 60)) 分待った" ;;
      *) say "merge queue の render は走っていない。$((SECONDS / 60)) 分待った" ;;
    esac
    finish true
  fi

  if [ "$mode" = yield ]; then
    say "merge queue の render が専用機を待っているので、render-pr は見送った (#2062):"
    say "$(sed 's/^/- run /' <<<"$blockers")"
    finish false
  fi

  if [ -n "$LIMIT_SECONDS" ] && [ "$SECONDS" -ge "$LIMIT_SECONDS" ]; then
    echo "::warning::$((LIMIT_SECONDS / 60)) 分待っても順番が来ないので通す (#2062)"
    say "$((LIMIT_SECONDS / 60)) 分待っても順番が来ないので通した。待っていた相手:"
    say "$(sed 's/^/- run /' <<<"$blockers")"
    finish true
  fi

  echo "待っている相手: $(tr '\n' ' ' <<<"$blockers")"
  sleep "$INTERVAL"
done
