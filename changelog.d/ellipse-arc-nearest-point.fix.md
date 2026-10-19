<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

楕円の扇 (`arc`) の輪郭が、弧の端の近くで帯の外へにじんだり、欠けたりしていたのを直した。`noFill()` で `strokeWeight(22)` の `arc(0, 0, 80, 20, 0.3, 2.9)` は、扇の外側に輪郭の色が最大 67% にじんでいた。既定の太さ 1 の扇でも、半径比 2:1 ほどの楕円では、弧の端の近くの帯の縁が最大 15〜25% 外れていた。円の扇の絵は変わらない。
