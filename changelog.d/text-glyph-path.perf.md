<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`text()` で文字を多く描くスケッチの CPU の時間が、半分以下になりました。1 字ごとに、書体と焼いた字形の置き場をそれぞれ引き直し、頂点を 1 つずつ積んでいたためです。65 字の行を 150 本描くフレームで 1.3 ms → 0.53 ms になります。絵は 1 画素も変わりません。
