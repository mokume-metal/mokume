#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# merge queue が捨てたグループの run と、専用機で先頭の render を待たせる render-pr を
# cancel する (#1265・#2064)。
#
#   queue-sweep.sh [--dry-run]
#
# merge queue はグループを作り直したり PR を外したりしても、**古いグループの
# merge_group run を cancel しない**。捨てられた run は macOS の枠を使い続け
# (1 回の検証で ci-check と test-release の 2 本)、今のグループの検証を待たせる。
# 2026-09-15 には 1 日に 2 回起き、どちらも merge が 30〜50 分止まった (#1265)。
#
# ## 捨てられたかどうかは ref で分かる
#
# グループには gh-readonly-queue/<base>/pr-<番号>-<base sha> の ref が 1 本ずつ付き、
# **グループが捨てられるとその場で消える**。作り直したグループは base sha が変わるので
# 別の名前で作られる (#1265 に events API の実測)。そこで run ごとに:
#
#   run の head_branch が無い                → 捨てられた   → cancel
#   ある が先端が run の head_sha と違う     → 作り直された → cancel
#   ある で先端が一致する                    → 今のグループ → 触らない
#   ref を読めなかった                       → 判定できず   → 触らず、非 0 で終える
#
# **判定できないものは生きている側に倒す。** 今のグループの検証を cancel すると、その PR は
# queue から外れて人手で入れ直すことになる — 枠を 1 本失うより重い。
#
# **自分の run も同じ判定を通す。** 自分のグループの ref は必ず在るので、特別扱いの分岐を
# 持たない (分岐を持つと、そこだけ検査の外に出る)。
#
# ## ref の読み方
#
# git/ref/heads/<名前> は無いと 404 で失敗し、「無い」と「読めなかった」をエラー文で
# 分けることになる。git/matching-refs は無ければ空の配列を 200 で返すので、失敗は
# そのまま「読めなかった」と読める。前方一致なので完全一致で絞る。
#
# ## 門番より前に積まれた render-pr を退かせる (#2064)
#
# 専用機は 1 台で、**runner は queued の job を先着順に拾わない** (#2062)。render.yml の
# 門番 (scripts/render-turn.sh の yield) は、merge_group の run が残っていれば render-pr を
# 見送る。ただし判定は **積む前の 1 回だけ**で、merge queue が空いている間に門番を通って
# 専用機の queue に入った render-pr は、後からできた先頭の render と取り合う。2026-10-04 には
# 08:38 と 08:50 に積まれた render-pr 2 本が、08:53 に積まれた先頭の render より先に拾われ、
# 先頭は 37 分待って queue の期限 (60 分) の 22 分前に人の手の cancel で解けた (#2064)。
#
# そこで上の判定で **今のグループ (keep) が 1 本でもあれば**、render.yml の pull_request の
# run を引き、render-pr の job ごとに:
#
#   job がまだ拾われていない (queued ほか)  → cancel (専用機の queue から退かせる)
#   job が走っている (in_progress)          → 触らない (走っている 1 本は止めない)
#   render-pr の job が無い・終わっている   → 触らない (まだ門番の中なら、門番が見送る)
#   jobs を読めなかった                     → 判定できず → 触らず、非 0 で終える
#
# 今のグループが無いとき (後ろにグループが居ない PR が外れた dequeued) は触らない。待たせる
# 相手が居ないので、退かせても得るものが無い。**イベントの種類では分けない** — 上と同じく、
# 分岐を持つとそこだけ検査の外に出る。
#
# render-pr は必須ではないので、cancel しても merge の可否は変わらない。cancel された
# render-pr は scripts/stall-act.sh も走らせ直さない (RERUN_EXCLUDED)。定期の検査
# (scheduled-*) は退かせない — 1 つの run の中では needs の鎖で 1 本ずつしか積まれず、
# 先頭の render と並ぶのは 1 本までである。受け入れた理由は ADR-0019 決定 7。
#
# 取り残しは 2 つあり、どちらも「退かせ損ねる」方向にしか外れない。jobs を読んでから
# cancel するまでの間に runner が拾った render-pr は止まらない (走っている 1 本と同じ
# 扱いになる)。門番が通すと決めてから job が queued になるまでの数秒に一覧を引くと、
# その render-pr は映らない。
#
# ## 出力
#
#   <run id> <cancel|keep|done|unknown> <head_branch> <理由>
#
# head_branch は、merge_group の run ならグループの ref、render-pr の run なら PR の枝である。
# done は cancel を打つ前に run が終わっていたもの (409)。
#
# 終了コード: 0 = 判定できなかった run が無い、1 = ある (または cancel に失敗した)。
#
# 呼び出しは .github/workflows/queue-sweep.yml、検査は scripts/tests/queue_sweep_test.py。
set -euo pipefail

# リポジトリの owner/repo。**literal は scripts/repo-slug.sh の 1 箇所だけ** (#818)
# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"

REPO="$(this_repo)"

dry_run=false
case "${1:-}" in
  "") ;;
  --dry-run) dry_run=true ;;
  *)
    echo "usage: queue-sweep.sh [--dry-run]" >&2
    exit 2
    ;;
esac

# 「まだ終わっていない」run の status。一覧 API の status は 1 つしか取らないので並べて引く
ACTIVE_STATUSES="queued in_progress waiting pending requested"

# run を cancel する。判定から cancel までの間に run が終わっていれば 409 が返る。
# 捨てたかった run が既に居ないだけなので失敗にしない
cancel_run() { # $1=run id、$2=head_branch
  $dry_run && return 0
  local err
  if ! err=$(gh api -X POST "repos/$REPO/actions/runs/$1/cancel" --silent 2>&1); then
    case "$err" in
      *"HTTP 409"*) printf '%s done %s cancel の前に終わっていた\n' "$1" "$2" ;;
      *)
        printf '%s unknown %s cancel に失敗した: %s\n' "$1" "$2" "$err"
        status=1
        ;;
    esac
  fi
}

runs=""
for active in $ACTIVE_STATUSES; do
  got=$(gh api --paginate \
    "repos/$REPO/actions/runs?event=merge_group&status=$active&per_page=100" \
    --jq '.workflow_runs[] | [.id, .head_branch, .head_sha] | @tsv')
  runs+="$got"$'\n'
done

status=0
live_group=false
while IFS=$'\t' read -r id branch sha; do
  [ -n "$id" ] || continue

  # merge_group の run は必ずグループの ref を持つ。形が違うものは読み違いを疑って触らない
  case "$branch" in
    gh-readonly-queue/*) ;;
    *)
      printf '%s unknown %s グループの ref の形ではない\n' "$id" "$branch"
      status=1
      continue
      ;;
  esac

  if ! tip=$(gh api "repos/$REPO/git/matching-refs/heads/$branch" \
    --jq ".[] | select(.ref == \"refs/heads/$branch\") | .object.sha"); then
    printf '%s unknown %s ref を読めなかった\n' "$id" "$branch"
    status=1
    continue
  fi

  if [ "$tip" = "$sha" ]; then
    printf '%s keep %s 今のグループ\n' "$id" "$branch"
    live_group=true
    continue
  fi

  if [ -z "$tip" ]; then
    reason="ref が消えた (グループが捨てられた)"
  else
    reason="ref の先端が ${tip:0:8} に変わった (作り直された)"
  fi
  printf '%s cancel %s %s\n' "$id" "$branch" "$reason"
  cancel_run "$id" "$branch"
done < <(printf '%s' "$runs" | sort -u)

# 門番より前に積まれた render-pr を退かせる (#2064)。今のグループが無ければ待たせる相手が居ない
$live_group || exit "$status"

pr_runs=""
for active in $ACTIVE_STATUSES; do
  got=$(gh api --paginate \
    "repos/$REPO/actions/workflows/render.yml/runs?event=pull_request&status=$active&per_page=100" \
    --jq '.workflow_runs[] | [.id, .head_branch] | @tsv')
  pr_runs+="$got"$'\n'
done

while IFS=$'\t' read -r id branch; do
  [ -n "$id" ] || continue

  if ! job=$(gh api "repos/$REPO/actions/runs/$id/jobs?per_page=100" \
    --jq '[.jobs[] | select(.name == "render-pr") | .status] | first // ""'); then
    printf '%s unknown %s render-pr の job を読めなかった\n' "$id" "$branch"
    status=1
    continue
  fi

  case "$job" in
    "" | completed) continue ;;
    in_progress)
      printf '%s keep %s render-pr が専用機で走っている\n' "$id" "$branch"
      continue
      ;;
  esac
  printf '%s cancel %s render-pr が専用機の queue で先頭の render を待たせる (%s)\n' \
    "$id" "$branch" "$job"
  cancel_run "$id" "$branch"
done < <(printf '%s' "$pr_runs" | sort -u)

exit "$status"
