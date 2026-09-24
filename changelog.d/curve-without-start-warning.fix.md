<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`beginShape()` の中で、手前に点を置かずに `bezierVertex` / `quadraticVertex` を呼んだときの注意が、見当違いのことを言わなくなりました。これまでは形の外で呼んだときと同じ `vertex(): call this between beginShape() and endShape()…` が出ていたため、呼んだ場所は既にその間なのに、`beginShape` の位置を探しに行くことになっていました。いまは呼んだ関数の名前で、曲線を続ける手前の点がまだ無いので何もしなかった、と言います。`beginContour()` の直後 (穴の最初) で呼んだときも同じ注意が出ます — 穴は外周の点から曲線を始めないからです。

何もしない振る舞いと、形の外で呼んだときの注意は変わりません。絵は 1 画素も変わりません。
