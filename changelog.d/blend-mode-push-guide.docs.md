<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`blendMode(_:)` の説明に、一部の図形だけ混ぜ方を変えて戻す書き方を足しました。`push { }` で包めば、抜けたときに混ぜ方が前の値へ戻ります。変換も戻ること、スタイルだけ戻すなら `pushStyle()` / `popStyle()` があることも書いています。
