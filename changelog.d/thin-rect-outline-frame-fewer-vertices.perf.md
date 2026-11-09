<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`shader()` を掛けた矩形の 1 画素より細い輪郭を、1 つあたり 120 頂点から 24 頂点で組むようにして軽くしました。細かさ (`pixelDensity`) 0.5 で 1 つずつ違う角度に回した 12×8 の輪郭つきの `rect` 5,000 個で、1 フレームの CPU 時間が 37 ms から 28 ms、同じ角度に畳める 24×16 の 5,000 個で GPU の時間が 0.47 ms から 0.38 ms になりました。代わりに、45° 近くに回して縁が画素の中心とほぼ重なる置き方では、光の量 (濃さ) が期待より最大 2 割ほど多く出ることがあります ([#3862](https://github.com/mokume-metal/mokume/issues/3862)。許容 ±25% の内・[#3859](https://github.com/mokume-metal/mokume/issues/3859))。
