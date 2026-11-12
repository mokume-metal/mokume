<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

同時に存在できる数 (64 個) を越えて作った合成音 (オシレータ・ノイズ) に `play()`・`play(at:)`・値つきの `play`・`Env.play` を呼ぶと、音は鳴らないのに `isPlaying` が `true` になっていたのを直しました。スケッチが終わった後に呼んだときも同じでした。どちらも鳴らないので、`isPlaying` は変わりません (スケッチが終わる前から鳴らしていた音は `true` のまま)。
