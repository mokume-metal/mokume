<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`createGraphics` の説明の冒頭に、描き場所へ描く 3 つの書き方 (`draw(into:)`・`Canvas.draw`・`beginDraw()` / `endDraw()`) の使い分けの表が付きました。素の `circle` がどこへ描かれるか、描き切りの失敗がどう伝わるかを一目で選べます。

最初の例は `draw(into:)` と `setup() throws` の形になり、`draw(into:)` の説明には、本体より小さい描き場所へマウス座標を写す例 (`mouseX * width / 400`) と、その筆跡の絵が付きました。
