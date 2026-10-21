<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

線を破線で引く `strokeDash(length, gap)` を追加した。長さと間隔は画素で、`strokeDash(4, 4)` の後に引いた `line()` と、`beginShape()` で並べた開いた線は、長さ 4・間隔 4 の破線になる。`noStrokeDash()` で実線へ戻す。

端の形 (`strokeCap`) は破線の 1 つずつに付き、折れ線では模様が曲がり角をまたいで続く。長さを 0 にして丸い端で引くと点線になる。`pushStyle()` / `popStyle()` で他の線のスタイルと同じく戻り、`createShape()` の中で指定した破線は形に焼き付く。負の値・数でない値・無限・両方 0 の指定は、実線で引いて 1 度だけ知らせる。

いまのところ破線になるのは平面の開いた線だけで、`rect()`・`ellipse()` などの閉じた輪郭と、奥行きを持つ線は実線のまま。格子の補助線を実線と破線で描き分ける参照スケッチ `dash-and-grid` を足した。
