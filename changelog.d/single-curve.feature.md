<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

通過点を結ぶ曲線の 1 区間を `curve(x1, y1, x2, y2, x3, y3, x4, y4)` の 1 行で引けるようになった。`beginShape()`・`curveVertex` を 4 回・`endShape()` と同じ絵で、引くのは 2 つ目から 3 つ目の点までである。4 点を `Vector2` で渡す `curve(from:control1:control2:to:)` もあり、`control1` は始点の手前、`control2` は終点の先の点になる。

曲線の上の点と傾きは `curvePoint(a, b, c, d, t)`・`curveTangent(a, b, c, d, t)` が返す。Processing と同じく、いまの `curveTightness()` の設定を読む。`createGraphics` で作った描画先にも同じ API があり、その描画先の張りを読む。
