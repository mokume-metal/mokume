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
# ## 打つのは 1 つの分類だけ
#
#   stale-checks         判定を固定している古い失敗ジョブを rerun する
#
# 名乗る (name) と黙る (quiet) の行には何もしない。**入力の 3 列目がその別**なので、
# ここで分類名を数え直さない — 判定は 1 箇所に保つ (ADR-0001 原則 9)。
#
# ## auto-merge は掛け直さない (#2614)
#
# 以前は auto-merge-dropped にも gh pr merge --auto --squash を打っていたが、**一度も
# 成功しなかった** (2026-10-13 に数えた直近 60 回で 0 回)。当番の GITHUB_TOKEN
# (contents: read) では enablePullRequestAutoMerge が `Resource not accessible by
# integration` (FORBIDDEN) で拒まれ、contents: write を足すと通る (probe の run
# 38541307087)。リポジトリへの書き込みを当番に渡すかは人の判断なので、権限は広げずに
# 掛け直しを消した。stall-watch.sh が名乗り、外れてから猶予を超えたら赤で人に返す。
# 掛け直すのは人である。
#
# ## gh の失敗の理由を捨てない (#2614)
#
# 失敗の行には gh の stderr を 1 行に畳んで添える。以前は 2>/dev/null で捨てていたので、
# 上の掛け直しが 60 回続けて落ちても理由がどこにも残らなかった。
#
# ## rerun は run 単位で打ってはいけない
#
# `gh run rerun <run-id> --failed` は**その run の失敗ジョブを全部**打ち直す。
# pr-title は ci.yml の同じ run の中に居るので、run 単位で打つと巻き添えで pr-title まで
# rerun してしまう。pull_request の rerun は元のイベントを再生するので、**古いタイトルで
# 判定され、その失敗が最新の結果になって打つ前より悪くなる** (#699)。
#
# だから**失敗ジョブを 1 つずつジョブの rerun の API で打ち、下の除外リストを飛ばす**。
# `gh run rerun --job` を使わないのは、拒まれたときに API の文面を捨てて
# 「job N cannot be rerun」としか言わないためである (#2614)。`gh api` は文面を
# 「gh: <message> (HTTP 403)」で返すので、下の 2 つを読み分けられる。
#
# ## 拒まれても赤にしない 2 つ (#2614)
#
# 次の 2 つは打つ側の失敗ではなく、打つ対象がその回に居ないだけなので、名乗って 0 のまま進む
# (queue-sweep.sh が cancel の 409 を読み分けるのと同じ形)。文面は 2026-10-14 に実物で取った:
#
# - `The workflow run containing this job is already running` — 同じ run の別のジョブを
#   先に打つと run が走り出し、残りは拒まれる。走り終われば次の回に打てる
# - `Only jobs from the current attempt can be re-run` — commit の check run の一覧には、
#   走り直す前の attempt のジョブも残る。それは打ち直せず、新しい attempt のジョブが同じ
#   一覧に居る
#
# それ以外の拒否 (権限など) は理由を添えて 1 で終える。
#
# ## 除外の基準は名前ではなく「何を読むジョブか」
#
# 除外が要るのは「**凍結されたイベントペイロードの可変な欄** (title / body / labels) を
# 読むジョブ」である。番号や sha は run の中で変わらないので、それだけを受け取る
# ジョブ (review-gate / drawing-evidence) は rerun して安全である —
# 本文は GH_TOKEN で都度取り直すからである。
#
# いま当てはまるのは pr-title 1 本だけだが、**同じ形のジョブが増えたらここへ足さないと
# 同じ壊れ方をする**。人手の対応にしないため、scripts/tests/stall_watch_test.py が
# ci.yml を読んで「可変欄を env へ流しているジョブが、このリストに載っているか」を見る
# (#801 と同じ形)。
#
# **もう 1 つの基準は「門番の後ろに居るジョブか」** (#2062)。render.yml の render-pr は、
# GitHub ホストの門番 (render-turn) を通ってから専用機に積まれる。ジョブ単位の rerun は
# 門番を走らせ直さないので、merge queue の render が専用機を待っている最中でも render-pr を
# 専用機へ直に積み、先頭の render と取り合わせる。render-pr は必須ではなく、rerun しなくても
# merge は止まらない。cancel された render-pr (queue-sweep が group のできた瞬間に退かせた
# もの・#2064、stall-watch の読み分け 9 で人が退かせたもの) が、
# 別の check の stale-checks の巻き添えで戻ってくるのも、これで止まる。
#
# **3 つ目の基準は「最新の run の結論が判定になるジョブか」** (#2668)。pr-gate
# (.github/workflows/pr-gate.yml) は直すと新しい run が付け直し、concurrency が走っている古い
# run を cancel する。head SHA に残る古い赤・cancelled は直す前の名残で、打ち直しても得るものが
# 無い。打てば同じ group で走っている新しい run を cancel しうる。stall-watch.sh の
# normalize_checks も古い pr-gate を stale-checks に数えない。
#
# 検査は scripts/tests/stall_watch_test.py。
set -euo pipefail

# リポジトリの owner/repo。**literal は scripts/repo-slug.sh の 1 箇所だけ** (#818)
# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"

REPO="$(this_repo)"

# rerun を打ってはならないジョブ。**readonly にしない** — 検査が差し替えて回すため
RERUN_EXCLUDED=${RERUN_EXCLUDED:-"pr-title render-pr pr-gate"}

LOG="${1:?stall-watch.sh の出力ファイルが必要}"
[ -f "$LOG" ] || {
  echo "判定の出力ファイルが無い: $LOG" >&2
  exit 66
}

failed=0

# gh の stderr の受け皿。標準出力を値として受ける呼び出しでも理由を拾えるように、
# ファイルへ逃がしてから読む
errfile=$(mktemp)
trap 'rm -f "$errfile"' EXIT

say() { printf '%s\n' "$*"; }

# 直前の gh の stderr を 1 行に畳む。空なら空と言う (黙ると「理由なし」と読めない)
reason() {
  local text
  text=$(tr '\n' ' ' <"$errfile" | sed -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //' -e 's/ $//')
  printf '%s' "${text:-gh は理由を出さなかった}"
}

excluded() { # $1=ジョブ名
  case " $RERUN_EXCLUDED " in *" $1 "*) return 0 ;; esac
  return 1
}

rerun_stale_jobs() { # $1=PR 番号
  local n=$1 sha runs name id acted=0
  sha=$(gh pr view "$n" --repo "$REPO" --json headRefOid --jq '.headRefOid' 2>"$errfile") || {
    say "#$n: head の commit を読めなかった: $(reason)" >&2
    failed=1
    return 0
  }
  # check run の id は、Actions のジョブ id そのものである
  runs=$(gh api "repos/$REPO/commits/$sha/check-runs" --paginate \
    --jq '.check_runs[] | select(.conclusion == "failure" or .conclusion == "cancelled"
                                 or .conclusion == "timed_out" or .conclusion == "startup_failure")
          | "\(.name) \(.id)"' 2>"$errfile") || {
    say "#$n: check run の一覧を読めなかった: $(reason)" >&2
    failed=1
    return 0
  }
  while read -r name id; do
    [ -n "${id:-}" ] || continue
    if excluded "$name"; then
      say "#$n: $name は rerun しない (凍結されたペイロードを読む #699・門番の後ろに居る #2062・最新の run が判定 #2668 のどれか)"
      continue
    fi
    if gh api "repos/$REPO/actions/jobs/$id/rerun" -X POST --silent 2>"$errfile"; then
      say "#$n: $name を rerun した"
      acted=1
    else
      case "$(reason)" in
        *"is already running"*)
          say "#$n: $name は同じ run が走り直している — 次の回に回す" ;;
        *"Only jobs from the current attempt"*)
          say "#$n: $name は古い attempt のジョブで打ち直せない — 新しい attempt の側を見る" ;;
        *)
          say "#$n: $name を rerun できなかった: $(reason)" >&2
          failed=1
          ;;
      esac
    fi
  done <<<"$runs"
  [ "$acted" -eq 1 ] || say "#$n: 打てる失敗ジョブが無かった"
}

while read -r number kind action _rest; do
  [ -n "${number:-}" ] || continue
  [ "${action:-}" = act ] || continue
  case "$kind" in
    stale-checks) rerun_stale_jobs "$number" ;;
    *) say "打ち方を知らない分類: $kind (#$number)" >&2; failed=1 ;;
  esac
done <"$LOG"

exit "$failed"
