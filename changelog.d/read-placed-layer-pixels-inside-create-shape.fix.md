<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`createShape { }` の中で、同じフレームで先に `image(layer)` と置いた描き場所の画素を `get()`・`pixels`・`loadPixels()` で読むと、描き場所の色が読めるようになりました。これまでは `get()` が透明を返し、「画素を読み書きしない」と注意していました。断るのは、組み立てている面自身の画素の口だけです。置いた描き場所の写しの上限に達したときや写しに失敗したときも、組み立てた形は中身を持ったままで、組み立てた図形がフレームに出ることはありません。
