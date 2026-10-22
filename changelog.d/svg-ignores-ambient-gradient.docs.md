<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**読んだ SVG (`loadShape`) と `createShape { }` で色を塗った形は、置く前の `fill(.linearGradient(…))`・`fill(.radialGradient(…))` では塗れないことを、説明文で名乗るようにしました。** これらの形は記録した色で出る (色は形に焼き付く) ので、置く前に決めた勾配は、色の `fill` と同じく効きません。形を勾配で塗るなら、`createShape { }` の中で `fill(_: Gradient)` を渡します。読んだ SVG を勾配で塗る口はまだありません。SVG に書いた `<linearGradient>`・`<radialGradient>` も、いまは読みません。検査でこの振る舞いを固定しました。
