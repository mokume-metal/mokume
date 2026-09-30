<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

白をずっと越える明るさ (灰色でおよそ `background(27400)` 以上) で `background()` を塗ると、その上に描いた不透明な図形が黒く抜けていたのを直した。面に置ける明るさの上限を越えた色が、塗り直しでは無限大として置かれ、その上の図形の色が数でなくなっていた。`set()`・`pixels`・`Image` の `set` / `fill` で書いた色も同じだった。どれも図形で塗ったときと同じく上限 (線形の値で 65504) で止まるようになる。色の値そのものは締めないので、`red(color(40000))` は 40000 のままである。
