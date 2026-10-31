<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

計算と効果の断片から、CPU の `noise()` と同じ揺らぎ `mokume_noise()` を引けるようにした。効果は `Pixel` の欄を、計算は入口に `constant Frame &frame [[buffer(MOKUME_FRAME)]]` と書くだけで、`noiseSeed()` と `noiseDetail()` が決めた種と細かさで引ける (積んだ時点のものが届く)。

計算には時刻も届くようになった。`frame.time` で読めるので、時刻を `values` に手で書き写さなくてよい。入口に書かなければ、これまでの計算は何も変わらない。
