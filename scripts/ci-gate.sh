#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# ci.yml の必須チェック ci-gate の判定。呼ぶのは ci.yml の ci-gate だけである。
#
#   RESULTS=<toJSON(needs)> EVENT_NAME=<github.event_name> HEAD_SHA=<PR の head の SHA> \
#     GITHUB_REPOSITORY=<owner/repo> GH_TOKEN=<token> bash scripts/ci-gate.sh
#
# ## needs の failure と cancelled は赤、skipped は通す
#
# PR では走らない段 (merge_group だけの段など) が skipped で現れても止まらない。
#
# ## PR の run で skipped の検査は、同じ head SHA の最新の結論を読む (#2690)
#
# 本文・タイトルだけの edited の run では、ci-check・ci-static が skipped になる (ci.yml の
# ci-check の if:)。そのまま通すと緑の ci-gate が付く。必須の判定は同じ名前の check のうち
# 作成順で最新のものを読む (#2577 の実測) ので、同じ SHA の別の run でコードの検査が走っている
# 途中でも、赤でも、必須が満たされていた。ci-gate を skipped にしても穴は塞がらない
# (skipped の必須チェックは通過と扱われる)。
#
# そこで skipped の検査ごとに、同じ head SHA の check run から skipped を除いて最新のもの
# (id が最大 = 作成順で最新) を読み、completed かつ success のときだけ通す。走っている途中・
# 赤・見つからない・API の失敗は、理由を出して赤にする (閉じる側に倒す)。
#
# **待たない。** 走っている途中の検査の run は、その検査が終わってから自分の ci-gate を作り、
# そちらが最新になってこの赤を上書きする。代償は、その間 ci-gate の赤が見えること。
#
# 読む名前は needs から取り、コードの検査の名前の写しを持たない。check_name で引くので、
# ci-check・ci-static という job 名をほかのワークフローに置かない
# (scripts/tests/ci_workflow_test.py が見る)。

set -euo pipefail

: "${RESULTS:?toJSON(needs) を渡す}"

echo "$RESULTS"
# パイプにしない (#2609)。pipefail の下では、grep -q が一致して先に抜けたときに
# 書き終えていない printf が SIGPIPE で落ち、if が偽 (= 落ちていない) と読む
if grep -Eq '"result": *"(failure|cancelled)"' <<<"$RESULTS"; then
  echo "必須ジョブが落ちている" >&2
  exit 1
fi

[ "${EVENT_NAME:-}" = pull_request ] || exit 0

skipped=$(jq -r 'to_entries[] | select(.value.result == "skipped") | .key' <<<"$RESULTS")
[ -n "$skipped" ] || exit 0

: "${HEAD_SHA:?PR の head の SHA を渡す}"
: "${GITHUB_REPOSITORY:?owner/repo を渡す}"

errfile=$(mktemp)
trap 'rm -f "$errfile"' EXIT

failed=0
while read -r name; do
  # 1 行 = "<id> <status> <conclusion> <url>"。ページごとに出るので、並べ直してから最大の id を取る
  if ! rows=$(gh api --paginate \
    "repos/$GITHUB_REPOSITORY/commits/$HEAD_SHA/check-runs?check_name=$name&filter=all&per_page=100" \
    --jq '.check_runs[] | select(.app.slug == "github-actions" and .conclusion != "skipped")
          | "\(.id) \(.status) \(.conclusion // "-") \(.html_url)"' 2>"$errfile"); then
    echo "$name: 同じ SHA の check run を読めなかった: $(tr '\n' ' ' <"$errfile")" >&2
    failed=1
    continue
  fi
  latest=$(sort -n <<<"$rows" | tail -n 1)
  if [ -z "$latest" ]; then
    echo "$name: この run では skipped で、同じ SHA に走った $name が無い" >&2
    failed=1
    continue
  fi
  read -r _id status conclusion url <<<"$latest"
  if [ "$status" != completed ]; then
    echo "$name: この run では skipped で、同じ SHA の $name が走っている途中 ($url)。" \
      "その run の ci-gate が終わったときに付け直す" >&2
    failed=1
  elif [ "$conclusion" != success ]; then
    echo "$name: この run では skipped で、同じ SHA の最新の $name が $conclusion ($url)" >&2
    failed=1
  else
    echo "ok: $name はこの run では skipped で、同じ SHA の最新が success ($url)"
  fi
done <<<"$skipped"

exit "$failed"
