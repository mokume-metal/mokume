<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

半径の違う `sphere()` をたくさん置くスケッチが速くなりました。半径の違う球 1,000 個を毎フレーム置く場面で、1 フレームが 15.5 ms から 1.2 ms になります (Apple M3 Max)。球の形を半径ごとに組み直さず、1 組の単位球を GPU で半径に広げて描くためです。絵と、`loadShader` の断片が読む `shapePosition` は 1 ビットも変わりません。
