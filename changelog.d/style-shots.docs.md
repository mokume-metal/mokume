<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

参照の面の**スタイルの口**にも実行結果の絵が付いた。`background` / `fill` / `stroke` / `strokeWeight` / `noFill` / `noStroke` / `strokeCap` / `strokeJoin` / `blendMode` に、引数を 1 つずつ動かした例が 21 本並ぶ。端の形 (3 つ) と折れ目の形 (3 つ) と混ぜ方 (4 つ) は**選べる数だけ絵が出る**ので、名前から形を想像しなくてよい。`blendMode` には重なりが動く絵も 1 本ある。

絵を並べたことで、`strokeJoin(.miter)` がいまは `.bevel` と同じ形で描かれる (角が尖らない) ことが見て分かるようになった。説明文にもその旨を書いてある。
