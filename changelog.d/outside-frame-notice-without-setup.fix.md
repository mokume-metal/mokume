<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

フレームの外で視点・変換・光・影・材質・効果などを書いたときの注意が、**どこで書いても「setup の間に書いた」と名乗っていた**のを直した。`noLoop()` で止めた後の `mousePressed()` で `translate(10, 0)` を書いても `The transform written during setup belongs to no frame, and was ignored` と出て、setup で書いた覚えの無い人に直す場所を取り違えさせた。いまは `This was called outside a frame, so it belongs to no frame, and was ignored` と、フレームの外で呼ばれたとだけ言う。同じ注意を `noLights()`・`perspective()`・`popStyle()`・`force()` などでも言うので、「置いた」「積んだ」のような口ごとの言い方もやめ、11 種とも同じ 1 文にした。前半の「`draw()` から呼ぶ」という案内と、書いたものを無視して 1 度だけ知らせる振る舞いは変わらない。視点・光・計算の説明と利用の手引きも、`setup()` だけでなく止まっている間の入力のコールバックで書いたものも無視されると書くよう揃えた。
