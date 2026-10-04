<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`Canvas(target:gpu:)` や `Canvas(output:gpu:pixelDensity:upscale:)` で直に作った面でも、`createShape { }` の中で書いた `randomSeed()` が組み立ての外へ残らなくなりました。** これまでは本体の面と `createGraphics` の描き場所だけが直っていて、スケッチの `setup()` や `draw()` の中で直に作った面 (と、そこから `createGraphics` した描き場所) では、組み立ての後の `random()` が中で書いた種の列から続いていました。これからは面の作り方に依らず、抜けた後の列は最初に種を書く直前の状態から続きます。

**絵が変わる場合があります。** 直に作った面の `createShape { randomSeed(42); … }` の後で `random()` を引いていた作品は、組み立ての後の値が変わります。外でも種 42 を使い続けたいときは、組み立てた後で `randomSeed(42)` を書き直してください。
