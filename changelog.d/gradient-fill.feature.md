<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`fill(.linearGradient(…))` と `fill(.radialGradient(…))` で、円・矩形・字などを勾配で塗れるようになりました。** 区切りは `(色, 位置)` をそのまま並べて書き (組み立てた `[(LinearRGBA, Float)]` を渡す形もあります)、線形の勾配は `from` から `to` へ、放射の勾配は `center` から `radius` まで、位置 0 から 1 で色が変わります。例えば `fill(.linearGradient((color(40, 30, 90), 0), (color(250, 140, 80), 1), from: [0, 0], to: [0, height])); rect(0, 0, width, height)` は、紫から橙へ縦に変わる空になります。色は `lerpColor(_:_:_:)` と同じ線形の光の量で混ざります。

勾配は塗りだけに効き、線 (`stroke`) の色は変わりません。`pushStyle()` と `popStyle()` で積み降ろされ、`createShape { }` の中で塗った勾配は形に焼き付いて、置き場所で回すと一緒に回ります。`shader()` を付けると自分の断片が勝ちます。値型 (`Circle`・`Rect`) と `Placement` の `fill` は色のままで、勾配は描く状態に置いて、`fill` が `nil` の値を描きます。勾配の座標は `fill(_:)` を呼んだときの座標系で読みます。円錐の勾配と線の勾配はまだありません。
