<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`pixelDensity` を 1 より下げたスケッチで、`blur` / `bloom` のぼけ・にじみが細かさに反比例して広がっていたのを直しました。細かさ 0.5 では同じ `blur(radius: 8)` のぼけが倍の幅になり、`bloom` の裾も 2 倍以上に延びていました。半径は座標や線の太さと同じく出す細かさの画素で測るようになり、細かさを変えてもぼけの幅は変わりません。細かさ 1 の絵は変わりません。
