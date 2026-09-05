#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# フレームレートを前面・背面・最小化の 3 条件で測る。--observe を付けると、4 つ目の条件
# 「背面 + 観測を続ける」だけを測って**数字ではなく合否**を返す (#370 の完了条件がこの判定)。
#
# ADR-0012 決定 5 は「アプリの窓が画面に出ていない状態でも描画のフレームレートが
# 落ちない」ことを機能要件として固定している。ここはその要件を確かめる手順で、
# **測ってから判断する** (ADR-0008 決定 1)。4 つ目を別のスクリプトに切らないのは、
# 問うているものが 3 条件とまったく同じだからである。
#
# **1 つのプロセスで 1 つの条件だけを測る。** 同じプロセスで前面 → 背面と続けて測ると、
# 前の条件が残した状態 (確保済みの資源・温まったキャッシュ) が次の数字に混ざる。
#
# 使い方:
#   scripts/measure-frame-rate.sh [1 条件あたりの秒数]
#   scripts/measure-frame-rate.sh --observe [秒数]
#
# 画面が要る。ヘッドレスの実行環境では走らない。
set -euo pipefail

# **自分の隣を基準にする。** `$0` は source されると呼び出し側を指し、cwd にも依存する
# (#820)。`BASH_SOURCE` はこのファイル自身の場所で、`pwd -P` が symlink も解く
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

if [ "${1:-}" = "--observe" ]; then
  shift
  # 既定は 3 分。落ちるときは 48〜95 秒あたりだったので、それを跨ぐ長さが要る
  SECONDS_TO_MEASURE="${1:-180}"
  # 観測を始めた直後の水準をここで決める (秒)
  BASELINE_SECONDS=15
  # 基準に対してここまで落ちたら赤
  FLOOR_RATIO=0.5

  WORK="$(mktemp -d)"
  FPS_LOG="$WORK/fps.log"
  probe_pid=""
  requester_pid=""
  cleanup() {
    [ -n "$probe_pid" ] && kill "$probe_pid" 2>/dev/null
    [ -n "$requester_pid" ] && kill "$requester_pid" 2>/dev/null
    rm -rf "$WORK"
  }
  trap cleanup EXIT

  echo "== 背面 + 観測を続ける (${SECONDS_TO_MEASURE} 秒) =="
  swift build >/dev/null
  # **区画は起動より先に作る。** 観測が有効になるのは起動の瞬間に区画があるときだけである
  mkdir -p "$WORK/.mokume/observe"
  MOKUME_WORK_DIR="$WORK" ./.build/debug/frame-rate-probe \
    --seconds "$((SECONDS_TO_MEASURE + 10))" >"$FPS_LOG" 2>&1 &
  probe_pid=$!
  sleep 3
  osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1 || true
  sleep 1

  # 識別子を変えながら要求を置き続ける。置き方と待ち方は ADR-0018 決定 3 の規約で、
  # **実装は scripts/observe_lib.py の 1 つだけ**である (#817 まではここと
  # check-observation-roundtrip.sh に写しがあり、コメントがそれを自白していた)
  python3 scripts/frame_rate_observe.py pressure \
    "$WORK/.mokume/observe" "$SECONDS_TO_MEASURE" &
  requester_pid=$!

  wait "$probe_pid" 2>/dev/null || true
  probe_pid=""
  kill "$requester_pid" 2>/dev/null || true
  requester_pid=""

  # 判定は純関数なので .py に出してある。中央値 → 閾値 → 最初に割った秒という組み立ては
  # 絵も GPU も無しに unittest で固定できる (#817)
  python3 scripts/frame_rate_observe.py judge \
    "$FPS_LOG" "$BASELINE_SECONDS" "$FLOOR_RATIO"
  exit $?
fi

SECONDS_TO_MEASURE="${1:-7}"

echo "== 前面 =="
swift run frame-rate-probe --seconds "$SECONDS_TO_MEASURE"

echo
echo "== 背面 =="
# 起動してから別のアプリを前面に出し、測る側を背面へ回す
swift run frame-rate-probe --seconds "$SECONDS_TO_MEASURE" &
probe_pid=$!
sleep 3
osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1 || true
wait "$probe_pid"

echo
echo "== 最小化 =="
# **測る側に自分で畳ませる。** よそのプロセスの窓を osascript から畳むには
# アクセシビリティの許可が要り、許可の無い環境では「フレームが落ちた」と
# 「窓を畳めなかった」を区別できない (#223)
swift run frame-rate-probe --seconds "$SECONDS_TO_MEASURE" --minimize-after 3
