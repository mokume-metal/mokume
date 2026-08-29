# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 「この変更は描画に触れているか」の判定 (#304 / #306)。
#
# 一覧そのものは scripts/drawing-paths.txt が持ち、**それを読む照合はここ 1 つ**に
# 保つ。読み手が 2 つある — 手元の実行の報告を代理で済ませてよいかの判定
# (scripts/render-status.sh) と、絵の証跡を要求するかの判定
# (scripts/check-drawing-evidence.sh) — ので、照合ループを各所へ写すと
# 「一覧は 1 つなのに読み方が 2 通り」という質の悪い二重管理になる
# (ADR-0001 原則 9)。guard-lib.sh と同じ形で source する。
#
# 使い方 (source する側):
#   . "$(dirname "${BASH_SOURCE[0]}")/drawing-paths.sh"
#   printf '%s\n' "${files[@]}" | touches_drawing && …
#   printf '%s\n' "${files[@]}" | drawing_files          # 絞り込んで並べる
#
# テストは scripts/tests/render_status_test.py と
# scripts/tests/drawing_evidence_test.py が、それぞれの読み手を通して行う。

# 一覧の置き場。テストは別のファイルを指す
DRAWING_PATHS=${DRAWING_PATHS:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/drawing-paths.txt}

# 標準入力のファイル群 (1 行 1 件) を、描画の場所に載っているものだけに絞って並べる。
#
# 行は「先頭一致するパスの前置き」で、# で始まる行と空行は無視する
# (書式は drawing-paths.txt の冒頭が定める)。
#
# **照合はここ 1 つ**。真偽だけ要る読み手 (touches_drawing) もこの上に載せる —
# 突き合わせる規則が 2 通りに分かれると、一覧が 1 つでも読み方が食い違う
drawing_files() {
  local file prefix
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    while IFS= read -r prefix; do
      case "$prefix" in '' | '#'*) continue ;; esac
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
