<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`invert`・`monochrome`・`vignette`・`adjust` を続けて重ねると、1 回の描画にまとめて掛かるようになりました。** 効果の間で絵を `.rgba16Float` に丸めて書き戻していた分が無くなり、全画面の描画も効果の数ぶん減ります。代わりに、まとめた絵は従来と最大 0.002 ほど（8 ビットの出力では 1 段階以内）だけ変わります。`blur`・`bloom`・`fringe` や自分で書いた効果を挟むと、そこで区切られて従来どおり 1 つずつ掛かります。
