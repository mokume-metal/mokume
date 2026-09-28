<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

曲線 (`curveVertex` / `bezierVertex`)・丸い継ぎ目の線と、3D の `beginShape` で組む線を描く CPU の時間が短くなりました。継ぎ目の円を描くたびに三角関数で周を作り直し、3D の線では視点の向きを頂点ごとに計算し直していたためです。3D の線は約半分、曲線は約 25% 速くなります。絵は 1 画素も変わりません。
