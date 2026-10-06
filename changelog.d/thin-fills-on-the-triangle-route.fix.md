<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`shader()` や `texture()` を付けた `rect` / `square` / `ellipse` / `circle` と一周の `arc` を 1 画素より細く描いたとき、置く位置によって塗りが消えたり 1 画素の濃さで出たりしていたのを直しました。`pixelDensity` を 0.5 にしたスケッチの高さ 1 の `rect` がこれに当たります。付けないときと同じく、置く位置によらず面積に比例した濃さで出ます (1 画素より小さい円は、外接する正方形の面積に比例します)。同じ形を並べて描くとき・`createShape` で作った形を縮めて置くときも同じです。`triangle`・`quad`・`beginShape` と扇形 (一周でない `arc`) の 1 画素より細い塗りは、これまでどおり画素の格子に丸まります。
