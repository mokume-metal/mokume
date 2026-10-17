<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

4 つの座標で引ける `noise(x, y, z, w)` を追加した。2 次元の場を、継ぎ目なくループさせられる — 時刻を円周に載せて 3 つ目と 4 つ目に渡す (`noise(x * 0.01, y * 0.01, cos(a), sin(a))`)。`a` が 1 周する間に場が巡って、元の場へ戻る。GIF や展示の繰り返しに使える。

断片の側にも `mokume_noise(in, float4(p, cos(a), sin(a)))` を足した。同じ種・同じ座標なら、CPU で引いても断片で引いても同じ値になる。`noiseSeed()` と `noiseDetail()` は 4 つ目の座標にも効く。4 つ目の座標を省くか 0 にすると、今までの 3 つの座標で引いた値とまったく同じなので、既存の絵は変わらない。4 つ目の座標を 0 以外にすると、格子の隅を 16 引くぶん 3 次元の約 2 倍の時間がかかる。
