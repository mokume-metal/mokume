<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`loadShape` が、SVG に書いた `<linearGradient>`・`<radialGradient>` で塗った要素を、その勾配で描くようになった。これまでは塗りが抜ける (代わりの色があればその色一色になる) うえに、捨てたものとして知らせていた。`<linearGradient id="g">` に赤と青の `stop` を置いて `<rect width="80" height="50" fill="url(#g)"/>` を読むと、矩形の左端が赤、右端が青の勾配で出る。勾配は形に焼き付き、置き場所と一緒に動く。

読むのは `stop` の色と不透明度・`x1`〜`y2`・`cx`・`cy`・`r`・`gradientTransform`・`gradientUnits` (既定の `objectBoundingBox` と `userSpaceOnUse`)・`href` (`xlink:href`) による区切りの引き継ぎ。`spreadMethod` の `reflect`・`repeat`、中心と違う焦点 (`fx`・`fy`)、`href` で指した勾配の属性、11 個目からの区切りは読まずに知らせ、`pad` と中心の焦点で描く。線の勾配 (`stroke="url(#…)"`) はこれまでどおり読まずに知らせる。色は `fill(_: Gradient)` と同じく線形の空間で混ぜるので、勾配の中ほどはブラウザより明るく出る。
