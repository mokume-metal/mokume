<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

文字列を組版して描く口 `shapedText(_:_:_:)` と、組版した幅 `shapedTextWidth(_:)`・墨の範囲 `shapedTextBounds(_:_:_:)` を足した。肌色の修飾子を付けた `👍🏽`・国旗の `🇯🇵`・ZWJ で繋いだ `👨‍👩‍👧`・異体字セレクタを付けた `❤️`・囲みを付けた `1️⃣` が、部品に分かれず 1 字で描かれ、結合文字 (`e` + アクセント) は基の字に重なる。ラテンの字にはカーニングが掛かる ([#2404](https://github.com/mokume-metal/mokume/issues/2404))。

既存の `text()`・`textWidth()`・`textBounds()` は変わらない (スカラ 1 つずつ並べ、部分の幅を足すと全体の幅になる)。描く・幅・整列・墨の範囲は、新しい口では 1 つの組版結果から出る。右から左へ書く文字の並べ替えと文脈による字形の変化は保証せず、矩形への流し込み (`text(_:_:_:_:_:)`)・`textOutline()` は組版しない。
