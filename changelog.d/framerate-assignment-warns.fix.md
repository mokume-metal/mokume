<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

走っている最中に `settings.frameRate` へ代入すると、警告を 1 度だけ標準エラーへ出すようにしました。`frameRate` は起動のときにだけ読むので、`var settings = SketchSettings(…)` と持って `draw()` の中で代入しても、画面の刻みも `time` / `deltaTime` も変わりません。それでも代入は通り、読み返すと代入した値が返るため、変えられたと思ったまま先へ進めてしまっていました。速さは今までどおり起動のときの値のままで、変わっていないことを知らせるだけです ([#1323](https://github.com/mokume-metal/mokume/issues/1323))。
