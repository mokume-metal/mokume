<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`save("x.svg")` で書き出した SVG の、穴を持つ形の塗り方が画面と同じになった。

これまでは、穴のある形を穴の向きによらず常に `fill-rule="evenodd"` で書いていたので、`beginContour()` の穴を外周と同じ向きに並べたとき、画面では穴にならずに塗られるのに、書き出した SVG では穴が抜けていた。いまは穴の有無で規則を替えず、画面と同じ回り数の規則 (`fill-rule` を書かない) で書く。外周と逆向きの穴はどちらでも抜ける。
