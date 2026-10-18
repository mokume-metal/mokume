<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`createShape { }` の中で、断られた `beginDraw()` と対の `endDraw()` が、組み立ての前に開いたフレームを閉じてしまう不具合を直しました。** 組み立ての中ではその面のフレームを始めず (`beginDraw()` は何もしない)、補助の関数が中で `beginDraw()` 〜 `endDraw()` の対を呼ぶと、対の `endDraw()` が外のフレームを組み立ての出口で閉じ、出口の後に置いたものがフレームの外として捨てられ、呼び手の最後の `endDraw()` が「`beginDraw()` より前」と注意していました。いまは断られた `beginDraw()` と対の `endDraw()` も何もせず、外のフレームは呼び手の `endDraw()` で閉じます。あわせて、組み立ての中で `beginDraw()` を書き忘れて `endDraw()` を呼んだときの注意が「`beginDraw()` でフレームを始めようとした」ではなく、本来の「`beginDraw()` より前に `endDraw()` を呼んだ」になり、その後に本当に断られた `beginDraw()` の注意も出るようになりました。組み立ての前に開いたフレームを組み立ての中の `endDraw()` で閉じる書き方 (組み立ての出口まで待たせる) は、今までどおりです。
