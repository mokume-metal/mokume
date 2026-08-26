#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# Claude Code の PreToolUse フック: 素の gh で Issue / PR にコメントしようとしたら
# 差し戻し、scripts/comment.sh へ誘導する (#18)。
#
# 署名を付けるのはラッパー (scripts/comment.sh) の仕事で、ここが見るのは「ラッパーを
# 通っているか」だけ。PreToolUse フックはツール入力を書き換えられない仕様なので、
# 通っていないものを deny で差し戻すのが決定論的に効かせられる唯一の形。
# ask ではなく deny なのは、ラッパーに変えればその場で続行できるから (人を呼ばない)。
#
# 判定はコメントを投稿するコマンドだけに絞る:
#   - gh issue comment / gh pr comment       → 差し戻す
#   - gh pr review で本文オプションが付くもの → 差し戻す (--approve だけなら発言が無い)
#   - それ以外 (view/list、gh api、--help)   → 素通し
#
# 契約: stdin に PreToolUse の JSON。素通しは無出力 + 終了コード 0。
# 配線は .claude/settings.json、テストは scripts/tests/comment_test.py。
set -uo pipefail

deny() { # $1=理由
  jq -n --arg r "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

payload=$(cat)
command -v jq >/dev/null 2>&1 || exit 0
command=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null) || exit 0
[ -n "$command" ] || exit 0

# ラッパー自身の呼び出しは素通し (内部で gh を呼ぶが、それは別プロセスでここを通らない)
printf '%s' "$command" | grep -qE '(^|[;&|[:space:]])(bash[[:space:]]+)?[^[:space:];&|]*scripts/comment\.sh([[:space:]]|$)' && exit 0

# gh のサブコマンドの手前にはグローバルオプション (-R owner/repo など) が入りうるので、
# 「gh … <サブコマンド>」の間は緩く見る
readonly GH='(^|[;&|[:space:]])gh([[:space:]]+[^;&|[:space:]]+)*[[:space:]]+'

is_comment_command() {
  printf '%s' "$command" | grep -qE "${GH}(issue|pr)[[:space:]]+comment([[:space:]]|$)" && return 0
  # レビューは本文を伴うときだけ。--approve / --request-changes だけなら発言が無い
  printf '%s' "$command" | grep -qE "${GH}pr[[:space:]]+review([[:space:]]|$)" &&
    printf '%s' "$command" | grep -qE '(^|[[:space:]])(-b|--body|-F|--body-file)([[:space:]]|=)' &&
    return 0
  return 1
}

is_comment_command || exit 0

# 使い方を尋ねているだけなら投稿ではない
printf '%s' "$command" | grep -qE '(^|[[:space:]])(-h|--help)([[:space:]]|$)' && exit 0

deny "$(cat <<'EOF'
Issue / PR へのコメントは scripts/comment.sh から投稿してください。

同じ Issue には人間も複数のエージェントも書き込みます。どの AI が書いたかを本文の
署名で判別できる必要があり、ラッパーがそれを実行環境から判定して自動で付けます
(規約を覚えていることに依存させない)。

  bash scripts/comment.sh issue <番号> --body-file <ファイル>
  bash scripts/comment.sh pr    <番号> --body "<本文>"

投稿前に本文を確かめたいときは --dry-run を付けてください。
gh pr review で本文を添える場合も、本文はこのラッパーで投稿し、レビュー自体は
--approve / --request-changes だけで送ってください。
EOF
)"
