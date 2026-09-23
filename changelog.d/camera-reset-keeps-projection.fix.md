<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

引数なしの `camera()` が、視点だけでなく投影まで既定の透視へ戻していたのを直しました。`ortho()` の後に `camera()` を書くと、その後に置いた立体が透視で写っていました。`camera()` が戻すのは見る位置・見ている先・上方向だけになり、`ortho(…)` や `perspective(…)` で決めた写し方はそのまま残ります。9 引数の `camera(…)` や `perspective()` / `ortho()` と同じく、どこから見るかと、どう写すかを別々に扱います。写し方も既定の透視へ戻したいときは `perspective()` を合わせて書いてください。
