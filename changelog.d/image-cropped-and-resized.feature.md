<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`Image.cropped(x:y:width:height:)` で絵の一部を切り出し、`Image.resized(width:height:)` で大きさを変えた新しい絵を作れるようになった。Processing の `PImage.get(x, y, w, h)` と `PImage.resize(w, h)` に当たるが、どちらも元の絵を変えない (Processing の `resize` は自分を変える)。

切り出しで絵をはみ出す範囲は透明になる。大きさを変えるとき、縮める向きは線形のまま光の量で平均し (白黒の縞は中間より明るい灰色になる)、広げる向きは `image()` が絵を引き伸ばすときと同じく画素の間を直線で補う。幅か高さが 1 を割る指定は `createImage` と同じく `ImageFailure.unplaceable` を投げ、Processing の `resize(150, 0)` (0 で縦横比を保つ) の形は無い。カメラの `image` から作った絵も、次の 1 枚で書き換わらない。
