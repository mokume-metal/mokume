<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

文字列を描いたときに墨が載る範囲を返す `textBounds(_:_:_:)` と、その値の `TextBounds` (`x`・`y`・`width`・`height`) を足しました。p5.js の `textBounds` と同じく、同じ引数で `text()` を描いたときの墨を、左上を原点に囲みます。`textAlign` の横・縦に従い、`rectMode` や変換には依りません。`textWidth` は字の左右の余白を含む送り幅なので、字の中心を送り幅で取ると `1` のような余白の大きい字が片寄って見えます。墨の中心はこの枠から取れます。墨が無いとき (空の文字列・空白だけ・大きさ 0) は `nil` を返します。
