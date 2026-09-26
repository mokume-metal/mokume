<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

矩形へ流し込む `text(s, x, y, w, h)` が、改行しない空白 (U+00A0 NO-BREAK SPACE・U+202F NARROW NO-BREAK SPACE・U+2007 FIGURE SPACE) でも行を折っていたのを直しました。「10 km」のように切らないために置いた空白で、数と単位が別の行に分かれていました。改行しない空白は字と同じに扱い、そこでは折らず、切れ目の後ろでも消費せず、行の末尾からも削りません。行末に改行しない空白を置いた右揃え・中央揃えの行は、その幅だけ寄るようになります。
