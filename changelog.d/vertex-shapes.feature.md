<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

頂点を並べて自由な形を描けるようになった (`beginShape` / `vertex` / `endShape`)。**凹んでいても穴があってもよい** — 穴は `beginContour` / `endContour` で開ける。

曲線は 3 種類 — 制御点による 3 次 (`bezierVertex`) と 2 次 (`quadraticVertex`)、通過点を結ぶもの (`curveVertex`)。細かさは `curveDetail`、張り具合は `curveTightness` で決める。

描く範囲を矩形に限る `clip` / `noClip` も入った。積み降ろしで元へ戻る。
