<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`text()` と `textWidth()` の説明に、字を Unicode のスカラ 1 つずつ引き当てて並べ、組版をしないことを書いた。肌色の修飾子を付けた `👍🏽`・国旗の `🇯🇵`・ZWJ で繋いだ `👨‍👩‍👧` のような複数のスカラでできた絵文字は 1 字にならず部品ごとに描かれ、`textWidth()` はその部品の幅の和を返す。描き方も幅も変えていない。
