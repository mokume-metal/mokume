<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

絵を貼って塗る (`texture`) か断片 (`shader`) を効かせた `arc` の太い輪郭で、**扇の中心と弧の両端の 3 つの角に四角い出っ張りが出ていた**のを直しました。既定の `strokeJoin(.miter)` と `.bevel` では、その 3 つの角を軸に沿った正方形で埋めていたためです。何も効かせない `arc` はもとから 3 つの角を `strokeJoin` によらず丸く繋いでおり (`StrokeJoin.miter` の説明もそう書いています)、`texture` を 1 行足しただけで角の形が変わっていました。いまはどちらの描き方でも、扇の 3 つの角は丸く繋がります。`strokeJoin(.round)` で引いた絵と、何も効かせない `arc` の絵は変わりません ([#1486](https://github.com/mokume-metal/mokume/issues/1486))。

`v0.11.1` のノートでは「扇の中心と弧の両端は、これまでどおり角として `strokeJoin` に従います」とお知らせしましたが、この記述を改めます。扇の 3 つの角は、描き方によらず `strokeJoin` の外で、いつも丸く繋ぎます。
