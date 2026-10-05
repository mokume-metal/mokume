#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 止まった PR の判定 (#961)。下の「読み分け表」の実行者。
#
#   stall-watch.sh
#
# **手元で打ってもよい** (読み取りしかしない)。当番は数時間おきにしか回らないので
# (#1197)、急ぐときは自分で打って分類を読む。
#
# ## 読み分け表
#
# 以前は AGENTS.md が持っていた (#1364 でここへ移した)。行番号は下の「分類」が指す。
#
#   1. autoMerge: true + UNKNOWN で **check が 1 本も付かない**
#      原因: main と衝突していて合流後の木が作れず、pull_request の workflow が起動して
#      いない (#694)。衝突しても赤くならず DIRTY にもならない — 「まだ来ていない」では
#      なく「来ない」(#690)
#      対処: git merge-tree --write-tree origin/main HEAD で確かめ、手元で解いて push する。
#      ラベルの付け直しも close → reopen も効かない
#   2. autoMerge: false + BLOCKED
#      原因: auto-merge が外れた (#114 に出来事ごとの実測)。承認待ちはもう無い —
#      ADR-0044 が承認のゲートを外した (#2108)
#      対処: gh pr merge <番号> --auto --squash を打ち直す
#   3. 全 check が緑なのに進まない
#      原因: 同じコミットに残る古い失敗 check run が判定を固定している (#259)
#      対処: gh run rerun <run-id> --failed — **ただし pr-title と render-pr には打たない**
#      (#699・#2062。render-pr の rerun は門番を通らずに専用機へ積む。必須ではないので
#      打たなくても merge は止まらない)
#   4. autoMerge: false + CLEAN + 全 check 緑 で isInMergeQueue: true
#      原因: 止まっていない — 予約が queue へ移ると autoMergeRequest は null になる (#628)
#      対処: 何も打たない
#   5. 同じ 3 つで isInMergeQueue: false
#      原因: merge queue の合流後の木で必須チェック (ci-gate か、専用機の render) が落ちて
#      弾かれ、auto-merge も一緒に外れた (eject の副作用)
#      対処: 弾いた merge_group の run を読む。一過性か main 側で直ったなら予約を掛け直す
#      (当番は auto-merge-dropped として掛け直す)。PR 側で直すものなら直して push する
#   6. pr-title が落ちた
#      原因: タイトルが Conventional Commits ではない (design は Issue Type であって型ではない)
#      対処: タイトルを直し、**新しいコミットを push して run を作り直す** (空コミットでよい)。
#      **rerun しない** — pull_request の rerun は元のイベントを再生するので古いタイトルで判定し、
#      打つ前より悪くなる (#699)。タイトルを直すと edited で新しい run が走り pr-title は緑に
#      なるが、先の run の赤い pr-title と、それを受けた赤い ci-gate は同じコミットに残って必須
#      チェックを赤のままにし、rerun でも消えない (元のタイトルを読んで同じ赤を返す)。新しい
#      コミットは head の sha を変えるので、古い赤が丸ごと外れる (#2134)。直した後も、古い赤い
#      pr-title が rollup に残る間はここが bad-title を名乗り続ける (failing_names は名前ごとの
#      最新を見ない) — 新しいコミットを push すれば消える
#   7. close して作り直した PR が、全 check 緑なのに赤い
#      原因: close した側の run が付けた赤が同じコミットに残っている (#513)
#      対処: **新しい PR の側**の run を rerun する (close した側を打つと同じ赤を再生産する)。
#      render.yml の run は rerun しない (3 と同じ)
#   8. 描画に触れない PR も含めて、queue に入った PR が 60 分ごとに弾かれ続ける
#      原因: 専用機の runner が止まっていて、必須の render が queued のまま走らない
#      (#1774)。専用機は 1 台で、render は paths で絞らず merge_group ごとに走る。弾かれた
#      PR には 5 の行も出るが、掛け直しても同じ 60 分を待つだけである
#      対処: 1) 専用機の前で runner を戻す (ssh では入れない — #1767)。戻ったかは
#      Settings → Actions → Runners か gh api repos/<repo>/actions/runners (メンテナの権限)
#      で見る。2) 戻せない間も merge を通すなら、メンテナが .github/rulesets/main-protection.json
#      の必須チェックから render を外した定義を手元で scripts/apply-rulesets.sh --apply
#      してから、その定義の PR を出す — 必須チェックを消すときは適用を merge より先にする
#      (AGENTS.md「ブランチ保護の正本」)。戻すときは逆順 (PR を merge してから適用) にする。
#      外している間は描画を誰も見ないので、戻した後の最初の merge_group の render を確かめる
#   9. 専用機は online で busy なのに、queue の先頭の render だけが queued のまま進まない
#      原因: 専用機は queued の job を先着順に拾わない (#2062)。先頭の render が後から
#      積まれた render-pr や後ろの group の render に抜かれ続け、60 分の期限で弾かれる。
#      render.yml の門番 (render-turn) が積む順番を絞るので、普段は起きない。起きたら
#      門番が効いていない (render-turn が赤) か、門番より前に積まれた job が残っている。
#      門番より前に積まれた render-pr のうち、まだ拾われていないものは、group ができた
#      瞬間に queue-sweep が cancel する (#2064)。残りうるのは、走っている render-pr と
#      定期の scheduled-* (1 本まで・退かせない) と、queue-sweep が赤で掃除できなかった回
#      対処: 先頭の group と、専用機で走っている job の run の render-turn の要約と、先頭の
#      group の queue-sweep の出力 (render-pr の cancel 行) を読む。専用機で走っている・
#      queued の job が render-pr なら、gh run cancel で退かせてよい (必須ではなく、stall-act
#      も rerun しない — 戻すなら queue が空いてから push し直す)。弾かれた先頭は 5 と同じく予約を掛け直す。
#      8 との見分け: 8 は runner が offline で、どの render も走らない。9 は runner が
#      busy で、後ろの render や render-pr は走っている。runner が online なのに専用機の
#      job が 1 本も走らないまま先頭の render だけが queued なら (stall-watch は 8 と名乗る)、
#      job そのものが詰まっている — 先頭の PR を queue から出し入れして job を作り直す
#
# 読むときの注意:
#
# - **autoMerge: false は「外れた」と「queue に入った」の両方を指す** (#628)。分けるのは
#   isInMergeQueue の 1 欄だけで、gh pr view --json に無い — 掛け直す前にこれを見る:
#     gh api graphql -f query='{repository(owner:"mokume-metal",name:"mokume"){pullRequest(number:<番号>){isInMergeQueue mergeQueueEntry{position state}}}}' --jq '.data.repository.pullRequest'
#
# 表は PR が止まるたびに 1 行ずつ増えてきたが、**読むのは人間とエージェントの目だけ**
# だった。気付く経路が「誰かがたまたま見る」しか無いので、夜間や人が離れている間は
# 止まったままになる (#840 は 2 時間 47 分・#690 は 45 分)。
#
# 詰まりは *何かが起きること* ではなく ***何も起きないこと*** なので、pull_request や
# merge_group を契機に走る既存の機構 (review-gate / drawing-evidence / render)
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
# ## 分類 (表の 9 行に対応する)
#
#   分類                 別     表の行  なぜその別か
#   bad-title            name   6       タイトルの修正は人手。**rerun を打つと悪化する**
#   conflict             name   1       衝突の解消は人手
#   in-queue             quiet  4       止まっていない (queue が進めている)
#   stale-checks         act    3・7    古い失敗 check を打ち直す。冪等
#   auto-merge-dropped   act    2・5    予約を掛け直すだけ。ゲートは飛び越えない
#   runner-offline       name   8       専用機の前での操作と、保護の定義の適用は人手
#   unreadable           name   —       読めなかった。**何も判定していない**ので打たない
#
# **unreadable は表の行を持たない。** PR そのものか専用機の render の run が読めなかった回で、
# 詰まりの種類を言っていない — 黙って通す (quiet) と、読めていないことが誰にも見えない
# まま「正常」に混ざる (#1303)。
#
# 表の行 3 と 7 が同じ分類になるのは、対処が同じ (失敗ジョブの rerun) だからである。
# 7 が言う「**新しい PR の側**を rerun する」は、ここが open な PR しか見ないことで
# 自動的に満たされる。
#
# **承認待ち (awaiting-approval) と落ちた承認 (dismissed-approval) の分類はもう無い。**
# ADR-0044 が承認のゲートを外したので、BLOCKED のまま予約が外れていれば常に
# auto-merge-dropped である (#2108。分類の経緯は #1033・#1303)。
#
# ## 順序に意味がある
#
# **名乗る側を先に判定する。** 特に bad-title は stale-checks より前に置く — 後ろに
# 置くと「古い失敗 check がある」に当たって pr-title へ rerun を打ってしまい、古い
# タイトルで判定されて**打つ前より悪くなる** (#699)。
#
# ## 騒がしさの上限
#
# 名乗る行は人が動くまで消えないので、毎回赤くすると走るたびに通知が飛び、「毎回出る
# 注意は意味を失う」(#642) を踏む。**閾値 (既定 60 分) を超えて続いているものがある
# ときだけ 1 で終える。** それ以下は出力するだけで 0。
#
# 経過は「その状態を作った出来事の時刻」から測る — 失敗 check があればその completedAt、
# check が 1 本も無い conflict では PR の updatedAt。**状態をどこにも記録しない**ので、
# 当番が落ちていても復帰すればそのまま正しく測れる。
#
# **猶予の値は、走る間隔に合わせて動かさない** (#1197)。cron は 15 分ごとに頼んでいるが、
# GitHub の schedule は間引かれて実測は数時間おきにしか走らない。それでも値 (60 分) は
# 据え置く。
#
# - 猶予は上の「出来事の時刻」から測るので、走る間隔とは独立して意味を持つ
# - 間隔が詰まる日 (間引きが緩む日) にも、猶予が騒がしさの上限として同じように効く
#
# ## PR ではなくリポジトリを見る行 (runner-offline・#1774)
#
# runner-offline だけは PR ごとの状態ではなく、専用機という 1 台の状態を見る。番号の欄は
# `-` になる。判定は render.yml の終わっていない run の、**専用機の job** (ラベル
# mokume-render) の並びから読む — runners API は GITHUB_TOKEN では読めないためである。
# 「queued の専用機の job があり、in_progress の専用機の job が 1 本も無く、最古の queued が
# 猶予を超えた」ときに名乗る。
#
# - **run ではなく job で見る** (#2062)。render.yml の run はどれも先に GitHub ホストの門番
#   (render-turn) が走るので、専用機が止まっていても run は数秒で in_progress になる。run の
#   status で読むと、runner が落ちても「走っている」に倒れて黙る
# - **専用機の job が 1 本でも in_progress なら名乗らない。** runner は生きていて、1 台なので
#   順番を待っているだけである (render の所要は約 7〜8 分)
# - 生きている runner は queued の run を数秒で拾うので、猶予 (既定 15 分) は PR の猶予より
#   短い。**ここは猶予を超えたときにしか行を出さず、出したら必ず 1 で終える** — 猶予の
#   内の queued は正常な順番待ちなので、出すと毎回の注意になる (#642)
# - run の一覧を読めなかったら unreadable を名乗る。黙ると「止まっていない」に倒れる (#1303)
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

REPO="$(this_repo)"

# 名乗りを赤へ上げるまでの猶予。**readonly にしない** — 検査が短い値で回すため
STALL_MINUTES=${STALL_MINUTES:-60}

# 専用機の runner が render を拾わないまま過ぎてよい時間。理由は冒頭の「PR ではなく
# リポジトリを見る行」
RUNNER_STALL_MINUTES=${RUNNER_STALL_MINUTES:-15}

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

# 終わっていない render.yml の run の、専用機の job を「<status> <created_at>」で出す。
# 門番 (GitHub ホスト) の job は数えない。読めなければ非 0 で返す
runner_jobs() {
  local st ids="" got id
  for st in queued in_progress; do
    got=$(gh api "repos/$REPO/actions/workflows/render.yml/runs?status=$st&per_page=100" \
      --jq '.workflow_runs[].id' 2>/dev/null) || return 1
    ids+="$got"$'\n'
  done
  for id in $(printf '%s' "$ids" | sort -u); do
    gh api "repos/$REPO/actions/runs/$id/jobs?per_page=100" \
      --jq '.jobs[] | select((.labels // []) | index("mokume-render"))
        | select(.status == "queued" or .status == "in_progress")
        | "\(.status) \(.created_at)"' 2>/dev/null || return 1
  done
}

# --- 走査 -------------------------------------------------------------------

overdue=0

# 専用機の死活。PR の走査より先に出す — 止まっていれば、下の PR の行 (弾かれた・予約が
# 外れた) の原因はたいていここにある
if ! jobs=$(runner_jobs); then
  say_line - unreadable name 0 "専用機の render の run を読めなかった (runner の死活を判定していない)"
else
  oldest_queued=$(awk '$1 == "queued" { print $2 }' <<<"$jobs" | sort | sed -n '1p')
  running=$(awk '$1 == "in_progress" { n++ } END { print n + 0 }' <<<"$jobs")
  if [ -n "$oldest_queued" ] && [ "$running" -eq 0 ]; then
    mins=$(minutes_since "$oldest_queued")
    if [ "$mins" -ge "$RUNNER_STALL_MINUTES" ]; then
      say_line - runner-offline name "$mins" \
        "専用機の runner が render を拾っていない — 戻す手順は表の 8 行目"
      overdue=1
    fi
  fi
fi

# Draft は当番の対象外である。**作業中の PR を Draft にしておくのが opt-out** である。
# **fork からの PR も見ない** (#1361)。予約を掛けるかは引き取るメンテナが決める —
# 当番が掛けると、メンテナが引き取ると判断する前に queue へ入りうる
numbers=$(gh pr list --repo "$REPO" --state open --limit 100 \
  --json number,isDraft,isCrossRepository \
  --jq '.[] | select((.isDraft or .isCrossRepository) | not) | .number') || {
  echo "open な PR の一覧を読めなかった" >&2
  exit 1
}

for n in $numbers; do
  json=$(gh pr view "$n" --repo "$REPO" \
    --json isDraft,autoMergeRequest,mergeStateStatus,statusCheckRollup,updatedAt \
    2>/dev/null) || {
    say_line "$n" unreadable name 0 "PR を読めなかった (判定していない)"
    continue
  }

  auto=$(jq -r '.autoMergeRequest != null' <<<"$json")
  state=$(jq -r '.mergeStateStatus // ""' <<<"$json")
  updated=$(jq -r '.updatedAt // ""' <<<"$json")

  checks=$(normalize_checks <<<"$json")
  failing=$(failing_names <<<"$checks")
  failed_at=$(newest_failure_at <<<"$checks")
  others=$(jq -r 'length' <<<"$checks")

  # 名乗る行を先に判定する。順序の理由は冒頭の「順序に意味がある」
  if contains_name "$failing" pr-title; then
    mins=$(minutes_since "${failed_at:-$updated}")
    say_line "$n" bad-title name "$mins" \
      "タイトルが Conventional Commits でない — 直して、新しいコミットを push する (rerun は打たない・#699)"
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

  # BLOCKED でも承認待ちとは読まない。承認のゲートは ADR-0044 で外れた (#2108)
  if [ "$auto" != true ]; then
    say_line "$n" auto-merge-dropped act 0 "auto-merge が外れている — 予約を掛け直す"
    continue
  fi
done

exit "$overdue"
