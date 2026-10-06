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
# auto-merge も掛けない。読み取りが増えるのは 2 つの場合だけである — 自分に証拠の無い
# 着手印があるときは、その
# 家族を読む `gh api graphql` が 1 回加わる (下の「落ちて見えるか」)。open な Bug か ready の
# 候補があるときは、その親を読む `gh api graphql` が 1 回加わる (下の「根と判断」)。scripts/stall-watch.sh と
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
#   ready    verify: triaged が付き、着手中でもなく、紐づく open PR も無く、親が open な Bug でない
#   stock    **B-1 の対象** — エージェントが起票したのに無印で、型が Bug / Task / Docs
#   dropped  status: in progress なのに、open PR も手元の worktree / 枝も無く、静かで久しい。
#            家族 (親・兄弟・子) にも同じ証拠が無い
#   busy     着手中 (紐づく open PR がある・手元に worktree / 枝がある・まだ動いている・
#            家族のどれかがそうである)。または ready の候補のうち、親が open な Bug のもの
#            (根を直す側で閉じる)
#   decide   **人が決める行** — 無印の Design で、open な Bug の子を持つもの。子の多い順
#
# ## 根と判断 (#1661)
#
# バグの直しは「深いが狭い」— 原因の特定と再現はよくできているのに、兄弟の口を探さず、
# 同じ根のバグが 1 件ずつ直されていた (#1659)。ADR-0040 は同じ根の群を sub-issue で束ね、
# 根を直す PR が子をまとめて閉じるとした (決定 2)。判定はその形に 2 つで合わせる:
#
#   親が open な Bug の子   ready に出さず busy へ回す。子を 1 件ずつ拾うと、根を直さずに
#                           症状だけを閉じる直しが続く。根のほうが ready に出ていれば、そちらを取る
#   Bug の子を持つ Design   根本の直し方が人の判断を待っている (決定 3 — 約束を決める・変える
#                           ときだけ人を待つ)。人の目に入らないと、子の Bug が症状のまま直される
#
# 親は GraphQL 1 回で、open な Bug と ready の候補の分だけ読む。**読めなかったら ready は
# 従来どおり出し、decide は出さず、そう名乗る。** decide は終了コードに数えない — 打てる
# 仕事ではなく、人が決める仕事である。
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
#   B-1 の対象か    本文末尾の Assisted by [Claude Code] の署名。**これが唯一の手掛かり**
#                   である — Issue の author は identity 分離の対象外なので (ADR-0003 が
#                   分けたのは PR の作成だけ)、エージェントの起票も人の名義で立つ
#   落ちて見えるか  紐づく open PR が無く、git worktree list のパスと枝の名前に番号が
#                   現れず、**そのうえ Issue が静かになって久しい**こと
#
# 3 つ目が要るのは、**枝の名前が番号を持たないことのほうが多い**からである — AGENTS.md が
# 定める枝の形は `<type>/<短い説明>` で、番号はどこにも入らない。worktree の照合だけに頼ると
# 「いま着手した Issue」がそのまま dropped に出る (実際にこのスクリプト自身の #1028 で出た)。
# 静かさは Issue の updatedAt で測る — 着手すればラベルが動きプランが投稿されるので、
# 生きている着手は必ず新しい。
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

REPO="$(this_repo)"

# 一度に読む上限。**readonly にしない** — 検査が小さい値で回すため
ISSUE_LIMIT=${ISSUE_LIMIT:-200}
PR_LIMIT=${PR_LIMIT:-100}
# 着手印が残っている Issue を「落ちて見える」と呼ぶまでの静けさ (分)
DROPPED_MINUTES=${DROPPED_MINUTES:-120}

readonly TRIAGED='verify: triaged'
readonly IN_PROGRESS='status: in progress'
# エージェントの起票の唯一の手掛かり (scripts/comment.sh が付ける署名の綴り)
readonly AGENT_MARK='Assisted by [Claude Code]'
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
# ready の候補 (「<番号> <タイトル>」) と、未トリアージの Design
# (「<番号> <タイトル>」)。どちらも親を読んでから分ける (#1661)
ready_rows='' designs=''

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
      busy+="$n busy まだ動いている ($updated ・$title)"$'\n'
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
    *"$AGENT_MARK"*) stock+="$n stock [$type] エージェントの起票が無印のまま ($title)"$'\n' ;;
  esac
done < <(jq -c '.[]' <<<"$issues_json")

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
    if [[ $3 > $QUIET_BEFORE ]]; then
      echo "家族 #$1 がまだ動いている ($3)"
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

# 番号ごとの親を 1 回で読む。「<番号> <親> <親の state> <親の型>」を 1 行 1 件で出す
# (親の無いものは出さない。型の無い親は - にする — 空にすると欄がずれる)
read_parents() { # $1=番号 (空白区切り)
  local owner=${REPO%%/*} name=${REPO#*/} q='' n
  for n in $1; do
    q+="i$n: issue(number: $n) { parent { number state issueType { name } } } "
  done
  gh api graphql -f query="{ repository(owner: \"$owner\", name: \"$name\") { $q } }" \
    --jq '.data.repository | to_entries[]
      | (.value.parent // empty) as $p
      | "\(.key | ltrimstr("i")) \($p.number) \($p.state) \($p.issueType.name // "-")"'
}

# 引くのは open な Bug と ready の候補だけ。**どちらも無ければ引かない** — 平常時の呼び出しを
# 増やさないため (家族と同じ作法)
open_bugs=$(jq -r '.[] | select(.issueType.name == "Bug") | .number' <<<"$issues_json")
asked=$(printf '%s\n%s\n' "$(awk '{ print $1 }' <<<"$ready_rows")" "$open_bugs" |
  awk 'NF && !seen[$1]++ { printf "%s ", $1 }')
parents=''
if [ -n "$asked" ]; then
  # 読めなかったら、ready の候補は従来どおり ready に出し、decide は出さない。**そう名乗る** —
  # 黙ると「根で直す子が ready に出ている」ことに誰も気付かない
  parents=$(read_parents "$asked") || {
    parents=''
    echo "親を読めなかった — 根で直す子も ready に出し、decide は出していない" >&2
  }
fi

# (a) 親が open な Bug なら、子は根を直す側で閉じる (ADR-0040 決定 2)。子を ready に出すと
# 症状の 1 か所だけが直され、同じ根の兄弟が残る — #1659 が数えた「深いが狭い」直しの形である
while read -r n type title; do
  [ -n "$n" ] || continue
  root=$(awk -v n="$n" '$1 == n && $3 == "OPEN" && $4 == "Bug" { print $2; exit }' <<<"$parents")
  if [ -n "$root" ]; then
    busy+="$n busy 根 #$root で直す ($title)"$'\n'
  else
    ready+="$n ready [$type] $title"$'\n'
    ready_count=$((ready_count + 1))
  fi
done <<<"$ready_rows"

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
