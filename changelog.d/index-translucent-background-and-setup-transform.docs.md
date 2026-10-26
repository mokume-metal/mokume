<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

入口の「手本の名前から引く」に、p5.js 2D の `background(0, 20)` が残像にならないことと、`setup()` で書いた `translate` などが無視されることの 2 行が足されました。

どちらも黙ってずれる口で、残像の作り方は `background` の説明、`draw()` の中で書いて `noLoop()` で止める形は「状態の寿命」の節へ辿れます。
