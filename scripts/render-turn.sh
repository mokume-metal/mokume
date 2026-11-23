#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 専用機へ job を積む順番を決める門番 (#2062)。
#
#   render-turn.sh merge_group <base sha> [<base ref>]
#   render-turn.sh yield
#   render-turn.sh wait
#   render-turn.sh slots <event>[|<event>...]
#
# 専用機は 1 台 (runner は RENDER_TURN_SLOTS 本・下の「並走の数」) で、必須の render (merge_group)・情報の render-pr (pull_request)・定期の
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
#   merge_group  自分より前の N 本 (RENDER_TURN_SLOTS) の group の run のうち終わっていないものと、
#                render-pr が専用機で取っている枠 (下の「専用機の枠を数える」) の合計が N 本未満に
#                なるまで待つ。N=1 なら 1 つ前の group の run (自分の base sha を head に持つ
#                merge_group の run) が終わるまで待ち、group は queue の順に 1 本ずつ専用機に
#                積まれる。base sha が base ref (既定 refs/heads/main) の先端なら、自分が先頭なので
#                前の group は数えない (merge 済みの前の group の run を人が走らせ直していても
#                待たない)。先頭も render-pr は数える
#   yield        merge_group の run が無ければ通す。あれば、その数と、render-pr と定期の job が
#                専用機で取っている枠の合計が N 本未満のときだけ通し、そうでなければ go=false を出して
#                抜ける (render-pr は見送る。必須ではないので merge の可否は変わらない)。通す直前に、
#                この run の head (RENDER_TURN_HEAD_SHA) が PR の branch (RENDER_TURN_HEAD_REF)
#                の今の先端と違えば、同じく go=false で見送る (下の「古い head」)
#   wait         merge_group の run が 1 本でも終わっていなければ、終わるまで待つ
#                (scheduled-* は見送らずに後ろへ回す)
#   slots        門番ではない。下の「専用機の枠を数える」の数え方で、指定した event の run が取って
#                いる枠を 1 本 1 行で出して終わる。queue-sweep.sh が、門番と同じ数え方で render-pr を
#                残すか退かせるかを決めるために呼ぶ
#
# 待つ相手は render job ではなく **run** で見る。group の run は門番で待っている間も
# in_progress なので、「専用機に積まれる予定の render」まで数えられる。job で見ると、
# 前の render が終わってから次の門番が気付くまでの隙間に render-pr が入り込む。
#
# ## 並走の数 (RENDER_TURN_SLOTS・#3319)
#
# 専用機の runner の数に合わせる (#2252 の案 3-a)。**守るのは「専用機に積まれた job
# (queued + in_progress) の数が runner の数を越えない」で、越えなければ拾う順は問題に
# ならない。** merge_group の門番は、前の group を N 段まで遡って、終わっていない run を
# 持つ group を数える。N 段目の前の group は、N-1 段目の base sha の親 (queue の squash の
# commit は親 1 つで、親が 1 つ前の group の base sha) を head に持つ run で引く。base ref の
# 先端に着いたら、それより前の group は merge 済みなので遡らない。
#
# 未設定か空なら 1 (今までどおり 1 本ずつ)。1 以上の整数でなければ使い方の誤り (2) で止め、
# 黙って並走させない。render.yml はリポジトリの変数 vars.RENDER_TURN_SLOTS を渡すので、
# runner を足した後の切り替えと戻しは変数だけで行う。wait は N を見ない (merge_group の run が
# 1 本でも残っていれば待つ)。
#
# ## 専用機の枠を数える (#4018)
#
# group が専用機を待っている間も、runner が空いていれば render-pr を走らせる。そのぶん、
# merge_group の門番も render-pr が取っている枠を数えて待つ — 数えないと、render-pr が 1 本
# 走っている間に group が N 本来たとき、専用機に積まれる job が N+1 本になり、上の不変条件が
# 破れる。
#
# 枠は job の名前ではなく、render.yml の run ごとに数える (runner_slots)。**数え方はここ 1 か所に
# 置き、queue-sweep.sh も slots の mode で同じ実装を呼ぶ** (門番と掃除が別々に数えて食い違った)。
# job が「走っている」のは status が queued か in_progress のときだけ (stall-watch.sh と同じ語。
# needs や concurrency で待つ waiting・pending の job は runner を取っていない)。終わっていない
# run (queued・in_progress) のうち:
#   - 専用機の job (ラベル mokume-render) が走っていれば、その数だけ取っている
#   - 走っている job が 1 本も無いのに run が終わっていなければ、1 本取っていると数える (門番の後。
#     まだ走っていない専用機の job があればその名前で出す)。門番が通してから専用機の job が queued に
#     なるまでの数秒 (と、job の間の隙間) で、ここを数えないと yield が通した直後の render-pr を後ろの
#     group の門番が見落とし、両方が積まれる。go=false の run も render-pr が skipped で現れるまでの
#     数秒は数えられるが、数え過ぎは次の周で解ける。待つ job が何本並んでいても run 1 本で 1 枠
#   - pull_request の run で、門番 (ホストの job) が走っていて専用機の job がまだ走っていなければ、
#     1 本取っていると数える (門番の中)。yield はその場で結論を出すので、通るかもしれない 1 本を
#     数えておかないと、yield が読んでから通すまでの間に読んだ merge_group の門番が見落とす。
#     見送られれば次の周で数えなくなる。2 本の PR の yield が同時に走ると互いを数え、空き枠が
#     1 本でも両方が見送りうる (見送りの側に倒れる)
#   - それ以外 (定期の門番 wait だけが走っている・専用機の job が終わり後続のホストの job だけが
#     走っている) は取っていない。定期の門番は最大 60 分待つので、数えると group を長く止める
# 自分の run (GITHUB_RUN_ID) は数えない。自分の門番は走っているので、除かないと yield が自分を
# 門番の中と数える。
#
# 数える run の種類は mode で違う:
#   - merge_group は pull_request の run (render-pr) だけを数える。定期の scheduled-* は数えない
#     — 割り込みうる 1 本として queue の期限で受け入れてある (下の「上限」・ADR-0019 決定 7 の
#     「queue の期限を 60 分から約 95 分へ延ばす」)
#   - yield は pull_request と schedule の run を数える。必須でない render-pr のために、定期の job と
#     group の render の上へ N+1 本目を積まない。queue-sweep.sh も同じ 2 種類で数え、yield なら
#     見送る render-pr を残さない
#
# **merge_group の run が無い間の yield は、数えずに通す** (N=1 では今までと同じ結論)。
# 待たせる相手が居ないからで、その間に積まれた render-pr は、拾われる前に group ができて
# 枠を越えれば queue-sweep.sh が cancel し (#2064)、走っていれば merge_group の門番が数えて待つ。
# 代償は、render-pr が枠を取っている間に来た group の render が、render-pr の 1 本分
# (最大 30 分) 待ちうることである。N=1 では、先頭の group も走っている render-pr を待つ
# (以前は待たずに積まれ、専用機の queue で待った)。入れてから 7 日、merge_group の render の
# 待ちの p90 を測り、10 分を越えたら戻す (#4018)。
#
# yield は merge_group の run を run の状態で数える (merge_group の門番が前の group を数えるのと
# 同じ)。group の render が終わった後もホストの後続 (render-notice-report は concurrency で前の
# run を待ちうる) が走る間は枠を取っていると数え、空いた runner があっても render-pr を見送る
# (見送りの側に倒れる・短い間)。
#
# 残る重なり:
#   - merge_group の門番は定期の job を数えないので、定期の job が走っている間は group の render と
#     合わせて N+1 本になりうる (上のとおり受け入れた割り込み)。queue-sweep は group ができた時点で
#     定期の job も数え、枠を越える queued の render-pr を退かせるので、render-pr がそこへ重なる形は
#     その時点で解く
#   - 2 本の PR の yield と merge_group の門番は、互いの run が一覧に現れる前に読めば相手を数えない
#     (run の作成から一覧に出るまでの数秒)。現れた後は、門番の中・門番の後・走っている job の
#     どれかで数える
#   - API の上限で門番が待たずに通した回・読めずに通した回 (下の「判定できないときは通す」)
#
# ## 古い head (yield・#3551)
#
# render-pr は `render-pr-${{ github.ref }}` の concurrency (cancel-in-progress) で、同じ PR への
# push し直しの旧い job を捨てる。**GitHub は後から群に入った job を残す**ので、入る順が push の順と
# 逆になると、旧 head の job が走っている新 head の job を取り消し、古い木の絵が残る。入る順は
# この門番が終わった順で、門番は待たない (yield の limit は 0) が、ホストの queue の揺れや API の
# 引き直し (60 秒を最大 2 回眠る) で旧い門番が遅れうる。
#
# そこで通す直前に、この run の head と PR の branch の今の先端を比べ、違えば go=false で見送る。
# 比べる場所はここ (群に入る前の最後の場所) で、render-pr の最初の step ではない — job レベルの
# concurrency は step が始まる前に評価されるので、step で比べても旧 head はもう群に入っている。
# 先端は matching-refs の API (contents: read) で引く。権限は actions: read のまま広げない。
# 読めない・branch が無い・環境変数が無いときは比べずに通す。
#
# **ウィンドウを縮めるだけで、ゼロにはならない。** 比べるのは出口の 1 回だけなので、出口から旧 head の
# render-pr が群に入るまでの遅れが、新しい push の門番の所要を超えれば、旧 head が新 head を取り消す向きは
# 残る (権限を広げない決定の下では、根まで消せない)。見送られた run も、新しい push の run が立たなければ
# (`[skip ci]`・GITHUB_TOKEN による push・main との衝突) 誰も render-pr を走らせないが、render-pr は
# 必須ではないので merge は止まらない。
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
# **merge_group は queue の期限の直前 (90 分・期限は 95 分) まで放さない。** 前の group が
# 終わらないまま待ちが長引くのは、専用機が他の job (最大 30 分) を走らせているときで、早く
# 放すと後ろの group がそろって専用機に積まれ、期限に近い前の group と取り合う — 元の症状に
# 戻る。90 分まで待てば自分の group も期限で外れる間際なので、放しても前の group を邪魔しない。
# 期限は、前の group の render 30 分 + 割り込みうる専用機の job 1 本 30 分 + 自分の render
# 30 分 + 門番の間隔に収まるよう 60 分から 95 分へ延ばした (#3502)。「割り込みうる 1 本」は走っている
# render-pr か、wait で放された定期の job のどちらか 1 本で、両方が重なる形 (30 + 30 + 30 + 30 = 120 分)
# は 95 分でも覆えず、今までどおり期限で外れる。適用後 7 日の測定で数える (ADR-0019 決定 7 の
# 「queue の期限を 60 分から約 95 分へ延ばす」)。
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
# merge_group で 2N 件 (先端・前の N 本の run・遡るための親 N-1 件)、yield / wait で 2 件
# (queued と in_progress) なので、N=1 の門番 1 本で 1 時間 120 件、N=2 で 240 件になる。
# 前の group が N 本未満のときだけ、枠を数えるのに 2 + k 件 (render.yml の run の一覧 2 件と、
# 数える種類の終わっていない run k 本の jobs) を足す。
# 同時に待つ merge_group の門番は、group で待つものは queue が同時に組む group の数
# (main-protection.json の max_entries_to_build) より N 本少ない。今の 2 なら N=1 で 1 本
# (120 件)、N=2 では group で待つ門番が無い。render-pr で待つのは render-pr が終わるまで
# (最大 30 分) で、N=2 で 2 本が 1 周に 6 + k 件と 3 + k 件 (先頭) を引いても、k=1 で 30 分に
# 330 件ほどである。定期の門番 1 本を足しても枠の内に収まる。
#
# ## 判定できないときは通す
#
# API が 3 回続けて読めなければ go=true で通し、::warning:: を出す。門番の失敗で検査が
# 走らないほうが、順番が乱れるより重い。1 回の 502 では通さない — 通すと後ろの group と
# render-pr が一度に積まれ、元の症状に戻る。終了コードは使い方の誤りでだけ非 0 にする。
#
# **例外は yield で、merge_group の run があるのに専用機の枠を読めなかったときは、引き直さずに
# 見送る** (#4018)。この判定の結論は以前は常に「見送る」で、通す理由 (必須の検査が走らない
# ほうが重い) は必須でない render-pr には当たらない。引き直しで yield が遅れると、古い head の
# ウィンドウ (上の「古い head」) も広がる。merge_group の run の一覧を読めないときは今までどおり。
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
  sed -n '7,10p' "${BASH_SOURCE[0]}" | sed 's/^# *//' >&2
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
    mode=merge_group base=$2 base_ref=${3:-refs/heads/main} limit_default=90
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
  slots)
    # 数える run の event を | で区切った並び (例: pull_request|schedule)。正規表現に入るので語を絞る
    [ $# -eq 2 ] && [ -n "$2" ] && [[ "$2" != *[!a-z_\|]* ]] || {
      usage
      exit 2
    }
    mode=slots events=$2
    # 門番ではないので待たない (上限は使わない。下の変数を組むためだけに置く)
    limit_default=0
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
# 専用機で同時に走らせる merge_group の render の数 (上の「並走の数」)
SLOTS="${RENDER_TURN_SLOTS:-1}"
case "$SLOTS" in
  "" | *[!0-9]* | 0*)
    echo "render-turn: RENDER_TURN_SLOTS は 1 以上の整数で渡す: '${RENDER_TURN_SLOTS}'" >&2
    exit 2
    ;;
esac

# 「まだ終わっていない」run の status。一覧 API の status は 1 つしか取らないので並べて引く
# (queue-sweep.sh と同じ)。render.yml の run は environment も run 単位の concurrency も
# 持たないので、waiting / pending / requested にはならない — 引くのは 2 つで足りる
ACTIVE_STATUSES="queued in_progress"

# 空でない行の数 (空なら 0。grep -c は 0 件で非 0 を返すので、終了コードを捨てる)
count_lines() {
  printf '%s\n' "$1" | grep -c . || true
}

say() {
  echo "$1"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$1" >> "$GITHUB_STEP_SUMMARY"; fi
}

# yield だけ: この run の head が、PR の branch の今の先端のままか (#3551)。古ければ 0 を返し、
# 今の先端を current_head に入れる。比べる相手を読めない・branch が無い・環境変数が渡されていない
# ときは 1 (古いとは言わない — 「判定できないときは通す」と同じ向き)
current_head=""
stale_head() {
  local ref=${RENDER_TURN_HEAD_REF:-}
  [ -n "${RENDER_TURN_HEAD_SHA:-}" ] && [ -n "$ref" ] || return 1
  if ! current_head=$(gh api "repos/$REPO/git/matching-refs/heads/$ref" |
    jq -r --arg ref "refs/heads/$ref" '.[] | select(.ref == $ref) | .object.sha'); then
    echo "::warning::PR の branch の先端を読めなかったので、head が古いかは見ずに通す (#3551)"
    current_head=""
    return 1
  fi
  [ -n "$current_head" ] && [ "$current_head" != "$RENDER_TURN_HEAD_SHA" ]
}

finish() { # $1=go の値
  local go=$1
  # 通す直前に、古い head なら見送る。job レベルの concurrency は job の step が始まる前に評価される
  # ので、job の中で比べても遅い — 旧 head の job が群に入って、走っている新 head の job を取り消した後に
  # なる。比べる場所は、群に入る前の最後の場所であるこの出口である
  if [ "$go" = true ] && [ "$mode" = yield ] && stale_head; then
    say "この run の head (${RENDER_TURN_HEAD_SHA:0:8}) は PR の今の先端 (${current_head:0:8}) と違うので、render-pr は見送った (#3551):"
    say "- 新しい push の run があれば、render-pr はそちらで走る。旧 head の job が群に入ると、走っている新 head の job を取り消しうる"
    say "- この run を rerun しても同じく見送られる。rerun ではなく、新しい head の run を見る"
    go=false
  fi
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "go=$go" >> "$GITHUB_OUTPUT"; fi
  exit 0
}

unreadable() { # $1=何を読めなかったか
  echo "::warning::$1を読めなかったので、順番を待たずに通す (#2062)"
  say "$1を読めなかったので、順番を待たずに通した"
  finish true
}

# 専用機の枠を取っている render.yml の run を、取っている枠 1 本につき 1 行
# 「<id> <event> <head_branch> <何が取っているか> [<job の status>]」で出す (上の「専用機の枠を数える」)。
# 何が取っているかは、専用機の job の名前 (status つき)・「門番の中」・「門番の後」・「読めなかった」。
# $1 は数える run の event を | で区切った並び。**queue-sweep.sh も slots の mode でこれを呼ぶ** —
# 門番と掃除が別々に数えると、片方が通した render-pr を片方が枠の外と読む。
# run の一覧を読めなければ何も出さずに非 0、jobs を読めない run があれば「読めなかった」の行を出して
# 残りを数え、非 0 で返す
runner_slots() {
  local events=$1 active got runs="" id event branch slots slot failed=0
  for active in $ACTIVE_STATUSES; do
    got=$(gh api "$RUNS?status=$active&per_page=100" \
      --jq ".workflow_runs[] | select(.event | test(\"^($events)\$\")) | \"\(.id) \(.event) \(.head_branch)\"") ||
      return 1
    runs+="$got"$'\n'
  done
  while read -r id event branch; do
    [ -n "$id" ] && [ "$id" != "${GITHUB_RUN_ID:-}" ] || continue
    # job の status は queued と in_progress だけを「走っている」と読む (stall-watch.sh の runner_jobs と
    # 同じ語)。needs や concurrency で待つ job (waiting・pending) は runner を取っていない
    if ! slots=$(gh api "repos/$REPO/actions/runs/$id/jobs?per_page=100" \
      --jq '[.jobs[] | select(.status == "queued" or .status == "in_progress")] as $active
        | [.jobs[] | select((.labels // []) | index("mokume-render"))] as $runner
        | [$active[] | select((.labels // []) | index("mokume-render"))] as $busy
        | if ($busy | length) > 0 then $busy[] | "\(.name) \(.status)"
          elif ($active | length) == 0 then
            ([$runner[] | select(.status != "completed")] | first
              | if . then "\(.name) \(.status)" else "門番の後" end)
          elif ([$runner[] | select(.status == "completed")] | length) == 0 then "門番の中"
          else empty end'); then
      echo "$id $event $branch 読めなかった"
      failed=1
      continue
    fi
    while IFS= read -r slot; do
      [ -n "$slot" ] || continue
      # 門番の中は pull_request の run だけを数える。yield はすぐ結論を出すので、通るかもしれない 1 本と
      # 数えても次の周で解ける。定期の門番 (wait) は長く待つので数えない
      [ "$slot" != 門番の中 ] || [ "$event" = pull_request ] || continue
      echo "$id $event $branch $slot"
    done <<<"$slots"
  done < <(printf '%s' "$runs" | sort -u)
  return "$failed"
}

# runner_slots の行を、待つ相手の表示「<id> <head_branch> (<何が取っているか>)」にする
slot_lines() {
  awk 'NF { print $1, $3, "(" $4 ")" }'
}

if [ "$mode" = slots ]; then
  runner_slots "$events" || exit 1
  exit 0
fi

# 待つ相手を 1 行ずつ「<id> <head_branch>」で出す。読めなければ非 0
blocking_runs() {
  local active got out="" tip sha=${base:-} step busy=0 open prs
  case "$mode" in
    merge_group)
      # 先端と先に比べる: 先頭なら、前の group の run の状態によらず group では待たない
      tip=$(gh api "repos/$REPO/git/matching-refs/${base_ref#refs/}" \
        --jq ".[] | select(.ref == \"$base_ref\") | .object.sha") || return 1
      # 前の group を N 段まで遡り、終わっていない run を持つ group を数える
      for ((step = 1; step <= SLOTS; step++)); do
        [ "$sha" != "$tip" ] || break
        got=$(gh api "$RUNS?event=merge_group&head_sha=$sha&per_page=100" \
          --jq '.workflow_runs[] | "\(.id) \(.status) \(.head_branch)"') || return 1
        if [ -z "$got" ]; then
          # 先頭でないのに前の group の run が無い: まだ作られていない (組み直しの直後)
          if [ "$SECONDS" -lt "$MISSING_GRACE" ]; then
            out+="- (前の group の run がまだ作られていない: head_sha=${sha:0:8})"$'\n'
            busy=$((busy + 1))
          fi
        else
          open=$(awk '$2 != "completed" { print $1, $3 }' <<<"$got")
          if [ -n "$open" ]; then
            out+="$open"$'\n'
            busy=$((busy + 1))
          fi
        fi
        [ "$step" -lt "$SLOTS" ] || break
        sha=$(gh api "repos/$REPO/commits/$sha" --jq '.parents[0].sha') || return 1
        [ -n "$sha" ] || return 1
      done
      # 終わっていない group と render-pr が取っている枠が合わせて N 本未満なら、自分の分の runner が
      # 空いている。group だけで N 本なら枠は引かない。定期の job は数えない (上の「専用機の枠を数える」)
      if [ "$busy" -lt "$SLOTS" ]; then
        prs=$(runner_slots pull_request | slot_lines) || return 1
        [ -z "$prs" ] || out+="$prs"$'\n'
        busy=$((busy + $(count_lines "$prs")))
        [ "$busy" -ge "$SLOTS" ] || return 0
      fi
      ;;
    *)
      for active in $ACTIVE_STATUSES; do
        got=$(gh api "$RUNS?event=merge_group&status=$active&per_page=100" \
          --jq '.workflow_runs[] | "\(.id) \(.head_branch)"') || return 1
        out+="$got"$'\n'
      done
      out=$(printf '%s' "$out" | sed '/^$/d' | sort -u)
      # yield: group が N 本未満なら、render-pr と定期の job が取っている枠と合わせて N 本未満の
      # ときだけ通す (上の「専用機の枠を数える」)。group が無ければ今までどおり通す。枠を読めなければ
      # 引き直さずに見送る (上の「判定できないときは通す」の例外)
      if [ "$mode" = yield ] && [ -n "$out" ]; then
        busy=$(count_lines "$out")
        if [ "$busy" -lt "$SLOTS" ]; then
          if ! prs=$(runner_slots 'pull_request|schedule' | slot_lines); then
            prs="- (専用機の枠を読めなかったので見送る側に倒した)"
            busy=$SLOTS
          fi
          busy=$((busy + $(count_lines "$prs")))
          [ "$busy" -ge "$SLOTS" ] || return 0
          out+=$'\n'"$prs"
        fi
      fi
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
      merge_group)
        if [ "$SLOTS" -eq 1 ]; then
          say "前の group の render は終わっていて (または自分が先頭)、render-pr も専用機の枠を取っていない。$((SECONDS / 60)) 分待った"
        else
          say "前の $SLOTS 本の group のうち終わっていない render (自分が先頭なら数えない) と、render-pr が取っている枠は合わせて $SLOTS 本未満。$((SECONDS / 60)) 分待った"
        fi
        ;;
      yield) say "merge queue の render と、render-pr・定期の job が取っている枠は合わせて $SLOTS 本未満 (merge queue の render が無ければ枠は数えない)" ;;
      *) say "merge queue の render は走っていない。$((SECONDS / 60)) 分待った" ;;
    esac
    finish true
  fi

  if [ "$mode" = yield ]; then
    say "専用機の枠 ($SLOTS 本) が merge queue の render と render-pr・定期の job で埋まっているので、render-pr は見送った (#2062・#4018):"
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
