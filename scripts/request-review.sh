#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 承認待ちの PR に、メンテナへレビュー要求を投げる (#498)。
#
# 承認が要る PR を止める仕組みは「経路 2 本 × (要求 / ブロック)」の 4 象限でできて
# いる。このスクリプトが埋めるのは**左下の 1 マスだけ**である。
#
#   |                      | 要求 (人に届く)              | ブロック (マージが止まる)   |
#   | パス由来 (3 パス)     | CODEOWNERS + required_reviewers | ルールセット required_reviewers |
#   | ラベル由来 (verify: human) | **ここ**                  | human-approval commit status |
#
# 右列は GitHub 側の機構が担っていて、ここでは 1 つも触らない。ラベル由来だけ要求が
# 無かったため、Reviewers 欄が空のまま human-approval だけが pending で止まり、
# メンテナは PR を開くまで気付けなかった (#494 / #495 が実際に滞留した)。
# verify: human は「機械では判定できないから人が見る」ためのラベルなので、その人に
# 声が掛からないなら、ラベルは待ち状態を作るだけで機能していない。
#
# **要求を飛ばすことと、ブロックすることは別である。** ここが失敗しても終了コードは
# 0 のままにする — 通知の失敗をマージのブロックに変えない。fork からの PR では
# GITHUB_TOKEN が read-only になるので、赤くしない性質がそのまま要る。
#
# 呼ぶのは ci.yml の approval-signal ジョブ (review-gate が pending を出したときだけ)。
# 使い方: request-review.sh <PR番号> (要 GH_TOKEN / gh 認証)
set -euo pipefail

PR="${1:?PR 番号が必要}"
REPO="${GITHUB_REPOSITORY:-mokume-metal/mokume}"
# 承認者集合の読める代理 (ADR-0007 決定 3)。テストは別のファイルを指す。
# **CODEOWNERS を読むのはこの 1 か所だけ**にしてある — パス由来の要求はルールセットの
# required_reviewers が team へ既に飛ばしており、CODEOWNERS を要求経路から降ろす掃除が
# 別 Issue で走りうるため、そのとき差し替える箇所を 1 つに閉じ込めておく
CODEOWNERS_FILE="${CODEOWNERS_FILE:-$(cd "$(dirname "$0")/.." && pwd)/.github/CODEOWNERS}"

# CODEOWNERS に名前が挙がっている owner をすべて出す (review-gate.sh の codeowners_all
# と同じ読み方)。パス照合はしない — verify: human が求めるのは「メンテナの承認」で、
# 触ったパスに紐づかないためである
codeowners_all() {
  [ -f "$CODEOWNERS_FILE" ] || return 0
  sed 's/#.*//' "$CODEOWNERS_FILE" |
    awk 'NF > 1 { for (i = 2; i <= NF; i++) { sub(/^@/, "", $i); print $i } }' | sort -u
}

# チーム表記 (@org/team) は落とす。要求 API はユーザーとチームで配列が別で、
# このリポジトリの CODEOWNERS にはチームが 1 つも無い。増えたらここで気付けるよう、
# 黙って混ぜずに落とす
owners=$(codeowners_all | grep -v '/' || true)
if [ -z "$owners" ]; then
  echo "request-review: CODEOWNERS に owner が居ないので何もしない"
  exit 0
fi

if ! pr_json=$(gh pr view "$PR" -R "$REPO" --json author,reviewRequests,latestReviews 2>&1); then
  echo "request-review: PR の情報を引けなかったので要求を投げない" >&2
  echo "$pr_json" >&2
  exit 0
fi

author=$(jq -r '.author.login // ""' <<<"$pr_json")
requested=$(jq -r '[.reviewRequests[]?.login // empty] | join("\n")' <<<"$pr_json")
# DISMISSED は「見た」に数えない。ルールセットが dismiss_stale_reviews_on_push: true
# なので、承認後に push すると承認が外れる。パス由来は GitHub が自動で再要求するが、
# ラベル由来はここで投げ直さないと「承認が外れたのに誰も知らない」に戻る
reviewed=$(jq -r '
  [ .latestReviews[]? | select(.state != "DISMISSED") | .author.login ] | join("\n")
' <<<"$pr_json")

targets=()
for owner in $owners; do
  if [ "$owner" = "$author" ]; then
    # GitHub は自己要求に 422 を返す。メンテナ名義の PR がこれに当たる
    # (その PR は ADR-0007 の不変条件のほうで review-gate が差し戻す)
    echo "request-review: $owner は author 本人なので投げない"
  elif grep -qxF "$owner" <<<"$requested"; then
    # パス由来と重なった PR では GitHub が既に飛ばしている。3 通目を作らない
    echo "request-review: $owner には既に要求が飛んでいる"
  elif grep -qxF "$owner" <<<"$reviewed"; then
    echo "request-review: $owner は既にこの PR を見ている"
  else
    targets+=("$owner")
  fi
done

if [ ${#targets[@]} -eq 0 ]; then
  echo "request-review: 投げる相手が居ない"
  exit 0
fi

args=()
for owner in "${targets[@]}"; do args+=(-f "reviewers[]=$owner"); done

if gh api -X POST "repos/$REPO/pulls/$PR/requested_reviewers" "${args[@]}" --silent; then
  echo "request-review: レビューを要求した — ${targets[*]}"
else
  # ここで止めない (冒頭のとおり、通知の失敗はブロックに変えない)
  echo "request-review: レビュー要求に失敗した — ${targets[*]}" >&2
  echo "次にすること: 承認は human-approval が引き続き待っているので、メンテナへ直接声を掛ける" >&2
fi
