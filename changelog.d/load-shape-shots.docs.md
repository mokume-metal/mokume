<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`loadShape(_:)` に例と絵が付きました。例はその場で小さな SVG を一時ディレクトリへ書き出してから読みます。1 枚ごとに SVG の中身か置き方を 1 か所だけ変えた 4 枚で、次のことが見えます。

- 置いた位置が `viewBox` の左上になる
- `width` と `height` を書くとその大きさへ写される
- `scale(3, 3)` で拡大しても、縁は `circle()` で描いたときと同じく滑らか
- 置く前の `fill` は効かず、白で描いた SVG は置き場所に渡した色でそのまま染まる

`requestShape(_:)` は、届いた形の見え方が `loadShape(_:)` と同じなので、そちらの絵を見るよう案内しています。何枚目のフレームで届くかは SVG の大きさとフレームの間隔で変わるため、この口だけの絵は付けていません。
