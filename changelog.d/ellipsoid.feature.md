<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`ellipsoid(x, y, z)` を足した。軸ごとに半径を決めた球で、3 つが等しければ `sphere()` と同じ形になる。組み込みの原形はこれで 7 つ揃う。

同じ形は `push()` / `scale()` / `sphere()` / `pop()` でも作れるが、そちらは置き場所の変換を動かすので後続へ残さないよう挟む必要がある。`ellipsoid()` は形の側が半径を持つので変換は汚れない。
