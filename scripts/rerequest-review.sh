#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 承認が push で落ちた PR へ、レビュー依頼を出し直す (#1177)。
#
#   rerequest-review.sh <PR 番号>
#
# 承認済みの PR へ push すると、ルールセットの dismiss_stale_reviews_on_push が承認を
# 落とす。**そのとき、メンテナの画面上部にレビュー依頼の表示は出ない。** 3 つが重なる:
#
#   1. 作成時に required_reviewers が飛ばした依頼は、1 回目の Approve で満たされて消える
#   2. push で承認が落ちても、依頼は出し直されない
#   3. 落とした出来事の名義は push をした本人 (メンテナ) なので、GitHub は本人に通知しない
#
# 気付く経路は当番 (stall-watch) の赤だけで、その当番は実測で数時間おきにしか回らない
# (#1197)。塞ぎたい停止は #1019 が 69 分・#1020 が 17 分・#1174 が 7.5 分なので、当番より
# 速い機構が要る — **承認が落ちたその瞬間に依頼を出し直す**のがこのスクリプトである。
# 呼ぶのは .github/workflows/review-request.yml (pull_request_review の dismissed)。
#
# ## 打つのは bot 名義である
#
# 出すのは workflow の GITHUB_TOKEN なので、依頼の actor は github-actions[bot] になる。
# **App 名義 (mokume-agent) にはしない** — そのためには App の秘密鍵を Actions secrets へ
# 入れることになり、同一リポジトリの PR 枝に置いたワークフローからも token を発行できる
# 状態になる (ADR-0003 は鍵を単一用途に保ち、在処もリポジトリに書かないことで守っている)。
# 上の 3 が言う穴は「名義が本人だから通知されない」ことなので、本人でなければ塞がる。
#
# ## 宛先は PR 自身から採る
#
# チーム名を直書きしない。ルールセット (.github/rulesets/main-protection.json) は reviewer を
# **id でしか持たず**、id から slug を引く口 (repos/*/teams) を GITHUB_TOKEN が読める保証も
# 無い。代わりに **その PR の timeline に残る過去の依頼先 (Team)** を宛先にする — 出し直しと
# はそもそも「一度飛んだ依頼をもう一度出す」ことなので、正典は PR 自身にある。
#
# 副産物として、重要パスに触れず作成時の依頼が飛ばなかった PR には何も打たない。承認が
# 要らない PR に依頼を出しても merge は進むので、通知だけが増える (#642)。
#
# ## 出し直さないもの (#1177 の完了条件 3)
#
#   承認が落ちた出来事が無い     一度も承認されていない PR。押し直す承認が無い
#   いま承認が付いている         落ちていない (別の誰かが既に押し直した場合を含む)
#   依頼が既に残っている         同じ PR に 2 通目を出さない
#
# 判定に外れたときは理由を 1 行出して 0 で終える。**非 0 は API が落ちたときだけ** —
# 「打つ必要が無かった」を赤くすると、走るたびに赤が出て意味を失う。
#
# 検査は scripts/tests/rerequest_review_test.py。
set -euo pipefail

# リポジトリの owner/repo。**literal は scripts/repo-slug.sh の 1 箇所だけ** (#818)
# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"

REPO="$(this_repo)"

usage() {
  echo "使い方: rerequest-review.sh <PR 番号>" >&2
  exit 64
}

[ $# -eq 1 ] || usage
case "${1:-}" in '' | *[!0-9]*) usage ;; esac
PR=$1

# 1 回の問い合わせで 3 つを読む。**gh pr view では足りない** — 落とした出来事も、過去に
# 誰へ依頼が飛んだかも、あちらの JSON 欄には無い (stall-watch.sh の dismissed_at と同じ理由)
# shellcheck disable=SC2016
pr=$(gh api graphql -f owner="${REPO%%/*}" -f name="${REPO##*/}" -F number="$PR" \
  -f query='query($owner:String!,$name:String!,$number:Int!){
    repository(owner:$owner,name:$name){pullRequest(number:$number){
      latestReviews(first:50){nodes{state}}
      reviewRequests(first:50){nodes{requestedReviewer{
        __typename ... on Team{slug} ... on User{login}}}}
      timelineItems(itemTypes:[REVIEW_REQUESTED_EVENT,REVIEW_DISMISSED_EVENT],last:100){
        nodes{__typename
          ... on ReviewRequestedEvent{requestedReviewer{__typename ... on Team{slug}}}
          ... on ReviewDismissedEvent{createdAt}}}}}}' \
  --jq '.data.repository.pullRequest') || {
  echo "#$PR: PR を読めなかった" >&2
  exit 1
}

[ -n "$pr" ] && [ "$pr" != "null" ] || {
  echo "#$PR: PR を読めなかった" >&2
  exit 1
}

dismissed=$(jq -r '[.timelineItems.nodes[]? | select(.__typename == "ReviewDismissedEvent")]
  | length > 0' <<<"$pr")
approved=$(jq -r '[.latestReviews.nodes[]? | select(.state == "APPROVED")] | length > 0' <<<"$pr")
# いま残っている依頼と、過去に飛んだ依頼。どちらも Team だけを見る (User 宛ての依頼は
# 人が手で出したものなので、機械が数え直さない)
pending=$(jq -r '[.reviewRequests.nodes[]?.requestedReviewer
  | select(.__typename == "Team") | .slug] | unique | join(" ")' <<<"$pr")
wanted=$(jq -r '[.timelineItems.nodes[]? | select(.__typename == "ReviewRequestedEvent")
  | .requestedReviewer | select(.__typename == "Team") | .slug] | unique | join(" ")' <<<"$pr")

if [ "$dismissed" != true ]; then
  echo "#$PR: 承認が落ちた出来事が無い — 出し直さない"
  exit 0
fi

if [ "$approved" = true ]; then
  echo "#$PR: いま承認が付いている — 出し直さない"
  exit 0
fi

if [ -z "$wanted" ]; then
  echo "#$PR: チームへの依頼が飛んだことが無い (承認が要らない PR) — 出し直さない"
  exit 0
fi

# 残っている依頼を差し引く。**依頼が既に残っている相手に 2 通目を出さない** (完了条件 3)
targets=""
for team in $wanted; do
  case " $pending " in *" $team "*) continue ;; esac
  targets="${targets:+$targets }$team"
done

if [ -z "$targets" ]; then
  echo "#$PR: 依頼が既に残っている ($pending) — 出し直さない"
  exit 0
fi

args=()
for team in $targets; do
  args+=(-f "team_reviewers[]=$team")
done

if gh api --method POST "repos/$REPO/pulls/$PR/requested_reviewers" "${args[@]}" >/dev/null; then
  echo "#$PR: $targets へレビュー依頼を出し直した"
else
  echo "#$PR: レビュー依頼を出し直せなかった ($targets)" >&2
  exit 1
fi
