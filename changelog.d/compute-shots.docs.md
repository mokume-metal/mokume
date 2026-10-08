<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

数の並びと GPU の計算の口 — `makeNumbers(count:)` / `makeComputation(_:name:values:)` / `compute(_:over:reads:writes:)` / `compute(_:over:by:reads:writes:)` / `numbers(_:)` / `resetNumbers()` / `read(_:)` — に、引数を 1 つずつ動かした例と絵を 14 枚付けた (うち動く絵 2 本)。並びの長さだけ升が出る、`name` で入口の関数を選ぶ、`set` で差し替えた値は頼んだ時点のものが効く、走らせる数だけ並びの先頭が書かれる、前の計算が書いた並びを読む計算は後に走る、`setup()` で頼んだ計算は走らない、並びを読む図形は置いた時点ではなく描き切りの時点の中身で描かれる、`resetNumbers()` は並びの中身を消さずに読まない状態へ戻しその状態がフレームを越える、読むたびにそこまでに頼んだ計算の結果が返る、といった説明文の主張を、絵で見られる。`loadComputation(_:values:)` は `makeComputation(_:name:values:)` の絵を指す。
