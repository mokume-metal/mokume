<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`texture()` を貼ったまま・`shader()` を当てたまま `particles()` を呼ぶと、粒が貼った絵や断片の色に染まっていたのを直した。粒は `makeParticles(count:)` を呼んだ瞬間の混ぜ方と塗りで出る (保持した形と同じ)。置く時点の `texture()` / `shader()` は粒に効かない。前のフレームで貼ったまま外し忘れた `texture()` でも染まっていた。
