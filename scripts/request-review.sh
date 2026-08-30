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
#   | パス由来 (3 パス)     | ルールセット required_reviewers | ルールセット required_reviewers |
#   | ラベル由来 (verify: human) | **ここ**                  | human-approval commit status |
#
# 宛先は左列で揃えてある — どちらも team maintainers へ投げる。当初は CODEOWNERS を
# 読んで user へ投げていたが、CODEOWNERS 自体を #530 で畳んだ (パス由来の要求が
# 二重に飛ぶだけの写しになっていた)。team ならメンバーを引く権限が要らず、パス由来と
# 重なった PR で宛先が割れることもない。
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
# 宛先の team。正典は .github/rulesets/main-protection.json の required_reviewers の
# reviewer だが、あちらは id しか持たず slug を引くには read:org が要るので、綴りは
# ここ 1 か所で持つ。ルールセットの reviewer を変えるときはここも直す
MAINTAINERS_TEAM="${MAINTAINERS_TEAM:-maintainers}"

if ! pr_json=$(gh pr view "$PR" -R "$REPO" --json author,reviewRequests,latestReviews 2>&1); then
  echo "request-review: PR の情報を引けなかったので要求を投げない" >&2
  echo "$pr_json" >&2
  exit 0
fi

# 保留中のチーム要求。**login を持たない要素がチーム**である — 綴り (name / slug /
# __typename) に頼らないので、GitHub が形を変えても読み違えない。このリポジトリの
# チームは maintainers 1 つなので、1 件でもあればパス由来が既に飛んでいる
teams_requested=$(jq -r '[ .reviewRequests[]? | select(has("login") | not) ] | length' <<<"$pr_json")
# DISMISSED は「見た」に数えない。ルールセットが dismiss_stale_reviews_on_push: true
# なので、承認後に push すると承認が外れる。パス由来は GitHub が自動で再要求するが、
# ラベル由来はここで投げ直さないと「承認が外れたのに誰も知らない」に戻る
reviewed=$(jq -r '
  [ .latestReviews[]? | select(.state != "DISMISSED") ] | length
' <<<"$pr_json")

if [ "$teams_requested" -gt 0 ]; then
  # パス由来と重なった PR では GitHub が既に飛ばしている。2 通目を作らない (#530)
  echo "request-review: 既にチームへ要求が飛んでいる"
  exit 0
fi
if [ "$reviewed" -gt 0 ]; then
  echo "request-review: 既にこの PR を見ている人が居る"
  exit 0
fi

# author 本人の除外は要らない。GitHub が 422 を返すのは user 宛の自己要求だけで、
# そもそもメンテナ名義の PR は review-gate が ADR-0007 の不変条件で差し戻すため、
# 承認待ち (pending) にならず、ここは呼ばれない
if gh api -X POST "repos/$REPO/pulls/$PR/requested_reviewers" \
     -f "team_reviewers[]=$MAINTAINERS_TEAM" --silent; then
  echo "request-review: レビューを要求した — @$MAINTAINERS_TEAM"
else
  # ここで止めない (冒頭のとおり、通知の失敗はブロックに変えない)
  echo "request-review: レビュー要求に失敗した — @$MAINTAINERS_TEAM" >&2
  echo "次にすること: 承認は human-approval が引き続き待っているので、メンテナへ直接声を掛ける" >&2
fi
