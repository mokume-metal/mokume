<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`Image.mask(_:)` で、別の絵の明るさをこの絵の不透明度に掛けられるようになった。Processing の `PImage.mask(img)` に当たり、同じく自分を書き換える。白いところは元のまま、黒いところは透明になり、灰色は半分になる (明るさは `brightness(_:)` と同じ表示の色の物差しで読む)。

不透明な絵では Processing と同じ結果になる。半透明の画素では不透明度を置き換えずに掛けるので、Processing と結果が違う。マスクの大きさがこの絵と違えば、何も変えずに 1 度だけ警告する (`resized(width:height:)` で揃えられる)。整数の配列を渡す `mask(maskArray)` の形は無い。
