<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

乱数と揺らぎの 7 口 — `random()` / `random(_:)` / `random(_:_:)` / `randomSeed(_:)` / `noise(_:_:_:)` / `noiseSeed(_:)` / `noiseDetail(_:_:)` — に、引数を 1 つずつ動かした例と絵を 10 枚付けた。`random()` を割合と比べてマスを塗る使い方、`random(_:)` に負の値を渡すと逆の側へ散らばること、`random(_:_:)` は端を逆の順に渡しても同じ幅に散らばること、同じ種なら同じ並び・同じ線が出ること、近い `z` には近い模様が返ること、`noiseDetail` の枚数と弱まりを大きくすると細かい揺れが乗ることを、どれも種を固定した絵で並べて見られる。
