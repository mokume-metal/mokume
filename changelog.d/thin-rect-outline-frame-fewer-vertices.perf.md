<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`shader()` を掛けた矩形の 1 画素より細い輪郭を、1 つあたり 120 頂点から 24 頂点 (`strokeJoin(.bevel)` は 156 頂点から 60 頂点) で組むようにして軽くしました。v0.43.0 で入れた「45° 近くに回した細い輪郭の光の量 (濃さ) が 1 割以上多く出る」直しを戻したもので、細かさ (`pixelDensity`) 0.5 で 1 つずつ違う角度に回した 12×8 の輪郭つきの `rect` 5,000 個で、1 フレームの CPU 時間が 37 ms から 28 ms、同じ角度に畳める 24×16 の 5,000 個で GPU の時間が 0.47 ms から 0.38 ms になりました。

代わりに、45° 近くに回して縁が画素の中心とほぼ重なる置き方では、v0.43.0 より前と同じく光の量が期待より多く出て、角の近くで輪郭が 2 画素の太さに見えることがあります。細かさ 0.32 で角度 0.786 に回した `strokeWeight(1)` の 40×20 の `rect` で、期待より最大 21% 多く出ます (v0.43.0 では 7%)。光の量の許容 ±25% の内に収まることを、角の形 (`.miter`・`.bevel`) と矩形の寸法を振って確かめています ([#3862](https://github.com/mokume-metal/mokume/issues/3862)・[#3859](https://github.com/mokume-metal/mokume/issues/3859))。
