<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

立体の空間に曲線を引けるようになった。奥行き `z` を持つ `bezierVertex(cx1, cy1, cz1, cx2, cy2, cz2, x, y, z)`・`quadraticVertex(cx, cy, cz, x, y, z)`・`curveVertex(x, y, z)` と、12 の数の `bezier()`・`curve()` を足した。刻んだ点は `vertex(x, y, z)` と同じ奥行きを持つ点になり、視点と奥行きを通る。`curveDetail()`・`curveTightness()` は平面の曲線と同じに効く。平面の曲線の API は、奥行きを持つ曲線の API に `z` = 0 を渡したのと同じ絵になる (`vertex(x, y)` が `vertex(x, y, 0)` と同じなのと同じ)。

点を `Vector3` で渡すラベル付きの形 (`bezier(from:control1:control2:to:)`・`curve(from:control1:control2:to:)`・`bezierVertex(control1:control2:to:)`・`quadraticVertex(control:to:)`) も、平面の形と同じラベルで足した。
