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
# **区切りの頭で名乗るのも同じにする** (#2457)。実行時の ShaderSource.assemble は、区切り
# (値の宣言・前置きの各ファイル・断片) ごとに `#line 1 "<名前>"` を差し、区切りの後に改行を
# 1 つ足す。ここも区切りごとに差す (part)。差さないと、同梱した断片の誤りが、つないだ一時の
# ファイルの行 (`Shapes.metal:1050`) で出る。名前は実行時の `mokume/<名前>.metal` ではなく、
# **木の中のパス** (`Sources/MokumeCore/Drawing/Shaders/Shapes.metal:12`) にする — ここで読むのは
# 本体を直す人で、開くのはそのファイルである。
#
# どの前置きを付けるかは置き場で決まる。
#
#   Shaders/               図形を塗る断片   値の宣言 + Kinds.metal + Common.metal
#   Shaders/Computations/  計算の断片       値の宣言 + Kinds.metal + Compute.metal
#   Shaders/Effects/       効果の断片       値の宣言 + Kinds.metal + Effect.metal
#   それ以外               単体で組み立てられる
#
# 前置きが 3 通りあるのは、書く側が受け取るものと返すものが違うためである (それぞれの
# 前置きの冒頭が理由を持つ)。置き場で分けているので、判定に中身を読む必要が無い。
#
# **Kinds.metal は 3 通りすべてに入る。** 種別番号の正本で、どの断片からも同じ名前で
# 読める必要があるためである (#802)。
#
# **前置きそのものは単体では確かめない。** どれも「呼ぶ先を利用者が書く」形なので
# 単体では組み上がらず、代わりに**その前置きを使う断片が 1 つでもあれば確かめられる**。
# 前置きを足したのに使う断片が無い、という状態は作らない。
set -euo pipefail

# **自分の隣を基準にする。** `$0` は source されると呼び出し側を指し、cwd にも依存する
# (#820)。`BASH_SOURCE` はこのファイル自身の場所で、`pwd -P` が symlink も解く
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# **在処を探すだけ (`--find`) にしない。** Xcode 26 のスタブは在処を持ったまま、起こすと
# コンポーネントが無いと言って落ちうる。探すだけだと、断片ごとに生のエラーが並ぶ
if ! xcrun metal --version >/dev/null 2>&1; then
  # スケッチのビルドは metal を使わない (断片は実行時に組む・#2351) ので、利用者向けの
  # README は Metal Toolchain を案内しない。入れ方を言うのはここだけになる
  echo "metal コンパイラが見つからない。この検査には Xcode と Metal Toolchain が要る" >&2
  echo "  (Xcode の Settings → Components、または xcodebuild -downloadComponent MetalToolchain)" >&2
  exit 1
fi

# 見るファイルは「git add -A したときに CI の木になるもの」(追跡 + 未追跡 − 無視・#2072)。
# find で作業ツリーを見ると、手元にだけ在る (無視された) 前置きで断片を組み立てて手元で
# 通り、前置きの無い CI の木では断片が単体で組まれて落ちる。index にだけ残る旧パス
# (git rm していない削除) は -f で落とす。名前は -z で割る (非 ASCII の名前は C 引用符
# つきで返る)
shaders=()
while IFS= read -r file; do shaders+=("$file"); done < <(
  git ls-files -z --cached --others --exclude-standard -- Sources |
    while IFS= read -r -d '' path; do
      # パターンを `(` で開く — macOS の /bin/bash (3.2) は <( ) の中の case の `)` を
      # プロセス置換の閉じと読み違える
      case "$path" in
        (*.metal) if [ -f "$path" ]; then printf '%s\n' "$path"; fi ;;
      esac
    done | sort
)

if [ ${#shaders[@]} -eq 0 ]; then
  echo "ok: シェーダは無い"
  exit 0
fi

# 前置きも同じ列挙から引く (無視された手元のものを在ると数えない)
first_named() {
  local name="$1" shader
  for shader in "${shaders[@]}"; do
    if [ "$(basename "$shader")" = "$name" ]; then
      printf '%s\n' "$shader"
      return
    fi
  done
}

kinds=$(first_named Kinds.metal)

common=$(first_named Common.metal)
common_dir=""
if [ -n "$common" ]; then common_dir=$(dirname "$common"); fi

compute=$(first_named Compute.metal)
compute_dir=""
if [ -n "$compute" ]; then compute_dir="$(dirname "$compute")/Computations"; fi

effect=$(first_named Effect.metal)
effect_dir=""
if [ -n "$effect" ]; then effect_dir="$(dirname "$effect")/Effects"; fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# 値の宣言。実行時は利用者が渡した値から組み立てるので、ここでは何も渡さないときの形
# (ShaderSource.declaration の分岐と同じ) を置く。名乗りは実行時と同じ `mokume/Values`
printf 'struct Values {\n    float4 mokume_unused;\n};\n' > "$work/values.metal"

# 区切り 1 つ: `#line 1 "<名前>"`・中身・改行 (ShaderSource.assemble と同じ形)。名前の `\` と
# `"` は逃がす (木の中のパスに改行や制御文字は無い)
part() {
  local name="${1//\\/\\\\}"
  name="${name//\"/\\\"}"
  printf '#line 1 "%s"\n' "$name"
  cat "$2"
  printf '\n'
}

# 前置きつきの断片を組み立てる: 値の宣言 → Kinds.metal → 前置き → 断片
assemble() {
  local prelude="$1" shader="$2"
  part mokume/Values "$work/values.metal"
  if [ -n "$kinds" ]; then part "$kinds" "$kinds"; fi
  part "$prelude" "$prelude"
  part "$shader" "$shader"
}

failed=0
for shader in "${shaders[@]}"; do
  # 前置きは飛ばす (上の理由)
  case "$shader" in "$common" | "$compute" | "$effect" | "$kinds") continue ;; esac
  source="$work/$(basename "$shader")"
  if [ -n "$effect_dir" ] && [ "$(dirname "$shader")" = "$effect_dir" ]; then
    assemble "$effect" "$shader" > "$source"
    label="$shader (効果の前置きつき)"
  elif [ -n "$compute_dir" ] && [ "$(dirname "$shader")" = "$compute_dir" ]; then
    assemble "$compute" "$shader" > "$source"
    label="$shader (計算の前置きつき)"
  elif [ -n "$common_dir" ] && [ "$(dirname "$shader")" = "$common_dir" ]; then
    assemble "$common" "$shader" > "$source"
    label="$shader (共通部分つき)"
  else
    # 単体で組む断片も、木の中のパスで名乗る (一時のファイルの名前で出さない)
    part "$shader" "$shader" > "$source"
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
