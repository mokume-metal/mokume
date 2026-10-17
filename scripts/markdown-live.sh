# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# Markdown の本文を行で読む検査のための、「どの行が生きているか」の読み方 (#2816)。
#
# PR 本文・Issue 本文・ADR を行で読む検査 (見出しで節を切る・宣言の行を探す・絵の URL を
# 探す) は、**コードブロックと HTML コメントの中の行を生きた行として読んではならない**。
# GitHub はそこを見出しにも本文にも描かないので、読み手が数えると、書き手に見えていない
# 行で判定が動く。#2768 では `body_section` がコードブロックの中の `#` の行を見出しと読み、
# 節が途中で切れた。直したのは `body_section` だけで、同じ約束を持たない読み手が 7 つ残って
# いた (#2816)。**読み方を各読み手が持つと、片方だけが直る** — だから 1 か所に置き、
# 読み手はここを通す。
#
# 読み方は CommonMark (GitHub の描画) に合わせる。**描画 API (POST /markdown) で確かめた形**:
#   - フェンスは ``` と ~~~。字下げは 3 桁まで・閉じは同じ種類で開き以上の長さ・閉じの行に
#     文字は続けられない・閉じ忘れは本文の終わりまで続く
#   - **行頭から始まる** `<!--` は HTML ブロックで、`-->` を含む行で終わる。中の行頭の ``` は
#     フェンスを開かず、中の `## x` は見出しにならない。閉じ忘れは本文の終わりまで続く
#   - 行の途中から始まる `text <!--` は保護されない。次の行頭の ``` はフェンスを開く
#   - リスト項目の中のフェンスは、項目の内容の幅より浅い非空行で暗黙に閉じる (空行を挟んでも
#     挟まなくても同じ)。リストが閉じた後の字下げフェンスは項目に属さない
# 引用 (`> ` の中のフェンス) と、タブの字下げは読まない。
#
# 使い方 (source する側):
#   . "$(dirname "${BASH_SOURCE[0]}")/markdown-live.sh"
#   live=$(markdown_live_lines <<<"$body")   # フェンスの中の行を空行へ潰す。行数は変わらない
#   awk -f 相当: "$MARKDOWN_LINES_AWK" の関数 md_kind を自分の awk に連結して使う
#               (例は review-gate.sh の body_section)
#
# **コメントの行は潰さない。** HTML コメントを取り除く側 (review-gate の strip_html_comments)
# が別にあり、読み手によって「コメントの中も読む」「読まない」が分かれているため、この
# フィルタはコードブロックだけを扱う。コメントの行を見たいときは md_kind の戻り値 2 を使う。
#
# **パイプラインの左辺には置かない。** `markdown_live_lines … | grep -q` は pipefail の下で、
# grep が先に抜けると書き手が SIGPIPE で止まり、判定が裏返る (#1900)。変数へ受けてから
# here-string で読む。
#
# テストは scripts/tests/markdown_live_test.py。

# 行の種類を返し、状態を進める awk の関数 (行を 1 本ずつ順に渡す)。
#   0  生きた行
#   1  コードブロック (開きの行・中身・閉じの行)
#   2  HTML コメントのブロック (開きの行・中身・閉じの行)
#
# 状態は md_ で始まる大域変数で、複数の入力をまたいで使わない (1 回の awk に 1 本の本文)。
# md_ws[] は開いているリスト項目の内容の幅の積み (md_depth が段数)。**暗黙に閉じる規則を
# 持つために、リスト項目の頭 (`- `・`1. `) だけを読む。** 段落の途中の `2. foo` のように、
# 項目と数えない行を項目と読むことがあるが、害が出るのは「項目の幅以上に字下げした
# フェンスを開き、直後に浅い行が来る」形だけで、実際には出会わない。
read -r -d '' MARKDOWN_LINES_AWK <<'AWK' || true
function md_kind(line,    blank, ind, rest, c, n, info, lead, base, ismark, mlen, nx, sp, w, erest, c2, ishead, inter) {
  blank = (line ~ /^[[:space:]]*$/)
  match(line, /^ */); ind = RLENGTH

  if (md_infence) {
    # 項目の中のフェンスは、項目の幅より浅い非空行で暗黙に閉じる。閉じたあとはその行を
    # 普通の行として読む
    if (!blank && ind < md_fw) {
      md_infence = 0
    } else {
      if (!blank && ind - md_fw <= 3) {
        rest = substr(line, ind + 1); c = substr(rest, 1, 1)
        if (c == md_fc) {
          match(rest, c "+"); n = RLENGTH
          if (n >= md_fn && substr(rest, n + 1) ~ /^[[:space:]]*$/) md_infence = 0
        }
      }
      md_para = 0
      return 1
    }
  }

  # コメントは `-->` を含む行で終わる (閉じ忘れは本文の終わりまで。GitHub の描画も、閉じない
  # コメントが後ろをすべて隠す)
  if (md_incomment) {
    if (index(line, "-->")) md_incomment = 0
    md_para = 0
    return 2
  }

  if (blank) { md_para = 0; return 0 }

  rest = substr(line, ind + 1); c = substr(rest, 1, 1)
  ismark = 0
  if (match(line, /^ *([-+*]|[0-9]+[.)])/)) {
    mlen = RLENGTH; nx = substr(line, mlen + 1, 1)
    if (nx == "" || nx == " ") ismark = 1
  }
  ishead = (ind <= 3 && (rest ~ /^#+$/ || rest ~ /^#+[[:space:]]/))
  inter = (ismark || ishead || c == ">" || rest ~ /^```/ || rest ~ /^~~~/ || substr(rest, 1, 4) == "<!--")

  # 浅い行はそれより深い項目を閉じる。ただし段落の続きの行 (遅延継続) は閉じない。
  # 見出し・フェンス・項目の頭・コメント・引用は段落を割るので、いつも閉じる
  while (md_depth > 0 && ind < md_ws[md_depth] && (!md_para || inter)) md_depth--
  base = (md_depth > 0) ? md_ws[md_depth] : 0

  if (ismark) {
    sp = 0
    if (match(substr(line, mlen + 1), /^ */)) sp = RLENGTH
    if (sp > 4 || mlen + sp >= length(line)) w = mlen + 1; else w = mlen + sp
    md_ws[++md_depth] = w
    base = w
    erest = substr(line, w + 1)
    match(erest, /^ */); lead = RLENGTH
    erest = substr(erest, lead + 1)
  } else {
    erest = rest
    lead = ind - base
  }

  if (lead >= 0 && lead <= 3) {
    c2 = substr(erest, 1, 1)
    if (c2 == "`" || c2 == "~") {
      match(erest, c2 "+"); n = RLENGTH; info = substr(erest, n + 1)
      if (n >= 3 && !(c2 == "`" && index(info, "`"))) {
        md_infence = 1; md_fc = c2; md_fn = n; md_fw = base; md_para = 0
        return 1
      }
    }
    if (substr(erest, 1, 4) == "<!--") {
      if (!index(substr(erest, 5), "-->")) md_incomment = 1
      md_para = 0
      return 2
    }
  }
  md_para = (ishead || erest == "") ? 0 : 1
  return 0
}
AWK

# 標準入力の Markdown から、コードブロックの中の行 (開き・中身・閉じ) を空行へ潰して返す。
# 行数と、生きた行の中身は変えない。
markdown_live_lines() {
  awk "$MARKDOWN_LINES_AWK"'
    { print (md_kind($0) == 1 ? "" : $0) }
  '
}
