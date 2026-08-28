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
#
# ## 組み立て方は実行時と同じにする
#
# 図形を塗る断片は、単体ではコンパイルできない。実行時は「値の宣言 → 共通部分 →
# 断片」の順で 1 本に組み立ててから渡す (Sources/MokumeCore/Drawing/ShaderSource.swift)。
# ここも同じ順で組み立てる — **1 本ずつ分けて確かめると、実行時に通る組み合わせを
# 落とすか、逆に実行時に落ちる組み合わせを通してしまう。**
#
# どの断片が図形を塗るものかは置き場で決まる: 共通部分 (Common.metal) と同じ
# ディレクトリにあるものがそれで、他の場所にあるものは単体で組み立てられる。
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

common=$(find Sources -name 'Common.metal' | head -1)
common_dir=""
if [ -n "$common" ]; then common_dir=$(dirname "$common"); fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# 値の宣言。実行時は利用者が渡した値から組み立てるので、ここでは何も渡さないときの形
# (ShaderSource.declaration の分岐と同じ) を置く
printf 'struct Values {\n    float4 mokume_unused;\n};\n' > "$work/values.metal"

failed=0
for shader in "${shaders[@]}"; do
  [ "$shader" = "$common" ] && continue
  source="$work/$(basename "$shader")"
  if [ -n "$common_dir" ] && [ "$(dirname "$shader")" = "$common_dir" ]; then
    cat "$work/values.metal" "$common" "$shader" > "$source"
    label="$shader (共通部分つき)"
  else
    cp "$shader" "$source"
    label="$shader"
  fi
  if xcrun metal -c "$source" -o "$source.air" 2>"$work/err"; then
    echo "ok: $label"
  else
    echo "NG: $label" >&2
    cat "$work/err" >&2
    failed=1
  fi
done

exit "$failed"
