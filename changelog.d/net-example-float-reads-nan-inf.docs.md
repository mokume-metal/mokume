<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

ネットワークの受信の説明にある作例 `size = Float(line) ?? size` の注釈を、実際の読み方に合わせた。`Float(String)` は `0.3` のような 10 進の数のほか `"nan"`・`"inf"`・`"0x1p-2"` も数として読むので、「数だけを読む」とは言えず、「`Float` として読めた行だけを使う」と書き直した。コードの挙動は変えていない。
