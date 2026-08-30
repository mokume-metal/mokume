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
#   - gh issue comment / gh pr comment          → 差し戻す
#   - gh pr review で本文オプションが付くもの    → 差し戻す (--approve だけなら発言が無い)
#   - gh {issue,pr} {close,reopen} の --comment → 差し戻す (閉じ / 開き ながら発言する)
#   - 他のリポジトリ宛て (-R other/repo)        → 素通し (このリポジトリの規約の外)
#   - それ以外 (view/list、gh api、--help)      → 素通し
#
# **サブコマンドを絞ってからオプションを見る。** 「-c が付いていたら発言」と短絡すると
# 読み取りまで止まる — gh の中で -c の意味は衝突している (#123):
#
#   gh pr view -c / gh issue view -c  → --comments (コメントを読む)
#   gh issue develop -c               → --checkout
#
# --comment は --comments の前方一致でもあるので、オプション側も後ろを区切りで留める。
# gh が発言を伴うサブコマンドを増やしたらここに足す。取りこぼしを後から足すほうが、
# 誤検知で読み取りを止めるより安い。
#
# 契約: stdin に PreToolUse の JSON。素通しは無出力 + 終了コード 0。
# 配線は .claude/settings.json、テストは scripts/tests/comment_test.py。
set -uo pipefail

deny() { # $1=理由
  jq -n --arg r "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

# コマンド文字列の読み方は pr-identity-guard.sh と共有する (#128)。
# 読めなければ素通し — guard が壊れて Bash ツール全体が使えなくなるほうが害が大きい
# (下の jq と同じ fail open の考え方)
# shellcheck source=scripts/guard-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/guard-lib.sh" 2>/dev/null || exit 0

payload=$(cat)
command -v jq >/dev/null 2>&1 || exit 0
command=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null) || exit 0
[ -n "$command" ] || exit 0

# -R が無いコマンドの宛先はカレントディレクトリのリポジトリ。payload の cwd は
# シェルが実際に居るディレクトリを持つ (#611)
cwd=$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null)
[ -n "$cwd" ] || cwd=$PWD

# ラッパー自身の呼び出しは素通し (内部で gh を呼ぶが、それは別プロセスでここを通らない)
printf '%s' "$command" | grep -qE '(^|[;&|[:space:]])(bash[[:space:]]+)?[^[:space:];&|]*scripts/comment\.sh([[:space:]]|$)' && exit 0

is_comment_command() {
  is_gh_subcommand "$command" '(issue|pr)[[:space:]]+comment' && return 0
  # レビューは本文を伴うときだけ。--approve / --request-changes だけなら発言が無い
  is_gh_subcommand "$command" 'pr[[:space:]]+review' &&
    printf '%s' "$command" | grep -qE '(^|[[:space:]])(-b|--body|-F|--body-file)([[:space:]]|=)' &&
    return 0
  # close / reopen も本文を伴うときだけ。状態を変えるだけなら発言が無い。
  # 冒頭のとおり、-c の意味はサブコマンドによって違うのでここで絞ってから見る
  is_gh_subcommand "$command" '(issue|pr)[[:space:]]+(close|reopen)' &&
    printf '%s' "$command" | grep -qE '(^|[[:space:]])(-c|--comment)([[:space:]]|=)' &&
    return 0
  return 1
}

is_comment_command || exit 0

# 使い方を尋ねているだけなら投稿ではない
printf '%s' "$command" | grep -qE '(^|[[:space:]])(-h|--help)([[:space:]]|$)' && exit 0

# 他のリポジトリ宛てのコメントはこのリポジトリの規約の外 (#188)。あちらの署名の作法は
# 別に決まっており、ラッパーの投稿先は mokume 固定なので、ここで止めると逃げ道が無くなる。
# 判定は guard-lib.sh が持つ (pr-identity-guard.sh と共有する)
targets_other_repo "$command" "$cwd" && exit 0

deny "$(cat <<'EOF'
このリポジトリの Issue / PR へのコメントは scripts/comment.sh から投稿してください。

同じ Issue には人間も複数のエージェントも書き込みます。どの AI が書いたかを本文の
署名で判別できる必要があり、ラッパーがそれを実行環境から判定して自動で付けます
(規約を覚えていることに依存させない)。

  bash scripts/comment.sh issue <番号> --body-file <ファイル>
  bash scripts/comment.sh pr    <番号> --body "<本文>"

投稿前に本文を確かめたいときは --dry-run を付けてください。
gh pr review で本文を添える場合も、本文はこのラッパーで投稿し、レビュー自体は
--approve / --request-changes だけで送ってください。

close / reopen に --comment を添える場合は 2 手に分けます。発言を先に投稿してから、
状態の変更は発言なしで実行してください (説明してから閉じる、という読み順になります):

  bash scripts/comment.sh pr <番号> --body "<本文>"
  gh pr close <番号>
EOF
)$(other_repo_hint 'gh issue comment <番号>')"
