#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 止まった PR の判定 (#961)。AGENTS.md「止まって見えるときの読み分け」表の実行者。
#
#   stall-watch.sh
#
# 表は PR が止まるたびに 1 行ずつ増えてきたが、**読むのは人間とエージェントの目だけ**
# だった。気付く経路が「誰かがたまたま見る」しか無いので、夜間や人が離れている間は
# 止まったままになる (#840 は 2 時間 47 分・#690 は 45 分)。
#
# 詰まりは *何かが起きること* ではなく ***何も起きないこと*** なので、pull_request や
# merge_group を契機に走る既存の機構 (review-gate / render-status / drawing-evidence)
# では原理的に捕まえられない。時計を持つ機構が要る、というのがこのスクリプトの理由で
# ある。
#
# ## ここは判定しかしない
#
# 打つのは scripts/stall-act.sh で、**スクリプトごと分けてある**。理由は
# report-ruleset-drift.sh を check-rulesets.sh から分けたのと同じで、手元で様子を見る
# ために打っただけで auto-merge が掛かってしまうのを防ぐため。こちらは読み取りしか
# しないので、いつ打っても安全である。
#
# ## 分類 (表の 7 行に対応する)
#
#   分類                 別     表の行  なぜその別か
#   bad-title            name   6       タイトルの修正は人手。**rerun を打つと悪化する**
#   ejected              name   5       make catch-up は手元で絵を回す必要がある
#   conflict             name   1       衝突の解消は人手
#   in-queue             quiet  4       止まっていない (queue が進めている)
#   stale-checks         act    3・7    古い失敗 check を打ち直す。冪等
#   awaiting-approval    quiet  2       承認待ちは正常な状態
#   auto-merge-dropped   act    2       予約を掛け直すだけ。ゲートは飛び越えない
#
# 表の行 3 と 7 が同じ分類になるのは、対処が同じ (失敗ジョブの rerun) だからである。
# 7 が言う「**新しい PR の側**を rerun する」は、ここが open な PR しか見ないことで
# 自動的に満たされる。
#
# ## 順序に意味がある
#
# **名乗る側を先に判定する。** 特に bad-title は stale-checks より前に置く — 後ろに
# 置くと「古い失敗 check がある」に当たって pr-title へ rerun を打ってしまい、古い
# タイトルで判定されて**打つ前より悪くなる** (#699)。
#
# ## 騒がしさの上限
#
# 名乗る行は人が動くまで消えないので、毎回赤くすると 15 分ごとに通知が飛び、「毎回出る
# 注意は意味を失う」(#642) を踏む。**閾値 (既定 60 分) を超えて続いているものがある
# ときだけ 1 で終える。** それ以下は出力するだけで 0。
#
# 経過は「その状態を作った出来事の時刻」から測る — 失敗 check があればその completedAt、
# check が 1 本も無い conflict では PR の updatedAt。**状態をどこにも記録しない**ので、
# 当番が落ちていても復帰すればそのまま正しく測れる。
#
# ## 出力
#
#   <番号> <分類> <act|name|quiet> <経過分> <説明>
#
# 終了コード: 0 = 詰まりなし / 閾値内、1 = 閾値を超えた名乗りがある。
#
# 呼び出しは .github/workflows/stall-watch.yml、検査は scripts/tests/stall_watch_test.py。
set -euo pipefail

# リポジトリの owner/repo。**literal は scripts/repo-slug.sh の 1 箇所だけ** (#818)
# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"
# 変更ファイルの取り方。gh pr view --json files には上限がある (#793)
# shellcheck source=scripts/pr-files.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-files.sh"
# 「承認が要るパスに触れているか」— BLOCKED の 2 つの意味を分けるのに使う
# shellcheck source=scripts/protected-paths.sh
. "$(dirname "${BASH_SOURCE[0]}")/protected-paths.sh"
# 「描画に触れているか」— ejected の説明で先頭かどうかを言うのに使う
# shellcheck source=scripts/drawing-paths.sh
. "$(dirname "${BASH_SOURCE[0]}")/drawing-paths.sh"
# 描画 PR の順番の判定。**自分で drawing-paths.sh を読み込まない**ので読み手が並べる
# shellcheck source=scripts/drawing-queue.sh
. "$(dirname "${BASH_SOURCE[0]}")/drawing-queue.sh"
# 手元の実行の報告の綴り。探す側だけ直書きにすると打つ側の改名に付いていけない (#785)
# shellcheck source=scripts/render-context.sh
. "$(dirname "${BASH_SOURCE[0]}")/render-context.sh"

REPO="$(this_repo)"

# 名乗りを赤へ上げるまでの猶予。**readonly にしない** — 検査が短い値で回すため
STALL_MINUTES=${STALL_MINUTES:-60}

# 「まだ答えが出ていない」と読む check の結果。ここに無いものは失敗として扱う
# (FAILURE / ERROR / CANCELLED / TIMED_OUT / ACTION_REQUIRED / STARTUP_FAILURE)
readonly UNSETTLED='["PENDING","EXPECTED","QUEUED","IN_PROGRESS",""]'
readonly PASSED='["SUCCESS","NEUTRAL","SKIPPED"]'

# ISO8601 を epoch 秒へ。GNU と BSD の両方で通す形にする (CI は Linux・手元は macOS)
epoch_of() { # $1=ISO8601 (空可)
  local iso=$1
  [ -n "$iso" ] || { echo 0; return 0; }
  date -u -d "$iso" +%s 2>/dev/null && return 0
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null && return 0
  echo 0
}

# いま何分前か
minutes_since() { # $1=ISO8601 (空可)
  local moment now
  moment=$(epoch_of "$1")
  [ "$moment" -gt 0 ] || { echo 0; return 0; }
  now=$(date -u +%s)
  echo $(((now - moment) / 60))
}

# PR の checks を {name,result,at} の並びへ均す。CheckRun と StatusContext で
# 欄の名前が違うので、ここで 1 つの形にしておく
normalize_checks() { # 標準入力=PR の JSON
  jq -c '[.statusCheckRollup[]? | {
    name: (.name // .context // ""),
    result: (.conclusion // .state // ""),
    at: (.completedAt // .startedAt // .createdAt // "")
  }]'
}

# 失敗している check の名前 (重複を畳む)
failing_names() { # 標準入力=均した checks
  jq -r --argjson unsettled "$UNSETTLED" --argjson passed "$PASSED" \
    '[.[] | . as $c
          | select(($unsettled | index($c.result)) == null)
          | select(($passed | index($c.result)) == null)
          | $c.name]
     | unique | join(" ")'
}

# 失敗している check のうち、いちばん新しいものの時刻
newest_failure_at() { # 標準入力=均した checks
  jq -r --argjson unsettled "$UNSETTLED" --argjson passed "$PASSED" \
    '[.[] | . as $c
          | select(($unsettled | index($c.result)) == null)
          | select(($passed | index($c.result)) == null)
          | $c.at]
     | sort | last // ""'
}

# 「同じ名前で、新しい方は緑・古い方が赤」— 判定を固定している古い失敗 check (#259 / #513)
stale_names() { # 標準入力=均した checks
  jq -r --argjson unsettled "$UNSETTLED" --argjson passed "$PASSED" '
    [ group_by(.name)[]
      | . as $group
      | ($group | sort_by(.at) | last) as $latest
      | select(($passed | index($latest.result)) != null)
      | select([$group[] | . as $c
                          | select(($unsettled | index($c.result)) == null)
                          | select(($passed | index($c.result)) == null)] | length > 0)
      | $latest.name ]
    | unique | join(" ")'
}

# 名前の並びに含まれるか (前後の空白ごと照合する — 部分一致を拾わないため)
contains_name() { # $1=名前の並び $2=探す名前
  case " $1 " in *" $2 "*) return 0 ;; esac
  return 1
}

# queue に居るか。**gh pr view には無い欄**なので GraphQL で引く (#628)。
# 読めなかったときは「居ない」に倒さず空で返し、呼び手が判定を諦められるようにする
in_merge_queue() { # $1=PR 番号
  # shellcheck disable=SC2016
  gh api graphql -f owner="${REPO%%/*}" -f name="${REPO##*/}" -F number="$1" \
    -f query='query($owner:String!,$name:String!,$number:Int!){
      repository(owner:$owner,name:$name){pullRequest(number:$number){isInMergeQueue}}}' \
    --jq '.data.repository.pullRequest.isInMergeQueue' 2>/dev/null || echo ""
}

say_line() { # $1=番号 $2=分類 $3=別 $4=経過分 $5=説明
  printf '%s %s %s %s %s\n' "$1" "$2" "$3" "$4" "$5"
}

# --- 走査 -------------------------------------------------------------------

# Draft は当番の対象外である。**作業中の PR を Draft にしておくのが opt-out** で、
# それは描画 PR の順番待ち (AGENTS.md) が既に採っている形と同じ
numbers=$(gh pr list --repo "$REPO" --state open --limit 100 \
  --json number,isDraft --jq '.[] | select(.isDraft | not) | .number') || {
  echo "open な PR の一覧を読めなかった" >&2
  exit 1
}

overdue=0

for n in $numbers; do
  json=$(gh pr view "$n" --repo "$REPO" \
    --json isDraft,autoMergeRequest,mergeStateStatus,statusCheckRollup,latestReviews,updatedAt \
    2>/dev/null) || {
    say_line "$n" unreadable name 0 "PR を読めなかった (判定していない)"
    continue
  }

  auto=$(jq -r '.autoMergeRequest != null' <<<"$json")
  state=$(jq -r '.mergeStateStatus // ""' <<<"$json")
  updated=$(jq -r '.updatedAt // ""' <<<"$json")
  approved=$(jq -r '[.latestReviews[]? | select(.state == "APPROVED")] | length > 0' <<<"$json")

  checks=$(normalize_checks <<<"$json")
  failing=$(failing_names <<<"$checks")
  failed_at=$(newest_failure_at <<<"$checks")
  # 手元の commit status は「check が付いていない」の数に入れない (AGENTS.md 行 1)
  others=$(jq -r --arg r "$RENDER_CONTEXT" '[.[] | select(.name != $r)] | length' <<<"$checks")

  # 名乗る行を先に判定する。順序の理由は冒頭の「順序に意味がある」
  if contains_name "$failing" pr-title; then
    mins=$(minutes_since "${failed_at:-$updated}")
    say_line "$n" bad-title name "$mins" \
      "タイトルが Conventional Commits でない — 直す (rerun は打たない・#699)"
    [ "$mins" -lt "$STALL_MINUTES" ] || overdue=1
    continue
  fi

  if contains_name "$failing" "$RENDER_CONTEXT"; then
    mins=$(minutes_since "${failed_at:-$updated}")
    ahead=$(ahead_drawing_pr "$REPO" "$n" 2>/dev/null || echo '?')
    case "$ahead" in
      '' | draft) note="自分が先頭 — 手元で make catch-up を打つ" ;;
      '?') note="先に居る描画 PR を読めなかった (手元で make catch-up を試す)" ;;
      *) note="先に #$ahead が居る — その merge を待つ (いま打っても無駄になる)" ;;
    esac
    say_line "$n" ejected name "$mins" "$note"
    [ "$mins" -lt "$STALL_MINUTES" ] || overdue=1
    continue
  fi

  # main と衝突していると合流後の木が作れず、pull_request の workflow が起動しない。
  # 赤くならず**無音**になるので、状態欄からも衝突とは読めない (#694)
  if [ "$auto" = true ] && [ "$state" = UNKNOWN ] && [ "$others" -eq 0 ]; then
    mins=$(minutes_since "$updated")
    say_line "$n" conflict name "$mins" \
      "main と衝突していて check が 1 本も付かない — 手元で解いて push する"
    [ "$mins" -lt "$STALL_MINUTES" ] || overdue=1
    continue
  fi

  # 予約が queue へ移ると autoMergeRequest は null になる。**外れたのではない** (#628)
  if [ "$auto" != true ]; then
    queued=$(in_merge_queue "$n")
    if [ "$queued" = true ]; then
      say_line "$n" in-queue quiet 0 "queue が進めている (何も打たない)"
      continue
    fi
  fi

  stale=$(stale_names <<<"$checks")
  if [ -n "$stale" ]; then
    say_line "$n" stale-checks act "$(minutes_since "${failed_at:-$updated}")" \
      "古い失敗 check が判定を固定している ($stale)"
    continue
  fi

  if [ "$auto" != true ]; then
    # BLOCKED は「承認待ち」と「auto-merge が外れた」の両方を指す。分けるのは
    # 「承認が要るパスに触れているか」と「もう承認されたか」の 2 つである
    if [ "$state" = BLOCKED ] && [ "$approved" != true ] &&
      pr_files "$REPO" "$n" | touches_protected_path; then
      say_line "$n" awaiting-approval quiet 0 "重要パスに触れる PR の承認待ち (正常)"
      continue
    fi
    say_line "$n" auto-merge-dropped act 0 "auto-merge が外れている — 予約を掛け直す"
    continue
  fi
done

exit "$overdue"
