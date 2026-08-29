#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# ADR の連番が一意であることを検査する (#500)。
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
  exit 1
fi

echo "ok: ADR の番号は一意 ($(wc -l <<<"$numbered" | tr -d ' ') 本検査)"
