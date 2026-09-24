<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`pixelDensity` を 1 未満にした面で、線・輪郭・点の濃さが置く位置で変わらなくなった。これまでは縁の被覆を出す画素で測っていたので、`pixelDensity: 0.5` の面の `strokeWeight(1)` の縦線は、置く位置で描く画素の濃さが倍になったり消えたりしていた (x = 80 / 80.5 / 81 / 81.5 で 0.5 / 1.0 / 0.5 / 0)。`rect` / `circle` / `arc` の輪郭と点も同じだった。いまは描く画素で測るので、線と輪郭は描く画素での太さに、点は面積に比例した濃さで出る。塗りの縁も描く画素 1 つの幅で滑らかになる (これまでは半分の幅だった)。`pixelDensity` が 1 の絵は 1 ビットも変わらない。
