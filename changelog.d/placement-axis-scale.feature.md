<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`Placement` が軸ごとの倍率を持てるようになった。** `Placement(x: 100, y: 200, scale: Vector3(1, 4, 1))` のように倍率を `Vector3` で渡すと、`shape(_:at:)` で置いた形が、`push()`・`translate(100, 200, 0)`・`scale(1, 4, 1)` を同じ順で書いて置いたものと同じ絵になる。高さだけ伸ばした箱 (棒グラフの街並み・音の柱) を、箱 1 つの形から `[Placement]` でまとめて置ける。

倍率は形自身の軸に掛かり、回転より先に効く (大きさ → 回転 → 位置)。値は `axisScale` プロパティでも読み書きでき、一様の `scale` と掛け合わさる。数でない値・無限を含む倍率の置き場所は、これまでの `scale` と同じく置かれない。`Placement(x: …, scale: 2)` のように一様の倍率で書いた既存の呼び出しは、書き換えずにそのまま組み上がり、絵も変わらない。
