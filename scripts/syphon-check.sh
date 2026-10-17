#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 外のパッケージ mokume-syphon の main を、指定した本体の木に向けて組み、検査する (#1973)。
#
# 本体の変更が mokume-syphon を壊しても、本体の PR の時点では誰も気付かない。気付くのは
# mokume-syphon が新しい版へ追随したときで、そのとき本体は壊した版をもう出している
# (mokume-metal/mokume-syphon#26 は API の一覧の差分に出ない振る舞いの変化だった)。
# ここは mokume-syphon の木を取り、依存の mokume を `swift package edit --path` で渡された
# 木へ差し替えて (版の指定を無視して、その木で組む)、build と test を走らせる。
#
# **GPU の検査が走ったことまで確かめる。** mokume-syphon の送出・受け取りの検査は
# `RenderDevice.isAvailable` の門の内側にあり、GPU が見えない機械では Suite ごと飛んで
# 緑になる。gpu-ran (Makefile) と同じく、記録 (xunit) を読んで代表の Suite が通ったことを見る。
#
# PR の上で head と base を比べる口は scripts/syphon-check-pr.sh が持つ (render.yml の
# render-pr)。手元からは make syphon-check で、この木に向けて走る。
#
# ## 使い方
#
#   bash scripts/syphon-check.sh <本体の木> <作業場所>
#
# 作業場所 (無ければ作る) に mokume-syphon を clone し、記録をそこへ書く。
#   SYPHON_REPO  clone 元 (既定は本体と同じ owner の mokume-syphon)
#   SYPHON_REF   取る枝 (既定 main)
#
# ## 終了コード
#
#   0  通った (GPU の検査も走った)
#   10 組めない (swift package edit か swift build が落ちた)
#   20 検査が落ちた
#   30 GPU の検査が走っていない (この機械で GPU が見えていない・Suite が記録に無い)
#   それ以外  判定できない (clone できない・引数の誤り・記録を読めない)
#
# テストは scripts/tests/syphon_check_test.py。
set -uo pipefail

if [ "$#" -ne 2 ]; then
  echo "使い方: bash scripts/syphon-check.sh <本体の木> <作業場所>" >&2
  exit 2
fi

here="$(cd "$(dirname "$0")" && pwd)"
tree="$(cd "$1" && pwd)" || exit 2
work="$2"
# clone 元は本体と同じ owner の mokume-syphon (ADR-0019 決定 7 の追補・同じ org のものだけを
# 専用機へ届ける)。owner は repo-slug.sh の this_repo から取る (literal をそこに 1 つに保つ)
. "$here/repo-slug.sh"
owner="$(this_repo)"
repo="${SYPHON_REPO:-https://github.com/${owner%%/*}/mokume-syphon.git}"
ref="${SYPHON_REF:-main}"

# 代表の Suite。どちらも Suite 全体が RenderDevice.isAvailable で飛ぶ
GPU_SUITES="MokumeSyphonTests.SyphonRoundTripTests MokumeSyphonTests.SyphonReceiveTests"

mkdir -p "$work" || exit 3
# 下で mokume-syphon の木へ移るので、相対で渡された作業場所をここで絶対に直す
work="$(cd "$work" && pwd)" || exit 3
syphon="$work/mokume-syphon"
rm -rf "$syphon"
if ! git clone --quiet --depth 1 --branch "$ref" "$repo" "$syphon"; then
  echo "syphon-check: mokume-syphon を clone できない: $repo ($ref)" >&2
  exit 3
fi
echo "syphon-check: mokume-syphon $(git -C "$syphon" rev-parse --short HEAD) を $tree に向けて組む"

cd "$syphon" || exit 3

if ! swift package edit mokume --path "$tree"; then
  echo "syphon-check: 依存の mokume を $tree へ差し替えられない" >&2
  exit 10
fi
if ! swift build --build-tests; then
  echo "syphon-check: 組めない" >&2
  exit 10
fi

# 記録の名前は SwiftPM が test ライブラリの名を挟んで決める (Makefile の TEST_RECORD と同じ)
record="$work/syphon-results-swift-testing.xml"
rm -f "$record"
python3 "$here/gpu-slot.py" -- swift test --skip-build --xunit-output "$work/syphon-results.xml"
test_status=$?

if [ ! -f "$record" ]; then
  echo "syphon-check: test の記録が無い (${record}・swift test の終了コード $test_status)" >&2
  exit 4
fi

failed=0
not_ran=0
for suite in $GPU_SUITES; do
  read -r verdict _ < <(python3 "$here/read-test-record.py" "$record" "$suite")
  case "$verdict" in
    passed) echo "syphon-check: ok: $suite が通った" ;;
    failed) echo "syphon-check: $suite が落ちている" >&2; failed=1 ;;
    skipped) echo "syphon-check: $suite が飛ばされている — この機械で GPU が見えていない" >&2; not_ran=1 ;;
    absent) echo "syphon-check: $suite が記録に無い" >&2; not_ran=1 ;;
    *) echo "syphon-check: 記録を読めない ($record)" >&2; exit 4 ;;
  esac
done

# 代表の外で落ちた検査も赤に数える。swift test が 0 以外で終わったのに記録に落ちた検査が
# 無いときは、検査の赤ではない (枠の待ちの期限・途中で落ちた) ので判定できないと名乗る
read -r _ failures < <(python3 "$here/read-test-record.py" --failures "$record")
if [ "$failed" -ne 0 ] || [ "${failures:-0}" != "0" ]; then
  exit 20
fi
if [ "$test_status" -ne 0 ]; then
  echo "syphon-check: swift test が $test_status で終わったが、記録に落ちた検査が無い" >&2
  exit 4
fi
if [ "$not_ran" -ne 0 ]; then
  exit 30
fi
exit 0
