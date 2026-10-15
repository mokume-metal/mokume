<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`rect` / `ellipse` / `circle` の輪郭が形より太い (線の内側の穴が潰れる) か、穴が 1 画素より細いとき、輪郭の帯が欠けて背景が透けていたのを直した。`noStroke()` を書かずに描いた 1 画素より細い塗り (`rect(x, y, 0.6, 20)` や `ellipse(x, y, 0.7, 20)`) の輪郭も、塗りとの継ぎ目で背景が最大 84% 透けていたが、透けなくなった。`noFill()` の細長い楕円に太い輪郭を付けた形 (`ellipse(80, 80, 100, 6)`・`strokeWeight(20)`) で、長軸に沿って帯が抜けていたのも直った。混ぜ方 (`blendMode`) によらず同じに直る。
