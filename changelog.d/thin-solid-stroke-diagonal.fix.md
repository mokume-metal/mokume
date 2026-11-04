<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

描く画素で 1 画素より細い立体の線 (細かさ 0.5 の既定の `strokeWeight(1)` の稜線など) を斜めに描いたとき、置く位置によって明るさが 1/√2 倍か √2 倍に振れていたのを直しました。対象は、奥行きを持つ `beginShape()` の線・`createShape` で記録した形の線・`box()` やモデルの稜線です。平面の線と同じく、線の向きに合わせて広げる幅を決めるので、45° でも太さに比例した濃さで出ます。
