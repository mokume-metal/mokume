<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

透明な下地 (`background(.transparent)` や、透明で始まる `createGraphics` の描き場所) の上に `blend` と `replace` 以外の混ぜ方で描いたとき、色が狂わなくなりました。これまでは下地のアルファを見ずに、透明な所を「黒」と読んで混ぜていたので、`multiply` と `darkest` は置いた色の代わりに黒い形を、`subtract` は負の色を置き、半透明の色はどの混ぜ方でも暗く沈んでいました。いまは W3C の合成の一般式に揃えてあり、混ぜる相手が無い透明な所では、どの混ぜ方でも置いた色がそのまま載ります。半分透ける下地の上では、混ぜた色と置いた色が下地のアルファの分ずつ効きます。

不透明な下地の上に描いた絵は 1 画素も変わりません。
