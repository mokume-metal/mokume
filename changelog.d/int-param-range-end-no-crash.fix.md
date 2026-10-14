<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

上端が `Int.max` の範囲を持つ整数の `@Param` (`@Param(0...Int.max)`) へ、外から `Int.max` かその近くの値を書いても、スケッチが落ちなくなった。窓の段付きスライダーを右端まで寄せたときも同じで、落ちずに `Int.max` が入る ([#2478](https://github.com/mokume-metal/mokume/issues/2478))。

整数の範囲は端も整数のまま持ち、整数の値は `Int` のまま収めるので、2^53 を超える整数も丸まらず、宣言した端そのもの (`0...(Int.max - 1)` の `Int.max - 1` など) は範囲の中として入る。端の外は端へ収まり、応答の `clamped` に載る。応答の `min`・`max` も整数の宣言では整数のまま出る (`Int.max` が 2^63 の実数にならない)。
