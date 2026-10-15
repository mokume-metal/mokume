<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`loadShape(_:)` と `requestShape(_:)` で、SVG の読めない値を黙って一方へ倒していた 3 つの口を直した。`preserveAspectRatio` の読めない値 (`foo`) は左上寄せになっていたが、いまは書いていないときと同じ中央寄せ (`xMidYMid meet`) で置き、捨てたものとして知らせる (`preserveAspectRatio "foo"`)。`stroke-dasharray` の読めない値・負の値 (`abc`・`-1 2`) は、破線を捨てたと知らせる代わりに値が読めなかったと知らせ (`stroke-dasharray "abc"`)、下に書いた有効な `none` を消さなくなった。`0pt` は破線なしと読む。`fill="url(#a) abc"` のように塗りの参照の代わりの色が読めないときも知らせる。読める値の扱いと、破線を描かないことは変わらない。
