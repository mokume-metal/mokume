#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 窓を出して走らせているスケッチへ、観測と入力の要求を続けて置き、すべてに応答が返るか
# 数える。フレーム番号が進み続けていることも同時に見る。
#
# #221 の受け入れ条件そのもの。区画のファイルを直に叩くので、道具 (窓口・見張り) を
# 挟まずに面だけを測る — 面の能力が窓口の実装に閉じ込められていないことは ADR-0018
# 決定 1 の前提でもある。
#
# **画面と GPU が要るので `make ci-check` には入れない** (#180)。手元で確かめる手順を
# 毎回組み直さずに済ませるために置いてある。
#
# 使い方:
#   scripts/check-observation-roundtrip.sh [回数] [1 回あたりの待ちの上限 (秒)]
#   scripts/check-observation-roundtrip.sh --minimized [回数] [待ちの上限]
#
# --minimized は #223 の受け入れ条件。窓を畳んでも面が応答し続けることを見る。
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$(pwd)"

MINIMIZED=0
if [ "${1:-}" = "--minimized" ]; then
  MINIMIZED=1
  shift
fi

ROUNDS="${1:-100}"
DEADLINE="${2:-1.5}"

WORK="$(mktemp -d)"
SKETCH_PID=""
cleanup() {
  [ -n "$SKETCH_PID" ] && kill "$SKETCH_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

if [ "$MINIMIZED" = 1 ]; then
  # **測る側に自分で畳ませる。** よそのプロセスの窓を osascript から畳むには
  # アクセシビリティの許可が要り、許可の無い環境では「面が応答しなかった」と
  # 「窓を畳めなかった」を区別できない (#223)
  echo "== 測るための窓を出す (3 秒後に自分で畳む) =="
  swift build >/dev/null
  FACETS="$WORK"
  mkdir -p "$FACETS/.mokume/observe" "$FACETS/.mokume/input"
  MOKUME_WORK_DIR="$FACETS" ./.build/debug/frame-rate-probe \
    --seconds "$((ROUNDS * 2 + 60))" --minimize-after 3 >/dev/null &
  SKETCH_PID=$!
  sleep 6
else
  # **いま手元にあるライブラリを測る。** ひな形が既定で指すのは公開済みの版なので、
  # --local でこの作業ツリーへ向け直す
  echo "== ひな形のスケッチを作る =="
  swift run mokume-cli new roundtrip --path "$WORK" --local "$REPO" >/dev/null

  SKETCH="$WORK/roundtrip"
  echo "== 作って走らせる (窓が出る) =="
  (cd "$SKETCH" && swift build >/dev/null)
  FACETS="$SKETCH"
  mkdir -p "$FACETS/.mokume/observe" "$FACETS/.mokume/input"
  (cd "$SKETCH" && exec ./.build/debug/roundtrip) &
  SKETCH_PID=$!
  sleep 3
fi

echo "== 観測と入力の要求を $ROUNDS 回続けて置く =="
python3 - "$FACETS/.mokume" "$ROUNDS" "$DEADLINE" <<'PY'
import json, os, pathlib, sys, time

root = pathlib.Path(sys.argv[1])
rounds, deadline = int(sys.argv[2]), float(sys.argv[3])
observe, inbox = root / "observe", root / "input"


def place(facet, payload):
    """要求を原子的に置く (ADR-0018 決定 3)。"""
    temporary = facet / ".request.json.tmp"
    temporary.write_text(json.dumps(payload))
    os.replace(temporary, facet / "request.json")


def answered(facet, identifier):
    """同じ識別子の応答が返るまで待つ。壁時計ではなく識別子の一致で完了を知る。"""
    limit = time.time() + deadline
    while time.time() < limit:
        try:
            report = json.loads((facet / "report.json").read_text())
            if report.get("id") == identifier:
                return report
        except Exception:
            pass
        time.sleep(0.01)
    return None


missed = {"観測": [], "入力": []}
# フレームが進み続けているか。**応答が返るだけでは足りない** — 止まったランタイムでも
# 観測には応えられる (ADR-0018) ので、番号が動いていることまで見て絵の生死を分ける
frames = []
for index in range(1, rounds + 1):
    identifier = f"r{index}"
    place(observe, {"id": identifier})
    place(inbox, {"id": identifier, "events": [{"type": "mouseMoved", "x": 1, "y": 2}]})

    report = answered(observe, identifier)
    if report is None:
        missed["観測"].append(index)
    else:
        frames.append(report.get("frame", 0))
    if answered(inbox, identifier) is None:
        missed["入力"].append(index)

failed = False
for name, indexes in missed.items():
    if indexes:
        failed = True
        shown = ", ".join(str(i) for i in indexes[:10])
        print(f"{name}: 応答が返らなかった回 {shown}{' …' if len(indexes) > 10 else ''}")
    print(f"{'NG' if indexes else 'ok'} {name} {rounds - len(indexes)}/{rounds}")

if len(frames) >= 2 and frames[-1] <= frames[0]:
    failed = True
    print(f"NG フレームが進んでいない ({frames[0]} → {frames[-1]})")
elif frames:
    print(f"ok フレームは進み続けた ({frames[0]} → {frames[-1]})")

sys.exit(1 if failed else 0)
PY
