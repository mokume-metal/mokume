#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 本体の PR が mokume-syphon を壊したかを、PR の時点で知らせる (#1973)。render.yml の
# render-pr の最後の段がこれを呼ぶ。
#
# **知らせるだけで、merge は止めない。** 段は continue-on-error で、render-pr は必須でもない。
# 外のリポジトリの検査が不安定でも、Syphon と無関係な本体の PR を止めないためである。
#
# **この PR が壊したのか、もう壊れていたのかを分ける。** 本体の木 (pull_request の合流
# ref・HEAD) で mokume-syphon の検査が落ちたときだけ、base の木 (HEAD^1) でも走らせる。
# 壊す変更が一度 main に入ると、mokume-syphon が追随するまで後の全 PR で同じ赤が出るので、
# 比べなければ「この PR の赤」と「前からの赤」の見分けが付かない。base を走らせるのは
# head が落ちた回だけなので、普段の所要は増えない。
#
# **ライブラリに触れた PR だけを見る。** HEAD^1 と HEAD の差が下の LIBRARY_PATHS に
# 触れなければ、mokume-syphon から見える本体は変わらないので走らせない。
# SYPHON_CHECK_FORCE=1 で判定を飛ばして走らせる (段そのものを確かめるときの口)。
#
# 専用機の job は token を持ち込まない (ADR-0019 決定 7) ので、変更ファイルは GitHub の
# API ではなく合流 commit の 2 つの親の差から取る (例の絵の比較と同じ)。
#
# ## 使い方 (本体の木の根で)
#
#   bash scripts/syphon-check-pr.sh
#
#   SYPHON_CHECK_WORK    作業場所 (既定 .build/syphon-check)
#   SYPHON_CHECK_SCRIPT  1 つの木を検査するもの (既定 scripts/syphon-check.sh。テストが差し替える)
#
# 結論は annotation (::warning:: / ::notice::) と、GITHUB_STEP_SUMMARY があればそこへ書く。
# 終了コードは「この PR が壊した」と「判定できない」のときだけ 1 (段に赤い印が付く)。
#
# テストは scripts/tests/syphon_check_test.py。
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(pwd)"
work="${SYPHON_CHECK_WORK:-$root/.build/syphon-check}"
check="${SYPHON_CHECK_SCRIPT:-$here/syphon-check.sh}"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

# mokume-syphon から見える本体。ここに触れない PR は、mokume-syphon の結果を変えない
LIBRARY_PATHS="Sources/ Package.swift Package.resolved"

touches_library() {
  local f p
  while IFS= read -r f; do
    for p in $LIBRARY_PATHS; do
      case "$f" in
        "$p"*) return 0 ;;
      esac
    done
  done
  return 1
}

describe() {
  case "$1" in
    10) echo "組めない" ;;
    20) echo "検査が落ちた" ;;
    30) echo "GPU の検査が走っていない" ;;
    *) echo "判定できない (終了コード $1)" ;;
  esac
}

say() {
  # annotation は 1 行。要約には見出しを付けて書く
  echo "::$1 title=mokume-syphon::$2"
  printf '### mokume-syphon\n\n%s\n\n' "$2" >> "$summary"
}

if [ "${SYPHON_CHECK_FORCE:-}" != "1" ]; then
  if ! files=$(git diff --name-only HEAD^1 HEAD); then
    say warning "変更ファイルを取れない (HEAD^1 が無い)。mokume-syphon の検査は走らせていない"
    exit 1
  fi
  if ! touches_library <<<"$files"; then
    echo "ライブラリ ($LIBRARY_PATHS) に触れていないので、mokume-syphon は検査しない"
    exit 0
  fi
fi

failure_messages() {
  local record="$1/syphon-results-swift-testing.xml"
  if [ -f "$record" ]; then
    python3 "$here/read-test-record.py" --failure-messages "$record" >> "$summary" || true
  fi
}

bash "$check" "$root" "$work/head"
head_status=$?

case "$head_status" in
  0)
    say notice "この PR の木で mokume-syphon を組み、GPU の検査まで通った"
    exit 0
    ;;
  30)
    say warning "この PR の木で mokume-syphon の GPU の検査が走っていない — この機械で GPU が見えていない"
    exit 0
    ;;
  10 | 20) ;;
  *)
    say warning "この PR の木で mokume-syphon を$(describe "$head_status")"
    exit 1
    ;;
esac

# head で落ちた。base の木でも走らせて、この PR が壊したのかを見分ける
base_tree="$work/base-tree"
git worktree remove --force "$base_tree" >/dev/null 2>&1 || rm -rf "$base_tree"
if ! git worktree add --quiet --detach "$base_tree" HEAD^1; then
  say warning "この PR の木で mokume-syphon が$(describe "$head_status")。base の木を出せず、この PR が壊したかは見分けていない"
  failure_messages "$work/head"
  exit 1
fi
bash "$check" "$base_tree" "$work/base"
base_status=$?
git worktree remove --force "$base_tree" >/dev/null 2>&1 || true

case "$base_status" in
  0)
    say warning "この PR が mokume-syphon を壊した — base の木では通り、この PR の木では$(describe "$head_status")。本体の側で直すか、mokume-syphon に追随の Issue を立てる"
    failure_messages "$work/head"
    exit 1
    ;;
  10 | 20)
    say notice "mokume-syphon は base の木でも$(describe "$base_status") — この PR より前から壊れている (この PR の木では$(describe "$head_status"))"
    exit 0
    ;;
  *)
    say warning "この PR の木で mokume-syphon が$(describe "$head_status")。base の木では$(describe "$base_status")ので、この PR が壊したかは見分けていない"
    failure_messages "$work/head"
    exit 1
    ;;
esac
