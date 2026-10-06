#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# ADR の形を検査する。見るのは 3 つ — 連番の一意性 (#500)、改訂を抱えた
# ADR の状態欄が「改訂あり」の印を持つこと (#545 / #1946)、本文の改訂の見出しが
# 5 つを超えていないこと (#2140 / #2146)。
#
# ## 1. 連番が一意であること (#500)
#
# ADR は互いを ADR-00NN の綴りで参照する (docs/decisions/AGENTS.md 「形」)。番号が
# 一意でないと「ADR-0026 のとおり」と書いたときにどちらを指すか決まらない。
# 実際に #490 と #491 が並走し、どちらも「次は 0026」と読んで採番したまま
# 両方 merge された — **別ファイルなので文字の衝突は起きない**ので、git も CI も
# 止めなかった。
#
# **check-docs-links.py の責務は広げない** (ADR-0008 決定 5 の段 1)。あちらが
# 見るのは「指し先の不在」で、別名ファイルの番号重複はどのみち全リンクが解決
# するため構造的に拾えない — 今回まさに docs-links は緑のまま通っている。
#
# **効くのは merge queue の層である。** PR 単体では相手の枝が見えないので、
# 並走した 2 本目が赤くなるのは合流後の姿を検査するとき。.github/workflows/ci.yml
# は merge_group でも make ci-check を呼ぶので、そこでこの検査が鳴る。
#
# ## 2. 改訂を抱えた ADR の状態欄が印を持つこと (#545 / #1946)
#
# #545 の当時、状態欄は改訂を抱えても `採用` のまま残っていた (29 本中 27 本が
# 同じ値で、節が情報を運んでいなかった)。そこで状態欄に ` / 改訂 (YYYY-MM-DD):
# <何を>` を書き足させ、本文の改訂の日付が状態欄にも現れることを見ていた。
# ところがこの形では、同じ ADR を改訂する PR が並ぶと、**どの 2 本も状態欄の
# 同じ 1 行で必ず衝突する** (#1946。ADR-0021 を改訂した 4 本が、状態欄の 1 行
# だけの衝突で merge queue から外れた)。
#
# いまは改訂の正本を本文の日付入り見出しに置き、状態欄には一字一句固定の印
# (下の MARKER) を 1 度だけ置く。2 回目以降の改訂は状態欄に触れないので、並んだ
# PR が状態欄で衝突しない。初めての改訂が 2 本並んでも、両方が同じ行を同じ文字に
# 書き換えるだけなので git は衝突させない (scripts/tests/adrs_test.py の
# ParallelRevisionTest が固定している)。
#
# 見るのは構造だけで、**散文は読まない**。赤くするのは次の 2 つ:
#
#   (a) 改訂を抱えているのに状態欄に印が無い。「改訂を抱えている」とは、本文に
#       改訂の見出しがあるか、状態欄に切り替え前の ` / 改訂 (日付)` が残って
#       いるかのどちらか。改訂の見出しは `^##`〜`^####` の行で「改訂」か「追補」と
#       YYYY-MM-DD を両方持つもの。既存の 2 通りの綴りをどちらも拾う:
#
#         ### 4. …… (2026-08-28 改訂)          ← 決定見出しに併記する形
#         #### 改訂 (2026-08-30) — ……          ← 追記節を立てる形
#         ## 追補 — …… (2026-08-29)
#
#   (b) 状態欄に、切り替えの日 (SWITCH_DATE) より後の日付の ` / 改訂 (日付)` が
#       書き足されている。切り替え前の並びは消さずに凍結した (#1946 の M1) ので
#       咎めないが、新しく足すと共有の 1 行がまた衝突の元になる
#
# **日付を持たない見出しは拾わない。** ADR-0006 決定 6 は「ADR-0003 決定 1 の
# 権限表は改訂しない」で、素朴な grep はここで誤検出する。日付の有無が
# 「実際に改訂した」と「改訂について語っている」を分ける。
#
# 本文の見出しの日付が状態欄に現れることは、もう見ない (#1946 で手放した保証)。
# 状態欄から読めるのは「改訂がある」までで、日付と中身は見出しを grep して引く。
#
# ## 3. 本文の改訂の見出しが 5 つを超えないこと (#2140 / #2146)
#
# 改訂が重なった ADR は 1 本で 2〜3 万字になり、決定を変えるときと退けた案の理由を
# 引くときに、1 本を丸ごと読む重さが残る (#2140)。そこで本文の改訂の見出しが
# MAX_REVISIONS を超えたら赤にし、軽くさせる: 番号と決定の番号は変えずに、本文を
# 現行の決定に絞り、改訂の経緯を docs/decisions/history/<番号>.md へ移す。
#
# 数えるのは **見出しの数** で、(a) が改訂と読む行 (上の 2 通りの綴り) と同じ定義で
# ある (revision_headings_of)。挙げられた日付の種類の数ではない — 同じ日に 3 つの
# 決定を改訂した ADR は、読む重さとしては 3 つ分である。副題だけの小見出し (日付も
# 「改訂」「追補」も含まない行) は数えない。軽くした後の本文は 0 に戻り、経緯の
# 見出しは history/ にある。history/ は **ここの走査に入らない** (上の走査が `/` を
# 含む名前を捨てる) ので、番号付きの ADR として数えられず、連番の一意性にも掛からない。
#
# 状態欄の印は、軽くした後もそのまま残す (綴りを変えると並んだ PR が衝突する・
# 上の 2)。印は「改訂がある」ことを示すだけで、見出しが本文と history/ のどちらに
# あるかは言わない。軽くした本文の「改訂の経緯は history/<番号>.md にある」の 1 行が
# 行き先を示す。
#
# ## この検査が見ないもの
#
# **上書きされた側が `置換` を名乗っているか。** 上書きは散文で宣言される
# (ADR-0004 影響節「ADR-0002 決定 1 のうち分類の表現に関する部分は本 ADR が
# 上書きする」) ため、構造的な印が無い。ここを担うのは書く人とレビューで、
# 機械で見張る仕組みは実害が出てから足す (ADR-0008)。
#
# **軽くした後の形。** 経緯の見出しが history/ に移っているか、本文に案内の 1 行が
# あるかは見ない。見るのは本文の見出しの数だけで、見出しを消して経緯を捨てても
# 緑になる。経緯を捨てていないかは書く人とレビューが確かめる (history/ に移した
# 見出しが元と同じ数であること)。
#
# 検査対象は省略可能な位置引数で受ける (既定は git root の docs/decisions)。
# テストが一時ディレクトリを指すためで、check-drawing-evidence.sh が
# DRAWING_PATHS で同じことをしているのに倣う。
set -euo pipefail

DIR="${1:-}"
if [ -z "$DIR" ]; then
  cd "$(git rev-parse --show-toplevel)"
  DIR="docs/decisions"
fi

if [ ! -d "$DIR" ]; then
  echo "ADR の置き場が無い: $DIR" >&2
  exit 1
fi

# 先頭 4 桁を持つ .md だけを数える。番号を名乗らないファイル (README 等) は
# 参照の綴りを持ちようがないので、この検査の対象ではない。
#
# 見る木は「git add -A したときに CI の木になるもの」(追跡 + 未追跡 − 無視・#2072)。
# 作業ツリーを find で見ると、無視された手元の下書きが状態欄の指し先として数えられ、
# 手元で緑・CI で赤になる。index にだけ残る旧パス (git rm していない削除) は -f で落とす。
# 名前は -z で割る (非 ASCII の名前は C 引用符つきで返る)
if ! listed=$(git -C "$DIR" ls-files -z --cached --others --exclude-standard -- . | tr '\0' '\n'); then
  echo "ADR の置き場が git の作業ツリーの中に無い: $DIR" >&2
  exit 1
fi
# パターンを `(` で開く — macOS の /bin/bash (3.2) は $( ) の中の case の `)` を
# コマンド置換の閉じと読み違える
numbered=$(while IFS= read -r name; do
  case "$name" in
    (*/*) ;;
    ([0-9][0-9][0-9][0-9]-*.md) if [ -f "$DIR/$name" ]; then printf '%s\n' "$DIR/$name"; fi ;;
  esac
done <<<"$listed" | sort)

if [ -z "$numbered" ]; then
  echo "ok: 番号付きの ADR が無い ($DIR)"
  exit 0
fi

failed=0

# --- 1. 連番の一意性 ---------------------------------------------------------

duplicates=$(while IFS= read -r path; do
  basename "$path" | cut -c1-4
done <<<"$numbered" | sort | uniq -d)

if [ -n "$duplicates" ]; then
  echo "ADR の番号が重複している (ADR-00NN の綴りがどちらを指すか決まらない):" >&2
  while IFS= read -r number; do
    echo "  ADR-$number:" >&2
    while IFS= read -r path; do
      case "$(basename "$path")" in
        "$number"-*) echo "    $path" >&2 ;;
      esac
    done <<<"$numbered"
  done <<<"$duplicates"
  echo "どちらかを空き番号へ改番する。後から merge されたほうが譲る (#500 の判断)。" >&2
  echo "見出しの ADR-00NN と、その ADR を指す参照の綴り・パスも同時に直す。" >&2
  failed=1
fi

# --- 2. 状態欄の印 -----------------------------------------------------------

# 改訂を抱えた ADR の状態欄に置く印。一字一句固定である — 並んだ 2 本が別々の綴りで
# 印を足すと、それだけで状態欄が衝突する。綴りを変えるなら既存の ADR も同時に直す
MARKER='改訂あり (本文の「改訂 (日付)」見出し)'
# この日より後の日付で状態欄に ` / 改訂 (日付)` を足すのは赤い (#1946 の切り替え)
SWITCH_DATE='2026-10-05'
# 本文の改訂の見出しの上限 (#2140)。この数までは通し、超えたら赤い (下の (c))
MAX_REVISIONS=5

# 「## 状態」の次に来る最初の非空行を状態欄とする
status_of() {
  awk '/^## 状態[[:space:]]*$/ { seen = 1; next } seen && NF { print; exit }' "$1"
}

# 本文の改訂の見出し — 「改訂」か「追補」と日付を両方持つ `##`〜`####` の行。1 行が
# 1 つの改訂で、日付が前にあっても後ろにあっても拾う。(a) が改訂を抱えているかを
# 読むのも、(c) が数えるのも、この定義 1 つに揃える。1 つも無いのは正常なので、
# 空振りした grep で set -e に落ちないよう受ける
revision_headings_of() {
  grep -E '^#{2,4} ' "$1" \
    | grep -E '改訂|追補' \
    | grep -E '20[0-9]{2}-[0-9]{2}-[0-9]{2}' || true
}

# 改訂の見出しが挙げる日付 (重複を畳んで昇順)
revision_dates_of() {
  revision_headings_of "$1" \
    | grep -oE '20[0-9]{2}-[0-9]{2}-[0-9]{2}' \
    | sort -u || true
}

# 状態欄に書き足された ` / 改訂 (日付)` の日付。印の `改訂あり (` は日付を持たない
# ので拾わない
status_revision_dates_of() {
  grep -oE '改訂 \(20[0-9]{2}-[0-9]{2}-[0-9]{2}\)' <<<"$1" \
    | grep -oE '20[0-9]{2}-[0-9]{2}-[0-9]{2}' \
    | sort -u || true
}

while IFS= read -r path; do
  headings=$(revision_headings_of "$path")
  dates=$(revision_dates_of "$path")
  status=$(status_of "$path")

  # (c) 本文の改訂の見出しが上限を超えている (#2140 / #2146)。状態欄の検査とは
  # 独立なので、状態欄が読めなくても先に言う。副題だけの小見出しは数えない
  revision_count=0
  if [ -n "$headings" ]; then
    revision_count=$(wc -l <<<"$headings" | tr -d ' ')
  fi
  if [ "$revision_count" -gt "$MAX_REVISIONS" ]; then
    adr_no=$(basename "$path" | cut -c1-4)
    echo "本文の改訂・追補の見出しが ${MAX_REVISIONS} 個を超えている (${revision_count} 個・読む重さが残る): $path" >&2
    echo "  数えた見出し:" >&2
    while IFS= read -r heading; do
      echo "    $heading" >&2
    done <<<"$headings"
    echo "  直し方: 番号と決定の番号は変えず、経緯を ${DIR}/history/${adr_no}.md へ移して本文を軽くする" >&2
    echo "    1. 本文には、状態・文脈・現行の決定・その決定で退けた案・影響だけを残す" >&2
    echo "    2. 当初の決定と改訂の理由・改訂の見出しの本文・置き換わった決定を ${DIR}/history/${adr_no}.md へ移す" >&2
    echo "       (既にあれば末尾へ足す。経緯ファイルは番号付きの ADR として数えない)" >&2
    echo "    3. 本文の「## 状態」の下に「改訂の経緯は [history/${adr_no}.md](history/${adr_no}.md) にある」の 1 行を置く" >&2
    echo "    状態欄の印と「 / 改訂 (日付)」の並びは、そのまま残す" >&2
    echo "  全文: docs/decisions/AGENTS.md 「改訂が重なった ADR を軽くする」 (理由: #2140)" >&2
    failed=1
  fi

  # 状態欄が読めないことを咎めるのは、印を置くべき改訂を抱えているときだけに
  # とどめる。「ADR は 4 節を持つ」の検査はこの検査の責務ではない
  if [ -n "$dates" ] && [ -z "$status" ]; then
    echo "状態欄が読めない (「## 状態」節とその本文が要る): $path" >&2
    failed=1
    continue
  fi

  status_dates=$(status_revision_dates_of "$status")

  # (a) 改訂を抱えているのに印が無い
  if [ -n "$dates$status_dates" ]; then
    case "$status" in
      *"${MARKER}"*) ;;
      *)
        echo "改訂を抱えているのに、状態欄に印が無い: $path" >&2
        if [ -n "$dates" ]; then
          echo "  本文の改訂の見出し: $(tr '\n' ' ' <<<"$dates")" >&2
        fi
        echo "  状態欄: $status" >&2
        echo "  直し方: 状態欄の末尾に「 / ${MARKER}」を 1 度だけ足す" >&2
        failed=1
        ;;
    esac
  fi

  # (b) 切り替えの日より後の改訂を状態欄に書き足している
  while IFS= read -r date; do
    [ -n "$date" ] || continue
    if [[ "$date" > "$SWITCH_DATE" ]]; then
      echo "状態欄に改訂の日付を書き足している (改訂は本文の見出しにだけ書く): $path" >&2
      echo "  状態欄の改訂: $date" >&2
      echo "  直し方: 状態欄から「 / 改訂 (${date}): …」を外し、本文に「#### 改訂 (${date}) — …」の見出しを立てる" >&2
      failed=1
    fi
  done <<<"$status_dates"

  # 状態欄が指す ADR-00NN の実在。`一部置換 (→ ADR-0031)` のような
  # 指し先の不在を拾う (本文中のリンクは check-docs-links.py の担当)
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    number="${ref#ADR-}"
    # 指し先も上と同じ木から引く (無視された下書きを在ると数えない)
    if ! grep -q "/$number-[^/]*\.md\$" <<<"$numbered"; then
      echo "状態欄が実在しない ADR を指している: $path" >&2
      echo "  指し先: $ref" >&2
      failed=1
    fi
  done <<<"$(grep -oE 'ADR-[0-9]{4}' <<<"$status" | sort -u || true)"
done <<<"$numbered"

if [ "$failed" -ne 0 ]; then
  echo "" >&2
  echo "状態欄の綴りと、改訂が重なった ADR の軽くし方は docs/decisions/AGENTS.md が持つ (#545 / #1946 / #2146)。" >&2
  exit 1
fi

echo "ok: ADR の番号は一意で、改訂を抱えた ADR の状態欄は印を持ち、本文の改訂の見出しは ${MAX_REVISIONS} 個以内 ($(wc -l <<<"$numbered" | tr -d ' ') 本検査)"
