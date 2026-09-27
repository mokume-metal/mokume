<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

図形・絵・背景を置くことと、画素を書くこと (`set()`・`pixels[x, y] = …`・`pixels.fill()`) は、**次のフレームを約束する区間の中でだけ効く**ようになった。区間は、画面では `setup()`・`draw()`・入力のコールバック (止まっている間も含む)、描き場所 (`createGraphics`) では `beginDraw()` と `endDraw()` の間、`Canvas` を直に使うときは `draw { }` の中である。**区間の外で置いたものは、1 度注意して置かない** ([ADR-0021](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md) 決定 4 の追補 (2026-09-27)・[#1672](https://github.com/mokume-metal/mokume/issues/1672))。`beginShape()` と `vertex()` などの頂点の仲間も同じで、区間の外で形を開いたり点を足したりしても、何も溜まらない。

これまでは区間の外で置いたものが黙って溜め場に積まれていた。描き場所では次の描き切りが来ないので、`beginDraw()` を書き忘れると何も描かれないまま記憶だけが 1 枚ごとに増え続けた ([#1592](https://github.com/mokume-metal/mokume/issues/1592))。描き場所へ区間の外で書いた画素は、`get()` では読めるのに `image()` には出ず ([#1654](https://github.com/mokume-metal/mokume/issues/1654))、効果を掛けた描き場所では次のフレームに効果が 2 回掛かった ([#1655](https://github.com/mokume-metal/mokume/issues/1655))。

`setup()` だけで 1 枚を描くスケッチと、止まっている間のコールバックで置いて `redraw()` する書き方は、今までどおり動く。

**移行:** 次の注意が出たら、置く行を区間の中へ移す。

- `Shapes, images and backgrounds are placed in setup(), draw() or an input callback, or between beginDraw() and endDraw() on a drawing target. …` — 描き場所へ置く行を `layer.beginDraw()` と `layer.endDraw()` で挟む (`setup()` の中でも挟む)。`Canvas` を直に使っているなら、`draw { }` の中へ移す。`Task` の続きで置いていたなら、結果を変数に受け取り、`draw()` で置く
- `Pixels are written in setup(), draw() or an input callback, or between beginDraw() and endDraw() on a drawing target. …` — 描き場所への `set()` や `pixels` への書き込みを、同じく `beginDraw()` と `endDraw()` の間へ移す。`pixels` は書くフレームの中で取り直す
