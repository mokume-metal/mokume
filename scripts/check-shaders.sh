#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# シェーダの原文をビルド時に組み立てて、誤りをここで落とす。
#
# シェーダの原文は資源として同梱し、実行時に組み立てる (SwiftPM は .metal を
# コンパイルせずそのまま運ぶだけなので、他に手がない)。すると**誤りは実行するまで
# 分からない**。しかも描画を要する検査は実行環境の制約で CI では走らない (#180) ので、
# 壊れたシェーダが緑のまま入ってしまう。
#
# そこでビルド時に一度だけ組み立てて、通ることを確かめる。生成物は捨てる —
# 欲しいのは合否であって成果物ではない。
set -euo pipefail

cd "$(dirname "$0")/.."

if ! xcrun --find metal >/dev/null 2>&1; then
  echo "metal コンパイラが見つからない (Xcode のツールチェーンが要る)" >&2
  exit 1
fi

shaders=()
while IFS= read -r file; do shaders+=("$file"); done < <(find Sources -name '*.metal' | sort)

if [ ${#shaders[@]} -eq 0 ]; then
  echo "ok: シェーダは無い"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failed=0
for shader in "${shaders[@]}"; do
  if xcrun metal -c "$shader" -o "$work/$(basename "$shader").air" 2>"$work/err"; then
    echo "ok: $shader"
  else
    echo "NG: $shader" >&2
    cat "$work/err" >&2
    failed=1
  fi
done

exit "$failed"
