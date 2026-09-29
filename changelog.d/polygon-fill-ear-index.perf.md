<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`beginShape()` … `endShape(.close)` で頂点の多い多角形を塗るとき、三角形への分け方が頂点の数の二乗で重くならなくなりました。`mokume run` の既定 (debug 組み) で、1000 頂点の多角形の 1 フレームは約 62 ms から約 8 ms に、4000 頂点では約 970 ms から約 34 ms になります (Apple M5 で計測)。

分け方が変わるので、頂点ごとに `fill` を変えた形、`lights()` の下の平らでない形、4 引数の `vertex` で読み取り位置を書いた形では、色や陰のつなぎ目が以前と違って見えることがあります。一様な色で不透明に塗る形の見た目は変わりません。
