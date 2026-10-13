<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`textBounds()` が、絵文字などの色を持つ字形の墨も囲むようになりました。** これまでは `textBounds("🌲", x, y)` が `nil` を返し、`textBounds("A🌲", x, y)` は `A` だけを囲んでいたので、絵文字の入ったラベルを枠で囲むと絵文字が枠の外へはみ出しました。いまは `text()` が描く絵文字の墨まで、送り幅の余白を含めずに囲みます。
