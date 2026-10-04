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
#   merge_group  base sha が base ref (既定 refs/heads/main) の先端なら、自分が先頭なので
#                待たない。そうでなければ、自分の base sha を head に持つ merge_group の
#                run (1 つ前の group) が終わるまで待つ。group は queue の順に 1 本ずつ
#                専用機に積まれる。先端と先に比べるので、merge 済みの前の group の run を
#                人が走らせ直していても、先頭は待たない
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
# **merge_group は queue の期限の直前 (55 分) まで放さない。** 前の group が終わらないまま
# 待ちが長引くのは、専用機が他の job (最大 30 分) を走らせているときで、早く放すと後ろの
# group がそろって専用機に積まれ、期限に近い前の group と取り合う — 元の症状に戻る。55 分
# まで待てば自分の group も期限で外れる間際なので、放しても前の group を邪魔しない。
#
# **上限は自分で終わって守る。** render.yml の門番の timeout-minutes に任せると、timeout は
# GitHub が job を cancel する扱いになり、後ろの render がどう終わるか (skipped は必須
# チェックを満たす) が GitHub の振る舞い次第になる。timeout-minutes はこの上限より外に置く
# (検査は scripts/tests/render_workflow_test.py)。
#
# wait (定期の検査) は 60 分で通す。定期の検査は queue の期限を持たないが、走らないまま
# 日をまたぐほうが重い。どちらも RENDER_TURN_LIMIT (分) で差し替えられる。
#
# ## 間隔と API の上限
#
# 60 秒おきに引く (RENDER_TURN_INTERVAL で差し替え)。GITHUB_TOKEN の REST の上限は
# リポジトリで 1 時間 1,000 件を共有する (review-gate・queue-sweep も同じ枠)。1 周に引くのは
# merge_group で 2 件 (先端と前の run)、yield / wait で 2 件 (queued と in_progress) なので、
# 門番 1 本で 1 時間 120 件になる。merge_group の門番が 4 本と定期の門番 1 本が同時に
# 待っても約 600 件で、枠の内に収まる。
#
# ## 判定できないときは通す
#
# API が 3 回続けて読めなければ go=true で通し、::warning:: を出す。門番の失敗で検査が
# 走らないほうが、順番が乱れるより重い。1 回の 502 では通さない — 通すと後ろの group と
# render-pr が一度に積まれ、元の症状に戻る。終了コードは使い方の誤りでだけ非 0 にする。
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
    mode=merge_group base=$2 base_ref=${3:-refs/heads/main} limit_default=55
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
INTERVAL="${RENDER_TURN_INTERVAL:-60}"
LIMIT_SECONDS=$((${RENDER_TURN_LIMIT:-$limit_default} * 60))
# 読めなかったときに、通す前に引き直す回数 (上の「判定できないときは通す」)
READ_ATTEMPTS="${RENDER_TURN_READ_ATTEMPTS:-3}"
# 先頭でないのに前の group の run が無いとき、作られるのを待つ猶予 (秒)
MISSING_GRACE="${RENDER_TURN_MISSING_GRACE:-300}"

# 「まだ終わっていない」run の status。一覧 API の status は 1 つしか取らないので並べて引く
# (queue-sweep.sh と同じ)。render.yml の run は environment も run 単位の concurrency も
# 持たないので、waiting / pending / requested にはならない — 引くのは 2 つで足りる
ACTIVE_STATUSES="queued in_progress"

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
      # 先端と先に比べる: 先頭なら、前の group の run の状態によらず待たない
      tip=$(gh api "repos/$REPO/git/matching-refs/${base_ref#refs/}" \
        --jq ".[] | select(.ref == \"$base_ref\") | .object.sha") || return 1
      [ "$tip" != "$base" ] || return 0
      got=$(gh api "$RUNS?event=merge_group&head_sha=$base&per_page=100" \
        --jq '.workflow_runs[] | "\(.id) \(.status) \(.head_branch)"') || return 1
      if [ -z "$got" ]; then
        # 先頭でないのに前の group の run が無い: まだ作られていない (組み直しの直後)
        if [ "$SECONDS" -lt "$MISSING_GRACE" ]; then
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

failures=0
while :; do
  if ! blockers=$(blocking_runs); then
    failures=$((failures + 1))
    [ "$failures" -lt "$READ_ATTEMPTS" ] || unreadable "merge queue の render の run"
    echo "merge queue の render の run を読めなかった ($failures 回目)。引き直す"
    sleep "$INTERVAL"
    continue
  fi
  failures=0

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

  if [ "$SECONDS" -ge "$LIMIT_SECONDS" ]; then
    echo "::warning::$((LIMIT_SECONDS / 60)) 分待っても順番が来ないので通す (#2062)"
    say "$((LIMIT_SECONDS / 60)) 分待っても順番が来ないので通した。待っていた相手:"
    say "$(sed 's/^/- run /' <<<"$blockers")"
    finish true
  fi

  echo "待っている相手: $(tr '\n' ' ' <<<"$blockers")"
  sleep "$INTERVAL"
done
