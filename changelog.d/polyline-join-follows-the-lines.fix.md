<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`beginShape()` で並べた太い線の折れ目 (`strokeJoin(.miter)` / `.bevel`) を、出会う 2 本の線の向きと太さだけで決まる形で埋めるようにした。これまでは座標軸に沿った正方形で埋めていたので、斜めに一直線に並べた点で角が線の外へはみ出し、回してから描くと形が変わっていた。`miter` は尖りが角から線幅 × √2 / 2 より先へ伸びる所で先を平らに切り (直角は尖ったまま)、`bevel` は角から線幅の半分の所で削ぐ。`triangle()` や `quad()` を三角形の経路で描いたとき、`vertex(x, y, z)` の折れ線、組み込みの立体 (`plane`・`cylinder`・`cone` など) の稜線で 2 本だけが出会う角も、同じ形になる。同じ位置の点が続く所 (曲線で始点へ戻る周・字形の輪郭) では、その点を飛ばした両隣から向きを取るので、折れ目も出っ張らせる端 (`strokeCap(.project)`) も線の外へ出ない。`createShape` に記録した立体の折れ目は、記録したときの `strokeJoin` で出る。同じ向きへ折り返す角 (`vertex(A); vertex(B); vertex(A)`) は、向きによらず帯の先を延ばした形になる ([#1644](https://github.com/mokume-metal/mokume/issues/1644))。
