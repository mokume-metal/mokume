<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**描き場所 (`createGraphics`) の `createShape { }` の中で本体の `canvas.beginDraw()` / `canvas.draw { }` を呼んでも、形が空にならなくなりました。** これまでは、本体のフレームの始まりが組み立て中の描き場所の開いたフレームを閉じ忘れとして組み立ての途中で捨て、組み立てた図形ごと消えて、形が空になり「mokume の不具合」を名乗る注意 (`createShape { }: the frame was drawn out or dropped…`) が出ていました。いまは捨てるのを組み立ての出口まで延ばし、形は中で描いたものを持ちます。そのフレームは `endDraw()` を呼ばずに本体のフレームが進んだ描き場所と同じく、出口で描かずに捨てます (1 度注意し、出口の後の `endDraw()` は既に捨てたと言って何もしません)。`Sketch.canvas` を直に呼ぶスケッチと、`Canvas` を直に回す使い方の両方が対象です。
