#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# Claude Code の PreToolUse フック: いま居る worktree の外 (= 同じリポジトリの別
# worktree) へ書き込む事故を水際で止める (#499)。
#
# このリポジトリは worktree を常用する — 並行するセッションがそれぞれ自分のツリーを
# 持ち、同名のファイルが同じ相対パスで何本も存在する。その状態で、メイン作業ツリーの
# 絶対パスで Read → Edit してしまい、変更がブランチではなくメインツリーへ落ちる事故が
# 起きる。Edit の「事前に Read が必要」というガードは、同じ (間違った) ファイルを
# 読んでいれば通ってしまうので取り違えを検知できない。パスは自己申告で、しかも両ツリーに
# 同名のファイルが存在するため、間違いが目に見えない。
#
# 「編集先はいまのセッションの worktree の中」はリポジトリの状態から機械的に決まるので、
# 文書ルールではなくここで決定論的に落とす。
#
# 判定は「同じリポジトリの別 worktree か」だけを見る:
#   - 同じ worktree の中             → 素通し
#   - 別のリポジトリ (submodule 含む) → 素通し (正当な作業。ここで止める理由がない)
#   - 同じリポジトリの別 worktree     → deny (訂正後のパスを添えて返す)
#
# ask ではなく deny なのは、取り違えなら正しいパスへ直せばその場で続行できるから
# (人を呼ぶ必要がない)。本当に別ツリーを触りたいときは、そのツリーで作業している
# セッションから行う — 並行セッションが同じファイルを取り合う状況こそ避けたい。
#
# **効くのは、このリポジトリを主として開いたセッションだけである。** プロジェクト設定は
# セッションが主として開いたディレクトリのものしか読まれないので、別のリポジトリを主と
# するセッションがこのリポジトリの worktree で作業しても発火しない。塞ぐ手が無いことは
# ADR-0007 決定 3 が示しているので、その場合は AGENTS.md「エージェント環境の設定」の
# 但し書きを自分で守る (pr-identity-guard.sh と同じ限界。#513)。
#
# 契約: stdin に PreToolUse の JSON。素通しは無出力 + 終了コード 0。
# 呼び出し口は .claude/settings.json の hooks.PreToolUse、テストは
# scripts/tests/worktree_path_guard_test.py (make hooks-test が拾う)。

set -uo pipefail

# payload の解き方と差し戻し方は guard-lib.sh と共有する (#815)。読めなければ素通し —
# guard が壊れて書き込みが一切できなくなるほうが害が大きい (hook_payload の jq と同じ
# fail open の考え方。他 2 本のフックと同じ形)
# shellcheck source=scripts/guard-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/guard-lib.sh" 2>/dev/null || exit 0

hook_payload
cwd=$HOOK_CWD

# Edit/Write は file_path、NotebookEdit は notebook_path。書き込み先を持たない
# ツール (Bash など) は素通し
target=$(hook_field '.tool_input.file_path // .tool_input.notebook_path // ""')
[ -n "$target" ] || exit 0

# 実在する最も近い親ディレクトリの物理パス (新規ファイルの作成にも効かせるため、
# ファイル自身の実在は前提にしない)
resolve_dir() {
  local dir=$1 parent
  while [ ! -d "$dir" ]; do
    parent=$(dirname "$dir")
    [ "$parent" = "$dir" ] && return 1
    dir=$parent
  done
  (cd "$dir" 2>/dev/null && pwd -P)
}

# 相対パスはセッションの cwd 基準 (Claude Code は絶対パスを要求するが、念のため)
case $target in
  /*) ;;
  *) target=$cwd/$target ;;
esac

target_dir=$(resolve_dir "$(dirname "$target")") || exit 0
cwd_dir=$(resolve_dir "$cwd") || exit 0

# git 管理外はここで終わり (スクラッチパッド、セッションの記録など)
target_root=$(git -C "$target_dir" rev-parse --show-toplevel 2>/dev/null) || exit 0
current_root=$(git -C "$cwd_dir" rev-parse --show-toplevel 2>/dev/null) || exit 0
target_root=$(resolve_dir "$target_root") || exit 0
current_root=$(resolve_dir "$current_root") || exit 0

[ "$target_root" = "$current_root" ] && exit 0

# worktree は共通の .git ディレクトリを指す。ここが一致するときだけ「同じリポジトリの
# 別 worktree」= 取り違え。別リポジトリ (submodule やまったく別のプロジェクト) は素通し
common_of() {
  git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null
}
target_common=$(common_of "$target_dir")
current_common=$(common_of "$cwd_dir")
[ -n "$target_common" ] && [ -n "$current_common" ] || exit 0
target_common=$(resolve_dir "$target_common") || exit 0
current_common=$(resolve_dir "$current_common") || exit 0
[ "$target_common" = "$current_common" ] || exit 0

# 訂正後のパスを添える。取り違えの実体は「同じ相対パスを別のツリーに向けた」なので、
# ツリーの根だけ差し替えれば意図した先になる
relative=${target_dir#"$target_root"/}
[ "$relative" = "$target_dir" ] && relative=""  # 対象がツリー直下
suggested=$current_root${relative:+/$relative}/$(basename "$target")

note="（訂正先はまだ存在しません。新規作成ならこのままで問題ありません）"
[ -e "$suggested" ] && note="（訂正先は存在します）"

hook_deny "$(cat <<EOF
同じリポジトリの**別 worktree** へ書き込もうとしています。パスの取り違えです。

  このセッションの worktree : $current_root
  書き込もうとした worktree : $target_root

このまま書くと、変更はいまのブランチではなく別のツリーへ落ちます (同名のファイルが
両方にあるため、差分を見るまで気付けません)。

訂正後のパス:
  $suggested
$note

本当に別の worktree を変更する必要があるなら、そのツリーで作業しているセッションから
行ってください。
EOF
)"
