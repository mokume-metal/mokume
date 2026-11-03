<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`shader()` を付けた線や `beginShape()` の輪郭など、三角形の経路で引く描く画素で 1 画素より細い線を斜めに置いたとき、置く位置によって明るさが 1/√2 倍か √2 倍に振れていたのを直した。45° の線も、置く位置によらず太さに比例した濃さで出る。保持した形 (`createShape()`) を回して置くときも同じく直った。`shader()` / `texture()` を付けた `rect`・`ellipse`・`arc` の細い輪郭と、立体の細い線はまだ振れる (#3733・#3734 で直す)。
