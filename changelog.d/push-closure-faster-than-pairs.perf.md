<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

閉包で変換とスタイルを戻す `push { }` が速くなり、`push()` と `pop()` を対で書くより速くなりました。外で 1 段積んだ部品の中で `push { translate(1, 0) }` を繰り返すと、1 回の CPU 時間が 約 207 ns → 約 98 ns です (同じ条件の `push()`・`translate(1, 0)`・`pop()` は 約 150 ns。Apple M3 Max・release)。中の余分な `pop()` が外の段を取らないことや、早期 `return`・`throw` でも戻ることは変わりません。`createShape { }`・`createPath { }` も同じ方式で、本体の中の積み降ろしを外から切り離します。
