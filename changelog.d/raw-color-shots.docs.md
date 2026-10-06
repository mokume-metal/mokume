<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

素の数値 (0–255) で色を渡す 19 口 — `background` / `fill` / `stroke` / `tint` と、光の色の `ambientLight` / `directionalLight` / `pointLight` / `spotLight` / `ambient` / `emissive` — に、引数を 1 つずつ動かした例と絵を 32 枚付けた。不透明度が 0–255 に締められること (400 は 255、-100 は 0 と同じ絵)、色の成分は締められないこと (不透明度 128 の `fill(510, 0, 0, 128)` は不透明な `fill(255, 0, 0)` より明るい)、`background` の不透明度は前の絵に重ならず面を置き換えることを絵で示している。光の色の絵は既存の光・材質の絵と同じ場面で撮ってあり、`ambientLight(0.52, 0.52, 0.53)` のように 0…1 の値を渡すと真っ黒になることも並べて見られる。
