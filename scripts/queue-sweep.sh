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
# (1 回の検証で ci-check。2026-10 に release.yml へ移すまでは test-release も)、今のグループの
# 検証を待たせる。
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
# 専用機の runner は、**queued の job を先着順に拾わない** (#2062)。render.yml の
# 門番 (scripts/render-turn.sh の yield) は、merge_group の run が残っていて runner が空いていなければ
# render-pr を見送る。ただし判定は **積む前の 1 回だけ**で、merge queue が空いている間に門番を通って
# 専用機の queue に入った render-pr は、後からできた先頭の render と取り合う。2026-10-04 には
# 08:38 と 08:50 に積まれた render-pr 2 本が、08:53 に積まれた先頭の render より先に拾われ、
# 先頭は 37 分待って queue の期限 (60 分) の 22 分前に人の手の cancel で解けた (#2064)。
#
# そこで上の判定で **render.yml の今のグループの run (keep) が 1 本でもあれば**、専用機の枠を
# 数え、render-pr の run ごとに:
#
#   render-pr の job がまだ拾われていない (queued・待っている) → 枠を越える分だけ cancel
#                                                          (専用機の queue から退かせる)
#   render-pr の job が走っている (in_progress)  → 触らない (走っている 1 本は止めない)。枠を取る
#   門番の中・門番の後の run                     → 触らない。枠を取る (門番が見送るか、通した直後)
#   render-pr が終わっている                     → 触らない。枠を取らない
#   jobs を読めなかった                          → 触らず、枠を取ると数え、非 0 で終える
#
# **枠を越える分だけ cancel する** (#4018)。門番は runner が空いていれば group があっても
# render-pr を通し、merge_group の門番は render-pr を枠に数えて待つ。**枠は門番と同じ実装で
# 数える** — render-turn.sh の slots の mode (「専用機の枠を数える」) を、yield と同じ種類
# (render-pr と定期の job) で呼ぶ。今の group の run の数と、退かせられない枠 (走っている job・
# 門番の中・門番の後・読めなかった run) の数を runner の数 (RENDER_TURN_SLOTS・未設定なら 1) から
# 引き、残った枠の数だけ、まだ拾われていない render-pr を古い run から残す。yield なら見送る
# render-pr は残さない。N=1 なら今のグループがある限り残る枠は無く、今までどおり全部 cancel する。
# group の無い間に積まれた render-pr が group の枠を食う形 (#2064) は、枠を越えた分として
# cancel される。RENDER_TURN_SLOTS が 1 以上の整数でなければ、または render.yml の run の一覧を
# 読めなければ、render-pr に触らず非 0 で終える
#
# 今の group は、yield と違って keep と判定した run だけを数える (捨てられた group の run はここで
# cancel するので、枠を取り続けない)。
#
# render.yml の今のグループの run が無いとき (後ろにグループが居ない PR が外れた dequeued・
# 残った group が ci.yml だけを走らせている) は触らない。待たせる相手が居ないので、退かせても
# 得るものが無い。門番 (render-turn.sh の yield) が見送りに使うのと同じ範囲で見る — ci.yml の
# run も数えると、門番が正しく通した render-pr を退かせてしまう。**イベントの種類では分けない** — 上と同じく、
# 分岐を持つとそこだけ検査の外に出る。
#
# render-pr は必須ではないので、cancel しても merge の可否は変わらない。cancel された
# render-pr は誰も走らせ直さない。定期の検査
# (scheduled-*) は退かせない — 1 つの run の中では needs の鎖で 1 本ずつしか積まれず、
# 先頭の render と並ぶのは 1 本までである。受け入れた理由は ADR-0019 決定 7。枠には数える
# (yield と同じ。定期の job の上へ render-pr を重ねない)。
#
# cancel は run 単位で打つ。jobs を読んでから cancel するまでの間 (数秒) に runner が
# 拾った render-pr は、走り出していても止まる — 「走っている 1 本は止めない」はこの競り合い
# では守られない (必須ではないので受け入れる)。逆の取り残しもある: 門番が通すと決めてから
# job が queued になるまでの数秒に一覧を引くと、その run は門番の後として枠に数えるが、退かせは
# しない (枠を越えていれば、後ろの group の門番が数えて待つ)。
#
# **見直すのは group ができた瞬間と外れた瞬間だけである。** その後に門番を通らずに専用機へ
# 積まれた render-pr (門番が API を読めずに通した回・人が job 単位で rerun した回) は、次の
# 契機まで残る。拾われる直前に判定し直すには専用機の job に token を渡す必要があり、
# ADR-0019 決定 7 の「専用機の job は権限も秘密も持たない」とぶつかるので採らない (#2064 の
# 案 A)。
#
# ## 出力
#
#   <run id> <cancel|keep|done|unknown> <head_branch> <理由>
#
# head_branch は、merge_group の run ならグループの ref、render-pr の run なら PR のブランチである。
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
    --jq '.workflow_runs[] | [.id, .head_branch, .head_sha, .path] | @tsv')
  runs+="$got"$'\n'
done

status=0
live_group=false
live_groups=0
while IFS=$'\t' read -r id branch sha path; do
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
    # 門番が見送りに使うのは render.yml の run だけ。同じ範囲で「待たせる相手が居るか」を見る
    if [ "$path" = ".github/workflows/render.yml" ]; then
      live_group=true
      live_groups=$((live_groups + 1))
    fi
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

# 門番より前に積まれた render-pr を退かせる (#2064)。render.yml の今のグループの run が無ければ
# 待たせる相手が居ない
$live_group || exit "$status"

# 専用機の runner の数。門番 (render-turn.sh) と同じ変数を同じ既定で読む。1 以上の整数でなければ
# render-pr には触らない (判定できないものは生きている側に倒す)
SLOTS="${RENDER_TURN_SLOTS:-1}"
case "$SLOTS" in
  "" | *[!0-9]* | 0*)
    printf -- '- unknown - RENDER_TURN_SLOTS は 1 以上の整数で渡す: %s (render-pr は判定していない)\n' "'${RENDER_TURN_SLOTS}'"
    exit 1
    ;;
esac

# 専用機の枠は門番 (render-turn.sh) の実装で数える (render-turn.sh「専用機の枠を数える」)。数える
# run の種類も yield と同じ (render-pr と定期の job)。別々に数えると、yield なら見送る render-pr を
# ここが残し、門番の後の run を片方だけが数える (#4018)
slots_rc=0
slots=$(bash "$(dirname "${BASH_SOURCE[0]}")/render-turn.sh" slots 'pull_request|schedule') || slots_rc=$?
if [ "$slots_rc" -ne 0 ] && ! grep -q ' 読めなかった$' <<<"$slots"; then
  # render.yml の run の一覧そのものを読めなかった (または使い方の誤り)。判定できないので触らない
  printf -- '- unknown - 専用機の枠を読めなかった (終了コード %s・render-pr は判定していない)\n' "$slots_rc"
  exit 1
fi

# 枠を取っている run のうち、まだ拾われていない render-pr (queued と、待っている job) を古い run から
# 並べる (下で、空いた枠の数だけ残す)。走っている job・門番の中・門番の後・読めなかった run は
# 退かせられないので、枠を取っていると数える
taken=0
waiting=""
while read -r id event branch what job; do
  [ -n "$id" ] || continue
  if [ "$event" = pull_request ] && [ "$what" = render-pr ] && [ "$job" != in_progress ]; then
    waiting+="$id"$'\t'"$branch"$'\t'"$job"$'\n'
    continue
  fi
  taken=$((taken + 1))
  case "$what" in
    読めなかった)
      printf '%s unknown %s jobs を読めなかった (枠を取っていると数える)\n' "$id" "$branch"
      status=1
      ;;
    render-pr) printf '%s keep %s render-pr が専用機で走っている\n' "$id" "$branch" ;;
    *) printf '%s keep %s 専用機の枠を取っている (%s)\n' "$id" "$branch" "$what${job:+ $job}" ;;
  esac
done < <(sort -n -k1,1 <<<"$slots")

# 門番 (render-turn.sh の yield) と同じ数え方で、group と枠を取る job の合計が runner の数を越えない
# 分は残す (#4018)。越える分だけを cancel する
free=$((SLOTS - live_groups - taken))
while IFS=$'\t' read -r id branch job; do
  [ -n "$id" ] || continue
  if [ "$free" -gt 0 ]; then
    printf '%s keep %s render-pr は専用機の枠の内で待つ (group %s 本・枠を取る job %s 本・runner %s 本)\n' \
      "$id" "$branch" "$live_groups" "$taken" "$SLOTS"
    free=$((free - 1))
    taken=$((taken + 1))
    continue
  fi
  printf '%s cancel %s render-pr が専用機の queue で先頭の render を待たせる (%s)\n' \
    "$id" "$branch" "$job"
  cancel_run "$id" "$branch"
done <<<"$waiting"

exit "$status"
