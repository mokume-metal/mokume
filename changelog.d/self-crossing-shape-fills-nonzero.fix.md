<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`beginShape()` で塗る形が、周が自分と交わる形 (5 点を 1 つ飛ばしに結んだ星・砂時計など) や、`beginContour()` の穴が外周を跨ぐ形・外周の外に置いた周でも、**回り数が 0 でない所** (nonzero。p5・Processing と同じ) を塗るようにした。これまでは、どの規則でも外になる切れ込みまで塗ったり、形の一部が塗られなかったりしていた。星は中の五角形まで塗られ、半透明でも重ねて塗られない。外周と同じ向きに並べた `beginContour()` の周も、重なった所を 1 度だけ塗る (これまでは半透明の色で 2 重に塗っていた)。交わらずに同じ点で触れて戻る周・頂点で触れ合う葉・穴を 2 つ以上持つ形・外周の角や別の穴に触れる穴も、形の外まで塗ったり塗り残したりしなくなった ([#1886](https://github.com/mokume-metal/mokume/issues/1886))。周が交わらず、触れ合わず、穴を外周と逆に回した形の絵は変わらない ([#1538](https://github.com/mokume-metal/mokume/issues/1538))。
