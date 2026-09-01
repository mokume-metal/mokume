<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

変換の口 (`translate` / `rotate` / `scale` / `shearX` / `shearY` / `resetMatrix` / `pushMatrix` / `popMatrix` / `push` / `pop`) に、引数を 1 つずつ動かした例と絵が付きました。どれも**同じ図形を同じ座標に描いて**、変換を挟むと出る場所や形が変わることを見せています (薄い枠が変換前の位置)。

`push` と `pushMatrix` の違い — 色や線の太さも一緒に戻るかどうか — も、絵を並べて見分けられるようにしました。
