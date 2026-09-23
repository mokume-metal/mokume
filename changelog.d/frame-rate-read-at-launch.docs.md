<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`SketchSettings.frameRate` の説明に、この値を**起動のときに読む**ことを書いた。`var settings` と持てば `draw()` の中で代入でき、読み返しても代入した値が返るが、画面の刻みも `time` / `deltaTime` も変わらず、警告も出ない。振る舞いは変わっていない。

手本 (Processing / p5) の `frameRate(n)` と違い、走っている最中に速さを変える口はまだ無い ([#1323](https://github.com/mokume-metal/mokume/issues/1323))。
