<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

立体の線 (`noFill()` で球やモデルの稜線を描く絵) の GPU のフレーム時間が、#3165 で伸びた分を取り戻しました ([#3246](https://github.com/mokume-metal/mokume/issues/3246))。線の骨の片 1 つを、頂点 6 つの非添字ではなく、頂点 4 つと添字 6 つ (三角形 2 枚) で流すようにしたので、毎頂点で求め直している向きの決定の呼び出しが 2/3 で済みます。release・1280×720・球 1500 個・`strokeWeight(2)` で、#3165 の後の 8.4〜8.9 ms が 6.6〜7.0 ms (#3165 の前の 6.5〜6.9 ms の +2% 以内) になります。三角形の並びは変わらず、絵は 1 ビットも変わりません。
