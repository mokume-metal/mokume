<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

縦と横で違う拡大の下で一部の線だけが 1 画素より細くなる `Path` (部分道が 2 本以上) や `beginShape` の線は、細い線と太い線が交わる所の濃さが、部分道を書いた順で変わらなくなった。これまでは細い側を先に書くと、不透明な太い線が交わる所だけ細い線の濃さ (alpha 255 のはずが 204) に落ちていた。いまは書いた順によらず、交わる所には太い線が残る。`quad` の輪郭と、`shader()` を効かせた `rect`・`.pie` の `arc` の輪郭 (保持した形を潰して置いたときも) で、細い辺と太い辺が重なる所も同じく太い辺が残る (これまでは 204 など)。保持した形 (`createShape`) を潰して置くときと、半透明の SVG の `<path>` の線も同じ。被覆の揃った線の絵は変わらない ([ADR-0046](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0046-stroke-stencil.md) 段 5 の改訂)。
