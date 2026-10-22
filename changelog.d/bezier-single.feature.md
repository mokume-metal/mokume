<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

3 次のベジェ曲線を 1 行で引く `bezier()` と、曲線の上の点・向きを返す `bezierPoint()`・`bezierTangent()` を追加した。曲線に沿って物を動かすとき、3 次式を自分で展開しなくてよくなる (`bezierPoint(60, 260, 640, 900, t)` が `t` の位置の x、`atan2(bezierTangent(420, 60, 600, 160, t), bezierTangent(60, 260, 640, 900, t))` が進む向き)。

名前と引数の並びは Processing・p5.js と同じで、`bezier(x1, y1, x2, y2, x3, y3, x4, y4)` は始点・制御点 2 つ・終点の順に渡す。`bezier()` は `beginShape()`・`vertex()`・`bezierVertex()`・`endShape()` を順に呼んだのと同じ絵になる。`bezierPoint()`・`bezierTangent()` は `Sketch` の外からも呼べる軸ごとの関数で、`t` が 0 なら始点、1 なら終点がちょうど返り、0…1 の外は締めずに曲線を延ばす。数でない値が混じったときは絵へ NaN を通さず、1 度だけ注意を言う。
