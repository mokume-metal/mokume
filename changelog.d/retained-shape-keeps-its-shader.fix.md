<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`createShape` で記録した形が、組み立ての間に効いていた `shader()` とそのとき渡していた値・面・数の並びを持ち歩くようになった。置く前に `resetShader()` しても、別の断片へ切り替えても、形は記録した塗りで出る (これまでは置く時点の塗りで描かれていた)。`fill()` や `stroke()` が形に焼き付くのと同じ規則になる。

面 (`surfaces`) だけを差し替えて組み立てた 2 つの形を `group()` や `+` で組にしたときに、1 つ目の面で両方が描かれていたのも直した。
