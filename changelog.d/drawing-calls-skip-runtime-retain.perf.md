<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`rect()`・`circle()` などの描く API を 1 回呼ぶ費用が約 3 分の 2 になりました。別のパッケージのスケッチから 10 万個の `rect()` を置く場面で、`draw()` の CPU 時間が 約 11.7 ms → 約 8.0 ms (1 個あたり 約 117 ns → 約 80 ns) です。描く API が走っている実行を引くたびに、実行の保持と解放 (参照数の遅い道を通る) を 1 対ずつしていたのを外したためで、渡す数の型 (`Float`・`Double`・`Int`) によらず同じだけ速くなります。描く絵と、`setup()`・`draw()` の外から呼んだときの警告は変わりません。
