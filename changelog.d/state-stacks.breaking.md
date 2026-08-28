<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`push()` / `pop()` が変換とスタイルの両方を積むようになった。** 変換だけを積むには `pushMatrix()` / `popMatrix()`、スタイルだけなら `pushStyle()` / `popStyle()` を使う。

あわせて、斜めに歪める `shearX` / `shearY`、変換を直接重ねる `applyMatrix`、積み重ねを捨てる `resetMatrix`、点が変換でどこへ移るかを引く `screenX` / `screenY` が入った。
