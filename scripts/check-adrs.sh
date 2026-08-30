#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# ADR の形を検査する。見るのは 2 つ — 連番の一意性 (#500) と、状態欄が改訂に
# 追随していること (#545)。
#
# ## 1. 連番が一意であること (#500)
#
# ADR は互いを ADR-00NN の綴りで参照する (AGENTS.md 「正典の在処」)。番号が
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
# ## 2. 状態欄が改訂に追随していること (#545)
#
# ADR は本文で改訂をよく追えている (決定の直後に括弧書きで差し替えを名乗る・
# 「**当初の決定**は〜だった」と捨てたものを理由ごと残す) 一方、状態欄は
# `採用` のまま残っていた。29 本中 27 本が同じ値で、節が情報を運んでいなかった。
# 改訂を抱えた 7 本のうち 5 本が名乗れておらず、**書けている人は書いている**
# ので、原因は不注意ではなく書式の不在である。
#
# 見るのは構造だけで、**散文は読まない**。改訂の見出し — `^##`〜`^####` の
# 行が「改訂」か「追補」と YYYY-MM-DD を両方持つもの — が挙げる日付が、
# 状態欄にも現れていることを見る。既存の 2 通りの綴りをどちらも拾う:
#
#   ### 4. …… (2026-08-28 改訂)          ← 決定見出しに併記する形
#   #### 改訂 (2026-08-30) — ……          ← 追記節を立てる形
#   ## 追補 — …… (2026-08-29)
#
# **日付を持たない見出しは拾わない。** ADR-0006 決定 6 は「ADR-0003 決定 1 の
# 権限表は改訂しない」で、素朴な grep はここで誤検出する。日付の有無が
# 「実際に改訂した」と「改訂について語っている」を分ける。
#
# 向きは片方向で、状態欄が見出しより多くを名乗るのは正常である。ADR-0020 は
# 改訂の見出しを持たないまま状態欄で「決定 7 を追加」と名乗っている。
#
# ## この検査が見ないもの
#
# **上書きされた側が `置換` を名乗っているか。** 上書きは散文で宣言される
# (ADR-0004 影響節「ADR-0002 決定 1 のうち分類の表現に関する部分は本 ADR が
# 上書きする」) ため、構造的な印が無い。ここを担うのは書く人とレビューで、
# 機械で見張る仕組みは実害が出てから足す (ADR-0008)。
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
# 参照の綴りを持ちようがないので、この検査の対象ではない
numbered=$(find "$DIR" -maxdepth 1 -name '[0-9][0-9][0-9][0-9]-*.md' | sort)

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

# --- 2. 状態欄の追随 ---------------------------------------------------------

# 「## 状態」の次に来る最初の非空行を状態欄とする
status_of() {
  awk '/^## 状態[[:space:]]*$/ { seen = 1; next } seen && NF { print; exit }' "$1"
}

# 改訂の見出しが挙げる日付 (重複を畳んで昇順)。1 つも無いのは正常なので、
# 空振りした grep で set -e に落ちないよう受ける
revision_dates_of() {
  grep -E '^#{2,4} ' "$1" \
    | grep -E '改訂|追補' \
    | grep -oE '20[0-9]{2}-[0-9]{2}-[0-9]{2}' \
    | sort -u || true
}

while IFS= read -r path; do
  dates=$(revision_dates_of "$path")
  status=$(status_of "$path")

  # 状態欄が読めないことを咎めるのは、追随すべき改訂を抱えているときだけに
  # とどめる。「ADR は 4 節を持つ」の検査はこの検査の責務ではない
  if [ -n "$dates" ] && [ -z "$status" ]; then
    echo "状態欄が読めない (「## 状態」節とその本文が要る): $path" >&2
    failed=1
    continue
  fi

  while IFS= read -r date; do
    [ -n "$date" ] || continue
    case "$status" in
      *"$date"*) ;;
      *)
        echo "改訂が状態欄に現れていない: $path" >&2
        echo "  本文の改訂: $date" >&2
        echo "  状態欄:     $status" >&2
        failed=1
        ;;
    esac
  done <<<"$dates"

  # 状態欄が指す ADR-00NN の実在。`一部置換 (→ ADR-0031)` のような
  # 指し先の不在を拾う (本文中のリンクは check-docs-links.py の担当)
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    number="${ref#ADR-}"
    if ! find "$DIR" -maxdepth 1 -name "$number-*.md" | grep -q .; then
      echo "状態欄が実在しない ADR を指している: $path" >&2
      echo "  指し先: $ref" >&2
      failed=1
    fi
  done <<<"$(grep -oE 'ADR-[0-9]{4}' <<<"$status" | sort -u || true)"
done <<<"$numbered"

if [ "$failed" -ne 0 ]; then
  echo "" >&2
  echo "状態欄の綴りは AGENTS.md 「ADR の状態欄」が持つ (#545)。" >&2
  exit 1
fi

echo "ok: ADR の番号は一意で、状態欄は改訂に追随している ($(wc -l <<<"$numbered" | tr -d ' ') 本検査)"
