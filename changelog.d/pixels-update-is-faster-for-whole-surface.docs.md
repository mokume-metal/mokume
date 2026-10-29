<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`Canvas.pixels` の説明に、全画素を書き換えるなら `Pixels.update` が速いことを足した。1280×720 で、窓を 1 度取って添字で全画素を書く形が 73.2 ms、同じ処理を `update` で書く形が 2.0 ms (約 37 倍) で、添字の 2 重ループは画素ごとに書いてよいかを尋ね、`update` は入口で 1 回だけ尋ねるためである。
