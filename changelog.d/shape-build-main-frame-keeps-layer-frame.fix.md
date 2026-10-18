<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**描き場所 (`createGraphics`) の `createShape { }` の中で本体の `canvas.beginDraw()` / `canvas.draw { }` を呼んでも、形が空にならなくなりました。** これまでは、本体のフレームの始まりが組み立て中の描き場所の開いたフレームを閉じ忘れとして捨て、組み立てた図形ごと消えて、形が空になり「mokume の不具合」を名乗る注意 (`createShape { }: the frame was drawn out or dropped…`) が出ていました。いまは組み立て中の描き場所のフレームは捨てず、開いたまま続きます。組み立ての後は、`endDraw()` で閉じるか、閉じなければ本体の次のフレームの頭で (組み立てていない描き場所の閉じ忘れと同じく) 捨てます。`Sketch.canvas` を直に呼ぶスケッチと、`Canvas` を直に回す使い方の両方が対象です。
