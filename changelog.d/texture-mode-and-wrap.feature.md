<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`vertex(x, y, u, v)` の読み取り位置の単位を選ぶ `textureMode(_:)` と、貼る画像の端の外を繰り返す `textureWrap(_:)` を足しました (Processing の `textureMode(IMAGE / NORMAL)`・`textureWrap(CLAMP / REPEAT)`、[#3717](https://github.com/mokume-metal/mokume/issues/3717))。`textureMode(.normal)` の下では画像の大きさによらず `(0, 0)`〜`(1, 1)` で画像の全体を指せ、`textureWrap(.repeat)` の下では `u`・`v` を画像の大きさより大きく書くと画像がタイルのように繰り返します。既定は今までどおり画像の画素 (`.image`) と、端の色で延ばす `.clamp` です。

単位は Processing と同じく `vertex()` を呼んだ時点で決まり、端の外の読み方は塗りを置いた時点で決まります。どちらも描き方なのでフレームを越え、`push()` / `pop()` で積めます。`.repeat` が効くのは組み込みの塗りが貼る画像を読むときだけで、`shader()` の断片が `mokume_sample` で読む面は、今までどおり端の色で延ばして読みます。
