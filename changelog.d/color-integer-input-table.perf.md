<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`color(r, g, b)` や `fill(r, g, b)` のように 0〜255 の整数で色を作る処理が、およそ 2 倍速くなった。これまでは整数の入力でも成分ごとに `pow` を呼んでいたが、出口が使っている 256 段の表で引くようにした。画素ごとに色を作るループで 200 万回呼ぶと 45 ms → 22 ms (release・M3 Max)。返る色は 1 ビットも変わらない。`color(map(noise(…)))` のような整数でない入力は、これまでと同じ計算を通る。
