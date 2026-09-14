#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# make ci-check の段を 1 つずつ走らせ、いまどこに居てあとどれくらいかを名乗る (#1182)。
#
#   bash scripts/ci-check.sh <段...>     (呼ぶのは Makefile の ci-check。段の並びの正典もあちら)
#
# **並びは 1 つずつ・落ちたらそこで止まる。** 1 段でも非 0 を返せば後段を走らせず、
# その終了コードで抜ける。render-status を最後に置いて「全部が通ったときだけ手元の
# 実行を報告する」並びの意味 (Makefile の CI_CHECK_STEPS) は、ここで崩さない。
#
# **名乗るのは 3 つ。**
#   1. 各段の前に `[n/N] 段名` と、全体の経過・前回の所要
#   2. 段が続く間、一定の間隔 (既定 30 秒) ごとに継続中の 1 行
#   3. 最後に全体の所要と長かった段 / 落ちたらどの段で止まったか
#
# 2 が要るのは、無音の区間が段の中にあるためである。実測 (#1182) では swift test の出力が
# パイプ越しにまとめて吐かれて約 80 秒黙り、hooks-test は約 135 秒のあいだドットが 2 回
# 出るだけだった。段の出力には手を入れず (swift test の console は #1056 の上流の挙動)、
# 外から「まだ走っている」を足す。
#
# **段ごとに build を組み直さない。** examples / params / api / reference は build を
# prerequisite に持つので、段ごとに make を起こすと no-op の swift build が毎回走る
# (1 回 2.5 秒・手元の実測)。この実行の中で build 段が通った後は `-o build` を渡し、
# 済んだものとして扱わせる。build 段を含まない並びで呼ばれたら付けない (組まずに
# 走るのを防ぐ)。
#
# **前回の所要は .build/ci-check-durations.tsv に置く** (段名 TAB 秒)。通った段だけを
# 書き足して上書きするので、途中で落ちた実行も次の名乗りに効く。無ければ「前回」を
# 名乗らない — CI の clean な runner ではいつもそうなる。
#
# 環境変数:
#   MAKE                 段を走らせる make (Makefile が $(MAKE) を渡す。既定は make)
#   CI_CHECK_HEARTBEAT   継続中の行の間隔 (秒・既定 30)。検査を短時間で回すための口
# テストは scripts/tests/ci_check_test.py。
set -uo pipefail

MAKE="${MAKE:-make}"
INTERVAL="${CI_CHECK_HEARTBEAT:-30}"
RECORD=.build/ci-check-durations.tsv

if [ "$#" -eq 0 ]; then
  echo "使い方: ci-check.sh <段...>" >&2
  exit 2
fi

steps=("$@")
total=${#steps[@]}

# 秒を読みやすく綴る。1 分未満は秒だけ
span() {
  if [ "$1" -lt 60 ]; then
    printf '%ds' "$1"
  else
    printf '%dm%02ds' $(($1 / 60)) $(($1 % 60))
  fi
}

# 前回その段にかかった秒数。記録が無ければ空
previous() {
  [ -f "$RECORD" ] || return 0
  awk -F '\t' -v s="$1" '$1 == s { print $2 }' "$RECORD" | tail -n 1
}

remember() {
  mkdir -p "$(dirname "$RECORD")"
  local tmp="$RECORD.tmp"
  { [ -f "$RECORD" ] && awk -F '\t' -v s="$1" '$1 != s' "$RECORD"
    printf '%s\t%s\n' "$1" "$2"; } > "$tmp" && mv "$tmp" "$RECORD"
}

# 前回の全体は、今回の並びの段が全部記録にあるときだけ足し上げる (欠けた和は嘘になる)
previous_total=0
for step in "${steps[@]}"; do
  sec="$(previous "$step")"
  if [ -z "$sec" ]; then
    previous_total=""
    break
  fi
  previous_total=$((previous_total + sec))
done

heartbeat_pid=""
stop_heartbeat() {
  [ -n "$heartbeat_pid" ] || return 0
  kill "$heartbeat_pid" 2>/dev/null
  wait "$heartbeat_pid" 2>/dev/null
  heartbeat_pid=""
}
trap stop_heartbeat EXIT
trap 'stop_heartbeat; exit 130' INT
trap 'stop_heartbeat; exit 143' TERM

started=$SECONDS
built=0
summary=""

for i in "${!steps[@]}"; do
  step="${steps[$i]}"
  n=$((i + 1))
  prev="$(previous "$step")"

  note="経過 $(span $((SECONDS - started)))"
  [ -n "$prev" ] && note="$note · 前回この段 $(span "$prev")"
  [ -n "$previous_total" ] && note="$note · 前回全体 $(span "$previous_total")"
  printf '━━ [%*d/%d] %s  (%s)\n' "${#total}" "$n" "$total" "$step" "$note"

  step_started=$SECONDS
  # 背面で継続中を名乗る。sleep には出力を持たせない — kill した後も sleep は残りの
  # 間隔だけ生き延びるので、端末やパイプを握らせると読み手が EOF を待たされる。
  # 親が消えたら自分も抜ける (kill -9 で trap が走らなかった場合の保険)
  (
    parent=$$
    while sleep "$INTERVAL" </dev/null >/dev/null 2>&1; do
      kill -0 "$parent" 2>/dev/null || exit 0
      line="   … $step 継続中 $(span $((SECONDS - step_started)))"
      [ -n "$prev" ] && line="$line (前回 $(span "$prev"))"
      printf '%s\n' "$line"
    done
  ) &
  heartbeat_pid=$!

  options=(--no-print-directory)
  [ "$built" -eq 1 ] && options+=(-o build)
  "$MAKE" "${options[@]}" "$step"
  rc=$?
  stop_heartbeat

  took=$((SECONDS - step_started))
  if [ "$rc" -ne 0 ]; then
    printf '✘ ci-check は [%d/%d] %s で止まった (終了コード %d · 経過 %s)\n' \
      "$n" "$total" "$step" "$rc" "$(span $((SECONDS - started)))"
    exit "$rc"
  fi

  remember "$step" "$took"
  [ "$step" = build ] && built=1
  summary="$summary$took	$step
"
done

longest="$(printf '%s' "$summary" | sort -t "$(printf '\t')" -k1,1 -rn | head -n 3 \
  | while IFS="$(printf '\t')" read -r sec name; do printf '%s %s / ' "$name" "$(span "$sec")"; done)"
printf '✔ ci-check %d 段通過 %s — 長かった段: %s\n' \
  "$total" "$(span $((SECONDS - started)))" "${longest% / }"
