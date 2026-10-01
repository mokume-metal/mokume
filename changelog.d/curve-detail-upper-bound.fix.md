<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`curveDetail()` に大きな値を渡すと、その後の `bezierVertex()`・`quadraticVertex()`・`curveVertex()` が渡した数だけ点を作り、フレームが戻らなくなっていたのを直しました (`curveDetail(Int.max)` の後に曲線を 1 つ置くだけで止まっていました)。刻みの数は 1…1024 になり、1024 を越える値は 1024 として刻んで、注意を 1 度出します。1024 は円・楕円・弧の一周の分割の上限と同じ数です。1024 以下の値の絵は変わりません。1024 を越える値を渡していた場合は刻みが 1024 に減りますが、半円に近い 1 区間でも半径 20 万画素ほどまでは見た目の差が 0.25 画素に収まる見込みです。
