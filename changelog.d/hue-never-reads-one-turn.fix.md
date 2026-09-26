<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`hue(_:)` が赤の色相として 0 ではなく 360 を返すことがあったのを直した。`hue(color(255, 0, 0))` や `hue(color(hue: 0, saturation: 100, brightness: 100))` は 0 を返し、返る値はいつも 0 以上 360 未満になる。

これまでは `color(r, 0, 0)` の約半数と、g と b が等しい赤みの一部が 360 を返していた。`if hue(c) < 30` のような赤の判定から赤が漏れ、`Int(hue(c) / 360 * n)` で区画を引くと添字が範囲の外 (`n`) になっていた。
