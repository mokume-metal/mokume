<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

描く画素で 1 画素より細い立体の線 (細かさ 0.5 の既定の `strokeWeight(1)` の稜線など) も、1 つの図形の線全体を 1 回だけ混ぜるようにしました。これまでは不透明の色でも、`box()` の稜の集まる角や、奥行きを持つ `beginShape()` の折れ目が 1 画素ほど明るくなっていました。組み込みの立体・読み込んだモデル・保持した形の稜線は、これまでどおり GPU で広げます。
