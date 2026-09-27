<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

表示できる形にした絵 (`DisplayImage`。`encodeForDisplay()` や `OutputFrame.bytes()` が返すもの) を範囲の外の位置で読むと、プロセスごと落ちていたのを直しました。いまは透明 `(0, 0, 0, 0)` が返ります。読み出した画素 (`PixelBuffer`)・画素の面 (`pixels[x, y]`)・絵の `get(x, y)` と同じく、画素を読む口はどれも範囲の外で落ちずに透明を返します。大きさとバイト列から作るときに長さが合わなければ止まるのは、これまでどおりです。
