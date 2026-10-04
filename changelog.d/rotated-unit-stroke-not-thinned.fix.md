<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`rotate()` だけで回した太さ 1 の線と輪郭が、回す角度によって「1 画素より細い線」の描き方に切り替わっていたのを直しました。回すだけでは線の太さは変わらないのに、計算の丸め誤差で太さが 0.9998 画素ほどに見積もられ、`translate(80, 80); rotate(frameCount * 0.01)` のように回し続ける絵では、一部のフレームで折れ線 (`beginShape()`) の角の画素が数個入れ替わり、頂点の数も変わっていました。いまはどの角度でも、回さない線と同じ描き方のままです。`scale(2)` の下の太さ 0.5 や、`pixelDensity` を 0.5 にした絵の太さ 2 のように、描く画素でちょうど太さ 1 になる線も同じです。縮めて本当に 1 画素より細くなる線は、これまでどおり太さに比例した濃さで描きます ([#2039](https://github.com/mokume-metal/mokume/issues/2039))。
