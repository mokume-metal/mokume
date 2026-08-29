<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**シードから同じ値が出る乱数と揺らぎが引けるようになりました。** `random()` / `randomSeed()` は呼ぶたびに進む列を、`noise()` / `noiseSeed()` / `noiseDetail()` は同じ座標に同じ値が返るなめらかな乱れを返します。種を決めなくても走らせるたびに同じ絵になります (時刻から種を作らないため)。

**同じ揺らぎが、利用者の書いた塗りからも引けます。** 断片の中で `mokume_noise(in, p)` と書くと、`noiseSeed()` で決めた同じ種の同じ値が出ます — 断片へ種を値として渡す必要はありません。面と立体で同じ模様を出すのに、揺らぎを CPU 用と GPU 用に 2 つ書き分けなくてよくなりました。
