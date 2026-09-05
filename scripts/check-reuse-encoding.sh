#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# reuse が日本語の厚いヘッダを読み落とさないことを実地で確かめる (#48)。
#
# reuse 6.x は SPDX を探す前に、先頭 2048 バイトだけを encoding 判定器へ渡す
# (extract.HEURISTICS_CHUNK_SIZE)。判定器が None を返したファイルは「バイナリ」と
# 見なされ、中身を一切読まずに帰属情報なしとして扱われる。そして判定器の一つ
# charset_normalizer は、途中で切れた UTF-8 を渡されると None を返す。
# つまり 2048 バイト目がマルチバイト文字の途中に落ちると、そのファイルの SPDX
# ヘッダは丸ごと無視される — 日本語で厚く書くほど踏みやすい。
# 上流: https://codeberg.org/fsfe/reuse-tool/issues/1244 (open・修正待ち)
#
# 対処は判定モジュールの固定 (Makefile が REUSE_ENCODING_MODULE を渡す) だが、
# ここで検査するのは設定の中身ではなく症状の有無にする。設定が書き換わっても、
# reuse の既定が変わっても、この検査が実地で守る。
set -euo pipefail

command -v reuse >/dev/null 2>&1 || {
  echo "reuse が見つからない: make setup を参照" >&2
  exit 1
}

# 指定した判定モジュールが入っていないと reuse は import 時に落ちる。reuse 自身の
# 案内は charset_normalizer を勧めてくる (#48 を踏む側) ので、ここで踏まない道を示す
reuse --version >/dev/null 2>&1 || {
  cat >&2 <<EOF
reuse が起動できない (REUSE_ENCODING_MODULE=${REUSE_ENCODING_MODULE:-未指定})。
指定した判定モジュールが入っていない:

  pipx install reuse && pipx inject reuse chardet

Homebrew 版の reuse には chardet が同梱されていないため、入れ直しが要る。
EOF
  exit 1
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/LICENSES"
cp "$ROOT/LICENSES/MIT.txt" "$WORK/LICENSES/MIT.txt"

# 雛形は .py に出してある (#817)。組み方と、**雛形自身が 2048 バイト境界で文字を割って
# いること**の自己検査はあちらが持つ — 埋まったままでは lint も unittest も見ず、
# 詰め物が ASCII に変わって「何も検査しないまま緑」になっても気付けなかった
python3 "$ROOT/scripts/reuse_encoding_fixtures.py" "$WORK"

OUTPUT="$(reuse --root "$WORK" lint 2>&1)" && STATUS=0 || STATUS=$?

if [ "$STATUS" -eq 0 ]; then
  echo "ok: 2048 バイト境界が文字を割るファイルでも SPDX ヘッダを読めている"
  exit 0
fi

cat >&2 <<EOF
reuse が SPDX ヘッダを読み落とした (#48 の再発)。

先頭 2048 バイト目がマルチバイト文字の途中に落ちるファイルで、SPDX ヘッダが
あるのに「帰属情報が無い」と判定されている。原因は reuse の encoding 判定
モジュールで、charset_normalizer が選ばれていると起きる。

直し方 — 判定モジュールを chardet に固定する:

  pipx install reuse && pipx inject reuse chardet

Homebrew 版の reuse には chardet が同梱されていないため、そのままでは固定
できない (REUSE_ENCODING_MODULE=chardet を指定すると Traceback で落ちる)。

いま使われている判定モジュール:
$(reuse --debug --no-multiprocessing --root "$WORK" lint 2>&1 | grep -o "encoding module '[^']*'" | sort -u | sed 's/^/  /' || echo "  (判定できず)")

reuse lint の出力:
$(printf '%s' "$OUTPUT" | sed 's/^/  /')
EOF
exit 1
