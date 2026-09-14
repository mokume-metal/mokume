<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

描き場所を作っては捨てる書き方で、GPU のメモリが減らずに積み上がっていた問題を直した。`createGraphics` で作った描き場所は、手放しても面や置き場が解放されなかった (64x64 を 200 回作って捨てると、物理メモリが 172 MiB 増えていた)。いまは読み終えた後に解放され、同じ回し方で 3 MiB に収まる。

影・効果・`pixelDensity` を下げた拡大・画素の読み書き・出口へ渡す絵を通した描き場所も同じで、手放せばそれぞれの面や置き場が解放される。
