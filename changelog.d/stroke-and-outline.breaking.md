<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

図形が**塗りと輪郭の両方**を出すようになった。線の端の形 (丸・長さちょうどで切る・半分だけ出っ張らせる) と折れ目の形 (尖らせる・削ぐ・丸める) を選べる。塗りだけ・輪郭だけにする `noFill` / `noStroke` も入った。

**これまでに書いたスケッチの絵は変わる** — 輪郭を出したくない図形には `noStroke()` を呼ぶ。
