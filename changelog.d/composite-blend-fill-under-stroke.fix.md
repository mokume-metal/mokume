<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`blendMode(.add)` など下地を読む混ぜ方 (`.add` / `.subtract` / `.lightest` / `.darkest` / `.difference` / `.exclusion` / `.multiply` / `.screen`) で、塗りと輪郭を両方持つ `rect` / `circle` / `ellipse` / `arc` を描くと、不透明な輪郭の帯の内側半分で塗りが消えていたのを直しました。輪郭の不透明度を 254 から 255 へ上げただけで絵が不連続に変わっていました。いまは、塗りだけの図形の上に輪郭だけの図形を重ねて描いたのと同じ絵になります。`.blend` と `.replace` の絵は変わりません。
