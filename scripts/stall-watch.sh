#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 止まった PR の判定 (#961)。下の「読み分け表」を実行するスクリプト。
#
#   stall-watch.sh
#
# **手元で実行してもよい** (読み取りしかしない)。監視ジョブは数時間おきにしか回らないので
# (#1197)、急ぐときは自分で実行して分類を読む。
#
# ## 読み分け表
#
# 以前は AGENTS.md にあった (#1364 でここへ移した)。行番号は下の「分類」が指す。
#
#   1. autoMerge: true + UNKNOWN で **check が 1 本も付かない**
#      原因: main と衝突していてマージ後のツリーが作れず、pull_request の workflow が起動して
#      いない (#694)。衝突しても失敗にならず DIRTY にもならない — 「まだ来ていない」では
#      なく「来ない」(#690)
#      対処: git merge-tree --write-tree origin/main HEAD で確かめ、手元で解いて push する。
#      ラベルの付け直しも close → reopen も効かない
#   2. autoMerge: false + BLOCKED
#      原因: auto-merge が外れた (#114 に出来事ごとの実測)。承認待ちはもう無い —
#      ADR-0044 が承認のゲートを外した (#2108)
#      対処: gh pr merge <番号> --auto --squash を再実行する
#   3. autoMerge: false + CLEAN + 全 check が成功 で isInMergeQueue: true
#      原因: 止まっていない — 予約が queue へ移ると autoMergeRequest は null になる (#628)
#      対処: 何も実行しない
#   4. 同じ 3 つで isInMergeQueue: false
#      原因: merge queue のマージ後のツリーで必須チェック (ci-gate か、専用機の render) が失敗して
#      queue から外され、auto-merge も一緒に外れた (eject の副作用)
#      対処: 外した merge_group の run を読む。一過性か main 側で直ったなら予約を掛け直す。
#      PR 自身の必須チェックが成功していて原因が環境 (専用機の前検査の赤・時間切れ・他 PR の
#      merge 後に解いた衝突) だと読めたら、エージェントが人に聞かずに掛け直してよい (AGENTS.md
#      「マージ」)。監視ジョブ自身は掛けない — auto-merge-dropped と報告し、猶予を超えたら
#      失敗にするだけ (#2614)。PR 側で直すものなら直して push する
#   5. pr-gate のタイトルのチェックが失敗した
#      原因: タイトルが Conventional Commits ではない (design は Issue Type であって型ではない)
#      対処: タイトルを直す。edited で pr-gate の新しい run が作られ、必須はその結論を読む
#      (作成順で最新の suite・規則は scripts/ci-gate.sh 冒頭)
#      — 打ち直しも新しいコミットも要らない (pr-gate はタイトルを API から読む・#2669)。
#      **最新 (run の id の順) の pr-gate が失敗していて、そのタイトルの step が失敗している PR だけ**が
#      ここで報告される (step の結論は Actions の job の API で読む。照合の正規表現は持たない)
#   6. 描画に触れない PR も含めて、queue に入った PR がタイムアウト (95 分) ごとに外され続ける
#      原因: 専用機の runner が止まっていて、必須の render が queued のまま走らない
#      (#1774)。専用機は runner の数 (RENDER_TURN_SLOTS・既定 1) 本で、render は paths で
#      絞らず merge_group ごとに走る。runner が複数のとき、1 本が止まっても残りが走っている間は
#      空いた runner の数だけ queued が拾われないままになる (#3320)。外された
#      PR には 4 の行も出るが、掛け直しても同じ 95 分を待つだけである
#      対処: 1) 専用機の前で runner を戻す (ssh では入れない — #1767)。戻ったかは
#      Settings → Actions → Runners か gh api repos/<repo>/actions/runners (メンテナの権限)
#      で見る。2) 戻せない間も merge を通すなら、メンテナが docs/runner-degraded-mode.md の
#      手順で縮退運転 (必須チェックから render を外す) を適用する — 発動の条件・失う保証・復帰の
#      条件は、その文書だけに書いてある (#2252)。エージェントは --apply を実行しない
#   7. 専用機は online で busy なのに、queue の先頭の render だけが queued のまま進まない
#      原因: 専用機は queued の job を先着順に拾わない (#2062)。先頭の render が後から
#      キューに入った render-pr や後ろの group の render に抜かれ続け、95 分のタイムアウトで外される。
#      render.yml のゲートのジョブ (render-turn) がキューに入る順番を絞るので、普段は起きない。起きたら
#      ゲートのジョブが効いていない (render-turn が失敗) か、ゲートのジョブより前にキューに入った job が残っている。
#      ゲートのジョブより前にキューに入った render-pr のうち、まだ拾われていないものは、group ができた
#      瞬間に queue-sweep が cancel する (#2064)。残りうるのは、走っている render-pr と
#      定期の scheduled-* (1 本まで・キャンセルできない) と、queue-sweep が失敗で掃除できなかった回
#      対処: 先頭の group と、専用機で走っている job の run の render-turn の要約と、先頭の
#      group の queue-sweep の出力 (render-pr の cancel 行) を読む。専用機で走っている・
#      queued の job が render-pr なら、gh run cancel でキャンセルしてよい (必須ではない — 戻すなら
#      queue が空いてから push し直す)。外された先頭は 4 と同じく予約を掛け直す。
#      6 との見分け: 6 は runner が offline で、どの render も走らない。7 は runner が
#      busy で、後ろの render や render-pr は走っている。runner が online なのに専用機の
#      job が 1 本も走らないまま先頭の render だけが queued なら (stall-watch は 6 と報告する)、
#      job そのものが詰まっている — 先頭の PR を queue から出し入れして job を作り直す
#   8. 着手ラベル (status: in progress) が付いたまま、紐づく open PR が無く、人の操作 (bot の追記を除く) が
#      3 日以上無い Issue (stale-claim・#3366)
#      原因: 着手したセッションが PR を出さずに終わった・バッチの記録の閉じ忘れ・Refs の PR が merge された後の
#      ステップを持つ者がいない・bot の追記だけが続く。2026-10-27 には 14 件が溜まり、次の仕事を選ぶ側からは
#      どの Issue も「誰かが持っている」ように見えた。#2251 ではラベルが付いていたせいで、release の失敗が
#      9 日間誰にも読まれなかった (#3365)
#      対処: 条件を満たしているなら閉じる。残るならラベルを外し、残る条件と再開の手順を Issue に書く。続けて
#      いるなら、プランを更新して人の操作を残す (それで報告が止まる)。監視ジョブはラベルを外さない・起票しない
#      見えないもの: CI からは手元の worktree / ブランチが見えない。ブランチの名前は番号を持たないことが多いので、
#      リモートのブランチを読んでも補えない。だから閾値は日単位 (CLAIM_STALL_MINUTES・既定 3 日) で、PR を出す
#      前に 1 日を越えた着手は、手元で動いていても報告されうる。判定の式は scripts/ready-queue.sh の
#      dropped と 1 つで、ここにコピーは無い
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
# merge_group をきっかけに走る既存の仕組み (review-gate / drawing-evidence / render)
# では原理的に捕まえられない。時計を持つ仕組みが要る、というのがこのスクリプトの理由で
# ある。
#
# ## ここは判定しかしない
#
# **読み取りしかしない** — 再実行も予約の掛け直しも、ラベルの付け外しも起票もしない。手元で
# 様子を見るために実行しても何も変わらないので、いつ実行しても安全である。
#
# ## 分類 (表の行に対応する)
#
#   分類                 別     表の行  なぜその別か
#   bad-title            name   5       タイトルの修正は人手。再実行では直らない
#   conflict             name   1       衝突の解消は人手
#   in-queue             quiet  3       止まっていない (queue が進めている)
#   auto-merge-dropped   name   2・4    掛け直すのは人かエージェント。監視ジョブの権限では掛けられない
#   runner-offline       name   6       専用機の前での操作と、保護の定義の適用は人手
#   stale-claim          name   8       着手ラベルを外す・閉じる・プランを更新するのは人手。番号は Issue のもの
#   unreadable           name   —       読めなかった。**何も判定していない**
#
# **auto-merge-dropped は掛け直さずに報告し、猶予を超えたら失敗にして返す** (#2614)。監視ジョブの
# GITHUB_TOKEN (contents: read) では enablePullRequestAutoMerge が FORBIDDEN になる。掛けるには
# リポジトリへの書き込み権限を監視ジョブに渡すことになり、それは人の判断なので、監視ジョブは掛けずに
# 返す。掛け直すのは報告を読んだ人か、4 行目の条件を満たすと読めたエージェントである。
#
# **「外れた」は PR の状態ではなく timeline の出来事で読む。** 予約が無いという状態は、外れた
# PR と、一度も掛けていない PR (後からコミットを足す PR は掛けずに置く・AGENTS.md「マージの
# 判断基準」) の両方を指す。状態で読むと、掛けずに置いた PR に猶予の後で失敗を返してしまう
# (#642)。予約と queue の出来事のうち**最新のもの**が次のどちらかのときだけ外れたと読み、
# その時刻から経過を測る:
#
# - queue から外れた (RemovedFromMergeQueueEvent) で、理由が merged でも manual でもない
#   (実測で見た値は failed_checks・checks_timed_out・merge_conflict)
# - auto-merge が外された (AutoMergeDisabledEvent) で、reasonCode が manually_disabled でない
#
# 人が外したもの (manual・manually_disabled) は意図なので外れたと読まない — 足すコミットの
# 前に --disable-auto で外すのは決まりどおりの操作である。出来事を読めなければ unreadable。
#
# **unreadable は表の行を持たない。** PR そのものか専用機の render の run が読めなかった回で、
# 詰まりの種類を言っていない — 何も出力せずに通す (quiet) と、読めていないことが誰にも見えない
# まま「正常」に混ざる (#1303)。
#
# **承認待ち (awaiting-approval) と取り消された承認 (dismissed-approval) の分類はもう無い。**
# ADR-0044 が承認のゲートを外したので、BLOCKED のまま予約が外れていれば常に
# auto-merge-dropped である (#2108。分類の経緯は #1033・#1303)。
#
# ## 順序に意味がある
#
# **人が先に直すものを先に判定する。** 特に bad-title は auto-merge-dropped より前に置く — 後ろに
# 置くと、同じ PR の予約も外れていれば auto-merge-dropped に当たって掛け直しを勧めるだけになり、
# 人が直すまで進まないタイトルを誰にも報告しない。
#
# ## 騒がしさの上限
#
# 報告する行は人が動くまで消えないので、毎回失敗にすると走るたびに通知が飛び、「毎回出る
# 注意は意味を失う」(#642) を踏む。**閾値 (既定 60 分) を超えて続いているものがある
# ときだけ 1 で終える。** それ以下は出力するだけで 0。例外は runner-offline で、猶予を短く
# する代わりに猶予の内は行を出さない (下の節)。
#
# 経過は「その状態を作った出来事の時刻」から測る — 失敗 check があればその completedAt、
# check が 1 本も無い conflict では PR の updatedAt、auto-merge-dropped では外れた出来事の
# createdAt。**状態をどこにも記録しない**ので、監視ジョブが止まっていても復帰すればそのまま
# 正しく測れる。
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
# runner-offline だけは PR ごとの状態ではなく、専用機という (1 台の) 状態を見る。番号の欄は
# `-` になる。判定は render.yml の終わっていない run の、**専用機の job** (ラベル
# mokume-render) の並びから読む — runners API は GITHUB_TOKEN では読めないためである。
# 「queued の専用機の job があり、in_progress の専用機の job が runner の数
# (RENDER_TURN_SLOTS) 本未満で、最古の queued が猶予を超えた」ときに報告する。
#
# - **run ではなく job で見る** (#2062)。render.yml の run はどれも先に GitHub ホストのゲートのジョブ
#   (render-turn) が走るので、専用機が止まっていても run は数秒で in_progress になる。run の
#   status で読むと、runner が止まっても「走っている」と判定して何も出力しない
# - **専用機の job が runner の数 (RENDER_TURN_SLOTS) 本そろって in_progress なら報告しない。**
#   runner は生きていて、全部が埋まっているので順番を待っているだけである (render の所要は
#   約 7〜8 分)。**未満なら、空いている runner があるのに queued が拾われていない** — 2 本の
#   うち 1 本が止まって、残りが走っている間も報告する。N はゲートのジョブ (scripts/render-turn.sh) と同じ
#   vars.RENDER_TURN_SLOTS を stall-watch.yml が渡して読み、未設定なら 1 (従来どおり 1 本でも
#   走っていれば何も出力しない)。1 以上の整数でなければ unreadable を報告する (#3320)
# - 生きている runner は queued の run を数秒で拾うので、猶予 (既定 15 分) は PR の猶予より
#   短い。**ここは猶予を超えたときにしか行を出さず、出したら必ず 1 で終える** — 猶予の
#   内の queued は正常な順番待ちなので、出すと毎回の注意になる (#642)
# - run の一覧を読めなかったら unreadable を報告する。何も出力しないと「止まっていない」と判定される (#1303)
#
# ## Issue を見る行 (stale-claim・#3366)
#
# PR ではなく **着手ラベルの残った Issue** を見る。番号の欄は Issue の番号である。判定は
# scripts/ready-queue.sh の dropped で、**ここに式をコピーしない** — `DROPPED_MINUTES=
# $CLAIM_STALL_MINUTES bash scripts/ready-queue.sh` を実行して dropped の行だけを取る。
# DROPPED_MINUTES は静かな期間の境目と bot の操作を読む期間の両方を決める (ready-queue.sh の
# QUIET_BEFORE)。期間と境目を分ける必要が出たら、判定を関数に切り出して両方から読む。
#
# - ready-queue.sh の終了コードは 0 (ready がある)・1 (ready が 0 件) のどちらも読めている。
#   2 (一覧を読めなかった) は unreadable を報告する。1 で終えた回も、件数の行 (標準エラーの
#   `ready N / ...`) が無ければ途中で終了しているので unreadable にする
# - 経過の欄は閾値 (CLAIM_STALL_MINUTES) を出す。dropped の行は実際の経過を持たない下限である
# - **猶予を超えた報告しか出ないので、出したら必ず 1 で終える** (runner-offline と同じ形)。
#   人がラベルを外す・閉じる・プランで人の操作を残すまで失敗が続く。その間に起きた PR の詰まりの失敗が
#   同じ失敗に紛れる代償は、対処が 1 手で済むことで受ける (#3366)
# - **一部を読めないまま完走した回** (ready-queue.sh が標準エラーの最後に出す `incomplete: <印>`) も
#   unreadable を報告する。読めなかった番号は busy と判定されるので、dropped が 0 件の成功と区別がつかない
#   (人の操作を読めなかった hands-unread・一覧が上限に張り付いた capped-*)。見つかった dropped はそのまま報告する
# - unreadable は失敗にしない (ほかの unreadable と同じ)。ただし続けて読めなくても誰も見ないので、
#   監視ジョブの run の要約と annotation (::warning::) に出す (stall-watch.yml の最後の step)
# - 監視ジョブに要る権限は issues: read (読み取りだけ)。ラベルの付け外しも起票もしない
# - 監視ジョブは ubuntu で、ready-queue.sh は BSD の date -v が拒否されたときの GNU のブランチと mawk で走る。
#   手元の Mac と同じに出ることは scripts/tests/ready_queue_test.py が固定している
#
# ## 出力
#
#   <番号> <分類> <name|quiet> <経過分> <説明>
#
# 終了コード: 0 = 詰まりなし / 閾値内、1 = 閾値を超えた報告がある。
#
# **読めなかったときの gh の stderr は捨てずに stderr へ流す** (#2614)。標準出力は機械が
# 読む契約なので混ぜないが、unreadable と報告した理由はジョブのログに残す。
#
# 呼び出しは .github/workflows/stall-watch.yml、テストは scripts/tests/stall_watch_test.py。
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

# 着手印が残ったまま人の手が無いまま過ぎてよい時間 (既定 3 日)。CI からは手元の worktree / ブランチが
# 見えないので日単位に取る。理由は冒頭の「Issue を見る行」。**readonly にしない** — 検査が短い値で回す
CLAIM_STALL_MINUTES=${CLAIM_STALL_MINUTES:-4320}

# 判定の実体。**readonly にしない** — 検査が差し替える
READY_QUEUE=${READY_QUEUE:-"$(dirname "${BASH_SOURCE[0]}")/ready-queue.sh"}

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

# PR の checks を {name,result,at,run,job} の並びへ均す。CheckRun と StatusContext で
# 欄の名前が違うので、ここで 1 つの形にしておく。
#
# **run は「どちらが新しいか」の基準である。** at (完了時刻) では測れない — 古い run の
# ci-gate は macOS の ci-check を待つ分だけ新しい run より遅く完了し、古い失敗が時刻の上では最新に
# 見える (#2568)。run の id は単調に増えるので、detailsUrl の /actions/runs/<id> を新旧の順に
# する。読めなければ 0 (StatusContext など)。**同じ名前の check が全部 0 のときだけ at だけで
# 並ぶ** — 0 はどの run id よりも古いと読む。job は detailsUrl の /job/<id> で、bad-title が
# pr-gate の step を読むのに使う (読めなければ 0)
#
# かつてはここで、タイトルを直す前の run の赤い pr-title と ci-gate を入力から外していた
# (#2568)。作法の検査が ci-gate を離れた (#2669) ので、その組はもう生まれない
#
# **pr-gate は最新の 1 本だけを残す** (#2668)。pr-gate (.github/workflows/pr-gate.yml) は API を
# 読むだけの数十秒のジョブで、直すと新しい run が付け直す。判定になるのは作成順で最新の run
# (check suite) の結論で、古い失敗・cancelled は必須が読まない名残である。残すと、直す前の
# タイトルの赤まで bad-title が読む。新旧は上と同じく run の id で決める。最新が失敗なら、その赤は
# そのまま残る
#
# **run の id の順は、必須が読む check suite の作成順と同じに並ぶ** (観測。規則と根拠は
# scripts/ci-gate.sh 冒頭の「必須の判定が読む check run」・#2577)。rollup には suite の id が無いので、
# ここは run の id で代える
normalize_checks() { # 標準入力=PR の JSON
  jq -c '
    [.statusCheckRollup[]? | {
      name: (.name // .context // ""),
      result: (.conclusion // .state // ""),
      at: (.completedAt // .startedAt // .createdAt // ""),
      run: ((.detailsUrl // .targetUrl // "")
            | (capture("/actions/runs/(?<id>[0-9]+)") | .id | tonumber) // 0),
      job: ((.detailsUrl // .targetUrl // "")
            | (capture("/job/(?<id>[0-9]+)") | .id | tonumber) // 0)
    }]
    | ([ .[] | select(.name == "pr-gate") ] | sort_by([.run, .at]) | last) as $gate
    | [ .[] | select(.name != "pr-gate" or . == $gate) ]'
}

# 最新の pr-gate が失敗していれば、その job の id (読めなければ 0)。失敗していなければ空。
# normalize_checks が pr-gate を最新の 1 本だけに絞った後に読む
red_gate_job() { # 標準入力=均した checks
  jq -r --argjson unsettled "$UNSETTLED" --argjson passed "$PASSED" \
    '.[] | select(.name == "pr-gate") | . as $c
         | select(($unsettled | index($c.result)) == null)
         | select(($passed | index($c.result)) == null)
         | $c.job'
}

# pr-gate のタイトルの step (.github/workflows/pr-gate.yml の step の name)。改名するときは
# 同時に直す (scripts/tests/stall_watch_test.py が 2 つの一致を見る)
readonly TITLE_STEP='pr-title (Conventional Commits)'

# pr-gate の job のうち、タイトルの step の結論 (failure / success / skipped …)。無ければ空。
# 読めなければ非 0
title_step_conclusion() { # $1=job の id
  gh api "repos/$REPO/actions/jobs/$1" \
    --jq "[.steps[]? | select(.name == \"$TITLE_STEP\") | .conclusion] | first // \"\""
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

# queue に居るか。**gh pr view には無い欄**なので GraphQL で引く (#628)。
# 読めなかったときは「居ない」に倒さず空で返し、呼び手が判定を諦められるようにする
in_merge_queue() { # $1=PR 番号
  # shellcheck disable=SC2016
  gh api graphql -f owner="${REPO%%/*}" -f name="${REPO##*/}" -F number="$1" \
    -f query='query($owner:String!,$name:String!,$number:Int!){
      repository(owner:$owner,name:$name){pullRequest(number:$number){isInMergeQueue}}}' \
    --jq '.data.repository.pullRequest.isInMergeQueue' || echo ""
}

# 予約が外れた出来事 (#2614)。予約と queue の出来事のうち最新のものが、人の操作でない外れ方
# なら「<時刻> <理由>」を 1 行出す。何も出さなければ外れていない (一度も掛けていない・人が
# 外した・掛け直した)。読めなければ非 0。読み方の理由は冒頭の分類の表の下
dropped_event() { # $1=PR 番号
  # shellcheck disable=SC2016
  gh api graphql -f owner="${REPO%%/*}" -f name="${REPO##*/}" -F number="$1" \
    -f query='query($owner:String!,$name:String!,$number:Int!){
      repository(owner:$owner,name:$name){pullRequest(number:$number){
        timelineItems(last:1,itemTypes:[ADDED_TO_MERGE_QUEUE_EVENT,REMOVED_FROM_MERGE_QUEUE_EVENT,
                                        AUTO_MERGE_ENABLED_EVENT,AUTO_MERGE_DISABLED_EVENT]){
          nodes{__typename
            ... on RemovedFromMergeQueueEvent{createdAt reason}
            ... on AutoMergeDisabledEvent{createdAt reasonCode}}}}}}' \
    --jq '.data.repository.pullRequest.timelineItems.nodes[-1] // empty
      | select((.__typename == "RemovedFromMergeQueueEvent"
                and ((.reason // "") | ascii_downcase) != "merged"
                and ((.reason // "") | ascii_downcase) != "manual")
            or (.__typename == "AutoMergeDisabledEvent"
                and ((.reasonCode // "") | ascii_downcase) != "manually_disabled"))
      | "\(.createdAt) \(.reason // .reasonCode // "-")"'
}

say_line() { # $1=番号 $2=分類 $3=別 $4=経過分 $5=説明
  printf '%s %s %s %s %s\n' "$1" "$2" "$3" "$4" "$5"
}

# 専用機で同時に走る job の数 (runner の数)。**門番 (scripts/render-turn.sh) と同じ値を同じ
# 既定で読む** — render.yml と stall-watch.yml が、どちらもリポジトリの変数
# vars.RENDER_TURN_SLOTS を渡す。未設定か空なら 1。1 以上の整数でなければ非 0 で返す (#3320)
render_turn_slots() {
  local n="${RENDER_TURN_SLOTS:-1}"
  case "$n" in
    "" | *[!0-9]* | 0*) return 1 ;;
  esac
  printf '%s\n' "$n"
}

# 終わっていない render.yml の run の、専用機の job を「<status> <created_at>」で出す。
# 門番 (GitHub ホスト) の job は数えない。読めなければ非 0 で返す
runner_jobs() {
  local st ids="" got id
  for st in queued in_progress; do
    got=$(gh api "repos/$REPO/actions/workflows/render.yml/runs?status=$st&per_page=100" \
      --jq '.workflow_runs[].id') || return 1
    ids+="$got"$'\n'
  done
  for id in $(printf '%s' "$ids" | sort -u); do
    gh api "repos/$REPO/actions/runs/$id/jobs?per_page=100" \
      --jq '.jobs[] | select((.labels // []) | index("mokume-render"))
        | select(.status == "queued" or .status == "in_progress")
        | "\(.status) \(.created_at)"' || return 1
  done
}

# 着手印が残ったまま人の手が無い Issue (stale-claim・冒頭の「Issue を見る行」)。名乗った行が
# あれば 0、無ければ 1。読めなかったときは unreadable を名乗って 1
name_stale_claims() {
  local out errfile rc=0 line n rest title incomplete
  errfile=$(mktemp)
  out=$(DROPPED_MINUTES="$CLAIM_STALL_MINUTES" bash "$READY_QUEUE" 2>"$errfile") || rc=$?
  # 標準エラーは捨てずにジョブのログへ流す (件数の行も混ざる)
  cat "$errfile" >&2
  # 0 と 1 は読めている (1 は ready が 0 件)。ただし 1 は途中で落ちた回とも同じなので、
  # 最後に打つ件数の行があるときだけ読めたと数える
  if [ "$rc" -ge 2 ] || { [ "$rc" -eq 1 ] && ! grep -q '^ready [0-9]* / stock' "$errfile"; }; then
    say_line - unreadable name 0 "着手印の残った Issue を読めなかった (ready-queue.sh の終了コード ${rc}・判定していない)"
    rm -f "$errfile"
    return 1
  fi
  # 一部を読めないまま完走した回 (人の手を読めなかった番号・一覧の上限)。読めなかった番号は busy へ
  # 倒れて名乗られないので、dropped が 0 件でも緑にしない。見つかった dropped は続けて名乗る
  incomplete=$(sed -n 's/^incomplete: //p;' "$errfile" | sed -n '1p')
  rm -f "$errfile"
  if [ -n "$incomplete" ]; then
    say_line - unreadable name 0 "着手印の判定の一部を読めないまま終わった ($incomplete) — 名乗るべき着手印を見落としているかもしれない (判定しきれていない)"
  fi
  local named=1
  while IFS= read -r line; do
    n=${line%% *}
    rest=${line#* }
    [ "${rest%% *}" = dropped ] || continue
    title=${rest#dropped }
    say_line "$n" stale-claim name "$CLAIM_STALL_MINUTES" \
      "$title — 条件を満たしていれば閉じる / 残るなら印を外して残る条件と再開の手順を書く / 続けているならプランを更新する (CI からは手元の worktree が見えないので日単位・表の 8 行目)"
    named=0
  done <<<"$out"
  return "$named"
}

# --- 走査 -------------------------------------------------------------------

overdue=0

# 着手印の残った Issue。PR の走査とは別の対象なので先に出す
if name_stale_claims; then overdue=1; fi

# 専用機の死活。PR の走査より先に出す — 止まっていれば、下の PR の行 (弾かれた・予約が
# 外れた) の原因はたいていここにある
if ! jobs=$(runner_jobs); then
  say_line - unreadable name 0 "専用機の render の run を読めなかった (runner の死活を判定していない)"
else
  oldest_queued=$(awk '$1 == "queued" { print $2 }' <<<"$jobs" | sort | sed -n '1p')
  running=$(awk '$1 == "in_progress" { n++ } END { print n + 0 }' <<<"$jobs")
  # 専用機の job が runner の数 (RENDER_TURN_SLOTS) 本そろって走っていれば、queued は順番待ち。
  # 未満なのに最古の queued が猶予を超えていれば、空いている runner があるはずなのに拾われていない
  if ! slots=$(render_turn_slots); then
    say_line - unreadable name 0 "RENDER_TURN_SLOTS は 1 以上の整数で渡す: '${RENDER_TURN_SLOTS}' (runner の死活を判定していない)"
  elif [ -n "$oldest_queued" ] && [ "$running" -lt "$slots" ]; then
    mins=$(minutes_since "$oldest_queued")
    if [ "$mins" -ge "$RUNNER_STALL_MINUTES" ]; then
      say_line - runner-offline name "$mins" \
        "専用機の runner が render を拾っていない (走っている job $running 本 / runner $slots 本) — 戻す手順は表の 6 行目"
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
    --json isDraft,autoMergeRequest,mergeStateStatus,statusCheckRollup,updatedAt) || {
    say_line "$n" unreadable name 0 "PR を読めなかった (判定していない)"
    continue
  }

  auto=$(jq -r '.autoMergeRequest != null' <<<"$json")
  state=$(jq -r '.mergeStateStatus // ""' <<<"$json")
  updated=$(jq -r '.updatedAt // ""' <<<"$json")

  checks=$(normalize_checks <<<"$json")
  failed_at=$(newest_failure_at <<<"$checks")
  others=$(jq -r 'length' <<<"$checks")

  # 名乗る行を先に判定する。順序の理由は冒頭の「順序に意味がある」
  gate_job=$(red_gate_job <<<"$checks")
  if [ -n "$gate_job" ]; then
    # 読めなかったら判定しない。黙ると、タイトルの赤が「止まっていない」に混ざる (#1303)
    if [ "$gate_job" = 0 ] || ! title=$(title_step_conclusion "$gate_job"); then
      say_line "$n" unreadable name 0 "赤い pr-gate のタイトルの step を読めなかった (判定していない)"
      continue
    fi
    if [ "$title" = failure ]; then
      mins=$(minutes_since "${failed_at:-$updated}")
      say_line "$n" bad-title name "$mins" \
        "タイトルが Conventional Commits でない — 直せば pr-gate が付け直す (打ち直しも新しいコミットも要らない)"
      [ "$mins" -lt "$STALL_MINUTES" ] || overdue=1
      continue
    fi
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
    case "$queued" in
      true)
        say_line "$n" in-queue quiet 0 "queue が進めている (何も打たない)"
        continue
        ;;
      false) ;;
      # 読めなかった (空) を「居ない」と読むと、外れたと名乗りうる (#1303)
      *)
        say_line "$n" unreadable name 0 "queue に居るかを読めなかった (判定していない)"
        continue
        ;;
    esac

    # BLOCKED でも承認待ちとは読まない。承認のゲートは ADR-0044 で外れた (#2108)。
    # 外れたかは状態ではなく出来事で読み、外れた時刻から猶予を測る。理由は冒頭の分類の表の下 (#2614)
    event=$(dropped_event "$n") || {
      say_line "$n" unreadable name 0 "予約と queue の出来事を読めなかった (判定していない)"
      continue
    }
    # 外れた出来事が無い: 一度も掛けていない・人が外した。名乗らない
    [ -n "$event" ] || continue
    mins=$(minutes_since "${event%% *}")
    say_line "$n" auto-merge-dropped name "$mins" \
      "auto-merge が外れている (${event#* }) — 弾いた run を読み、gh pr merge $n --auto --squash で掛け直す (当番は掛けない・#2614)"
    [ "$mins" -lt "$STALL_MINUTES" ] || overdue=1
  fi
done

exit "$overdue"
