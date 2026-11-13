<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`strokeWeight` の説明に、描く画素で短い辺が 3 画素より短い矩形の細い輪郭は、光の量の約束 (置く位置で ±25% ほどまで) の外にあると書いた。`pixelDensity` を下げて描く画素で 1.9×1.3 ほどになった矩形の輪郭は、`shader()` を掛けると期待の 0.67 倍、掛けないと 1.29 倍の明るさで出ることがある。描画は変えていない。
