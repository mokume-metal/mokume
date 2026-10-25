#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 「次に何へ着手できるか」の判定 (#1028)。[ADR-0036](../docs/decisions/0036-unattended-issue-processing.md)
# 決定 1 が分けた 3 層のうち、**判定だけ**がこのリポジトリに居る。起床と子セッションの
# 起動は外に残る (ADR-0017 決定 1 の類型 2 — どのリポジトリにも属さない場所で走る)。
#
#   ready-queue.sh
#
# ## ここは何も打たない
#
# 呼ぶのは `gh issue list` / `gh pr list` / `git worktree list` の 3 つで、ラベルも付けず
# auto-merge も掛けない。読み取りが増えるのは 3 つの場合だけである — 自分に証拠の無い
# 着手印があるときは、その
# 家族を読む `gh api graphql` が 1 回加わる (下の「落ちて見えるか」)。最近動いた着手印か
# 家族があるときは、その手が人か bot かを読む `gh api graphql` が 1 回ずつ (最大 2 回) 加わる
# (下の「bot の追記は数えない」)。open な Bug・ready の候補・stock の候補があるときは、その親と
# 自分の子・開き直しの手を読む `gh api graphql` が 1 回加わる (下の「根と判断」)。scripts/stall-watch.sh と
# 同じ性質で、**手元でいつ打っても安全である**。打つ側 (stall-act.sh に当たるもの) はこのリポジトリには来ない — 打つのは
# 外に居るディスパッチャの仕事で、こちらが実行まで持つと「様子を見るために打ったら着手が
# 始まった」が起きる。
#
# ## 出力
#
#   <番号> <分類> <説明>
#
# 番号は Issue の番号である。
#
# **ready と stock の説明は、Issue Type を `[Bug]` の形で先頭に置く** (#2136)。Type は題から
# は読めず、Bug なら反証の節 (bug-refute) が要るので、着手の前に目に入っている必要がある
# (知らずに着手した Bug が review-gate で落ちた — #1998)。Type の無い Issue は `[-]` と出す
# (空にすると欄がずれる。parents の列と同じ作法)。**先頭の 2 語 (番号・分類) の位置は動かさ
# ない** — Type は説明の側に入るので、番号と分類だけを読む側は影響を受けない。dropped・busy・
# decide は Type を出さない (着手の前に見るのは ready と stock だけ)。
#
# 分類は 5 つで、この順に出す:
#
#   ready    verify: triaged が付き、着手中でもなく、紐づく open PR も無く、開いた根の子でもない
#   stock    **B-1 の対象** — エージェントが起票したのに無印で、型が Bug / Task / Docs
#   dropped  status: in progress なのに、open PR も手元の worktree / 枝も無く、静かで久しい。
#            家族 (親・兄弟・子) にも同じ証拠が無い
#   busy     着手中 (紐づく open PR がある・手元に worktree / 枝がある・まだ動いている・
#            家族のどれかがそうである)。または ready の候補のうち、開いた根の子 (親が open な
#            Bug か、親が open で印の付いた Design の Bug の子。根を直す側で閉じる)、または
#            本体を閉じた後に parent-guard (bot) が開き直した、子を持つ親 (自分の仕事を持たず、
#            残りは子が持つ — 「子 #N を待つ」。子がすべて閉じたら「閉じてよい」。stock・decide にも出さない)
#   decide   **人が決める行** — 無印の Design で、open な Bug の子を持つもの。子の多い順
#
# ## 根と判断 (#1661)
#
# バグの直しは「深いが狭い」— 原因の特定と再現はよくできているのに、兄弟の口を探さず、
# 同じ根のバグが 1 件ずつ直されていた (#1659)。ADR-0040 は同じ根の群を sub-issue で束ね、
# 根を直す PR が子をまとめて閉じるとした (決定 2)。判定はその形に 2 つで合わせる:
#
#   開いた根の子            ready に出さず busy へ回す。子を 1 件ずつ拾うと、根を直さずに
#                           症状だけを閉じる直しが続く。根のほうが ready に出ていれば、そちらを取る。
#                           根は、親が open な Bug (子の型は問わない) か、親が open で印の付いた
#                           Design (子が Bug のときだけ — #2228)
#   Bug の子を持つ          根本の直し方が人の判断を待っている (決定 3 — 約束を決める・変える
#   無印の Design           ときだけ人を待つ)。人の目に入らないと、子の Bug が症状のまま直される
#
# **開き直された親は、自分の仕事を持たない** (#3036)。本体の仕事を終えて閉じた親が open の子を
# 残していると、parent-guard が開き直す (閉じる = 全作業の完了という木の不変条件 — ADR-0002・#23)。
# 親には印が残るので、そのままでは済んだ仕事が ready に出る。**見るのは「最後の開き直しの手」と
# 「子の有無」の 2 つだけ** — 手が bot (scripts/bot-hand.sh) で、子を 1 件以上持つ親を、**自分の仕事を
# 持たない親**とする。open の子が残る間は「子 #N を待つ」、**最後の子が閉じた後も ready には戻さない**
# (親を閉じる仕組みは無いので、戻すと済んだ仕事が時刻を遅らせて再び出る — #1734 は #1744 が閉じた
# 瞬間に出る)。busy に「子がすべて閉じた — 閉じてよい」と名乗り、閉じるのは人に任せる。人が仕事を足す
# ために開き直した親・開き直されたことの無い親 (段を持つ Design・Bug の根)・子を持たない親は、自分の
# 仕事を持つ。「open の子を持つ親は ready に出さない」と一律にはしない。
#
# **この判定は 1 つで、4 つの口が使う。** 口ごとに別の式を持つと、1 つだけ直して他が残る:
#
#   ready の候補   自分の仕事を持たなければ ready に出さず、busy「子 #N を待つ」(番号が名乗れなければ
#                  「open の子 N 件を待つ」) へ回す
#   根             自分の仕事を持たない親は、子の根に数えない。数えると、親は子を待ち、子は親で直す側に
#                  回って、残りの仕事がどこにも出なくなる。子は自分で ready / busy に判定される
#   stock          エージェントが起票した無印の親が閉じられて開き直されても出さない
#   decide         人が決めて閉じた無印の Design が、open な Bug の子のために開き直されても出さない
#
# 開き直しの手と子は、候補自身の timeline と subIssues から、親の問い合わせと同じ 1 回で読む
#
# **Design の根で子を止めるのは、印が付いてから**である。無印のうちは decide に出て人を待ち、
# 子の症状の直しは止めない (決定 3「Design を待つ間も、症状を塞ぐ直しは止めない」)。印が付くと
# decide から外れて根そのものが ready に出るので、そこで子を根へ回す — 回さないと、根に束ねた
# Bug が ready に残って症状の 1 か所だけが直される。Design の Bug でない子 (段取りの Task など) は
# 根の症状ではないので止めない。止めると #1663・#1744 (印の付いた Design の子の Task) まで
# ready から消える。
#
# 親 (番号・state・型・印) は GraphQL 1 回で、open な Bug・ready の候補・stock の候補 (と、open な
# Bug があるときの未トリアージの Design) の分だけ読む。
# **読めなかったら ready と stock は従来どおり (開き直された親も) 出し、decide は出さず、そう名乗る。** decide は終了コードに
# 数えない — 打てる仕事ではなく、人が決める仕事である。
#
# busy を出すのは、**ready から外れた理由を見せるため**である。ready だけ出すと「なぜ
# この Issue が出てこないのか」が読めず、判定の誤りが黙って通る。
#
# ## 何を見て、何を見ないか
#
#   着手できるか    ラベル (verify: triaged / status: in progress)
#   紐づく PR       gh pr list の closingIssuesReferences。**GitHub 自身の答えを読む** —
#                   本文を正規表現で拾うと scripts/review-gate.sh と読み方が割れ、
#                   割れたほうが黙って「着手できる」に倒れる (ADR-0008 決定 6)
#   B-1 の対象か    本文の 🤖 Assisted by の署名 (エージェントを問わない。#3149)。**これが唯一の手掛かり**
#                   である — Issue の author は identity 分離の対象外なので (ADR-0003 が
#                   分けたのは PR の作成だけ)、エージェントの起票も人の名義で立つ
#   落ちて見えるか  紐づく open PR が無く、git worktree list のパスと枝の名前に番号が
#                   現れず、**そのうえ Issue が静かになって久しい**こと
#
# 3 つ目が要るのは、**枝の名前が番号を持たないことのほうが多い**からである — AGENTS.md が
# 定める枝の形は `<type>/<短い説明>` で、番号はどこにも入らない。worktree の照合だけに頼ると
# 「いま着手した Issue」がそのまま dropped に出る (実際にこのスクリプト自身の #1028 で出た)。
# 静かさは Issue の updatedAt で測る — 着手すればラベルが動きプランが投稿されるので、
# 生きている着手は必ず新しい。**ただし bot の手は数えない** (次の節)。
#
# ### bot の追記は数えない (#2660)
#
# 逆向きは成り立たない — 新しいからといって生きているとは限らない。Issue の活動には bot の手が
# 混じる (前提の宣言と「bot の手か」の判定は scripts/bot-hand.sh)。bot の追記は updatedAt を
# 動かすので、止まった着手印でも追記から 120 分は「まだ動いている」に見え、前検査が
# merge_group ごとに追記すると queue が回る間ずっと隠れる。
#
# 項目の種類は限らない — 窓の timeline はどの種類にも作者 / actor を引かせ (bot-hand.sh の
# 断片)、Bot のものを全部 bot の手として扱う。
# だから updatedAt が新しいだけの着手印 (PR も手元の worktree / 枝も無い) は、**窓の中
# (DROPPED_MINUTES 分) の timeline を引いて、人の手があるかを見る**。窓の中に bot の手が
# **少なくとも 1 つあり**、それ以外が無いときだけ静かとみなして家族の判定へ回す — 新しさを
# 説明しているのが bot の手だと分かるときに限る。それ以外 (人の手・作者の分からない項目・
# 本文の編集・窓に 100 件を超えて見えない項目・**窓が空**) は今までどおり動いているとみなす —
# **bot と分かるものだけを除く**。窓が空でも新しいのは、timeline に出ない動き (既存のコメントの
# 編集・子の close による親の更新など) が updatedAt を動かしたときで、それが人の手でないとは
# 言えない。家族の open な者も同じ式で測る。閉じた家族は「閉じたばかり」
# のまま (bot が追記するのは open な Issue だけ — scripts/report-check-failure.sh)。
#
# 問い合わせは、そういう着手印があるときに 1 回、家族にそういう者があるときにもう 1 回で、
# どちらも GraphQL 1 回にまとめる。**読めなかったら従来どおり updatedAt で測り、そう名乗る** —
# 親を読めなかったとき (下の「根と判断」) と同じ作法で、精密化が読めないことで元の判定より
# 悪くしない。
#
# ### 家族も見る (#1391)
#
# 上の前提は、**着手より前に付けた印**と**親の印**には成り立たない。1 つのセッションが兄弟を
# まとめて予約すると、PR を出すまで子は 1 度も動かない。プランは親に 1 通だけ載る。親の側も、
# 子で作業が進んでも自分の updatedAt は動かない — 子の PR の Closes が指すのは子だからである。
# 2026-09-23 には、生きている #1350 / #1352 / #1355 がこれで dropped に出た。
#
# だから、自分に 3 つの証拠 (PR・手元の worktree か枝・新しい updatedAt) が無い着手印は、
# **家族**を見てから決める。家族は親・その親の子すべて・自分の子すべてで、閉じたものも含む。
# 閉じた家族は PR も worktree も持たないので、updatedAt が新しいときだけ動いているとみなす。
# 兄弟の PR が merge されてから、次の子の PR が出るまでの間を拾うためである。
#
# **家族を渡るのは 1 段だけにする。** 家族の証拠に数えるのは上の 3 つだけで、家族を通じて
# busy になったものは数えない。連鎖させると、1 本の生きた PR が無関係な枝まで生かしてしまう。
#
# 家族を読む問い合わせは、そういう候補があるときだけ 1 回打つ。**読めなかったら dropped の
# まま**出し、そう書く — 読めなかったことを「生きている」と読まない。
#
# 代償は既知である: 家族が動き続けていると、本当に落ちた予約も busy に隠れる。拾う動作は
# いまのところ無い (ADR-0036 決定 5) ので、誤って拾うより安い側に倒した。
#
# **見ないもの**: 他のマシンで動いているセッション。worktree は手元のものしか見えないので、
# dropped は「落ちた」ではなく「**落ちて見える**」までしか言わない。拾う動作を足さないのも
# 同じ理由である (ADR-0036 決定 5 — 出すのは 0 円だが、拾うには実害が要る)。
#
# 未トリアージのうち stock に当たらないもの (人が起票したもの・型が Design / Feature の
# もの) は**出さない**。判断が要る側なので、機械が並べても着手には繋がらない。
#
# ## 終了コード
#
#   0  打てる仕事がある (ready が 1 件以上)
#   1  0 件 (在庫切れ — 呼ぶ側は B-1 へ回る)
#   2  判定できなかった (Issue か PR の一覧を読めなかった) — 在庫切れと読まない
#
# **読めなかったときに 1 を返さない** (#1235)。呼ぶ側は終了コードで分岐するので、1 だと判定が
# 壊れていても「在庫が尽きた」と読んで B-1 へ回る — #1045 が塞いだ形が、読み取りの失敗から
# 黙って戻る。gh の版は検査しない。古い gh で欄が足りなければ gh 自身がそう名乗る
# (例: issueType は gh 2.94.0 から)。
#
# 検査は scripts/tests/ready_queue_test.py。
set -euo pipefail

# リポジトリの owner/repo。**literal は scripts/repo-slug.sh の 1 箇所だけ** (#818)
# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"
# 「bot の手か」の判定と、その前提の宣言 (#2660)
# shellcheck source=scripts/bot-hand.sh
. "$(dirname "${BASH_SOURCE[0]}")/bot-hand.sh"

REPO="$(this_repo)"

# 一度に読む上限。**readonly にしない** — 検査が小さい値で回すため
ISSUE_LIMIT=${ISSUE_LIMIT:-200}
PR_LIMIT=${PR_LIMIT:-100}
# 着手印が残っている Issue を「落ちて見える」と呼ぶまでの静けさ (分)
DROPPED_MINUTES=${DROPPED_MINUTES:-120}

readonly TRIAGED='verify: triaged'
readonly IN_PROGRESS='status: in progress'
# エージェントの起票の唯一の手掛かり (scripts/agent-signature.sh の検知キー)。以前は
# Claude Code の綴りに固定で、Codex など他のエージェントの起票を人の起票と読んでいた (#3149)
readonly AGENT_MARK='🤖 Assisted by'
# 無印のまま出してよい型。Design / Feature は判断が要る側なので出さない (ADR-0036 決定 6)
readonly STOCK_TYPES='Bug Task Docs'

# 名前の並びに含まれるか (前後の区切りごと照合する — 部分一致を拾わないため)
has_label() { # $1=ラベルの並び (改行区切り) $2=探すラベル
  grep -Fxq "$2" <<<"$1"
}

# 手元の worktree / 枝の名前に番号が現れるか。
#
# 前後が数字でないことまで見る — 927 が 1927 に当たると、落ちた着手が「生きている」へ
# 倒れて誰にも拾われなくなる
seen_locally() { # $1=番号
  case " $WORKTREE_NAMES " in *[!0-9]"$1"[!0-9]*) return 0 ;; esac
  return 1
}

# --- 材料 -------------------------------------------------------------------

issues_json=$(gh issue list --repo "$REPO" --state open --limit "$ISSUE_LIMIT" \
  --json number,title,body,labels,issueType,updatedAt) || {
  echo "open な Issue の一覧を読めなかった" >&2
  exit 2
}

prs_json=$(gh pr list --repo "$REPO" --state open --limit "$PR_LIMIT" \
  --json number,title,closingIssuesReferences) || {
  echo "open な PR の一覧を読めなかった" >&2
  exit 2
}

# 上限に張り付いたら黙らない。**読み落としは「着手できる」へ倒れる** — 紐づく PR を
# 読み落とした Issue は ready に見えるので、二重に着手される
warn_if_capped() { # $1=読んだ件数 $2=上限 $3=何の一覧か
  [ "$1" -lt "$2" ] ||
    echo "$3 が上限 $2 件に張り付いた — 読み落としているかもしれない" >&2
}
warn_if_capped "$(jq 'length' <<<"$issues_json")" "$ISSUE_LIMIT" Issue
warn_if_capped "$(jq 'length' <<<"$prs_json")" "$PR_LIMIT" PR

# 番号 → その Issue を閉じようとしている open PR。**GitHub 自身の答えを読む** (review-gate と同じ)
claims=$(jq -r --arg repo "$REPO" '
  .[] | . as $pr
      | .closingIssuesReferences[]?
      | select((.repository.owner.login + "/" + .repository.name) == $repo)
      | "\(.number) \($pr.number)"' <<<"$prs_json")

# 静けさの境目。**BSD の date を先に試す** (このスクリプトが走るのは手元の Mac である)。
# 1 度だけ作って ISO8601 の字面で比べる — 同じ書式・同じ UTC なら辞書順が時刻順になる
QUIET_BEFORE=$(date -u -v-"${DROPPED_MINUTES}"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
  date -u -d "${DROPPED_MINUTES} minutes ago" +%Y-%m-%dT%H:%M:%SZ)

# 手元の worktree のパスと枝の名前。読めなければ空 (見えないものは「見えない」と扱う)
WORKTREE_NAMES=$(git worktree list --porcelain 2>/dev/null |
  sed -n 's#^worktree ##p; s#^branch refs/heads/##p' | tr '\n' ' ' || true)

# --- 走査 -------------------------------------------------------------------

ready='' stock='' dropped='' busy='' decide='' ready_count=0 decide_count=0
# 自分に証拠の無い着手印。「<番号> <タイトル>」の並びで、家族を読んでから分ける
candidates=''
# updatedAt だけが新しい着手印。「<番号> <updatedAt> <タイトル>」の並びで、人の手を読んでから分ける
recent=''
# ready の候補 (「<番号> <型> <タイトル>」)・stock の候補 (同じ形)・未トリアージの Design
# (「<番号> <タイトル>」)。どれも親を読んでから分ける (#1661・#3036)
ready_rows='' stock_rows='' designs=''

while IFS= read -r row; do
  n=$(jq -r '.number' <<<"$row")
  labels=$(jq -r '.labels[].name' <<<"$row")
  type=$(jq -r '.issueType.name // ""' <<<"$row")
  title=$(jq -r '.title' <<<"$row")
  updated=$(jq -r '.updatedAt // ""' <<<"$row")

  pr=$(awk -v n="$n" '$1 == n { print $2; exit }' <<<"$claims")

  if has_label "$labels" "$IN_PROGRESS" || [ -n "$pr" ]; then
    if [ -n "$pr" ]; then
      busy+="$n busy PR #$pr が出ている ($title)"$'\n'
    elif seen_locally "$n"; then
      busy+="$n busy 手元に worktree か枝がある ($title)"$'\n'
    elif [[ $updated > $QUIET_BEFORE ]]; then
      # 新しいのが人の手か bot の追記かは、まとめて読んでから分ける (#2660)
      recent+="$n $updated $title"$'\n'
    else
      candidates+="$n $title"$'\n'
    fi
    continue
  fi

  if has_label "$labels" "$TRIAGED"; then
    # ready と決めるのは親を読んでから (下の「根と判断」)。ここでは溜めるだけ。
    # 「<番号> <型> <タイトル>」で、型の無いものは - (型の名前は 1 語 — ADR-0004 の 5 型)
    ready_rows+="$n ${type:--} $title"$'\n'
    continue
  fi

  # 未トリアージの Design は、子の Bug を数えてから decide に出すかを決める (#1661)
  [ "$type" != Design ] || designs+="$n $title"$'\n'

  # 未トリアージ。**B-1 の対象になるのは、完了条件を書ける見込みがあるものだけ**である
  case " $STOCK_TYPES " in *" $type "*) ;; *) continue ;; esac
  case $(jq -r '.body // ""' <<<"$row") in
    *"$AGENT_MARK"*) stock_rows+="$n $type $title"$'\n' ;;
  esac
done < <(jq -c '.[]' <<<"$issues_json")

# --- 人の手 (#2660) ----------------------------------------------------------

# 窓の中に人の手があるかを 1 回で読む。「<番号> human|quiet」を 1 行 1 件で出す。
#
# quiet は「窓の中が bot の手 (scripts/bot-hand.sh) だけで、少なくとも 1 つある」ときに限る。
# 作者の分からない項目 (退会した人・断片の並びに無い種類)・本文の編集・窓に収まらない項目・
# 空の窓は human に倒す (冒頭の「bot の追記は数えない」— bot と分かるものだけを除く)。
#
# 「窓に収まらない」は filteredCount と引けた件数で見る。**filteredCount は since を反映した
# 窓の中の件数で、totalCount は反映しない** — 2026-10-16 に #2251 で確かめた (since なし:
# total 29・filtered 29。since つき last: 100: total 29・filtered 5・引けた 5。since つき
# last: 2: total 29・filtered 5・引けた 2)。totalCount で比べると、窓より前に履歴のある
# Issue はほぼ常に human に倒れて黙って効かなくなる
read_hands() { # $1=番号 (空白区切り)
  local owner=${REPO%%/*} name=${REPO#*/} q='' n
  for n in $1; do
    q+="i$n: issue(number: $n) { lastEditedAt timelineItems(since: \"$QUIET_BEFORE\", last: 100) {"
    q+=" filteredCount nodes { __typename ...hand } } } "
  done
  gh api graphql \
    -f query="{ repository(owner: \"$owner\", name: \"$name\") { $q } } $BOT_HAND_TIMELINE_FRAGMENT" \
    --jq "$BOT_HAND_JQ"'
      .data.repository | to_entries[]
      | .value.timelineItems as $t
      | (any($t.nodes[]?; bot_hand | not)
         or ($t.nodes | length) == 0
         or ($t.filteredCount // 0) > ($t.nodes | length)
         or (.value.lastEditedAt // "") > "'"$QUIET_BEFORE"'") as $hand
      | "\(.key | ltrimstr("i")) \(if $hand then "human" else "quiet" end)"'
}

# 読んだ答え。「<番号> human|quiet|unread」を 1 行 1 件で溜める
hands=''

# 答えを読み足す。読めなかった番号は unread として溜め、そう名乗る — その番号は従来どおり
# updatedAt で測る
read_hands_into() { # $1=番号 (空白区切り)
  local more n
  [ -n "${1// /}" ] || return 0
  if more=$(read_hands "$1"); then
    hands+="$more"$'\n'
  else
    for n in $1; do hands+="$n unread"$'\n'; done
    echo "人の手か bot の追記かを読めなかった — 静けさは updatedAt のまま測った" >&2
  fi
}

# 読んだ答え 1 つ。問い合わせに載せなかった番号は空
hand_of() { # $1=番号
  awk -v n="$1" '$1 == n { print $2; exit }' <<<"$hands"
}

# 新しさを「動いている」と読むときの注記。読めなかったときだけ名乗る
hand_note() { # $1=番号
  [ "$(hand_of "$1")" != unread ] || printf '・作者を読めなかった'
}

if [ -n "$recent" ]; then
  read_hands_into "$(awk '{ print $1 }' <<<"$recent" | tr '\n' ' ')"
  while read -r n updated title; do
    [ -n "$n" ] || continue
    # **quiet と答えたときだけ**静かとみなす。分からなければ従来どおり動いている
    if [ "$(hand_of "$n")" = quiet ]; then
      candidates+="$n $title"$'\n'
    else
      busy+="$n busy まだ動いている ($updated$(hand_note "$n") ・$title)"$'\n'
    fi
  done <<<"$recent"
fi

# --- 家族 (#1391) -------------------------------------------------------------

# 候補ごとの家族を 1 回で読む。「<候補> <家族> <state> <updatedAt>」を 1 行 1 組で出す。
# 候補自身は除く (親の子に自分も居る)
read_families() { # $1=候補の番号 (空白区切り)
  local owner=${REPO%%/*} name=${REPO#*/} fields='number state updatedAt' q='' n
  for n in $1; do
    q+="i$n: issue(number: $n) { parent { $fields subIssues(first: 100) { nodes { $fields } } }"
    q+=" subIssues(first: 100) { nodes { $fields } } } "
  done
  gh api graphql -f query="{ repository(owner: \"$owner\", name: \"$name\") { $q } }" \
    --jq '.data.repository | to_entries[]
      | (.key | ltrimstr("i") | tonumber) as $c
      | [.value.parent // empty, (.value.parent.subIssues.nodes // [])[], (.value.subIssues.nodes // [])[]]
      | map(select(.number != $c)) | unique_by(.number)[]
      | "\($c) \(.number) \(.state) \(.updatedAt)"'
}

# 家族 1 人の**直接の**証拠。無ければ何も出さず 1 を返す。
#
# 見るのは自分の判定と同じ 3 つだけで、家族を通じて busy になったかは見ない — それが
# 「家族を渡るのは 1 段だけ」である (冒頭の「家族も見る」)
member_evidence() { # $1=番号 $2=state $3=updatedAt
  local pr
  if [ "$2" = OPEN ]; then
    pr=$(awk -v n="$1" '$1 == n { print $2; exit }' <<<"$claims")
    if [ -n "$pr" ]; then
      echo "家族 #$1 に PR #$pr が出ている"
      return 0
    fi
    if seen_locally "$1"; then
      echo "家族 #$1 の worktree か枝が手元にある"
      return 0
    fi
    # 新しくても bot の追記だけなら数えない (#2660)
    if [[ $3 > $QUIET_BEFORE ]] && [ "$(hand_of "$1")" != quiet ]; then
      echo "家族 #$1 がまだ動いている ($3$(hand_note "$1"))"
      return 0
    fi
  elif [[ $3 > $QUIET_BEFORE ]]; then
    echo "家族 #$1 が閉じたばかり ($3)"
    return 0
  fi
  return 1
}

if [ -n "$candidates" ]; then
  family_note=''
  families=$(read_families "$(awk '{ print $1 }' <<<"$candidates" | tr '\n' ' ')") ||
    { families='' family_note='・家族を読めなかった'; }

  # 新しさだけが証拠になりうる open な家族の手を読む (#2660)。PR か手元の worktree / 枝が
  # あればそれで足り、既に読んだ番号は読み直さない
  read_hands_into "$(while read -r _ m state updated; do
    [ "$state" = OPEN ] && [[ $updated > $QUIET_BEFORE ]] || continue
    [ -z "$(awk -v n="$m" '$1 == n { print $2; exit }' <<<"$claims")" ] || continue
    ! seen_locally "$m" || continue
    [ -z "$(hand_of "$m")" ] || continue
    echo "$m"
  done <<<"$families" | awk '!seen[$1]++ { printf "%s ", $1 }')"

  while read -r n title; do
    [ -n "$n" ] || continue
    why=''
    while read -r c m state updated; do
      [ "$c" = "$n" ] || continue
      why=$(member_evidence "$m" "$state" "$updated") && break
      why=''
    done <<<"$families"
    if [ -n "$why" ]; then
      busy+="$n busy $why ($title)"$'\n'
    else
      dropped+="$n dropped 着手印が残ったまま $DROPPED_MINUTES 分以上動いていない ($title)$family_note"$'\n'
    fi
  done <<<"$candidates"
fi

# --- 根と判断 (#1661) ---------------------------------------------------------

# 番号ごとの親と、番号自身の子・開き直しの手を 1 回で読む (#3036)。1 行 1 件で 2 種類を出す:
#
#   <番号> <親> <親の state> <親の型> <親の印>        親があるときだけ。型の無い親は - にする
#                                                      (空にすると欄がずれる)。親の印は
#                                                      verify: triaged があれば triaged、無ければ -
#                                                      で、Design の根を見分けるのに使う (#2228)
#   self <番号> <手> <最小の open の子> <open の子の数> <子の総数>
#                                                      番号ごとに必ず 1 行。手は、最後の開き直しが
#                                                      bot の手 (scripts/bot-hand.sh) なら bot、
#                                                      それ以外 (人・無い・分からない) は -。
#                                                      子が無い・最初のページに open の子が載らない
#                                                      ときの子の番号は -
#
# self の行は「閉じた後に parent-guard が開き直した親」を見分けるのに使う。親の行と同じ応答に
# 載せるので、呼び出しは増えない。**子は open のものだけ数え、手は最後の 1 回だけ読む** —
# 閉じた・開いたの回数や時刻の近さでは推測しない。
#
# **open の子の数は subIssuesSummary (total - completed) から取る** — subIssues は 100 件までの
# 1 ページで、open の子が 101 件目以降にあると読み落として ready へ倒れる (parent-guard.sh が
# #793 で --paginate にしたのと同じ穴)。completed は、閉じた子を理由 (completed / not planned) に
# 関わらず数える (2026-10-21 に #2371 で確かめた: total 2・completed 1 で、閉じた 1 件は NOT_PLANNED)。
# 番号を名乗るのは最初のページに載った open の子だけで、載らなければ件数で名乗る
read_parents() { # $1=番号 (空白区切り)
  local owner=${REPO%%/*} name=${REPO#*/} q='' n
  for n in $1; do
    q+="i$n: issue(number: $n) { parent { number state issueType { name }"
    q+=" labels(first: 100) { nodes { name } } }"
    q+=" subIssuesSummary { total completed } subIssues(first: 100) { nodes { number state } }"
    q+=" timelineItems(itemTypes: [REOPENED_EVENT], last: 1) { nodes { ... on ReopenedEvent {"
    q+=" actor { __typename login } } } } } "
  done
  gh api graphql -f query="{ repository(owner: \"$owner\", name: \"$name\") { $q } }" \
    --jq "$BOT_HAND_JQ"'.data.repository | to_entries[]
      | ((.value.parent // empty) as $p
         | (if any($p.labels.nodes[]?; .name == "'"$TRIAGED"'") then "triaged" else "-" end) as $mark
         | "\(.key | ltrimstr("i")) \($p.number) \($p.state) \($p.issueType.name // "-") \($mark)"),
        ([.value.subIssues.nodes[]? | select(.state == "OPEN") | .number] | sort) as $page
        | ((.value.subIssuesSummary.total // 0) - (.value.subIssuesSummary.completed // 0)) as $open
        | (.value.timelineItems.nodes // [] | last) as $reopened
        | (if ($reopened != null) and ($reopened | bot_hand) then "bot" else "-" end) as $by
        | (.value.subIssuesSummary.total // 0) as $total
        | "self \(.key | ltrimstr("i")) \($by) \($page[0] // "-") \($open) \($total)"'
}

# 引くのは open な Bug・ready の候補・stock の候補と、(open な Bug があるときの) 未トリアージの
# Design。**どれも無ければ引かない** — 平常時の呼び出しを増やさないため (家族と同じ作法)。
# Design は decide に出るのが open な Bug の子を持つものだけなので、Bug が無ければ引かない。
# stock と Design を引くのは、開き直された親の判定 (下の `waiting`) をそこへも届けるため (#3036)
open_bugs=$(jq -r '.[] | select(.issueType.name == "Bug") | .number' <<<"$issues_json")
design_rows=''
[ -z "$open_bugs" ] || design_rows="$designs"
asked=$(printf '%s\n%s\n%s\n%s\n' "$(awk '{ print $1 }' <<<"$ready_rows")" "$open_bugs" \
  "$(awk '{ print $1 }' <<<"$stock_rows")" "$(awk '{ print $1 }' <<<"$design_rows")" |
  awk 'NF && !seen[$1]++ { printf "%s ", $1 }')
parents=''
if [ -n "$asked" ]; then
  # 読めなかったら、ready の候補は従来どおり ready に出し、decide は出さない。**そう名乗る** —
  # 黙ると「根で直す子が ready に出ている」ことに誰も気付かない
  parents=$(read_parents "$asked") || {
    parents=''
    echo "親を読めなかった — 根で直す子も、閉じた後に開き直された親も ready と stock に出し、decide は出していない" >&2
  }
fi

# **自分の仕事を持たない親** — 本体の仕事を終えて閉じた後に parent-guard (bot) が開き直した、子を
# 持つ親 (#3036)。残りの仕事は子が持ち (子がすべて閉じていれば、閉じるだけ)、ready にも stock にも
# decide にも出さず、
# 子を根に数えることもしない (子は自分で ready / busy に判定される)。**この 1 つの判定を 4 つの
# 口が使う** — ready の候補・根・stock・decide。口ごとに別の式を持つと、1 つだけ直して他が
# 残る (反証が 3 つの口で実走して見つけた)。「<番号> <最小の open の子> <open の子の数>」の並び
waiting=$(awk '$1 == "self" && $3 == "bot" && $6 > 0 { print $2, $4, $5 }' <<<"$parents")
is_waiting() { # $1=番号
  awk -v n="$1" '$1 == n { found = 1 } END { exit !found }' <<<"$waiting"
}

# (a) 根が開いていれば、子は根を直す側で閉じる (ADR-0040 決定 2)。子を ready に出すと
# 症状の 1 か所だけが直され、同じ根の兄弟が残る — #1659 が数えた「深いが狭い」直しの形である。
# 根は 2 つの形をとる (冒頭の「根と判断」):
#
#   親が open な Bug                子の型は問わない
#   親が open で印の付いた Design   子が Bug のときだけ (#2228)。無印のうちは子を止めない —
#                                   人の判断を待つ間も症状の直しは止めず、根本は (b) が人に見せる
#                                   (決定 3)。Bug でない子は根の症状ではない
while read -r n type title; do
  [ -n "$n" ] || continue
  root=$(awk -v n="$n" -v type="$type" -v waiting="$(awk '{ printf " %s ", $1 }' <<<"$waiting")" '
    $1 == n && $3 == "OPEN" && index(waiting, " " $2 " ") == 0 &&
      ($4 == "Bug" || ($4 == "Design" && $5 == "triaged" && type == "Bug")) {
      print $2; exit
    }' <<<"$parents")
  if [ -n "$root" ]; then
    busy+="$n busy 根 #$root で直す ($title)"$'\n'
  elif is_waiting "$n"; then
    read -r _ child open <<<"$(awk -v n="$n" '$1 == n { print; exit }' <<<"$waiting")"
    if [ "$open" -eq 0 ]; then
      # 最後の子が閉じた。親を閉じる仕組みは無いので、ready に戻すと済んだ仕事が出る
      who="子がすべて閉じた — 閉じてよい"
    elif [ "$child" != "-" ]; then
      who="子 #$child を待つ"
    else
      who="open の子 $open 件を待つ"
    fi
    busy+="$n busy $who (閉じた後に parent-guard が開き直した ・$title)"$'\n'
  else
    ready+="$n ready [$type] $title"$'\n'
    ready_count=$((ready_count + 1))
  fi
done <<<"$ready_rows"

# stock は、開き直された親を除いて出す (#3036)。エージェントが起票した無印の親が閉じられて
# parent-guard に開き直されても、残りは子が持つ
while read -r n type title; do
  [ -n "$n" ] || continue
  is_waiting "$n" || stock+="$n stock [$type] エージェントの起票が無印のまま ($title)"$'\n'
done <<<"$stock_rows"

# (b) open な Bug の子を持つ未トリアージの Design は、**根本が人の判断を待っている**ことを
# 表す (ADR-0040 決定 3 — 約束を決める・変えるときだけ人を待つ)。子の多い順に並べるのは、
# 1 つ決めれば閉じる Bug の多いものから人の目に入れるためである。終了コードには数えない —
# 打てる仕事ではなく、人が決める仕事なので。
#
# 数えるのは open な Bug の子だけ (ready の候補の親も同じ応答に混ざっている)。親の state は
# 見ない — 突き合わせる Design は open な一覧から集めたものなので、閉じた親には当たらない
children=$(awk -v bugs=" $(tr '\n' ' ' <<<"$open_bugs") " '
  index(bugs, " " $1 " ") { c[$2]++ }
  END { for (p in c) print p, c[p] }' <<<"$parents")
while read -r count n title; do
  [ -n "$n" ] || continue
  decide+="$n decide open な Bug の子 $count 件が根本の判断を待っている ($title)"$'\n'
  decide_count=$((decide_count + 1))
done < <(
  while read -r n title; do
    [ -n "$n" ] || continue
    # 開き直された Design は、人が決めて閉じた後である。判断を待っていない (#3036)
    ! is_waiting "$n" || continue
    count=$(awk -v n="$n" '$1 == n { print $2; exit }' <<<"$children")
    [ -z "$count" ] || printf '%s %s %s\n' "$count" "$n" "$title"
  done <<<"$designs" | sort -k1,1nr -k2,2n
)

printf '%s' "$ready$stock$dropped$busy$decide"

# 件数は標準エラーへ出す。**標準出力は 1 行 1 件のまま**にしておく (読む側が機械なので)
printf 'ready %s / stock %s / dropped %s / busy %s / decide %s\n' \
  "$ready_count" \
  "$(grep -c . <<<"$stock" || true)" \
  "$(grep -c . <<<"$dropped" || true)" \
  "$(grep -c . <<<"$busy" || true)" \
  "$decide_count" >&2

[ "$ready_count" -gt 0 ]
