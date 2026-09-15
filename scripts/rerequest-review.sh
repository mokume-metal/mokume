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
# ## 宛先は「落ちた承認の主」である (Team ではない)
#
# **GITHUB_TOKEN は Team 宛てにレビュー依頼を出せない。** #1232 の探り (run 34939239789)
# の実測:
#
#   GraphQL の timelineItems       requestedReviewer が null — Team のノードが見えない
#   REST の timeline               requested_team: maintainers は読める
#   POST team_reviewers[]          422 Could not resolve to a node with the global id …
#   POST reviewers[]=<User>        通る (run 34939697737)
#
# 名義を App (mokume-agent) に替えても同じ壁に当たる — App の権限は org を含まないため
# (ADR-0003 決定 1)。そこで宛先を **落とされた review の author (User)** にする。要るのは
# 「落ちた承認をもう一度もらうこと」で、押し直せるのはまさにその人である (#1174 で
# メンテナが手でやったのも、自分自身へのレビュー依頼だった)。
#
# ## 出し直すと何が見えるか
#
# PR のページ上部に黄色い帯が出る — 「<名義> requested your review on this pull request.」と
# 「Add your review」。#1177 が言う「画面上部の表示」はこれで、**自分宛ての依頼が pending で
# 残っていて、出した名義が自分でない**ときにだけ出る。承認が落ちただけでは出ない。
#
# ## 打つのは bot 名義である
#
# 出すのは workflow の GITHUB_TOKEN なので、依頼の actor は github-actions[bot] になる。
# 上の 3 が言う穴は「名義が本人だから通知されない」ことなので、本人でなければ塞がる。
#
# ## 出し直さないもの (#1177 の完了条件 3)
#
#   承認が落ちた出来事が無い     一度も承認されていない PR。押し直す承認が無い
#   いま承認が付いている         落ちていない (別の誰かが既に押し直した場合を含む)
#   承認が要らない PR            重要パスに触れていない — 依頼を出しても merge は進む
#   依頼が既に残っている         同じ PR に 2 通目を出さない
#
# 判定に外れたときは理由を 1 行出して 0 で終える。**非 0 は API が落ちたときだけ** —
# 「打つ必要が無かった」を赤くすると、走るたびに赤が出て意味を失う (#642)。
#
# 検査は scripts/tests/rerequest_review_test.py。
set -euo pipefail

# リポジトリの owner/repo。**literal は scripts/repo-slug.sh の 1 箇所だけ** (#818)
# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"
# 変更ファイルの取り方。gh pr view --json files には上限がある (#793)
# shellcheck source=scripts/pr-files.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-files.sh"
# 「承認が要るパスに触れているか」— 正本はルールセットで、写しは持たない
# shellcheck source=scripts/protected-paths.sh
. "$(dirname "${BASH_SOURCE[0]}")/protected-paths.sh"

REPO="$(this_repo)"

usage() {
  echo "使い方: rerequest-review.sh <PR 番号>" >&2
  exit 64
}

[ $# -eq 1 ] || usage
case "${1:-}" in '' | *[!0-9]*) usage ;; esac
PR=$1

# 1 回の問い合わせで 3 つを読む。**gh pr view では足りない** — 落とされた review の author は
# あちらの JSON 欄に無い (stall-watch.sh が dismissed_at を GraphQL で引くのと同じ理由)
# shellcheck disable=SC2016
pr=$(gh api graphql -f owner="${REPO%%/*}" -f name="${REPO##*/}" -F number="$PR" \
  -f query='query($owner:String!,$name:String!,$number:Int!){
    repository(owner:$owner,name:$name){pullRequest(number:$number){
      latestReviews(first:50){nodes{state author{login}}}
      reviewRequests(first:50){nodes{requestedReviewer{__typename ... on User{login}}}}
      timelineItems(itemTypes:[REVIEW_DISMISSED_EVENT],last:20){
        nodes{... on ReviewDismissedEvent{createdAt review{author{login}}}}}}}}' \
  --jq '.data.repository.pullRequest') || {
  echo "#$PR: PR を読めなかった" >&2
  exit 1
}

[ -n "$pr" ] && [ "$pr" != "null" ] || {
  echo "#$PR: PR を読めなかった" >&2
  exit 1
}

# 落とされた review の主。ここが空なら「一度も承認されていない」か「落ちていない」
dismissed_users=$(jq -r '[.timelineItems.nodes[]? | .review.author.login // empty]
  | unique | join(" ")' <<<"$pr")
approved=$(jq -r '[.latestReviews.nodes[]? | select(.state == "APPROVED")] | length > 0' <<<"$pr")
# いま残っている依頼 (User だけ見る — Team は GITHUB_TOKEN から見えない・冒頭の実測)
pending=$(jq -r '[.reviewRequests.nodes[]?.requestedReviewer
  | select(.__typename == "User") | .login] | unique | join(" ")' <<<"$pr")

if [ -z "$dismissed_users" ]; then
  echo "#$PR: 承認が落ちた出来事が無い — 出し直さない"
  exit 0
fi

if [ "$approved" = true ]; then
  echo "#$PR: いま承認が付いている — 出し直さない"
  exit 0
fi

# **読めなかったら出し直す側に倒す。** 落ちた承認が放置される害のほうが、要らない依頼が
# 1 通増える害より大きい (前者は merge が止まったままになる)
if files=$(pr_files "$REPO" "$PR"); then
  if ! printf '%s\n' "$files" | touches_protected_path; then
    echo "#$PR: 承認が要らない PR (重要パスに触れていない) — 出し直さない"
    exit 0
  fi
else
  echo "#$PR: 変更ファイルを読めなかった — 承認が要る PR として扱う"
fi

# 残っている依頼を差し引く。**依頼が既に残っている相手に 2 通目を出さない** (完了条件 3)
targets=""
for who in $dismissed_users; do
  case " $pending " in *" $who "*) continue ;; esac
  targets="${targets:+$targets }$who"
done

if [ -z "$targets" ]; then
  echo "#$PR: 依頼が既に残っている ($pending) — 出し直さない"
  exit 0
fi

args=()
for who in $targets; do
  args+=(-f "reviewers[]=$who")
done

if gh api --method POST "repos/$REPO/pulls/$PR/requested_reviewers" "${args[@]}" >/dev/null; then
  echo "#$PR: $targets へレビュー依頼を出し直した"
else
  echo "#$PR: レビュー依頼を出し直せなかった ($targets)" >&2
  exit 1
fi
