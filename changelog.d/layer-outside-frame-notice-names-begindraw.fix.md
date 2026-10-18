<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

描き場所 (`createGraphics`) で `beginDraw()` を書かずに `translate()`・`force()` などを呼んだときの注意が、**すでに `draw()` の中に居る人に「call this from draw()」と言っていた**のを直した。いまは `On a drawing target this only works between beginDraw() and endDraw(), so call it there. This was called outside them, so it belongs to no frame, and was ignored` と、本当の直し先 (`beginDraw()` と `endDraw()` の間) を言う。視点・変換・光・影・材質・効果・粒・計算に加え、図形や絵や背景を置くことと画素を書くことの、13 種すべてで同じ 1 文である。本体の面の注意は変わらない。形を開いたまま抜けて捨てたときの注意も、`draw()`・`setup()` だけでなく、入力のコールバック・`createShape()` の本体・描き場所の `endDraw()` を越えた場合も挙げる。
