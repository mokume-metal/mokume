<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`Image.readPixels()` で、絵の全画素を一度に `PixelBuffer` として読めるようにした。1 画素ずつ `get(x, y)` で読んでいた処理を、1 回の呼び出しに置き換えられる。

値は `get` と同じ線形・アルファ乗算済みで、左上原点の行優先に並ぶ。返るのは撮った時点の写しなので、読んだ後に絵を書き換えても返した値は変わらない。外のパッケージが絵を解析に渡す入口になる。
