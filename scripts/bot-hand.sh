# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 「bot の手か」の判定 (#2660)。Issue / PR の活動を読む道具が共有する。
#
# ## 前提 (ここで 1 度だけ宣言する)
#
# **このリポジトリの Issue / PR の活動には bot の手が混じる。** 定期の検査・前検査の赤は、
# 同じ題の Issue が open なら `github-actions` がそこへコメントで追記する
# (scripts/report-check-failure.sh・#2658)。追記は Issue の updatedAt を動かし、コメントの
# 並びの末尾を占める。
#
# **活動を読む側は、bot の手を人の活動に数えない。** 読み手は 3 つある:
#
#   scripts/ready-queue.sh   着手印の静けさ (bot の追記だけで「まだ動いている」にしない)
#   scripts/plan-record.sh   二重着手の跡 (bot の本文に混じった目印をプランと読まない)
#   scripts/comment.sh       宛先の近況 (人の最新のコメントを名乗り、bot の追記に埋もれさせない)
#
# 以前は読み手ごとに専用の除外を書いていたので、穴が兄弟として 1 つずつ見つかった
# (#2660 の反証)。判定をここに寄せ、新しい読み手もここを使う。
#
# ## 判定
#
# **作者 / actor の型が Bot のものだけを bot の手と呼ぶ。** GraphQL は `__typename`、REST は
# `user.type` で、どちらの形でも同じ定義が答える。login の綴りは見ない — 同じ bot が GraphQL
# では `github-actions`、REST では `github-actions[bot]` と経路で綴りを変える。
#
# **作者の分からないもの (作者を引かなかった・退会した人) は bot の手と呼ばない。** 読み手は
# それを人の手の側 — 従来どおりの判定 — に倒す。bot と分かるものだけを除く向きで、判定が
# 分からないことを「静か」「人の手が無い」と読まない。
#
# 項目の種類は限らない。bot がコメント以外の書き方 (ラベル付け・再オープンなど) を始めても、
# actor が Bot なら同じ定義が bot の手と答える。

# jq の定義。読み手の式の頭に足して `bot_hand` を呼ぶ (gh の --jq でも jq でも使える)。
# 入力は 1 件の項目 (コメント・timeline の出来事)
BOT_HAND_JQ='def bot_hand:
  [.author?, .actor?, .user?] | map(select(type == "object"))
  | length > 0 and all(.[]; .__typename == "Bot" or .type == "Bot");'

# GraphQL の timelineItems で、どの種類の項目にも手を引かせる断片。使う側は
# `nodes { __typename ...hand }` と書き、問い合わせの末尾にこれを足す。
#
# 種類の並びは IssueTimelineItems の全種 (2026-10-15 の introspection)。コメントだけが
# author、他はすべて actor を持つ。**並びに無い種類が増えても安全側に倒れる** — 手を引かない
# 項目は作者の分からないもの (上の判定) として人の手の側に数えられる。並びから GitHub が種類を消すと
# 問い合わせが失敗し、読み手は読めなかったときの作法 (従来どおりの判定) へ戻る
BOT_HAND_ACTOR_TYPES='AddedToProjectEvent AddedToProjectV2Event AssignedEvent
  BlockedByAddedEvent BlockedByRemovedEvent BlockingAddedEvent BlockingRemovedEvent ClosedEvent
  CommentDeletedEvent ConnectedEvent ConvertedFromDraftEvent ConvertedNoteToIssueEvent
  ConvertedToDiscussionEvent CrossReferencedEvent DemilestonedEvent DisconnectedEvent
  IssueCommentPinnedEvent IssueCommentUnpinnedEvent IssueFieldAddedEvent IssueFieldChangedEvent
  IssueFieldRemovedEvent IssueTypeAddedEvent IssueTypeChangedEvent IssueTypeRemovedEvent
  LabeledEvent LockedEvent MarkedAsDuplicateEvent MentionedEvent MilestonedEvent
  MovedColumnsInProjectEvent ParentIssueAddedEvent ParentIssueRemovedEvent PinnedEvent
  ProjectV2ItemStatusChangedEvent ReferencedEvent RemovedFromProjectEvent RemovedFromProjectV2Event
  RenamedTitleEvent ReopenedEvent SubIssueAddedEvent SubIssueRemovedEvent SubscribedEvent
  TransferredEvent UnassignedEvent UnlabeledEvent UnlockedEvent UnmarkedAsDuplicateEvent
  UnpinnedEvent UnsubscribedEvent UserBlockedEvent'

BOT_HAND_TIMELINE_FRAGMENT='fragment hand on IssueTimelineItems {
  ... on IssueComment { author { __typename } }'
for _bot_hand_type in $BOT_HAND_ACTOR_TYPES; do
  BOT_HAND_TIMELINE_FRAGMENT+=" ... on $_bot_hand_type { actor { __typename } }"
done
BOT_HAND_TIMELINE_FRAGMENT+=' }'
unset _bot_hand_type
