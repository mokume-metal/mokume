<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`scale()` で拡大して `shapedText()` を描いたとき、縁がぼけていたのを直した。`text()` と同じく、拡大に合わせた画素で字形を焼き直して置くので、拡大しても縁が鮮明になる。1 フレームに焼ける量を越えて先送りした字も、`text()` と同じに払うので、`noLoop()` で止めた絵や書き出した絵は先送りしなかった絵と変わらない。拡大しすぎで縁がぼけるときの知らせは、`text()` / `shapedText()` のどちらで描いたかを名乗る。
