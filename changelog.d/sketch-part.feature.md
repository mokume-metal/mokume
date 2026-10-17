<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

自分で書いた型に `: SketchPart` を付けると、その中でも `fill()`・`circle()`・`mouseX`・`random()` などのスケッチの語彙がそのまま使えるようになりました。Processing でタブに書いたクラスの中から `fill()` を呼ぶのと同じ書き方です。`Sketch` は `SketchPart` を継ぐので、これまでのスケッチは書き換えずに動きます。リファレンスでは語彙のページが `SketchPart` の下へ移り、URL が `…/sketch/…` から `…/sketchpart/…` に変わりました。音・カメラ・通信の口 (`createSinOsc()`・`createCapture(…)`・`createOSC(…)` など) と `params` は、まだ `Sketch` の中でだけ使えます。
