<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

スケッチが終わった後や、`setup()`・`draw()`・入力のコールバックの外 (`Task` の中など。それまでに合成音を 1 つも作っていないとき) で作った合成音 (オシレータ・ノイズ) に `play()`・`play(at:)`・値つきの `play`・`Env.play` を呼ぶと、警告が出て音は鳴らないのに `isPlaying` が `true` になっていたのを直しました。鳴らないので、`isPlaying` は `false` のままです。
