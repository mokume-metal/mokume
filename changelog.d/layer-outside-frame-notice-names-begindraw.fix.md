<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

描き場所 (`createGraphics`) で `beginDraw()` を書かずに `translate()`・`force()` などを呼んだときの注意が、**すでに `draw()` の中に居る人に「call this from draw()」と言っていた**のを直した。いまは `Transforms are written again every frame. On a surface you open yourself, call this between beginDraw() and endDraw(), or inside its draw { }. This was called outside them, so it belongs to no frame, and was ignored` と、本当の直し先を言う。先頭の主語は種類ごと (`Lights …`・`Particles …` など) なので、どの口を呼んだかも分かる。視点・変換・光・影・材質・効果・粒・計算に加え、図形や絵や背景を置くことと画素を書くことの 13 種すべてで同じ型で、直に使う `Canvas` も同じ文を言う。本体の面の注意は変わらない。形を開いたまま捨てたときの注意は、形を開いた場面 (`setup()`・`draw()`・入力のコールバック・`createShape()` の本体・描き場所の `beginDraw()`〜`endDraw()`) をすべて挙げ、捨てた境目は「フレームか本体が閉じたとき、または次のフレームが始まったとき」と言う。影の注意の直し先も、描き場所では `beginDraw()` と `endDraw()` の間で言う。描き場所の説明にも、視点・光・変換・粒・計算も対の中でだけ効くと書いた。
