<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

断片の中で揺らぎの傾きを引ける `mokume_noiseGradient(in, p)` を追加した。`mokume_noise(in, p)` が返す値を座標の各軸で微分したもの (∂/∂x, ∂/∂y, ∂/∂z) が、渡した座標と同じ次元 (`float3` / `float2` / `float`) で返る。揺らぎを高さとみた面の向きを作るのに、隣を引いて差を取らなくてよい — 画素の差 (`dfdx` / `dfdy`) から作った傾きは 2×2 画素ごとの段になるが、この傾きは格子の繋ぎ方を閉じた形で微分したものなので、画素ごとに滑らかに変わる。種・重ねる枚数・弱まりは `noiseSeed()` / `noiseDetail()` で決めたものが値と同じように効く。

傾きは断片の側にだけあり、Swift の `noise()` には対応するものが無い。値と傾きの両方が要るときは `mokume_noise` と別々に呼ぶ。
