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

cd "$(dirname "$0")/.."

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
  # scripts/check-observation-roundtrip.sh と同じ形にしてある
  python3 - "$WORK/.mokume/observe" "$SECONDS_TO_MEASURE" <<'REQUEST' &
import json, os, pathlib, sys, time

observe, limit = pathlib.Path(sys.argv[1]), float(sys.argv[2])
deadline = time.time() + limit
index = 0
while time.time() < deadline:
    index += 1
    identifier = f"m{index}"
    temporary = observe / ".request.json.tmp"
    temporary.write_text(json.dumps({"id": identifier, "scale": 0.5}))
    os.replace(temporary, observe / "request.json")
    answer = time.time() + 5
    while time.time() < answer:
        try:
            if json.loads((observe / "report.json").read_text()).get("id") == identifier:
                break
        except Exception:
            pass
        time.sleep(0.005)
REQUEST
  requester_pid=$!

  wait "$probe_pid" 2>/dev/null || true
  probe_pid=""
  kill "$requester_pid" 2>/dev/null || true
  requester_pid=""

  python3 - "$FPS_LOG" "$BASELINE_SECONDS" "$FLOOR_RATIO" <<'JUDGE'
import re, statistics, sys

log, baseline_seconds, floor_ratio = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
matches = (re.match(r"fps=([\d.]+)", line) for line in open(log))
rates = [float(m.group(1)) for m in matches if m]

# 観測が始まるまでの立ち上がりを落としてから基準を取る。**観測そのものの費用
# (60fps → 8fps) は基準の側に入る**ので、判定に残るのは「そこからさらに落ちるぶん」
# だけになる — #370 が見たいものはそれである
warmup = 5
sample = rates[warmup:]
if len(sample) < baseline_seconds + 10:
    print(f"NG 測れた秒数が足りない ({len(sample)} 行)")
    sys.exit(1)

baseline = statistics.median(sample[:baseline_seconds])
floor = baseline * floor_ratio
print(f"観測を始めた直後の水準 ({baseline_seconds} 秒ぶんの中央値): {baseline:.1f} fps")
print(f"下回ったら赤にする値: {floor:.1f} fps ({floor_ratio:.0%})")

after = sample[baseline_seconds:]
fell = [(warmup + baseline_seconds + i + 1, rate)
        for i, rate in enumerate(after) if rate < floor]
if fell:
    at, rate = fell[0]
    print(f"NG {at} 秒あたりで {rate:.1f} fps へ落ちた ({len(fell)} 秒ぶんが基準の下)")
    sys.exit(1)

print(f"ok 落ちなかった (以後の最低 {min(after):.1f} fps / 測った {len(sample)} 秒)")
# **緑はこの 1 回について以上のことを言わない。** 落ちるのは間欠なので、完了条件は
# 3 回続けて緑になることである (#370)
print("注意: 落ちるのは間欠 — 緑 1 回では足りない。3 回続けて回すこと (#370)")
JUDGE
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
