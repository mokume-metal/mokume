<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

光の口 (`ambientLight` / `directionalLight` / `pointLight` / `spotLight`) の説明で、同じ名前の 2 つの口を互いに指し合わせた。素の数値を受ける口は塗りと同じ 0–255、`LinearRGBA` を受ける口は 0…1 (1 を超えられる) の目盛りで、`ambientLight(0.52, 0.52, 0.53)` と書くとほぼ光の無い真っ黒な絵になる。どちらの口の説明から読んでも、もう一方の目盛りに辿り着ける。参照スケッチ `SolidsAndLight` も、底上げの光を素の数値で書いて 2 つの目盛りを並べて見せる。
