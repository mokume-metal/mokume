<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`textOutline(_:_:_:spacing:)` で、文字の輪郭の点を等間隔に取れるようになりました。`spacing` に画素で間隔を渡すと、周ごとに周の長さを均等に割る点が返るので、`I` や `T` の縦画の途中にも点が並び、粒が字の形に並ぶ絵を書けます。`spacing` を省いた `textOutline(_:_:_:)` は、これまでの折れ目の点のままです。

`spacing` が 0 以下・数でない値のときは、1 度だけ知らせて折れ目の点を返します。p5.js の `textToPoints` / `textToContours` の `sampleFactor` は書体の単位に対する比ですが、`spacing` は画素です。
