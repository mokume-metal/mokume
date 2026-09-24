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
# **問いは 2 つある** (#497)。どちらの問いで訊いているかは呼ぶ側が必ず渡す (用途に
# 既定を持たせない — 新しい読み手が黙ってどちらかへ倒れないため):
#
#   evidence  絵の証跡が要るか (#306)
#   coverage  手元の実行の覆いが壊れるか (#435)・描画 PR の順番待ちに入るか (#467)
#
# **いまは 2 つの問いの答えが違う場所が無いので、drawing_files は用途を読まない。**
# 答えを分けていた行の印 (`evidence-only`) は、最後の行 (Sketches/) から #1377 で外れ、
# 読む口ごと #1428 で畳んだ。それでも呼ぶ側は用途を渡し続ける — どの読み手がどちらの
# 問いで訊いているかが呼ぶ側に書いてあれば、片方の問いだけを畳むとき (#879 は coverage
# の側を消す計画) も、答えがまた分かれるときも、読み手を探し直さずに済む。
#
# 使い方 (source する側):
#   . "$(dirname "${BASH_SOURCE[0]}")/drawing-paths.sh"
#   printf '%s\n' "${files[@]}" | touches_drawing coverage && …
#   printf '%s\n' "${files[@]}" | drawing_files evidence          # 絞り込んで並べる
#
# テストは、照合そのものを scripts/tests/drawing_paths_test.py が、どちらの問いで
# 訊くかを scripts/tests/render_status_test.py と scripts/tests/drawing_evidence_test.py
# が、それぞれの読み手を通して行う。

# 一覧の置き場。テストは別のファイルを指す
DRAWING_PATHS=${DRAWING_PATHS:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/drawing-paths.txt}

# 標準入力のファイル群 (1 行 1 件) を、描画の場所に載っているものだけに絞って並べる。
# 引数の用途は受け取るが読まない (冒頭の「問いは 2 つある」)。
#
# 行は「先頭一致するパスの前置き」で、# で始まる行と空行は無視する (書式は
# drawing-paths.txt の冒頭が定める)。
#
# **照合はここ 1 つ**。真偽だけ要る読み手 (touches_drawing) もこの上に載せる —
# 突き合わせる規則が 2 通りに分かれると、一覧が 1 つでも読み方が食い違う
#
# **行の先頭の語だけを前置きとして読み、空白の後ろは読まない。** 後ろに何が書かれて
# いても、その行は外れずに両方の問いに効く — 一覧の冒頭が言う「迷ったら広く取る」と
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

# 標準入力のファイル群のうち 1 つでも描画の場所に載っていれば 0。用途は
# drawing_files へそのまま渡す。
#
# 早く打ち切る書き方 (grep -q / head -1) は取らない — 読み手は set -o pipefail の
# 下で呼ぶので、絞り込み側が SIGPIPE で落ちると「見つかった」が偽に化ける。
# 突き合わせるのは PR の変更ファイル一覧の長さなので、全部読んでも安い
touches_drawing() { [ -n "$(drawing_files "$@")" ]; }
