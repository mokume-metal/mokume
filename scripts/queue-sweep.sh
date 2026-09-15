#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# merge queue が捨てたグループの run を cancel する (#1265)。
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
# ## 出力
#
#   <run id> <cancel|keep|done|unknown> <head_branch> <理由>
#
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

runs=""
for active in $ACTIVE_STATUSES; do
  got=$(gh api --paginate \
    "repos/$REPO/actions/runs?event=merge_group&status=$active&per_page=100" \
    --jq '.workflow_runs[] | [.id, .head_branch, .head_sha] | @tsv')
  runs+="$got"$'\n'
done

status=0
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
    continue
  fi

  if [ -z "$tip" ]; then
    reason="ref が消えた (グループが捨てられた)"
  else
    reason="ref の先端が ${tip:0:8} に変わった (作り直された)"
  fi
  printf '%s cancel %s %s\n' "$id" "$branch" "$reason"

  $dry_run && continue
  # 判定から cancel までの間に run が終わっていれば 409 が返る。捨てたかった run が
  # 既に居ないだけなので失敗にしない
  if ! err=$(gh api -X POST "repos/$REPO/actions/runs/$id/cancel" --silent 2>&1); then
    case "$err" in
      *"HTTP 409"*) printf '%s done %s cancel の前に終わっていた\n' "$id" "$branch" ;;
      *)
        printf '%s unknown %s cancel に失敗した: %s\n' "$id" "$branch" "$err"
        status=1
        ;;
    esac
  fi
done < <(printf '%s' "$runs" | sort -u)

exit "$status"
