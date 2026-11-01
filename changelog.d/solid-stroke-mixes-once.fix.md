<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**奥行きを持つ形の半透明の線が、折れ目・端・稜の集まる点で濃くならなくなりました。** `stroke(255, 0, 0, 128)` のような半透明の色で `vertex(x, y, z)` の形や `noFill()` の `box`・`sphere` の稜線を引くと、これまでは角・丸い端・曲線の刻み・稜の集まる角と、奥行きの違う稜が画面で交わる所が 2〜3 回重ねて混ざっていました (半透明のワイヤーフレームの球では、網の交点の結び目と極の白い塊になっていました)。いまは線 1 本 (輪郭 1 つ・形 1 つの稜線) の全体を 1 回だけ混ぜ、交わる所も、箱を回す向きによらず 1 回です。別々の図形の線どうしが重なる所は、これまでどおり 2 回混ざります。`shader()` が効いている線・`createShape` で記録した形の線・1 画素より細い線は、まだ前の混ぜ方のままです ([#1561](https://github.com/mokume-metal/mokume/issues/1561)・[#3574](https://github.com/mokume-metal/mokume/issues/3574))。
