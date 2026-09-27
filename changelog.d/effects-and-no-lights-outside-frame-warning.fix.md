<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`setup()` や、`noLoop()` で止めている間の入力のコールバック (どちらもフレームの外) で呼んだ `effects()` と `noLights()` が、黙って捨てられることがなくなった。視点・光・切り抜きと同じく、「フレームごとに書き直すものなので、描くところ (draw) で呼んでください」と一度だけ知らせ、何も変えない。

これまで `effects()` は外で決めた並びを受け取ったまま次のフレームの頭で黙って捨て、`noLights()` は取り除く光が無いので何も言わずに戻っていた。どちらも効かないことは変わらず、`draw()` の中と、描き場所 (`createGraphics`) の `beginDraw()` 〜 `endDraw()` の間で呼んだときの振る舞いも変わらない。絵は変わらない。
