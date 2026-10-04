<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`createShape { }` の中で書いた `randomSeed()` が、組み立てのあとに引く `random()` の列まで変えていたのを直しました。** 中で種を書くと、そこから抜けるまでは中で決めた列で引き、抜けた後の列は、最初に種を書く直前の状態から続きます。描き場所 (`createGraphics`) の `createShape { }` でも、`setup()` と `draw()` のどちらで組み立てても同じです。種を書く前に中で `random()` を引いた分と、種を書かずに引いた分は、これまでどおり外の列を進めます。入れ子の組み立ては 1 段ごとに戻り、内側を抜けた直後は外側が書いた種の列の続きになります。

**絵が変わる場合があります。** `randomSeed(1)` の後に `createShape { randomSeed(42); … }` を呼んでいた作品は、これまで組み立ての後の `random()` が種 42 の列から続いていましたが、これからは種 1 の列から続きます。外でも種 42 を使い続けたいときは、組み立てた後で `randomSeed(42)` を書き直してください。`createShape` の説明と `randomSeed(_:)` の説明にも書き足しました。
