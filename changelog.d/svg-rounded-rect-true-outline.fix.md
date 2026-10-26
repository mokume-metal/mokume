<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`save("x.svg")` で、`texture()` を効かせた輪郭つきの角丸 `rect` と弧 (既定・`.chord`・`.open`)、破線の角丸 `rect`・楕円・円・弧の輪郭が、周を刻んだ折れ線でなく、実線の同じ図形と同じ真の形 (3 次ベジェ) で書かれるようになった。破線は破線の指定 (`stroke-dasharray`) を載せて書く。画面の絵は変わらない。破線の角丸 `rect` だけは、SVG の道が上辺の左端 (角の弧の終わり) から始まり、画面の破線は右上の弧の始まりから数えるので、破線の山谷の位置が (幅 − 2 × 半径) ぶんずれる。
