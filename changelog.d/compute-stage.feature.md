<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**描く前に GPU で計算させ、その結果で描けるようになりました。** `makeNumbers(count:)` で CPU と GPU が分け合う数の並びを用意し、`makeComputation(_:name:values:)` で計算の断片を作り、`draw()` の中で `compute(step, over: 4096, reads: [...], writes: [...])` と頼みます。断片の中の入口の関数は名前と同じ (`kernel void step(...)`) で、`reads + writes` の並びがそのまま `buffer(0)`, `buffer(1)`, … になります。2 次元は `compute(step, over: 幅, by: 高さ, …)`。計算が書いた並びは `numbers(_:)` で塗りへ渡し、断片からは `in.numbers[i]` で読めます。

**読むものと書くものを言うと、順序は仕組みが決めます。** 前に頼んだ計算が書いた並びに触れる計算はその計算が終わってから走り、触れない計算どうしは並行に走ります。計算と描画の間の同期も仕組みが入れるので、待つ仕掛けを自分で書くことはありません。**計算を頼まなかったフレームでは何も待たない**ので、計算を使わないスケッチが遅くなることはありません。計算は `draw()` の中でだけ効き、外から頼んだものは理由を添えて無視されます。CPU から並びへ書けるのは種を蒔く向きだけで、GPU が書いた値を読むのは `read(_:)` を通ります。
