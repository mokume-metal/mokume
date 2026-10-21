<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

外のパッケージの入り口・部品も、作者の時計の秒を読めるようにした (`authorTime` を公開した)。時刻を指定した観測の枚では、供給の間の `time` が観測の秒になるので、再生位置や起点のような状態を `time` で進めると、観測が済んだ後も指定の秒が状態に残る。`authorTime` は観測の枚でも作者の時計の秒で、観測でない枚では `time` と同じ値なので、動画のような入り口は、状態を `authorTime` で進め、映すコマだけを `time` で決められる。`time` の値と振る舞いは変えていない。`time` の説明にも、観測の秒を読むのは `draw()` と、その直前の入り口の供給の間だと書いた。
