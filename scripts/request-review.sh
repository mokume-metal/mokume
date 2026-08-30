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
# **宛先は user である。team ではない。** 一度 team へ揃えたが (#536)、GITHUB_TOKEN は
# org スコープを持たないので team_reviewers は 422 で落ちる。ラベル由来だけの PR で
# 初めて実際に投げられて分かった (#576 — #575 の run 33304452745 で実測)。
#
#   gh: Validation Failed (HTTP 422)
#   request-review: レビュー要求に失敗した — @maintainers
#
# ルールセットの required_reviewers が team へ飛ばせるのは **GitHub 自身が投げている**
# からで、API 経由とは別の話である。team のメンバーを引いて宛先を作る道も read:org が
# 要るので通らない。CI へ App の鍵を置けば通るが、Actions secret 0 件を保つ方針
# (ADR-0003 決定 1) に対して通知 1 通は釣り合わない。
#
# **宛先が割れることは受け入れる。** パス由来が飛んでいる PR では下の teams_requested で
# 抜けるので、user 宛が飛ぶのはラベル由来だけの PR に限られる — #530 が畳んだ「同じ人へ
# 2 通」は戻らない。
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
# 宛先の user。承認を課している集合の正典は .github/rulesets/main-protection.json の
# required_reviewers (team maintainers) だが、そこから user を引くには read:org が要る。
# 綴りはここ 1 か所で持つ — team のメンバーが変わったらここも直す
MAINTAINERS_USER="${MAINTAINERS_USER:-shinyaoguri}"

if ! pr_json=$(gh pr view "$PR" -R "$REPO" --json author,reviewRequests,latestReviews 2>&1); then
  echo "request-review: PR の情報を引けなかったので要求を投げない" >&2
  echo "$pr_json" >&2
  exit 0
fi

# 保留中のチーム要求。**login を持たない要素がチーム**である — 綴り (name / slug /
# __typename) に頼らないので、GitHub が形を変えても読み違えない。このリポジトリの
# チームは maintainers 1 つなので、1 件でもあればパス由来が既に飛んでいる
teams_requested=$(jq -r '[ .reviewRequests[]? | select(has("login") | not) ] | length' <<<"$pr_json")
# 同じ user への保留中の要求。**この経路が既に投げた分**である。CI は Approve や
# ラベルの付け外しでも走り直すので、見ないと同じ人へ 2 通目を作る
user_requested=$(jq -r --arg u "$MAINTAINERS_USER" '
  [ .reviewRequests[]? | select(.login? == $u) ] | length
' <<<"$pr_json")
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
if [ "$user_requested" -gt 0 ]; then
  echo "request-review: 既に @$MAINTAINERS_USER へ要求が飛んでいる"
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
     -f "reviewers[]=$MAINTAINERS_USER" --silent; then
  echo "request-review: レビューを要求した — @$MAINTAINERS_USER"
else
  # ここで止めない (冒頭のとおり、通知の失敗はブロックに変えない)
  echo "request-review: レビュー要求に失敗した — @$MAINTAINERS_USER" >&2
  echo "次にすること: 承認は human-approval が引き続き待っているので、メンテナへ直接声を掛ける" >&2
fi
