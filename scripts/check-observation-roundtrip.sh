#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 窓を出して走らせているスケッチへ、観測の要求を続けて置き、すべてに応答が返るか数える。
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
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$(pwd)"

ROUNDS="${1:-100}"
DEADLINE="${2:-1.5}"

WORK="$(mktemp -d)"
SKETCH_PID=""
cleanup() {
  [ -n "$SKETCH_PID" ] && kill "$SKETCH_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# **いま手元にあるライブラリを測る。** ひな形が既定で指すのは公開済みの版なので、
# --local でこの作業ツリーへ向け直す
echo "== ひな形のスケッチを作る =="
swift run mokume-cli new roundtrip --path "$WORK" --local "$REPO" >/dev/null

SKETCH="$WORK/roundtrip"
echo "== 作って走らせる (窓が出る) =="
(cd "$SKETCH" && swift build >/dev/null)
mkdir -p "$SKETCH/.mokume/observe"
(cd "$SKETCH" && exec ./.build/debug/roundtrip) &
SKETCH_PID=$!
sleep 3

echo "== 観測の要求を $ROUNDS 回続けて置く =="
python3 - "$SKETCH/.mokume/observe" "$ROUNDS" "$DEADLINE" <<'PY'
import json, os, pathlib, sys, time

facet = pathlib.Path(sys.argv[1])
rounds, deadline = int(sys.argv[2]), float(sys.argv[3])
request, report = facet / "request.json", facet / "report.json"


def place(identifier):
    """要求を原子的に置く (ADR-0018 決定 3)。"""
    temporary = facet / ".request.json.tmp"
    temporary.write_text(json.dumps({"id": identifier}))
    os.replace(temporary, request)


def answered(identifier):
    """同じ識別子の応答が返るまで待つ。壁時計ではなく識別子の一致で完了を知る。"""
    limit = time.time() + deadline
    while time.time() < limit:
        try:
            if json.loads(report.read_text()).get("id") == identifier:
                return True
        except Exception:
            pass
        time.sleep(0.01)
    return False


missed = []
for index in range(1, rounds + 1):
    identifier = f"r{index}"
    place(identifier)
    if not answered(identifier):
        missed.append(index)

if missed:
    shown = ", ".join(str(i) for i in missed[:10])
    print(f"応答が返らなかった回: {shown}{' …' if len(missed) > 10 else ''}")
    print(f"NG {rounds - len(missed)}/{rounds}")
    sys.exit(1)
print(f"ok {rounds}/{rounds} すべてに応答が返った")
PY
