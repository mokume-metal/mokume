<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

立体の線の太さが、投影の縦横比を面と違えても画面の画素で保たれるようになった。`perspective(fov, aspect, …)` の `aspect` や `ortho(left, right, …)` の横幅を面と違えると、これまでは立体の線の帯と丸い端・折れ目が画面で横に伸び (`aspect` を 0.5 にすると横の太さが 2 倍)、斜めの線の帯は画面の垂線から傾いていた。線の太さを画面の横と縦で別々に測るので、立体は伸びて写っても、`strokeWeight` の値はどの向きにも画素のまま、丸い端は円のままになる。面と同じ縦横比の投影 (`perspective()`・`ortho()` や、`perspective(fov, width / height, …)`) の絵は 1 ビットも変わらない。
