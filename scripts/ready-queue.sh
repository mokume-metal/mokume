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
# auto-merge も掛けない。読み取りが増えるのは 2 つの場合だけである — 弾かれた描画 PR が
# あるときは、その順番を読む `gh api` が加わる。自分に証拠の無い着手印があるときは、その
# 家族を読む `gh api graphql` が 1 回加わる (下の「落ちて見えるか」)。scripts/stall-watch.sh と
# 同じ性質で、**手元でいつ打っても安全である**。打つ側 (stall-act.sh に当たるもの) はこのリポジトリには来ない — 打つのは
# 外に居るディスパッチャの仕事で、こちらが実行まで持つと「様子を見るために打ったら着手が
# 始まった」が起きる。
#
# ## 出力
#
#   <番号> <分類> <描画の見込み> <説明>
#
# 番号は Issue の番号である。**catch-up の行だけは PR の番号**で、説明も PR #N から始める。
#
# 分類は 5 つで、この順に出す:
#
#   catch-up **手元で打てる catch-up** — local-render が failure の描画 PR で、描画の行列の先頭
#   ready    verify: triaged が付き、着手中でもなく、紐づく open PR も無い
#   stock    **B-1 の対象** — エージェントが起票したのに無印で、型が Bug / Task / Docs
#   dropped  status: in progress なのに、open PR も手元の worktree / 枝も無く、静かで久しい。
#            家族 (親・兄弟・子) にも同じ証拠が無い
#   busy     着手中 (紐づく open PR がある・手元に worktree / 枝がある・まだ動いている・
#            家族のどれかがそうである)
#
# ## catch-up を先頭に出す (#1045)
#
# 弾かれた描画 PR は当番 (scripts/stall-watch.sh) も ejected として見つけるが、当番は
# Actions の上で走るので GPU を持たず、`make catch-up` を打てない。名乗りは run の赤として
# しか現れず、**誰かが Actions を覗くまで止まったままになる** (#1022・#1026 は 2 時間ずつ
# 放置された)。打つのに要るのは人の判断ではなく、手元で動いている任意のセッションである
# (代打ちの手順は scripts/catch-up.sh の冒頭・#967)。
#
# このスクリプトは手元で走るので、まさに打てる側に居る。だから当番の名乗りをここへ移し、
# **着手の前に**見せる — 並びの順がそのまま「新しい Issue より先に、止まっている PR を
# 流す」を意味する。
#
# 判定は 2 つの積で、どちらも当番と同じ実体を読む:
#
#   弾かれたか    scripts/render-context.sh の render_failed。**写しを持たない** — 割れると
#                 「当番が名乗ったのに手元に現れない」が黙って起きる (ADR-0008 決定 6)
#   先頭か        scripts/drawing-queue.sh の ahead_drawing_pr。先に別の描画 PR が居る
#                 ものは**出さない** (打っても無駄になる — scripts/stall-watch.sh の読み分け表)。
#                 読めなかったときは出す (drawing-queue.sh の「判定できないときは通す」)
#
# 順番の判定は API を何度も呼ぶので、**弾かれた PR があるときだけ**引く。報告の状態は
# 紐づく PR を読む `gh pr list` の同じ 1 回に載せるので、平常時の呼び出しは増えない。
#
# **Draft は見ない。** 当番と同じく、作業中の PR を Draft にしておくのが opt-out である
# (scripts/catch-up.sh も Draft には打たない)。
#
# 打つのはここではない — 出力を読んだセッションである (上の「ここは何も打たない」)。
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
#   描画に触るか    Issue のタイトルと本文に現れるパス片を drawing-paths.sh の
#                   drawing_files coverage に通す。**見込みでしかない** — Issue は触る
#                   ファイルを宣言しないので、確定はプランが出てからである
#                   (ADR-0036 決定 4)。だから印には必ず ? を付ける
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
#   0  打てる仕事がある (catch-up か ready が 1 件以上)
#   1  どちらも 0 件 (在庫切れ — 呼ぶ側は B-1 へ回る)
#   2  判定できなかった (Issue か PR の一覧を読めなかった) — 在庫切れと読まない
#
# **読めなかったときに 1 を返さない** (#1235)。呼ぶ側は終了コードで分岐するので、1 だと判定が
# 壊れていても「在庫が尽きた」と読んで B-1 へ回る — #1045 が塞いだ形が、読み取りの失敗から
# 黙って戻る。gh の版は検査しない。古い gh で欄が足りなければ gh 自身がそう名乗る
# (例: issueType は gh 2.94.0 から)。
#
# **catch-up も 0 に数える** (#1045)。ready だけで決めると、打てる catch-up があるのに 1 が
# 返って呼ぶ側が在庫作りへ回り、弾かれた描画 PR が止まったままになる。ready と catch-up の
# 区別は標準出力の分類が持つ。
#
# 検査は scripts/tests/ready_queue_test.py。
set -euo pipefail

# リポジトリの owner/repo。**literal は scripts/repo-slug.sh の 1 箇所だけ** (#818)
# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"
# 「描画に触れているか」の照合。用途は必ず渡す (既定を持たせない — drawing-paths.sh)
# shellcheck source=scripts/drawing-paths.sh
. "$(dirname "${BASH_SOURCE[0]}")/drawing-paths.sh"
# 変更ファイルの取り方 (#793)。順番の判定 (drawing-queue.sh) が使う
# shellcheck source=scripts/pr-files.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-files.sh"
# 描画 PR の順番の判定。**自分で drawing-paths.sh / pr-files.sh を読み込まない**ので読み手が並べる
# shellcheck source=scripts/drawing-queue.sh
. "$(dirname "${BASH_SOURCE[0]}")/drawing-queue.sh"
# 報告の綴りと、それが failure かの判定。当番 (stall-watch.sh) と同じ実体を読む (#1045)
# shellcheck source=scripts/render-context.sh
. "$(dirname "${BASH_SOURCE[0]}")/render-context.sh"

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

# 標準入力の文字列から、パスらしい字面をすべて並べる。
#
# **/ の区切りごとに後ろも並べる** — 本文のパスは
# github.com/mokume-metal/mokume/blob/main/Sources/… のような URL の一部で現れることが
# あり、頭から照合すると Sources/ で始まる前置きに当たらない
path_tokens() {
  grep -oE '[A-Za-z][A-Za-z0-9_.-]*(/[A-Za-z0-9_.-]+)+' |
    awk '{ s = $0; while (1) { print s; i = index(s, "/"); if (i == 0) break; s = substr(s, i + 1); if (s == "") break } }' |
    sort -u
}

# 名前の並びに含まれるか (前後の区切りごと照合する — 部分一致を拾わないため)
has_label() { # $1=ラベルの並び (改行区切り) $2=探すラベル
  printf '%s\n' "$1" | grep -Fxq "$2"
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
  --json number,title,isDraft,closingIssuesReferences,statusCheckRollup) || {
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

# 手元で打てる catch-up。理由と判定の形は冒頭の「catch-up を先頭に出す」
catch_up='' catch_up_count=0

while IFS= read -r row; do
  render_failed <<<"$row" || continue
  pr_number=$(jq -r '.number' <<<"$row")
  pr_title=$(jq -r '.title // ""' <<<"$row")
  # 標準入力を閉じる — 走査の入力 (PR の並び) を中の呼び出しに食わせないため
  ahead=$(ahead_drawing_pr "$REPO" "$pr_number" </dev/null 2>/dev/null || echo '?')
  case "$ahead" in
    '' | draft) note="描画の先頭で $RENDER_CONTEXT が failure — make catch-up PR=$pr_number で queue へ戻せる" ;;
    '?') note="$RENDER_CONTEXT が failure で、先に居る描画 PR を読めなかった — make catch-up PR=$pr_number を試す" ;;
    *) continue ;; # 先に #$ahead が居る。打っても無駄になる
  esac
  catch_up+="$pr_number catch-up - PR #$pr_number: $note ($pr_title)"$'\n'
  catch_up_count=$((catch_up_count + 1))
done < <(jq -c '.[] | select(.isDraft | not)' <<<"$prs_json")

ready='' stock='' dropped='' busy='' ready_count=0
# 自分に証拠の無い着手印。「<番号> <タイトル>」の並びで、家族を読んでから分ける
candidates=''

while IFS= read -r row; do
  n=$(jq -r '.number' <<<"$row")
  labels=$(jq -r '.labels[].name' <<<"$row")
  type=$(jq -r '.issueType.name // ""' <<<"$row")
  title=$(jq -r '.title' <<<"$row")
  updated=$(jq -r '.updatedAt // ""' <<<"$row")

  pr=$(awk -v n="$n" '$1 == n { print $2; exit }' <<<"$claims")

  if has_label "$labels" "$IN_PROGRESS" || [ -n "$pr" ]; then
    if [ -n "$pr" ]; then
      busy+="$n busy - PR #$pr が出ている ($title)"$'\n'
    elif seen_locally "$n"; then
      busy+="$n busy - 手元に worktree か枝がある ($title)"$'\n'
    elif [[ $updated > $QUIET_BEFORE ]]; then
      busy+="$n busy - まだ動いている ($updated ・$title)"$'\n'
    else
      candidates+="$n $title"$'\n'
    fi
    continue
  fi

  if has_label "$labels" "$TRIAGED"; then
    # **早く打ち切る書き方は取らない** — touches_drawing は入力を最後まで読む形で
    # 書かれており、grep -q を後ろに置くと SIGPIPE で「見つかった」が偽に化ける
    # (理由は drawing-paths.sh の drawing_files のコメント)
    guess='plain?'
    if printf '%s\n%s\n' "$title" "$(jq -r '.body // ""' <<<"$row")" |
      path_tokens | touches_drawing coverage; then
      guess='drawing?'
    fi
    ready+="$n ready $guess $title"$'\n'
    ready_count=$((ready_count + 1))
    continue
  fi

  # 未トリアージ。**B-1 の対象になるのは、完了条件を書ける見込みがあるものだけ**である
  case " $STOCK_TYPES " in *" $type "*) ;; *) continue ;; esac
  case $(jq -r '.body // ""' <<<"$row") in
    *"$AGENT_MARK"*) stock+="$n stock - エージェントの起票が無印のまま (${type}・${title})"$'\n' ;;
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
      busy+="$n busy - $why ($title)"$'\n'
    else
      dropped+="$n dropped - 着手印が残ったまま $DROPPED_MINUTES 分以上動いていない ($title)$family_note"$'\n'
    fi
  done <<<"$candidates"
fi

printf '%s' "$catch_up$ready$stock$dropped$busy"

# 件数は標準エラーへ出す。**標準出力は 1 行 1 件のまま**にしておく (読む側が機械なので)
printf 'catch-up %s / ready %s / stock %s / dropped %s / busy %s\n' \
  "$catch_up_count" \
  "$ready_count" \
  "$(grep -c . <<<"$stock" || true)" \
  "$(grep -c . <<<"$dropped" || true)" \
  "$(grep -c . <<<"$busy" || true)" >&2

[ $((catch_up_count + ready_count)) -gt 0 ]
