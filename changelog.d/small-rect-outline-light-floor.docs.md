<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`strokeWeight` の説明に、短い辺が 3 画素より短い矩形の細い輪郭は、光の量の約束 (置く位置で ±25% ほどまで) の外にあると書いた。短い辺は、輪郭の中心線 (`rect` に渡した幅と高さ) の短い方を、`scale` と `pixelDensity` を掛けた後の描く画素で測った長さで、太さは含まない。`pixelDensity` を下げて描く画素で 1.92×1.28 になった矩形の輪郭は、`shader()` を掛けると期待の 0.67 倍、掛けないと 1.29 倍の明るさで出ることがある。描画は変えていない。
