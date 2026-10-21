<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`loadShape(_:)` が、`rect` の `width` / `height`・`circle` の `r`・`ellipse` の `rx` / `ry`・`rect` の `rx` / `ry` に書いた負の値を、捨てたものとして知らせるようになった。

これまでは何も知らせずに描かなかった (`rect` の `rx` / `ry` は書いていないものとして読み、これも知らせなかった)。あわせて、`ellipse` の負の `rx` / `ry` を SVG 2 のとおり書いていないものとして読むようにした。`<ellipse rx="-5" ry="5"/>` は、以前は何も描かなかったが、半径 5 の円になる。
