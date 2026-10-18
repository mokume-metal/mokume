<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

リファレンスの入口に「手本の名前から引く」表ができました。Processing・p5.js の名前で書いて通らない・動きが違うときに、mokume のどの口へ直せばよいかを引けます。

たとえば Processing の形で `func mouseDragged() { … }` と書くと、コンパイルは通るのに一度も呼ばれません。表と `mouseDragged(deltaX:deltaY:)` の説明に、`func mouseDragged(deltaX: Float, deltaY: Float)` と書き直せばドラッグで呼ばれることを書きました (`mouseWheel` も同じ)。ほかに `saveFrame` の番号・p5 の `deltaTime` (ミリ秒と秒)・`movedX`・`keyPressed()` の連射・`keyIsDown`・`PVector` などの直し方が並びます。
