# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 「この変更は描画に触れているか」の判定 (#304 / #306)。
#
# 一覧そのものは scripts/drawing-paths.txt が持ち、**それを読む照合はここ 1 つ**に
# 保つ。読み手は絵の証跡を要求するかの判定 (scripts/check-drawing-evidence.sh) と、
# Issue が描画に触りそうかの見込み (scripts/ready-queue.sh) で、照合ループを各所へ写すと
# 「一覧は 1 つなのに読み方が 2 通り」という質の悪い二重管理になる (ADR-0001 原則 9)。
# guard-lib.sh と同じ形で source する。
#
# **以前は用途 (evidence / coverage) を呼ぶ側が渡していた** (#497)。coverage は手元の
# 実行の覆い (#435) と描画 PR の順番待ち (#467) の問いで、専用機が merge queue の木を
# 直接描くようになって機構ごと畳んだ (#879)。問いが 1 つになったので、引数も畳んだ。
#
# 使い方 (source する側):
#   . "$(dirname "${BASH_SOURCE[0]}")/drawing-paths.sh"
#   printf '%s\n' "${files[@]}" | touches_drawing && …
#   printf '%s\n' "${files[@]}" | drawing_files          # 絞り込んで並べる
#
# テストは、照合そのものを scripts/tests/drawing_paths_test.py が、証跡の判定を
# scripts/tests/drawing_evidence_test.py が行う。

# 一覧の置き場。テストは別のファイルを指す
DRAWING_PATHS=${DRAWING_PATHS:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/drawing-paths.txt}

# 標準入力のファイル群 (1 行 1 件) を、描画の場所に載っているものだけに絞って並べる。
#
# 行は「先頭一致するパスの前置き」で、# で始まる行と空行は無視する (書式は
# drawing-paths.txt の冒頭が定める)。
#
# **照合はここ 1 つ**。真偽だけ要る読み手 (touches_drawing) もこの上に載せる —
# 突き合わせる規則が 2 通りに分かれると、一覧が 1 つでも読み方が食い違う
#
# **行の先頭の語だけを前置きとして読み、空白の後ろは読まない。** 後ろに何が書かれて
# いても、その行は外れずに効く — 一覧の冒頭が言う「迷ったら広く取る」と
# 同じ向きで、後ろの語で狭く倒れると絵の退行が誰にも見られずに main へ入る
drawing_files() {
  local file line prefix
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    while IFS= read -r line; do
      case "$line" in '' | '#'*) continue ;; esac
      prefix=${line%%[[:space:]]*}
      case "$file" in "$prefix"*)
        printf '%s\n' "$file"
        break
        ;;
      esac
    done < "$DRAWING_PATHS"
  done
}

# 標準入力のファイル群のうち 1 つでも描画の場所に載っていれば 0。
#
# 早く打ち切る書き方 (grep -q / head -1) は取らない — 読み手は set -o pipefail の
# 下で呼ぶので、絞り込み側が SIGPIPE で落ちると「見つかった」が偽に化ける。
# 突き合わせるのは PR の変更ファイル一覧の長さなので、全部読んでも安い
touches_drawing() { [ -n "$(drawing_files)" ]; }
