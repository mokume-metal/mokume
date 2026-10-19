<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`textBounds()` が絵文字を測るために CPU で描いた絵を、同じ大きさの `text()` が焼くときにそのまま使うようになりました。** `textSize()` を毎フレーム動かしながら絵文字を `textBounds()` で測って `text()` で描くスケッチで、1 フレームに 2 回あった絵文字の CPU の描画が 1 回になります (リリースビルドで 1000px は 12.2 ms → 7.1 ms、3000px は 114 ms → 69 ms)。返る枠と描かれる絵は変わりません。
