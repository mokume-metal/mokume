<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

立体を塗る断片が、面の向きを**世界の座標**と**視点から見た座標**でも受け取れるようになった。`Fragment` の `worldNormal` (置き場所の変換を通した後の向き・光が当たるのと同じ向き) と `viewNormal` (x が画面の右・y が画面の下・z が手前) がそれで、どちらも形を回すと値が変わる。これまで届いていた `shapeNormal` は形自身の座標なので、回しても面ごとの色が留まり、p5.js の `normalMaterial()` のように「回すと色が泳ぐ」塗りが書けなかった — `viewNormal` を色にすればそれが書ける。`worldNormal` は視点を動かしても変わらず、`viewNormal` は変わる。3 つとも長さ 1 で、向きを持たない頂点 (立体の線と点) と平面の図形では 0、形から求めた向きは裏から見ると 3 つそろって見えている側へ裏返る。
