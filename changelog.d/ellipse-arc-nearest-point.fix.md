<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

細長い楕円の扇 (`arc`) に太い輪郭を付けると、帯の外へ最大 67% の滲みが出ていたのを直した。`noFill()` で `strokeWeight(22)` の `arc(0, 0, 80, 20, 0.3, 3.2)` は、扇の外側に輪郭の色がにじみ、別の向きの扇では帯が欠けていた。円の扇の絵は変わらない。
