<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`texture()` を貼ったまま・`shader()` を当てたまま `particles()` を呼ぶと、粒が貼った絵や断片の色に染まっていたのを直した。粒は `makeParticles(count:)` を呼んだ瞬間の混ぜ方と塗りで出る (保持した形と同じ)。置く時点の `texture()` / `shader()` は粒に効かない。前のフレームで貼ったまま外し忘れた `texture()` でも染まっていた。

**これまで `shader(s)` を当ててから `particles()` を呼んで粒を塗っていたスケッチは、塗られなくなる。** 断片は `makeParticles(count:)` の前に当てる。そのとき断片に渡した値も作った瞬間のものが残るので、作った後で値を変えても粒は動かない。フレームごとに動かすなら、作る前に `numbers(_:)` で数の並びも置き、断片はその並びを読むように書く。並びへ書いた値は次に描く粒に出る。
