<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`loadShape` で読んだ SVG の群と要素の `opacity` が、重なった所だけ濃く描かれていたのを直した。`<g opacity="0.5">` の中で重なる白い矩形 2 つは、重なりが alpha 191 になっていたが、SVG のとおり群をまとめて描いてから 1 度だけ掛けるので、重なりも単独の所も alpha 128 になる。塗りと線を両方持つ要素の `opacity` (線が塗りに重なる帯)、部分パスどうしが重なる半透明の線 (`<path d="M20 40 H140 M80 10 V120" stroke-opacity="0.5"/>` の交わる所) も同じく 1 度だけ混ざる。Illustrator や Figma から持ち込んだ半透明のロゴが、作った見た目のまま出る。

まとめて描くのは重なりのある半透明の群と、塗りと線を両方持つ半透明の要素だけで、置くたびに外接の大きさの中間面を 1 枚使う。重ならない群・`opacity` が 1 の群の絵と費用は変わらない。`createShape { }` の中で置いた形や `Shape.group` で組んだ形も、まとめて描く範囲を引き継ぐ。既定と違う視点 (`camera()`・`ortho()` など) の下・奥行きのある変換で置く・`pixelDensity` が 1 未満・`blendMode(.replace)` では中間面を使えないので、これまでどおり子の色ごとに掛けて描き、そのことを 1 度知らせる。重なりを知らせていた近似の注意 (`drew opacity as an approximation`) は出なくなった。
