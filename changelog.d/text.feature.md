<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

文字を描けるようになりました。`text()` / `textFont()` / `textSize()` / `textStyle()` /
`textAlign()` / `textLeading()` と、寸法を測る `textWidth()` / `textAscent()` /
`textDescent()` を追加しています。

**文字列の幅は 1 文字ずつの送り幅の合計**です。部分に切って足すと全体の幅にそのまま
一致し、描画が前へ進む量も同じ値になります。指定した書体が覆えない文字は、この環境が
持つ別の書体から引いて描きます。
