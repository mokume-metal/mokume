#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# ci.yml の必須チェック ci-gate の判定。呼ぶのは ci.yml の ci-gate だけである。
#
#   RESULTS=<toJSON(needs)> EVENT_NAME=<github.event_name> HEAD_SHA=<PR の head の SHA> \
#     GITHUB_REPOSITORY=<owner/repo> GITHUB_RUN_ID=<この run> GH_TOKEN=<token> bash scripts/ci-gate.sh
#
# GITHUB_REPOSITORY と GITHUB_RUN_ID は Actions が渡す (ci.yml には書かない)。
#
# ## needs の failure と cancelled は赤、skipped は通す
#
# PR では走らない段 (merge_group だけの段など) が skipped で現れても止まらない。
#
# ## PR の run で skipped の検査は、同じ head SHA の検査が終わるのを待って、その結論を返す (#2690)
#
# 本文・タイトルだけの edited の run では、ci-check・ci-static が skipped になる (ci.yml の
# ci-check の if:)。そのまま通すと緑の ci-gate が付き、同じ SHA の別の run でコードの検査が
# 走っている途中でも必須が満たされていた。ci-gate を skipped にしても穴は塞がらない (skipped の
# 必須チェックは通過と扱われる)。
#
# ## 必須の判定が同じ SHA のどの check run を読むか (正本はここ)
#
# 観測のどれとも矛盾しない規則は次のとおり (#2577 の棚卸し。GitHub の文書では確かめていない
# 推定で、#2577 で確定させる)。ci.yml・stall-act.sh・pr-gate.yml はここを指す:
#
#   ワークフローごとに、作成順で最新の run (check suite) に載った、その名前の check run を読む。
#   古い suite の赤・cancelled は読まない。最新の suite にその名前がまだ無いときは未確認 (#2692)
#
# この規則で、次の観測が説明できる:
#
#   - 後から作られた古い suite の緑の ci-gate は、新しい suite の赤い ci-gate を上書きしない
#     (#2696: 11 時間 BLOCKED、赤を打ち直して CLEAN)。古い suite の検査を打ち直して緑にしても、
#     その suite の ci-gate が走り直すだけで、新しい suite の赤は残る (#2717)
#   - 新しい suite の緑の ci-gate は、走っている途中の古い suite を待たずに必須を満たした (#2688)
#
# そのため、走っている途中に赤を返すと、後から検査の run の緑の ci-gate が作られても、打ち直され
# るまで PR を塞ぐ。**だから待つ。** 待っている間、この ci-gate は in_progress で、必須は満たされ
# ない。待った末の赤 (検査の赤・期限切れ・見つからない・読めない) も、後で検査が打ち直されて
# 緑になれば残った赤になる。**当番 (stall-watch.sh の reread) が、同じ SHA の ci-check・ci-static
# の最新がどちらも success になったところでこの ci-gate を打ち直す** (#2717)。打ち直された
# ci-gate は同じ SHA を読み直して緑を返す。検査の最新が赤のままなら打ち直さない。
#
# ## 待ち方
#
# skipped の検査ごとに、同じ head SHA の check run から skipped とこの run 自身のものを除いて
# 最新のもの (id が最大 = 作成順で最新) を読み、completed になるまで POLL_WAIT 秒おきに読み直す。
# 結論が success なら通し、ほかの結論は赤。WAIT_LIMIT 秒を越えても終わらない・見つからない・
# API が読めないままなら、最後の理由を出して赤にする (閉じる側に倒す)。期限は ci.yml の
# timeout-minutes より内側に置く。EVENT_NAME が無い・知らない event も赤にする — 開く側に
# 倒れると、渡し忘れひとつで素通しに戻る。
#
# **この run 自身の check run は除く。** skipped になる job は ci-gate より数秒遅れて作られる
# ことがあり (#2690 の反証で実測)、作られた瞬間の状態が completed でなければ、自分自身の終わりを
# 待つことになる。
#
# 代償:
#   - 本文を編集するたびに、ubuntu の runner を最長で検査の所要時間ぶん (macOS の空き待ちを
#     含む) 占める。期限を越えた赤は、当番が打ち直すまで (当番の間隔ぶん) PR を塞ぐ
#   - 同じ head SHA の check run は PR を区別しない。同じブランチから出た別の PR (閉じて作り
#     直したものを含む) の検査の結論を読みうる
#
# 塞いでいない兄弟: base の変更・reopen では、その run の ci-gate が検査の終わるまで作られず、
# 前の run の緑の ci-gate だけで必須が満たされる。ci-gate がここで判定する前の穴で、別に扱う
# (#2692)。
#
# 読む名前は needs から取り、コードの検査の名前の写しを持たない。check_name で引くので、
# ci-check・ci-static という job 名をほかのワークフローに置かない
# (scripts/tests/ci_workflow_test.py が見る)。

set -euo pipefail

: "${RESULTS:?toJSON(needs) を渡す}"
: "${EVENT_NAME:?github.event_name を渡す}"

echo "$RESULTS"
# パイプにしない (#2609)。pipefail の下では、grep -q が一致して先に抜けたときに
# 書き終えていない printf が SIGPIPE で落ち、if が偽 (= 落ちていない) と読む
if grep -Eq '"result": *"(failure|cancelled)"' <<<"$RESULTS"; then
  echo "必須ジョブが落ちている" >&2
  exit 1
fi

case "$EVENT_NAME" in
  merge_group) exit 0 ;;
  pull_request) ;;
  *) echo "知らない event: $EVENT_NAME (ci.yml の on: と合わせる)" >&2; exit 1 ;;
esac

skipped=$(jq -r 'to_entries[] | select(.value.result == "skipped") | .key' <<<"$RESULTS")
[ -n "$skipped" ] || exit 0

: "${HEAD_SHA:?PR の head の SHA を渡す}"
: "${GITHUB_REPOSITORY:?owner/repo を渡す}"
: "${GITHUB_RUN_ID:?この run の id を渡す}"
POLL_WAIT=${POLL_WAIT:-30}
WAIT_LIMIT=${WAIT_LIMIT:-5400}

errfile=$(mktemp)
trap 'rm -f "$errfile"' EXIT

# 同じ SHA の、skipped とこの run 自身を除いた最新の 1 行 ("<id> <status> <conclusion> <url>")。
# 無ければ空。gh が落ちたら 1 を返す
latest_run() { # $1=名前
  local rows
  rows=$(gh api --paginate \
    "repos/$GITHUB_REPOSITORY/commits/$HEAD_SHA/check-runs?check_name=$1&filter=all&per_page=100" \
    --jq '.check_runs[] | select(.app.slug == "github-actions" and .conclusion != "skipped")
          | select(.details_url | contains("/actions/runs/'"$GITHUB_RUN_ID"'/") | not)
          | "\(.id) \(.status) \(.conclusion // "-") \(.html_url)"' 2>"$errfile" </dev/null) || return 1
  # ページごとに出るので、id の数の順に並べ直してから最大を取る
  sort -n <<<"$rows" | tail -n 1
}

failed=0
end=$((SECONDS + WAIT_LIMIT))
while read -r name; do
  while :; do
    if ! latest=$(latest_run "$name"); then
      reason="同じ SHA の check run を読めなかった: $(tr '\n' ' ' <"$errfile")"
    elif [ -z "$latest" ]; then
      reason="同じ SHA に走った $name が無い"
    else
      read -r _id status conclusion url <<<"$latest"
      if [ "$status" = completed ]; then
        break
      fi
      reason="同じ SHA の $name が走っている途中 ($url)"
    fi
    if [ "$SECONDS" -ge "$end" ]; then
      echo "$name: この run では skipped で、${WAIT_LIMIT} 秒待っても結論が出ない — $reason" >&2
      failed=1
      continue 2
    fi
    echo "$name: 待つ — $reason"
    sleep "$POLL_WAIT"
  done
  if [ "$conclusion" != success ]; then
    echo "$name: この run では skipped で、同じ SHA の最新の $name が $conclusion ($url)" >&2
    failed=1
  else
    echo "ok: $name はこの run では skipped で、同じ SHA の最新が success ($url)"
  fi
done <<<"$skipped"

exit "$failed"
