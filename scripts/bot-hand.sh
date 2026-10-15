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
#   scripts/plan-record.sh   二重着手の跡 (bot の本文に混じった目印をプランと読まない) と
#                            投稿済みの判定 (bot の本文に混じった記録 ID を投稿済みと読まない)
#   scripts/comment.sh       宛先の近況 (人の最新のコメントを名乗り、bot の追記に埋もれさせない)
#
# 以前は読み手ごとに専用の除外を書いていたので、穴が兄弟として 1 つずつ見つかった
# (#2660 の反証)。判定をここに寄せ、新しい読み手もここを使う。
#
# ## 判定
#
# **bot の手と呼ぶのは、追記の書き手として分かっている者 (BOT_HAND_WRITERS) の手だけである。**
# 「型が Bot なら人の手ではない」は広すぎる (#2660 の 2 回目の反証):
#
#   - GitHub App 経由で投稿するエージェントも Bot 型である (scripts/comment.sh の冒頭が存在を
#     認めている)。型で除くと、そのエージェントの作業中の着手印を ready-queue が静かと読む
#   - 書き手を名指しすれば、そうした別の Bot は人の側 — 従来どおりの判定 — に残る
#
# 名指しは login で行い、型が引けているときは型が Bot であることも求める (人の口座が同じ
# login を名乗っても bot の手と読まない)。login の綴りは経路で違う — GraphQL と gh の view は
# `github-actions`、REST は `github-actions[bot]` — ので、末尾の `[bot]` を落として照らす。
# gh の view は作者の型を返さないので、そこでは login だけで照らす (`github-actions` は
# GitHub Actions の bot の口座で、同名の人の口座は無い — 2026-10-15 に `users/github-actions` が
# 404 を返すのを確かめた)。
#
# `github-actions` の手は 1 種類ではない。定期の赤の追記 (#2658) のほかに、scripts/parent-guard.sh
# も github.token で reopen とその理由のコメントを書く。どちらも人の活動ではないので除いてよいが、
# 理由を人が読む必要はある — comment.sh は bot の追記の最新の見出しも添える。
#
# **作者の分からないもの (作者を引かなかった・退会した人) は bot の手と呼ばない。** 読み手は
# それを人の手の側 — 従来どおりの判定 — に倒す。bot と分かるものだけを除く向きで、判定が
# 分からないことを「静か」「人の手が無い」と読まない。
#
# 項目の種類は限らない。書き手がコメント以外の書き方 (ラベル付け・再オープンなど) を始めても、
# actor が書き手なら同じ定義が bot の手と答える。

# 追記の書き手として分かっている者の login (空白区切り。`[bot]` は付けない)。増やすのは、
# その書き手が Issue の活動へ書き込むようになったときだけ
BOT_HAND_WRITERS='github-actions'

# jq の定義。読み手の式の頭に足して `bot_hand` を呼ぶ (gh の --jq でも jq でも使える)。
# 入力は 1 件の項目 (コメント・timeline の出来事)。作者 / actor は GraphQL の
# `{__typename, login}`・REST の `user {login, type}`・gh の view の `{login}` のどれでもよい
_bot_hand_writers=''
for _bot_hand_writer in $BOT_HAND_WRITERS; do
  _bot_hand_writers+="${_bot_hand_writers:+, }\"$_bot_hand_writer\""
done
BOT_HAND_JQ='def bot_hand:
  ['"$_bot_hand_writers"'] as $writers
  | [.author?, .actor?, .user?] | map(select(type == "object"))
  | length > 0 and all(.[];
      ((.login // "") | sub("\\[bot\\]$"; "")) as $login
      | ($writers | index($login)) != null and (.__typename // .type // "Bot") == "Bot");'

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
  ... on IssueComment { author { __typename login } }'
for _bot_hand_type in $BOT_HAND_ACTOR_TYPES; do
  BOT_HAND_TIMELINE_FRAGMENT+=" ... on $_bot_hand_type { actor { __typename login } }"
done
BOT_HAND_TIMELINE_FRAGMENT+=' }'
unset _bot_hand_type _bot_hand_writer _bot_hand_writers
