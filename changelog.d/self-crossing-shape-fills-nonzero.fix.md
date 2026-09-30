<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`beginShape()` で塗る形が、周が自分と交わる形 (5 点を 1 つ飛ばしに結んだ星・砂時計など) や、`beginContour()` の穴が外周を跨ぐ形・外周の外に置いた周でも、**回り数が 0 でない所** (nonzero。p5・Processing と同じ) を塗るようにした。これまでは、どの規則でも外になる切れ込みまで塗ったり、形の一部が塗られなかったりしていた。星は中の五角形まで塗られ、半透明でも重ねて塗られない。周が交わらない形の絵は変わらない ([#1538](https://github.com/mokume-metal/mokume/issues/1538))。
