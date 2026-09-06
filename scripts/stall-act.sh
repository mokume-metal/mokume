#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 止まった PR へ、表が定める対処を打つ (#961)。
#
#   stall-act.sh <stall-watch.sh の出力ファイル>
#
# 判定 (scripts/stall-watch.sh) と**スクリプトごと分けてある**。理由は
# report-ruleset-drift.sh を check-rulesets.sh から分けたのと同じで、手元で様子を見る
# ために判定を打っただけで auto-merge が掛かってしまうのを防ぐため。打つのはここだけで、
# 呼ぶのは .github/workflows/stall-watch.yml である。
#
# ## 打つのは 2 つの分類だけ
#
#   auto-merge-dropped   gh pr merge --auto --squash を掛け直す
#   stale-checks         判定を固定している古い失敗ジョブを rerun する
#
# 名乗る (name) と黙る (quiet) の行には何もしない。**入力の 3 列目がその別**なので、
# ここで分類名を数え直さない — 判定は 1 箇所に保つ (ADR-0001 原則 9)。
#
# **auto-merge の掛け直しはゲートを飛び越えない。** --auto は予約にすぎず、承認も
# 必須チェックもそのまま効く。だから「承認待ちの PR を勝手に入れてしまう」ことは
# 起こらない (承認待ちはそもそも quiet に分類されるので、ここへは来ない)。
#
# ## rerun は run 単位で打ってはいけない
#
# `gh run rerun <run-id> --failed` は**その run の失敗ジョブを全部**打ち直す。
# pr-title は ci.yml の同じ run の中に居るので、run 単位で打つと巻き添えで pr-title まで
# rerun してしまう。pull_request の rerun は元のイベントを再生するので、**古いタイトルで
# 判定され、その失敗が最新の結果になって打つ前より悪くなる** (#699)。
#
# だから**失敗ジョブを 1 つずつ `gh run rerun --job` で打ち、下の除外リストを飛ばす**。
#
# ## 除外の基準は名前ではなく「何を読むジョブか」
#
# 除外が要るのは「**凍結されたイベントペイロードの可変な欄** (title / body / labels) を
# 読むジョブ」である。番号や sha は run の中で変わらないので、それだけを受け取る
# ジョブ (review-gate / drawing-evidence / render-signal) は rerun して安全である —
# 本文は GH_TOKEN で都度取り直すからである。
#
# いま当てはまるのは pr-title 1 本だけだが、**同じ形のジョブが増えたらここへ足さないと
# 同じ壊れ方をする**。人手の対応にしないため、scripts/tests/stall_watch_test.py が
# ci.yml を読んで「可変欄を env へ流しているジョブが、このリストに載っているか」を見る
# (#801 と同じ形)。
#
# 検査は scripts/tests/stall_watch_test.py。
set -euo pipefail

# リポジトリの owner/repo。**literal は scripts/repo-slug.sh の 1 箇所だけ** (#818)
# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"

REPO="$(this_repo)"

# rerun を打ってはならないジョブ。**readonly にしない** — 検査が差し替えて回すため
RERUN_EXCLUDED=${RERUN_EXCLUDED:-"pr-title"}

LOG="${1:?stall-watch.sh の出力ファイルが必要}"
[ -f "$LOG" ] || {
  echo "判定の出力ファイルが無い: $LOG" >&2
  exit 66
}

failed=0

say() { printf '%s\n' "$*"; }

excluded() { # $1=ジョブ名
  case " $RERUN_EXCLUDED " in *" $1 "*) return 0 ;; esac
  return 1
}

rearm_auto_merge() { # $1=PR 番号
  if gh pr merge "$1" --repo "$REPO" --auto --squash >/dev/null 2>&1; then
    say "#$1: auto-merge を掛け直した"
  else
    say "#$1: auto-merge を掛け直せなかった" >&2
    failed=1
  fi
}

rerun_stale_jobs() { # $1=PR 番号
  local n=$1 sha runs name id acted=0
  sha=$(gh pr view "$n" --repo "$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) || {
    say "#$n: head の commit を読めなかった" >&2
    failed=1
    return 0
  }
  # check run の id は、Actions のジョブ id そのものである
  runs=$(gh api "repos/$REPO/commits/$sha/check-runs" --paginate \
    --jq '.check_runs[] | select(.conclusion == "failure" or .conclusion == "cancelled"
                                 or .conclusion == "timed_out" or .conclusion == "startup_failure")
          | "\(.name) \(.id)"' 2>/dev/null) || {
    say "#$n: check run の一覧を読めなかった" >&2
    failed=1
    return 0
  }
  while read -r name id; do
    [ -n "${id:-}" ] || continue
    if excluded "$name"; then
      say "#$n: $name は rerun しない (凍結されたペイロードを読むジョブ・#699)"
      continue
    fi
    if gh run rerun --repo "$REPO" --job "$id" >/dev/null 2>&1; then
      say "#$n: $name を rerun した"
      acted=1
    else
      say "#$n: $name を rerun できなかった" >&2
      failed=1
    fi
  done <<<"$runs"
  [ "$acted" -eq 1 ] || say "#$n: 打てる失敗ジョブが無かった"
}

while read -r number kind action _rest; do
  [ -n "${number:-}" ] || continue
  [ "${action:-}" = act ] || continue
  case "$kind" in
    auto-merge-dropped) rearm_auto_merge "$number" ;;
    stale-checks) rerun_stale_jobs "$number" ;;
    *) say "打ち方を知らない分類: $kind (#$number)" >&2; failed=1 ;;
  esac
done <"$LOG"

exit "$failed"
