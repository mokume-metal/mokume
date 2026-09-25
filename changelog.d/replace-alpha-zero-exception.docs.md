<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`blendMode` の説明の「どのモードでも、アルファ 0 の色は下地を変えない」に、置き換える混ぜ方 (`.replace`) の例外を書いた。`.replace` は下地を見ず、形が掛かる画素を置いた色でアルファごと置き換える — アルファ 0 の色で描けば、形の所の下地は透明に抜ける。振る舞いは前から同じで、説明が振る舞いに追いついた。描き場所 (`createGraphics`) の一部を透明にしたいときは、`.replace` にしてアルファ 0 の色で形を描けばよい。
