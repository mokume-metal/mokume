#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""観測の圧をかけ続ける口と、fps の判定 (#817)。

`scripts/measure-frame-rate.sh --observe` が使う 2 つ。**同じ 1 本の shell が使う 2 つ**
なので 1 ファイルに置く。

  pressure  識別子を変えながら要求を置き続ける (観測を続けている状態を作る)
  judge     fps のログから、基準に対して落ちたかを判定する

**shell の heredoc から出してある。** とくに `judge` は引数とログだけで決まる純関数で、
出せば絵も GPU も無しに unittest で固定できる (`example-shots.py` の `mirror_warnings` を
「境目の当て方を絵を撮らずに検められるようにするため」純関数にしてあるのと同じ形)。

置き方・待ち方は `observe_lib` が持つ (ADR-0018 決定 3 の正典はあちら 1 つ)。

使い方:
  python3 scripts/frame_rate_observe.py pressure <observe 区画> <続ける秒数>
  python3 scripts/frame_rate_observe.py judge <fps のログ> <基準の秒数> <割合>
"""

from __future__ import annotations

import pathlib
import re
import statistics
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from observe_lib import answered, place  # noqa: E402

# 応答を見に行く間隔。**要求を置き続ける側は短くする** — 1 往復ごとの空きを詰めるほど
# 観測が続いている状態に近づく (measure-frame-rate が測りたいのはその状態である)
PRESSURE_POLL_SECONDS = 0.005
# 1 往復ぶんの待ちの上限。越えたら次の識別子へ進む (止まらない)
PRESSURE_DEADLINE_SECONDS = 5
# 観測が始まるまでの立ち上がりとして落とす秒数
WARMUP_SECONDS = 5

FPS_LINE = re.compile(r"fps=([\d.]+)")


def pressure(observe: pathlib.Path, limit: float) -> int:
    """識別子を変えながら要求を置き続ける。呼び出し側が kill するまで戻らない。"""
    deadline = time.time() + limit
    index = 0
    while time.time() < deadline:
        index += 1
        identifier = f"m{index}"
        place(observe, {"id": identifier, "scale": 0.5})
        answered(
            observe,
            identifier,
            PRESSURE_DEADLINE_SECONDS,
            poll=PRESSURE_POLL_SECONDS,
        )
    return 0


def rates_in(text: str) -> list[float]:
    """ログから fps の並びを取り出す。**行頭の `fps=` だけを読む。**"""
    matches = (FPS_LINE.match(line) for line in text.splitlines())
    return [float(m.group(1)) for m in matches if m]


def judgment(rates: list[float], baseline_seconds: int, floor_ratio: float) -> tuple[int, list[str]]:
    """(終了コード, 出す行) を返す純関数。

    観測が始まるまでの立ち上がりを落としてから基準を取る。**観測そのものの費用
    (60fps → 8fps) は基準の側に入る**ので、判定に残るのは「そこからさらに落ちるぶん」
    だけになる — #370 が見たいものはそれである。
    """
    sample = rates[WARMUP_SECONDS:]
    if len(sample) < baseline_seconds + 10:
        return 1, [f"NG 測れた秒数が足りない ({len(sample)} 行)"]

    lines = []
    baseline = statistics.median(sample[:baseline_seconds])
    floor = baseline * floor_ratio
    lines.append(f"観測を始めた直後の水準 ({baseline_seconds} 秒ぶんの中央値): {baseline:.1f} fps")
    lines.append(f"下回ったら赤にする値: {floor:.1f} fps ({floor_ratio:.0%})")

    after = sample[baseline_seconds:]
    fell = [
        (WARMUP_SECONDS + baseline_seconds + i + 1, rate)
        for i, rate in enumerate(after)
        if rate < floor
    ]
    if fell:
        at, rate = fell[0]
        lines.append(f"NG {at} 秒あたりで {rate:.1f} fps へ落ちた ({len(fell)} 秒ぶんが基準の下)")
        return 1, lines

    lines.append(f"ok 落ちなかった (以後の最低 {min(after):.1f} fps / 測った {len(sample)} 秒)")
    # **緑はこの 1 回について以上のことを言わない。** 落ちるのは間欠なので、完了条件は
    # 3 回続けて緑になることである (#370)
    lines.append("注意: 落ちるのは間欠 — 緑 1 回では足りない。3 回続けて回すこと (#370)")
    return 0, lines


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    if argv[1] == "pressure":
        return pressure(pathlib.Path(argv[2]), float(argv[3]))
    if argv[1] == "judge":
        text = pathlib.Path(argv[2]).read_text(encoding="utf-8", errors="replace")
        status, lines = judgment(rates_in(text), int(argv[3]), float(argv[4]))
        for line in lines:
            print(line)
        return status
    print(f"不明な口: {argv[1]}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
