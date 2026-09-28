<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

平面の塗り (`image()`・文字・`beginShape` の形・利用者の平面シェーダ) と立体の輪郭が、GPU で速くなりました。平面は光も周囲も受けないのに、立体の光と周囲の計算を抱えた断片で描いていたためです。塗りの面積が大きい絵ほど効き、画面を覆う半透明の四角 40 枚では GPU 時間が約 35% 減ります。絵は 1 画素も変わりません。
