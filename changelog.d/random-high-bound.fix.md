<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`random(low, high)` が `high` ちょうどを返すことがあったのを直しました。** `random(100, 110)` が 110 を返すことがあり、`array[Int(random(0, array.count))]` のような書き方が添字の範囲外で落ちえました。`low` が 0 でないときに、範囲へ移す計算で `Float` が上へ丸まっていたためです。引き直しではなく `high` の直前で止めるようにしたので、**乱数列の進み方は変わりません** — 同じ種からは以前と同じ列が出ます ([#1304](https://github.com/mokume-metal/mokume/issues/1304))。
