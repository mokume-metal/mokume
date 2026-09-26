<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`textSize(0)` や負の大きさの後で、`textWidth`・`textAscent`・`textDescent` が 0 ではなく書体ごとの既定の大きさ (システム書体なら 13pt) の値を返していたのを直しました。大きさ 0 の文字は何も描かれないのに、測ると幅 52 画素ほどがあると報告され、0.001 から 0 へ下げたところで値が跳んでいました。大きさ 0 では、測る口もどれも 0 を返します。
