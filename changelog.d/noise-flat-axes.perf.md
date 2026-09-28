<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`noise(x)` と `noise(x, y)` が速くなりました (1 回 28 ns → 14 ns / 21 ns)。使わない奥行き・縦の軸についても、格子の隅の値を引いていたためです。返す値は 1 ビットも変わらず、`noise(x, y, z)` の速さも変わりません。
