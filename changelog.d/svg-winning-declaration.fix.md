<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`loadShape(_:)` と `requestShape(_:)` で、SVG の同じ性質に宣言が重なったとき、CSS のとおり勝った宣言だけが効くようにした。これまでは勝った宣言が `inherit`・`none`・読めない値だと、負けた宣言の値が残っていた。`<g fill="blue"><rect fill="red" style="fill: inherit"/></g>` は赤ではなく青で塗る。`inherit` は `opacity`・`display`・`clip-path` などの受け継がない性質でも親の値を取る (`<g opacity="0.5"><rect opacity="0.2" style="opacity: inherit"/></g>` は 0.25)。`inherit` を書いた SVG は、色・不透明度・描くかどうかがブラウザと同じ見え方に変わりうる。

`display` は CSS Display の値 (`block`・`inline flex` など) だけを読み、読めない値 (`abc`) は捨てたものとして知らせ (`display "abc"`)、下に書いた `none` を消さなくなった。`<rect display="none" style="display: abc"/>` は描かない。`display="none"` の要素は、その要素の読めない値も知らせない。`clip-path`・`mask`・`filter`・`marker`・`mix-blend-mode` は、上に書いた `none` (`normal`) が下の効果を打ち消すので、何も捨てていない SVG で「捨てた」と知らせなくなった。読めない値 (`clip-path: bogus`) は効果を捨てたとは言わず、値が読めなかったと知らせる (`clip-path "bogus"`)。
