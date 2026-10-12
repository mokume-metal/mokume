<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`shape(_:at:)` で、三角形で組む図形と距離関数で描く図形 (`triangle` と `rect` など) が混ざった形や、途中で `blendMode` を変えた形を、重なる置き場所へまとめて置くと、**重なりの前後が 1 つずつ置いたときと入れ替わっていた**のを直しました。前の置き場所の後に描いた図形が、後の置き場所の先に描いた図形の上に出ていました。いまはまとめて置いても、1 つずつ置いたときと同じ置き場所の順に重なり、絵はビット単位で同じになります ([#2305](https://github.com/mokume-metal/mokume/issues/2305))。

その代わり、こうした形 (`Shape.drawCallCount` が 2 以上で、立体以外を含む形) をまとめて置くと、描く回数が置き場所ごとに `drawCallCount` 回になります (1 つずつ置いたときと同じ回数)。`drawCallCount` が 1 の形と、立体だけでできた形は、これまでどおりまとめて置いても描く回数は増えません。
