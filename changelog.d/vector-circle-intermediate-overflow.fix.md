<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`Vector2` の長さ・`normalized()`・`limited(to:)` が、成分は `Float` に収まるのに 2 乗だけが溢れる大きな値 (`Vector2(3e20, 4e20)` など) で、`infinity`・`(0, 0)`・`nan` を返していたのを直した。`Circle` の `intersects` / `contains` と `Rect.intersects(Circle)` も、半径の 2 乗が溢れる大きい円と、0 に潰れる小さい円で、離れていても `true` を返していたのを、距離と半径の比較に直した。

普通の大きさの値の結果は変わらない。
