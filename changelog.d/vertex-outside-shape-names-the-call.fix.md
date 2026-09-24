<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`beginShape()` の外で `bezierVertex` / `quadraticVertex` / `curveVertex` / `beginContour` / `index` を呼んだときの注意が、呼んだ関数の名前を名乗るようになりました。これまではどれを呼んでも `vertex(): call this between beginShape() and endShape()…` と出ていたため、呼んでいない `vertex()` の呼び出しを探しに行くことになっていました。いまは `index(): call this between beginShape() and endShape(). This call does nothing` のように、呼んだ関数の名前で言います。

理由の部分と、形の外で `vertex` を呼んだときの文面は変わりません。注意は入口によらず初回の 1 度だけで、何もしない振る舞いも変わりません。絵は 1 画素も変わりません。
