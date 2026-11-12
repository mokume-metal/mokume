<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`filter([…])`・`effects([…])`・`Image.filtered([…])` に掛けられる効果に、段数を減らす `.posterize(levels:)`、暗いところを広げる `.erode`、明るいところを広げる `.dilate`、不透明にする `.opaque` を足しました (Processing の `filter(POSTERIZE, levels)`・`filter(ERODE)`・`filter(DILATE)`・`filter(OPAQUE)`、[#3716](https://github.com/mokume-metal/mokume/issues/3716))。これで Processing の `filter()` の 8 つの種類がすべて揃います。

`.posterize(levels:)` は表示の色の 8 ビットの値を Processing と同じ式でチャンネルごとに段に切るので、8 ビットの灰は Processing と同じ値になります。段数が 2 未満 (0・1・負) なら何も変えません (Processing は投げます)。上限は締めません。

`.erode`・`.dilate` は、各画素を上下左右の近傍のうち最も暗い・明るい画素で丸ごと置き換えます (成分ごとに最小・最大を取りません)。明るさは Processing と同じ輝度の加重 (0.30・0.59・0.11) で比べるので、`.threshold(level:)`・`Image.mask(_:)` の物差し (R・G・B の最大) とは別です — 赤と緑が隣り合うと、緑が明るいとみなされます。乗算済みのまま比べるので、透明な画素は暗い側になります (Processing は不透明度を見ません)。1 回で 1 画素ずつ進むので、強く掛けるなら `[.dilate, .dilate]` と重ねます。

`.opaque` は色を保ったまま不透明度を 1 にします。不透明度 0 の画素は色が残っていないので黒の不透明になります。
