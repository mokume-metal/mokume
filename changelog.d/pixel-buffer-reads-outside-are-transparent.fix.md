<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`readPixels()` で読み出した画素 (`PixelBuffer`) を範囲の外の位置で読むと、プロセスごと落ちていたのを直しました。いまは透明が返ります。画素の面 (`pixels[x, y]`) と絵の `get(x, y)` は前から範囲の外で透明を返していて、`PixelBuffer` だけが違っていました。これで画素を読む 3 つの口が、範囲の外で同じ値を返します。
