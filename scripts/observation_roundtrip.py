#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""観測と入力の要求を続けて置き、すべてに応答が返るか数える (#817)。

`scripts/check-observation-roundtrip.sh` が窓を出した後に呼ぶ口。#221 / #223 の
受け入れ条件そのものを測る。

**shell の heredoc から出してある。** 埋まったままでは lint も Python の道具も見ず、
しかもこの手順は画面と GPU が要るので `make ci-check` に入っていない — 壊れていても
誰も気付かない状態だった。出したことで `scripts/tests/observe_lib_test.py` が、偽の
スケッチ役を相手に GPU 無しでこの経路を通せる。

置き方・待ち方は `observe_lib` が持つ (ADR-0018 決定 3 の正典はあちら 1 つ)。

使い方:
  python3 scripts/observation_roundtrip.py <.mokume の場所> <回数> <1 回の待ちの上限>
"""

from __future__ import annotations

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from observe_lib import answered, place  # noqa: E402


def main(argv: list[str]) -> int:
    root = pathlib.Path(argv[1])
    rounds, deadline = int(argv[2]), float(argv[3])
    observe, inbox = root / "observe", root / "input"

    missed: dict[str, list[int]] = {"観測": [], "入力": []}
    # フレームが進み続けているか。**応答が返るだけでは足りない** — 止まったランタイムでも
    # 観測には応えられる (ADR-0018) ので、番号が動いていることまで見て絵の生死を分ける
    frames: list[int] = []
    for index in range(1, rounds + 1):
        identifier = f"r{index}"
        place(observe, {"id": identifier})
        place(inbox, {"id": identifier, "events": [{"type": "mouseMoved", "x": 1, "y": 2}]})

        report = answered(observe, identifier, deadline)
        if report is None:
            missed["観測"].append(index)
        else:
            frames.append(report.get("frame", 0))
        if answered(inbox, identifier, deadline) is None:
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

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
