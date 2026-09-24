<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`strokeCap(.project)` で斜めの線を引くと、**端が線の向きではなく画面の縦横に沿った正方形になり、菱形に張り出していた**のを直しました。起きていたのは `beginShape(.lines)` や開いた折れ線 (`beginShape()` … `endShape()`)、`vertex(x, y, z)` で並べた線、`shader` を効かせた `line` です。何も効かせない `line` はもとから線の向きに沿って太さの半分だけ延ばしていたので、`shader` を 1 行足しただけで端の形が変わっていました。いまはどの描き方でも、端は線の向きに沿って太さの半分だけ延びます。水平・垂直な線と、`point` の四角い端は変わりません ([#1535](https://github.com/mokume-metal/mokume/issues/1535))。
