<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`beginContour()` で開けた穴が、置く位置によらず形どおりに抜けるようになりました。** これまでは穴を外周の左寄りに置くと、塗りが半分近く欠けていました。穴を 2 つ以上開けた形でも、右の穴と左の穴の並び方しだいで塗りが欠けたり外へはみ出したりしていました。`createShape` で記録した形や、奥行きを持つ `vertex(x, y, z)` で並べた形も同じように直っています。
