#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 人の関門ごとに「人が何かを変えた回数」を数える (#2109・ADR-0036 決定 7)。
#
# 関門は、人が見て何かを変えうる場所である。押されるだけで何も変えない関門は、本当に
# 見るべき 1 回まで反射で押させる。PR の native Approve は 62 回働いて何も変えず、
# 外した (ADR-0044)。ADR-0036 決定 7 は、関門ごとにこの回数を数え、**50 回続けて 0 なら、
# その関門をやめるか作り直す**と定めた。ここはその数え方の正本である。
#
# **読むだけで、何も変えない。** 判断は数字を見た人がする。
#
# ## 何を「変えた」と数えるか
#
#   reviews  直近に merge された PR に付いた、人のレビュー。Changes requested か、本文の
#            付いたレビューを「変えた」と数える。本文の無い Approve は数えない
#   plans    着手前のプラン (ExitPlanMode)。言葉の添えられた却下を「変えた」と数える。
#            言葉は tool_result の中身に `the user said:` として入る。is_error だけで数えると、
#            エージェント自身の誤呼び出し (`not in plan mode`) を却下と取り違える
#            (ADR-0036 の文脈が数え直した)
#
# ## 限界
#
# - plans の材料は手元の Claude Code の transcript で、**残っている期間しか数えられない**
#   (2026-10-06 の手元では最古が 2026-09-21)。数えた期間は出力の 1 行目に出す。過去の
#   数字は、そのとき数えた Issue / ADR にしか残らない
# - plans の承認の数には、トリアージ済みの着手で plan-pass が待たずに通したものも入る
#   (ADR-0036 決定 2)。却下 (人が変えた回数) の数はそれに左右されない
# - Codex のセッションは数えない (transcript の形が違う)
#
# ## 使い方
#
#   bash scripts/gate-changes.sh reviews [件数]      # 既定 200 件。レビューの主は gh の認証主
#   bash scripts/gate-changes.sh plans [YYYY-MM-DD]   # その日以降。既定は残っている全部
#
# 環境変数:
#   MOKUME_REVIEWER         レビューの主を差し替える (既定は gh api user の login)
#   MOKUME_TRANSCRIPTS      transcript の置き場の glob (既定 ${CLAUDE_CONFIG_DIR:-~/.claude}/projects/*mokume*)
set -euo pipefail

usage() { sed -n '/^# ## 使い方/,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }

reviews() {
  local limit=${1:-200} reviewer=${MOKUME_REVIEWER:-}
  [ -n "$reviewer" ] || reviewer=$(gh api user -q .login)
  gh pr list --state merged --limit "$limit" --json number,reviews |
    jq -r --arg who "$reviewer" '
      def mine: [.reviews[] | select(.author.login == $who)];
      def changed: select(.state == "CHANGES_REQUESTED" or ((.body // "") | length) > 0);
      (map(.number) | "PR #\(min)〜#\(max) の \(length) 本 (merge 済み)"),
      "  \($who) がレビューした: \(map(select(mine | length > 0)) | length) 本",
      "  変えた (Changes requested か本文つき): \(map(select([mine[] | changed] | length > 0)) | length) 本",
      (map(select([mine[] | changed] | length > 0) | "    #\(.number)") | .[])'
}

plans() {
  local since=${1:-} glob=${MOKUME_TRANSCRIPTS:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/*mokume*}
  # shellcheck disable=SC2086 # glob は展開させる
  cat $glob/*.jsonl 2>/dev/null |
    jq -r --arg since "$since" '
      select((.timestamp // "") >= $since) | .timestamp as $at | .message.content? | arrays[] |
      if .type == "tool_use" and .name == "ExitPlanMode" then "use\t\(.id)\t\($at)"
      elif .type == "tool_result" then
        "result\t\(.tool_use_id)\t\(.is_error // false)\t\(.content | tostring |
          if test("the user said:") then "words" elif test("not in plan mode") then "misfire" else "plain" end)"
      else empty end' 2>/dev/null |
    awk -F'\t' '
      $1 == "use" { used[$2] = 1; if (first == "" || $3 < first) first = $3; if ($3 > last) last = $3 }
      $1 == "result" { result[$2] = $3 " " $4 }
      END {
        for (id in used) {
          total++; r = result[id]
          if (r ~ /words/) words++
          else if (r ~ /misfire/) misfire++
          else if (r ~ /^true/) silent++
          else if (r != "") approved++
          else pending++
        }
        printf "ExitPlanMode %d 回 (%s〜%s)\n", total, substr(first, 1, 10), substr(last, 1, 10)
        printf "  承認: %d\n  変えた (言葉つきの却下): %d\n  無言の却下: %d\n  誤呼び出し (not in plan mode): %d\n  結果なし: %d\n",
          approved, words, silent, misfire, pending
      }'
}

case "${1:-}" in
  reviews) shift; reviews "$@" ;;
  plans) shift; plans "$@" ;;
  -h | --help) usage ;;
  *) usage >&2; exit 1 ;;
esac
