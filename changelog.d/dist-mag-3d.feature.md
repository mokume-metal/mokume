<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

空間の 2 点の距離 `dist(x1, y1, z1, x2, y2, z2)` と、3 成分の大きさ `mag(x, y, z)` を追加した。3 次元の距離をピタゴラスの定理で手書きしなくてよくなる。

数は `Float`・`Double`・`Int` のどれでも渡せて、返すのは `Float`。平面の `dist`・`mag` と同じく、2 乗が溢れる大きさでも距離は有限で返り、数でない値・無限の値が混じったときは 0 を返して 1 度だけ注意を言う (平面の口とは別に数える)。
