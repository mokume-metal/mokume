<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**名前の付いた色が書けるようになりました。** `fill(.red); circle(100, 100, 40)` や、`var brick = Rect(left: 24, top: 48, width: 40, height: 14, fill: .orange)`・`brick.fill = .navy` のように、色の値の型 `Color` に CSS 2.1 の 17 色 (`.black`・`.silver`・`.gray`・`.white`・`.maroon`・`.red`・`.purple`・`.fuchsia`・`.green`・`.lime`・`.olive`・`.yellow`・`.navy`・`.blue`・`.teal`・`.aqua`・`.orange`) を持たせました ([#2595](https://github.com/mokume-metal/mokume/issues/2595))。値は CSS と同じ (sRGB) で、`.orange` は `color(255, 165, 0)` と同じ色です。

`.green` は CSS の暗い緑 (`#008000`) で、SwiftUI の `.green` とは違います。明るい緑は `.lime` です。名前は、後で文字列の色名 (`"red"`) を足したときも同じ色になるように、CSS の名前と値のままにしてあります。
