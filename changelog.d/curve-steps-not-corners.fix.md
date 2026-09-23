<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

太い線で引いた曲線 (`bezierVertex` / `quadraticVertex` / `curveVertex`) の縁が、斜めに走る区間で鋸の歯のように太らなくなりました。曲線は刻みの数だけの折れ線で引かれ、刻みどうしの継ぎ目もこれまでは角と同じ形で埋めていました。既定の `strokeJoin(.miter)` と `.bevel` ではそれが軸に沿った正方形で、線が斜めのとき正方形の角が帯の外へ出ていました (太さ 10 の 45° の線で約 2 画素)。刻みの継ぎ目は角ではないので、`strokeJoin` によらず丸く繋ぐようにしました — 曲線は、刻みの折れ線から太さの半分の内側をちょうど塗ります。制御点を弦の上に置いた曲線は、同じ端点を `vertex` で結んだ直線と同じ絵になります。

`vertex` で置いた点と、曲線の終点・通過点 (`curveVertex` に渡した点) は、これまでどおり角として `strokeJoin` に従います。
