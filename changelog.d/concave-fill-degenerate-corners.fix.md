<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`textOutline` で取った字を `beginShape()` / `vertex` / `endShape(.close)` で塗っても、字が壊れなくなりました。** これまでは H や K のように辺の途中へ別の角が載る字で塗りが形の外へはみ出し、O や 8 のように穴を持つ字では途中で塗りが欠けていました。

利用者が頂点を並べた凹多角形でも同じことが起きていました。辺の上に別の角が触れる形、同じ位置の点が続く形 (最後に最初の点をもう一度置いた形を含む)、同じ点を 2 度通る形も、形どおりに塗られます。
