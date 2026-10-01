<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**描き場所 (`createGraphics`) で `endDraw()` を忘れたフレームは、画面の次のフレームの頭で描かずに捨てるようになりました。** これまでは次に `beginDraw()` を呼ぶまで捨てなかったので、その間に描き場所を `get`・`pixels`・`loadPixels()` で読むと捨てるはずの画素と図形が見え、図形は後で捨てても描き場所に残りました。この描き場所を置いた別の描き場所を描き換えたとき・`read` で数の並びを読んだとき・遅れて `endDraw()` を呼んだときも、捨てるはずの中身が描かれ、頼んだ計算が走っていました。今は捨てる前の絵が読め、遅れた `endDraw()` は既に捨てたことを 1 度知らせて何もしません。捨てたことの注意は、次の `beginDraw()` ではなく画面の次のフレームの頭で出ます。`setup()` で `beginDraw()` を開いて `endDraw()` を `draw()` で呼ぶ書き方は、最初のフレームの頭で捨てられるので、`beginDraw()` と `endDraw()` は同じフレームの中で対にしてください。
