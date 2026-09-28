<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`hue()` / `saturation()` / `brightness()` が約 2.3 倍速くなりました (1 回 42 ns → 18 ns)。色の 3 成分を読む同じ計算を、3 度繰り返していたためです。画素を色相で並べ替えるような、1 フレームに何十万回も呼ぶ書き方で効きます。返す値は 1 ビットも変わりません。
