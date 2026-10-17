<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

計算の語彙を足した。`pow` / `sqrt` / `exp` / `log` / `floor` / `ceil` / `round` が `import mokume` だけで呼べる (三角関数と同じく、Foundation を足さずに書ける)。あわせて `dist(x1, y1, x2, y2)`・`mag(x, y)`・`sq(x)`・`fract(x)`・`mod(x, n)` を足した。`fract` と `mod` は負の値も 0 以上へ畳むので、`mod(-1, 4)` は 3、巡る値を足して引き直さずに書ける。数でない値や 0 での剰余は 0 を返して 1 度だけ知らせる (絵へ NaN を通さないため)。

リテラルだけの `pow(2, 3)`・`exp(-1)`・`log(10)` は `Float` か `Double` か決まらず組めない (Darwin の性質で、`import Darwin` だけでも同じ)。`pow(2.0, 3)` や `Float` の値を渡す形で書く。
