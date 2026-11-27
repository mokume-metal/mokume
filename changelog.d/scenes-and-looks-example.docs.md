<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**シーンごとの値の束を、いまの見た目から次のシーンへ移す作例 `scenes-and-looks` を足した** (`swift run reference-sketches scenes-and-looks`)。1・2・3 のキーでシーンを選ぶと、輪の半径 (数値)・針の向き (角度)・色・塗りか輪郭か (真偽) が 2 秒かけて移る。遷移の途中で別のシーンを指定しても、そのとき表示していた値から移るので、値は跳ばない。

値の束と補間は、作例の構造体と関数として書いてあり、本体の API は足していない。数値は `lerp`、角度は最短の弧の `lerpAngle` (350° から 10° へは 20° だけ回る)、色は `lerpColor`、進み具合の曲線は `smoothstep` を使い、補間できない真偽の値は遷移の進み具合が半分を越えたところで切り替える。
