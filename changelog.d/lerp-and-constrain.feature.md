<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

2 つの値の間を取る `lerp()` と、値を範囲へ締める `constrain()` を追加した。動きを滑らかにする 1 行 (`lerp(from, to, 0.25)`) と、値が範囲を飛び出さないようにする 1 行 (`constrain(distance, 4, 120)`) を、スケッチごとに書かなくてよくなる。`radians()` / `map()` と同じくグローバル関数なので、`Sketch` の外に置いた型からも呼べる。

`lerp()` は **0…1 の外を締めない** — `lerp(0, 10, 2)` は 20 を返して外へ伸びる (`map()` の外挿と揃えてある)。締めたいときは `constrain()` を通す。`constrain()` は**上下を逆に渡しても入れ替えて締める**。どちらも、数でない値や無限が混じったときだけ範囲の端へ倒して 1 度だけ注意を言う (絵へ NaN を通さないため)。
