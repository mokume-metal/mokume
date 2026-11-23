<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

丸い端 (既定) の細い線を持つ `createShape()` の形を副画素ずつ動かして置いたとき、その場で引いた線とどれだけ違うかの名乗りを、測り直した値に直した。[#3864](https://github.com/mokume-metal/mokume/issues/3864) の項は「端の画素の濃さは最大 0.2 ほど違う」と書いていたが、測ると画素ごとの差の最大はほぼ 1 画素ぶん丸ごと (0.995) で、置き方の 4 割ほどで 0.2 を越えた。違う画素は端の近くに多いが、直線と折れ線では端から離れた画素が違うこともある。四角い端・延ばす端 ([#3903](https://github.com/mokume-metal/mokume/issues/3903)) と同じである。線全体の光の量 (その場で引いた線の ±25% の内) と絵は変わらない ([#4104](https://github.com/mokume-metal/mokume/issues/4104))。
