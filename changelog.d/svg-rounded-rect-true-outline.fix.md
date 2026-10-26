<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`save("x.svg")` で、`texture()` を効かせた輪郭つきの角丸 `rect` と、破線の角丸 `rect` の輪郭が、周を刻んだ折れ線でなく、角丸の矩形そのもの (四分円の 3 次ベジェ) で書かれるようになった。貼る絵の無い実線の角丸と同じ要素・同じ起点になる。画面の絵は変わらない。
