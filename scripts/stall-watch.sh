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
#      原因: 同じコミットに残る古い失敗 check run が判定を固定している (#259)。作法の検査が
#      ci-gate を離れた (#2669) 後に残るのは、同じコミットに段を走らせる ci.yml の run が複数
#      立つ場面 (reopen・閉じて作り直した PR) のコードの検査の赤である。base の変更と本文の編集
#      では ci.yml の run が立たない (#2718)。#2718 より前の本文の編集の run の緑 (段が skipped)
#      は直った証拠に数えない — 10 行目
#      対処: gh run rerun <run-id> --failed — **ただし render-pr・pr-gate には打たない**
#      (#2062・#2668。render-pr の rerun は門番を通らずに専用機へ積む。必須ではないので
#      打たなくても merge は止まらない。pr-gate は最新の run の結論が判定で、古い赤・cancelled は
#      この表の判定に数えない — normalize_checks。ただし最新の suite に載って必須を塞ぐ
#      cancelled は 13 行目)
#   4. autoMerge: false + CLEAN + 全 check 緑 で isInMergeQueue: true
#      原因: 止まっていない — 予約が queue へ移ると autoMergeRequest は null になる (#628)
#      対処: 何も打たない
#   5. 同じ 3 つで isInMergeQueue: false
#      原因: merge queue の合流後の木で必須チェック (ci-gate か、専用機の render) が落ちて
#      弾かれ、auto-merge も一緒に外れた (eject の副作用)
#      対処: 弾いた merge_group の run を読む。一過性か main 側で直ったなら予約を掛け直す
#      (当番は auto-merge-dropped と名乗り、猶予を超えたら赤くするだけで、掛け直すのは
#      人 — #2614)。PR 側で直すものなら直して push する
#   6. pr-gate のタイトルの検査が落ちた
#      原因: タイトルが Conventional Commits ではない (design は Issue Type であって型ではない)
#      対処: タイトルを直す。edited で pr-gate の新しい run が作られ、必須はその結論を読む
#      (作成順で最新の suite・規則は scripts/ci-gate.sh 冒頭)
#      — 打ち直しも新しいコミットも要らない (pr-gate はタイトルを API から読む・#2669)。
#      **最新 (run の id の順) の pr-gate が赤く、そのタイトルの step が落ちている PR だけ**が
#      ここで名乗る (step の結論は Actions の job の API で読む。照合の正規表現は持たない)
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
#  10. 最新の ci-gate が、段を走らせていない run (本文・タイトルの編集の run) の緑で、
#      コードの検査 (ci-check・ci-static) の赤がその下に残っている
#      原因: その run の ci-gate は needs が skipped なので緑になる。直った証拠ではない
#      (#2669 の反証 4)。必須の判定は最新の ci-gate を読むので、赤いまま queue に入りうる
#      対処: コードを直して push する。**打ち直さない** — 本当に赤い検査を当番のたびに macOS
#      で回し直すだけになる
#      (移行期) #2690 の後の run では起きない — 本文の編集の run の ci-gate は、同じ SHA の検査の
#      最新が success で終わったときしか緑にならない。**#2690 より前の ci.yml の run の緑を最新の ci-gate に
#      持つ open な PR が無くなったら、この行と masked の判定ごと消してよい**
#  11. (移行期) 最新の ci-gate が、作法のジョブを含む古い ci.yml の run の赤で、最新の
#      pr-gate は緑
#      原因: #2669 より前の ci.yml の run の ci-gate は作法のジョブを待っていた。作法をラベル
#      だけで直すと、ci.yml はラベルでは起きないので新しい ci-gate が付かない (#2669 の反証 2)。
#      その run は打ち直さない (古いイベントを再生し、needs の赤で ci-gate も赤く返す・#699)
#      対処: 新しいコミットを push する。本文の編集では新しい ci-gate が付かない — ci.yml は
#      edited で起きない (#2718)。**作法のジョブ (LEGACY_JOBS) を含む run を head に持つ open な
#      PR が無くなったら、この行と legacy の判定ごと消してよい**
#  12. autoMerge: true + CLEAN (か UNSTABLE・BEHIND) で isInMergeQueue: false のまま、揃ってから猶予を超えた
#      原因: 予約は掛かっていて必須も揃っているのに、予約が queue へ動かない (#2693)。予約が
#      効いていれば揃ってから数秒で入る。#2691 は揃ってから 27 分入らなかった。起きる条件は
#      分かっていない (#2693)。作成と同時のラベルで残る cancelled の pr-gate は、必須を塞ぐなら
#      BLOCKED になるので (13 行目)、CLEAN のこの形の説明にはならない (#2716 の反証 7)
#      対処: gh pr merge <番号> --disable-auto の後に gh pr merge <番号> --auto --squash で
#      掛け直す (#2691 はこれで直後に queue へ入った)。当番は掛けない (2・5 と同じ・#2614)
#  13. autoMerge: true + BLOCKED で、pr-gate 以外の必須は揃っている (最新が緑か skipped) のに、
#      作成順で最新の check suite の pr-gate の run が cancelled (結論の無い打ち切り)
#      原因: run が打ち切られた。必須は最新の suite の pr-gate を読む (規則は scripts/ci-gate.sh
#      冒頭の「必須の判定が読む check run」・#2577)。打ち切られたのが古い suite なら止まらない
#      (#2710・#2707・#2703 は merge された) が、新しい suite なら必須が揃った後も BLOCKED のまま
#      queue に入らない (#2712・#2716)。かつては pr-gate の concurrency が打ち切っていた (走っている
#      run の打ち切り・待ちの置き換え)。#2716 で concurrency を外したので、残るのは手で cancel した
#      ときである。待ちを置き換えられた run はジョブを作らないので、suite の順は run の一覧で読む。
#      最新の suite の赤は打ち切りではなく PR を読んだ結論なので、ここには当てない
#      対処: 名乗りの行に出る gh run rerun <run-id> で cancelled の run を打ち直す (#2712 は打ち直しの
#      14 秒後に CLEAN になった)。ジョブの無い run で打ち直せなければ、本文を編集して新しい run を
#      作る。**当番は打たない** — 古い pr-gate を当番に打たせない決まり (#2668・stall-act.sh の
#      除外) を変えるのは人の判断である
#  14. (移行期) 最新の ci-gate が、段を走らせていない run (#2718 より前の本文・タイトルの編集の
#      run) の赤で、同じ SHA の ci-check・ci-static の最新はどちらも success
#      原因: その run の ci-gate は同じ SHA の検査の最新を読んで結論を返した (#2690)。検査の赤を
#      読んだ後や待ちの期限を越えた後に、検査を打ち直して緑にしても、run の id の大きいその赤が
#      必須を塞ぎ続ける (#2717)。#2718 からは本文の編集で ci.yml の run が立たないので、新しくは
#      生まれない。当番の打ち直し (reread) は #2718 で外した
#      対処: 名乗りの行に出る gh run rerun <run-id> --failed で、その run を打ち直す (その run の版の
#      scripts/ci-gate.sh が同じ SHA を読み直して緑を返す) か、新しいコミットを push する。当番は
#      打たない。検査の最新が赤・走っている途中・片方が無いなら名乗らない (読み直しても緑に
#      ならない。直すのはコードの側)。**#2718 より前の本文の編集の run の赤を最新の ci-gate に持つ
#      open な PR が無くなったら、この行と edited の判定ごと消してよい**
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
# ## 分類 (表の行に対応する)
#
#   分類                 別     表の行  なぜその別か
#   bad-title            name   6       タイトルの修正は人手。打ち直しでは直らない
#   conflict             name   1       衝突の解消は人手
#   in-queue             quiet  4       止まっていない (queue が進めている)
#   stale-checks         act    3・7    古い失敗 check を打ち直す。冪等
#   masked-red           name   10      コードの直しは人手。打ち直しても同じ赤を返す
#   legacy-gate          name   11      push は人手。古い run は打ち直さない
#   edited-gate          name   14      (移行期) 打ち直しか push は人手。当番の読み直しは外した (#2718)
#   auto-merge-dropped   name   2・5    予約の掛け直しは人手。当番の権限では掛けられない
#   queue-not-entered    name   12      同上。掛かっている予約を外して掛け直す
#   stale-gate           name   13      古い pr-gate の打ち直しは人手。当番には打たせていない (#2668)
#   runner-offline       name   8       専用機の前での操作と、保護の定義の適用は人手
#   unreadable           name   —       読めなかった。**何も判定していない**ので打たない
#
# **auto-merge-dropped は打たずに名乗り、猶予を超えたら赤で人に返す** (#2614)。以前は act
# で、stall-act.sh が gh pr merge --auto --squash を打っていたが一度も成功しなかった — 当番の
# GITHUB_TOKEN (contents: read) では enablePullRequestAutoMerge が FORBIDDEN になる。掛けるには
# リポジトリへの書き込みを当番に渡すことになり、それは人の判断なので、掛けずに人へ返す。
#
# **「外れた」は PR の状態ではなく timeline の出来事で読む。** 予約が無いという状態は、外れた
# PR と、一度も掛けていない PR (後からコミットを足す PR は掛けずに置く・AGENTS.md「マージの
# 判断基準」) の両方を指す。状態で読むと、掛けずに置いた PR に猶予の後で赤を返してしまう
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
# 置くと、同じ PR にコードの検査の古い赤もあれば stale-checks に当たって打ち直すだけになり、
# 人が直すまで進まないタイトルを誰にも名乗らない。
#
# ## 騒がしさの上限
#
# 名乗る行は人が動くまで消えないので、毎回赤くすると走るたびに通知が飛び、「毎回出る
# 注意は意味を失う」(#642) を踏む。**閾値 (既定 60 分) を超えて続いているものがある
# ときだけ 1 で終える。** それ以下は出力するだけで 0。例外は runner-offline と
# queue-not-entered・stale-gate で、猶予を短くする代わりに猶予の内は行を出さない (下のそれぞれの節)。
#
# 経過は「その状態を作った出来事の時刻」から測る — 失敗 check があればその completedAt、
# check が 1 本も無い conflict では PR の updatedAt、auto-merge-dropped では外れた出来事の
# createdAt、queue-not-entered と stale-gate では check のうち最新の時刻と予約を掛けた時刻の遅い方
# (必須が揃い、予約も掛かった時刻の近似)。**状態をどこにも記録しない**ので、
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
# ## 予約が queue へ動かない行 (queue-not-entered・#2693)
#
# 予約が効いていれば、必須が揃ってから数秒で queue に入る。なので猶予 (既定 15 分) は PR の
# 猶予より短く、runner-offline と同じく**猶予を超えたときにしか行を出さず、出したら必ず 1 で
# 終える** — 揃った直後の隙間は正常で、出すと毎回の注意になる (#642)。UNSTABLE (必須でない
# check の赤・render-pr など) と BEHIND (保護は最新の main を求めず、queue が合流後の木で
# 測り直す) も必須は揃っているので含める。queue に居るかの GraphQL は、この形に当たった
# PR だけで引く。
#
# 経過は check の最新の時刻と予約を掛けた時刻 (enabledAt) の遅い方から測る。揃ってから
# 何時間も後に予約を掛けた PR を、掛けた直後の隙間で名乗らないため。check の時刻には
# 必須でない check や本文の編集の run も入るので、起点は遅い側に寄る — 誤って赤くするより、
# 名乗りが遅れるほうに倒している
#
# BLOCKED のうち、必須は揃っているのに最新の suite の pr-gate が cancelled の形 (stale-gate・
# #2716) も同じ猶予と出し方にする。必須かどうかは .github/rulesets/main-protection.json (正本) から
# 読み、待っている必須・赤い必須・まだ付いていない必須があれば名乗らない — それは予約が正しく
# 待っている形で、pr-gate を打ち直しても進まない。cancelled が古い suite のほうなら必須を塞いで
# いないので、BLOCKED の理由は別にあり、名乗らない
#
# ## 出力
#
#   <番号> <分類> <act|name|quiet> <経過分> <説明>
#
# 終了コード: 0 = 詰まりなし / 閾値内、1 = 閾値を超えた名乗りがある。
#
# **読めなかったときの gh の stderr は捨てずに stderr へ流す** (#2614)。標準出力は機械が
# 読む契約なので混ぜないが、unreadable と名乗った理由はジョブのログに残す。
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

# 予約が掛かり必須が揃ってから、queue に入らないまま過ぎてよい時間。理由は冒頭の「予約が
# queue へ動かない行」
QUEUE_ENTRY_MINUTES=${QUEUE_ENTRY_MINUTES:-15}

# 必須チェックの正本 (stale-gate が必須の context を読む)。**readonly にしない** — 検査が
# 読めない形を差し替えて回すため
RULESET=${RULESET:-"$(dirname "${BASH_SOURCE[0]}")/../.github/rulesets/main-protection.json"}

# 作法のジョブの名前。#2669 より前の ci.yml の run はこれらを含み、その ci-gate はそれらを
# 待っていた。この名前の check を含む run を「古い run」と読む (冒頭の表の 11 行目)。
# scripts/stall-act.sh の LEGACY_JOBS と同じに保つ (検査が見る)
readonly LEGACY_JOBS='["pr-title","review-gate","drawing-evidence"]'

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

# PR の checks を {name,result,at,run} の並びへ均す。CheckRun と StatusContext で
# 欄の名前が違うので、ここで 1 つの形にしておく。
#
# **run は「どちらが新しいか」の基準である。** at (完了時刻) では測れない — 古い run の
# ci-gate は macOS の ci-check を待つ分だけ新しい run より遅く完了し、古い赤が時刻の上では最新に
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
# (check suite) の結論で、古い赤・cancelled は必須が読まない名残である。残すと新しい緑と組になって stale-checks に読まれ、当番が head SHA の失敗ジョブを
# 打ち直す (凍結された run の ci-gate まで打ち直して「最新の赤」を作りうる)。新旧は上と同じく
# run の id で決める。最新が赤なら、その赤はそのまま残る
#
# **run の id の順は、必須が読む check suite の作成順と同じに並ぶ** (観測。規則と根拠は
# scripts/ci-gate.sh 冒頭の「必須の判定が読む check run」・#2577)。rollup には suite の id が無いので、
# ここは run の id で代える。**concurrency の group に入る順とは違いうる** — #2712 では新しい run
# (id も suite も大きい) が先に group に入り、後から入った古い run に cancel された。ここが選ぶ
# 「最新の pr-gate」はその cancelled で、必須が読むものと同じである。必須が揃っても BLOCKED の
# まま queue に入らず、打ち直しで CLEAN になった。この形は打ち直さずに stale-gate と名乗る (表の
# 13 行目)。cancelled が古い run のほうなら、ここで落ちて何も読まない (#2710 ほか・必須を塞がない)
#
# 各 check に 2 つの印を付ける (#2669 の反証 1・4):
#
# - legacy: 作法のジョブ (LEGACY_JOBS) を含む古い ci.yml の run の check。打ち直しの対象にしない
# - skips: 段を走らせていない run の ci-gate。同じ run の ci-check・ci-static が在って、どれも
#   SKIPPED のもの (本文・タイトルの編集の run。#2718 からは立たない)。その結論は同じ SHA の検査を
#   読んだもの (#2690)
# - hollow: skips のうち緑。直った証拠に数えない
#
# **古い pr-gate を落とす前の並びは flatten_checks が出す。** stale-gate (表の 13 行目・#2716) の
# 絞り込みが、pr-gate を全部並べて読む
flatten_checks() { # 標準入力=PR の JSON
  jq -c '
    [.statusCheckRollup[]? | {
      name: (.name // .context // ""),
      result: (.conclusion // .state // ""),
      at: (.completedAt // .startedAt // .createdAt // ""),
      run: ((.detailsUrl // .targetUrl // "")
            | (capture("/actions/runs/(?<id>[0-9]+)") | .id | tonumber) // 0),
      job: ((.detailsUrl // .targetUrl // "")
            | (capture("/job/(?<id>[0-9]+)") | .id | tonumber) // 0)
    }]'
}

normalize_checks() { # 標準入力=PR の JSON
  flatten_checks | jq -c --argjson legacy_jobs "$LEGACY_JOBS" '
    . as $all
    | ([ $all[] | select(.run > 0 and (.name as $n | $legacy_jobs | index($n)) != null) | .run ]
       | unique) as $legacy
    | [ $all[] | . as $c | . + {
        legacy: (.run > 0 and ((.run as $r | $legacy | index($r)) != null)),
        skips: (.name == "ci-gate" and .run > 0
                and ([ $all[] | select(.run == $c.run and (.name == "ci-check" or .name == "ci-static"))
                       | .result ] as $steps
                     | ($steps | length) > 0 and all($steps[]; . == "SKIPPED")))
      } ]
    | [ .[] | . + { hollow: (.skips and .result == "SUCCESS") } ]
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

# check のうち、いちばん新しい時刻 (揃った時刻の近似。queue-not-entered が経過を測る)
newest_check_at() { # 標準入力=均した checks
  jq -r '[.[].at | select(. != "")] | sort | last // ""'
}

# 必須が揃い、予約も掛かった時刻の近似。check の最新と予約を掛けた時刻の遅い方 (冒頭の
# 「予約が queue へ動かない行」)。queue-not-entered と stale-gate が経過を測る
ready_since() { # $1=均した checks $2=PR の JSON
  printf '%s\n%s\n' "$(newest_check_at <<<"$1")" \
    "$(jq -r '.autoMergeRequest.enabledAt // ""' <<<"$2")" | sort | tail -n 1
}

# 必須チェックの context の並び (JSON)。**写しを持たず、ブランチ保護の正本から読む**
# (AGENTS.md「ブランチ保護の正本」)。実設定との食い違いは check-rulesets.sh が見る。
# 読めないか 1 つも無ければ非 0
required_contexts() {
  jq -ce '[.rules[]? | select(.type == "required_status_checks")
           | .parameters.required_status_checks[]?.context]
          | select(length > 0)' "$RULESET"
}

# stale-gate (冒頭の表の 13 行目・#2716) に当たりうる PR か。当たりうれば yes を出す。
# **ここは statusCheckRollup だけで絞る** — rollup には check suite の id が無いので、どの suite が
# 新しいかは stale_gate_run が run の一覧で読む。API を引くのは、ここを通った PR だけである。
#
# - pr-gate 以外の必須: その名前の最新 (run の id の順) が SUCCESS・NEUTRAL・SKIPPED
# - pr-gate: 待っている run が無い
#
# **rollup の CANCELLED では絞らない** (#2716 の 2 回目の反証 1・2)。待ちを置き換えられた run は
# ジョブを 1 本も作らずに cancelled で終わり、rollup にも check-runs にも出ない。予約付きの BLOCKED で
# 必須が揃っている PR はそもそも少ないので、ここを通った PR は run の一覧を引く
stale_gate_candidate() { # $1=必須の context の並び (JSON) / 標準入力=PR の JSON
  flatten_checks | jq -r --argjson unsettled "$UNSETTLED" --argjson passed "$PASSED" \
    --argjson required "$1" '
    def ok: .result as $r | ($passed | index($r)) != null;
    def waiting: .result as $r | ($unsettled | index($r)) != null;
    . as $all
    | [ $all[] | select(.name == "pr-gate") ] as $gates
    | select(any($gates[]; waiting) | not)
    | select(all($required[] | select(. != "pr-gate");
                 . as $n | ([ $all[] | select(.name == $n) ] | sort_by([.run, .at]) | last) as $l
                 | $l != null and ($l | ok)))
    | "yes"'
}

# 必須が読む pr-gate (作成順で最新の check suite に載ったもの。規則は scripts/ci-gate.sh 冒頭の
# 「必須の判定が読む check run」) の run が cancelled の形 (#2716)。当たれば最新の suite の run の
# id を出す。当たらなければ空。API を読めなければ非 0。
#
# - **suite の作成順を、PR gate の run の一覧 (actions/runs の check_suite_id) で読む。** check-runs
#   では読まない — 待ちを置き換えられた run はジョブを作らず、suite に pr-gate の check run が残らない
#   (#2730 の a0ad3c6 の run 38767942922 ほか・#2716 の 2 回目の反証 1)。check run を持つ suite だけで
#   「最新」を選ぶと、ジョブの無い最新の suite を見落とし、古い suite の cancelled を打ち直しに挙げる
#   (同 反証 4)。ジョブの無い cancelled が最新の suite のとき、必須がそれを cancelled と読むか待ちと
#   読むかは未確認 (#2692)。どちらでも打ち直せば最新の suite に結論が付くので、名乗る
# - cancelled が古い suite のほう (#2710・#2707・#2703) は必須を塞がないので名乗らない。BLOCKED の
#   別の理由と重なったときに打ち直しを勧めてしまう
# - **当てるのは cancelled (結論の無い打ち切り) だけである** (#2716 の反証 1)。最新の suite の赤は
#   その run が PR を読んで出した結論 (タイトル・Issue の紐づけ・絵) で、打ち直しても同じ赤を返す。
#   直すのは人で、タイトルなら bad-title が名乗る
# - **古い suite の結論は問わない** (#2716 の反証 2)。打ち切られた run は何も判定していないので、
#   古い suite が赤でも、打ち直せば今の PR を読んで結論を返す
# - 打ち直した run は同じ run (同じ suite) のまま、一覧は最後の attempt の結論を返すので、打ち直しが
#   終われば当たらなくなる。--paginate はページごとに --jq を当てるので、最大はここで取る
stale_gate_run() { # $1=head の SHA (完全な 40 桁。短い SHA では一覧が空になる)
  local rows newest id status conclusion
  rows=$(gh api "repos/$REPO/actions/workflows/pr-gate.yml/runs?head_sha=$1&per_page=100" --paginate \
    --jq '.workflow_runs[] | "\(.check_suite_id // 0) \(.id) \(.status) \(.conclusion // "-")"') || return 1
  newest=$(sort -n -k1,1 <<<"$rows" | tail -n 1)
  [ -n "$newest" ] || return 0
  read -r _ id status conclusion <<<"$newest"
  if [ "$status" = completed ] && [ "$conclusion" = cancelled ]; then
    echo "$id"
  fi
  return 0
}

# 「同じ名前で、新しい方は緑・古い方が赤」— 判定を固定している古い失敗 check (#259 / #513)。
# **打ち直してはならない古い run (legacy) と、直った証拠にならない緑 (SKIPPED・hollow) は数えない**
# (#2669 の反証 1・4)。SKIPPED の ci-check を「新しい緑」と読むと、本当に赤いコードの検査を当番の
# たびに打ち直す
stale_names() { # 標準入力=均した checks
  jq -r --argjson unsettled "$UNSETTLED" --argjson passed "$PASSED" '
    [ .[] | select((.legacy or .hollow or .result == "SKIPPED") | not) ]
    | [ group_by(.name)[]
      | . as $group
      | ($group | sort_by([.run, .at]) | last) as $latest
      | select(($passed | index($latest.result)) != null)
      | select([$group[] | . as $c
                          | select(($unsettled | index($c.result)) == null)
                          | select(($passed | index($c.result)) == null)] | length > 0)
      | $latest.name ]
    | unique | join(" ")'
}

# 最新の ci-gate が判定を表していない形 (冒頭の表の 10・11・14 行目)。masked / legacy /
# edited <run の id> / 空を出す。
#
# - masked: 最新の ci-gate が hollow (段を走らせていない run の緑) で、ci-check・ci-static の
#   最新の結論 (SKIPPED を除く) のどれかが赤い
# - legacy: 最新の ci-gate が古い run の赤で、その下のコードの検査は赤くなく (作法の赤)、最新の
#   pr-gate が SUCCESS。コードの赤なら名乗らない — 直すのはコードの側である
# - edited: (移行期) 最新の ci-gate が skips の赤で、ci-check・ci-static の最新の結論 (SKIPPED を
#   除く) がどちらも在って SUCCESS (#2717)。打ち直せば同じ SHA を読み直して緑を返すので、その
#   run の id を添えて名乗る。かつては当番が打ち直していた (reread) が、本文の編集で ci.yml の
#   run が立たなくなったので (#2718) 外した。検査の最新が赤・走っている途中なら出さない
#   (読み直しても同じ赤を返す・待ちで runner を占める)。
#   **検査の「最新」は、その run の版の ci-gate.sh の latest_run と同じものを読む** (#2717 の反証 2)
#   — 作成順で最新の run (suite) の、その中の最後の attempt (job の id の最大)。run の id は suite の
#   作成順と同じに並ぶ (規則と観測は scripts/ci-gate.sh 冒頭の「必須の判定が読む check run」)。
#   作法のジョブを含む古い run (legacy) の赤は legacy-gate に残す (#2717 の反証 1)
#
# ci-check・ci-static は rollup から名前だけで選ぶ。同じ名前の job をほかのワークフローに置かない
# (scripts/tests/ci_workflow_test.py が見る)
gate_state() { # 標準入力=均した checks
  jq -r --argjson unsettled "$UNSETTLED" --argjson passed "$PASSED" '
    def red: .result as $r | (($unsettled | index($r)) == null) and (($passed | index($r)) == null);
    def latest($n): [ .[] | select(.name == $n) ] | sort_by([.run, .at]) | last;
    def latest_ran($n): [ .[] | select(.name == $n and .result != "SKIPPED") ] | sort_by([.run, .at]) | last;
    def latest_read($n): [ .[] | select(.name == $n and .result != "SKIPPED") ] | sort_by([.run, .job, .at]) | last;
    latest("ci-gate") as $g
    | latest("pr-gate") as $p
    | ([ latest_ran("ci-check"), latest_ran("ci-static") ] | map(select(. != null)) | any(red)) as $code_red
    | ([ latest_read("ci-check"), latest_read("ci-static") ] | map(select(. != null))) as $read
    | if $g == null then ""
      elif $g.skips and ($g.legacy | not) and ($g | red)
           and ($read | length) == 2 and all($read[]; .result == "SUCCESS")
        then "edited \($g.run)"
      elif $g.hollow and $code_red then "masked"
      elif $g.legacy and ($g | red) and ($code_red | not) and $p != null and $p.result == "SUCCESS"
        then "legacy"
      else "" end'
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

# stale-gate (冒頭の表の 13 行目・#2716) の判定と名乗り。名乗って赤へ上げるなら 0、当たらない・
# 猶予の内・読めなかった (unreadable を名乗る) なら 1。予約が掛かった BLOCKED の PR に対して呼ぶ。
# 必須の定義は 1 度だけ読んで required に持つ
name_stale_gate() { # $1=番号 $2=PR の JSON $3=均した checks
  local n=$1 json=$2 checks=$3 mins sha gate_run
  if [ -z "${required:-}" ] && ! required=$(required_contexts); then
    say_line "$n" unreadable name 0 "必須チェックの定義 ($RULESET) を読めなかった (判定していない)"
    return 1
  fi
  [ -n "$(stale_gate_candidate "$required" <<<"$json")" ] || return 1
  mins=$(minutes_since "$(ready_since "$checks" "$json")")
  [ "$mins" -ge "$QUEUE_ENTRY_MINUTES" ] || return 1
  sha=$(jq -r '.headRefOid // ""' <<<"$json")
  if [ -z "$sha" ] || ! gate_run=$(stale_gate_run "$sha"); then
    say_line "$n" unreadable name 0 "PR gate の run の一覧を読めなかった (判定していない)"
    return 1
  fi
  # 最新の suite の run が cancelled でない (緑・赤・待ち): この形ではない
  [ -n "$gate_run" ] || return 1
  # ジョブの無い run の打ち直しは確かめていないので、効かないときの手を添える
  say_line "$n" stale-gate name "$mins" \
    "必須は揃っているのに、必須が読む最新の suite の pr-gate の run が cancelled で BLOCKED のまま — gh run rerun $gate_run で打ち直す (打ち直せなければ本文を編集して新しい run を作る。当番は打たない・#2716)"
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
    --json isDraft,autoMergeRequest,mergeStateStatus,statusCheckRollup,updatedAt,headRefOid) || {
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
      # 読めなかった (空) を「居ない」と読むと、外れた・古い check へ落ちて打ちうる (#1303)
      *)
        say_line "$n" unreadable name 0 "queue に居るかを読めなかった (判定していない)"
        continue
        ;;
    esac
  fi

  # 最新の ci-gate が判定を表していない形。打ち直さずに人へ返す (冒頭の表の 10・11・14 行目)
  read -r gstate grun <<<"$(gate_state <<<"$checks")" || true
  case "$gstate" in
    edited)
      mins=$(minutes_since "${failed_at:-$updated}")
      say_line "$n" edited-gate name "$mins" \
        "(移行期) 最新の ci-gate が #2718 より前の本文の編集の run の赤で、同じ SHA の検査の最新は success — gh run rerun $grun --failed で打ち直すか、新しいコミットを push する (当番は打たない・#2718)"
      [ "$mins" -lt "$STALL_MINUTES" ] || overdue=1
      continue
      ;;
    masked)
      mins=$(minutes_since "${failed_at:-$updated}")
      say_line "$n" masked-red name "$mins" \
        "コードの検査が赤いのに、最新の ci-gate は段を走らせていない run の緑 — コードを直して push する (打ち直さない)"
      [ "$mins" -lt "$STALL_MINUTES" ] || overdue=1
      continue
      ;;
    legacy)
      mins=$(minutes_since "${failed_at:-$updated}")
      say_line "$n" legacy-gate name "$mins" \
        "最新の ci-gate が作法のジョブを含む古い ci.yml の run の赤 — 新しいコミットを push する (本文の編集では ci.yml が起きない・#2718)"
      [ "$mins" -lt "$STALL_MINUTES" ] || overdue=1
      continue
      ;;
  esac

  stale=$(stale_names <<<"$checks")
  if [ -n "$stale" ]; then
    say_line "$n" stale-checks act "$(minutes_since "${failed_at:-$updated}")" \
      "古い失敗 check が判定を固定している ($stale)"
    # 同じ PR で必須が読む pr-gate が cancelled なら、それも名乗る (#2716 の反証 6)。打ち直す古い
    # check が残っていても、cancelled の pr-gate を打ち直すのは人である
    if [ "$auto" = true ] && [ "$state" = BLOCKED ] && name_stale_gate "$n" "$json" "$checks"; then
      overdue=1
    fi
    continue
  fi

  # BLOCKED でも承認待ちとは読まない。承認のゲートは ADR-0044 で外れた (#2108)。
  # 外れたかは状態ではなく出来事で読み、外れた時刻から猶予を測る。理由は冒頭の分類の表の下 (#2614)
  if [ "$auto" != true ]; then
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
    continue
  fi

  # 予約が掛かり必須も揃っているのに、必須が読む pr-gate が cancelled で BLOCKED のまま
  # (冒頭の表の 13 行目・#2716)。猶予の扱いは queue-not-entered と同じ
  if [ "$state" = BLOCKED ]; then
    if name_stale_gate "$n" "$json" "$checks"; then overdue=1; fi
    continue
  fi

  # 予約が掛かり必須も揃っているのに queue へ動かない (冒頭の表の 12 行目・#2693)
  if [ "$state" = CLEAN ] || [ "$state" = UNSTABLE ] || [ "$state" = BEHIND ]; then
    mins=$(minutes_since "$(ready_since "$checks" "$json")")
    [ "$mins" -ge "$QUEUE_ENTRY_MINUTES" ] || continue
    case "$(in_merge_queue "$n")" in
      true) ;;
      false)
        say_line "$n" queue-not-entered name "$mins" \
          "予約が掛かり必須も揃っているのに queue に入らない — gh pr merge $n --disable-auto の後に gh pr merge $n --auto --squash で掛け直す (当番は掛けない・#2693)"
        overdue=1
        ;;
      *) say_line "$n" unreadable name 0 "queue に居るかを読めなかった (判定していない)" ;;
    esac
  fi
done

exit "$overdue"
