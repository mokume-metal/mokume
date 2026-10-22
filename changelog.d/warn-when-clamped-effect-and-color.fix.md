<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

説明どおりに範囲へ締める口も、締めたときに 1 度だけ警告するようになった。書いた値と違う値が効いたことを、利用者が知れる。

対象は、効果の `amount` (0…1) と `radius` (上限は 131072 画素)、不透明度 (0–255。`fill`・`stroke`・`tint`・`background`・`color()`・`fill(c, alpha)` など)、`color(hue:saturation:brightness:)` の負の彩度・明度 (0 へ丸める)、`lerpColor()`・`paletteLerp()` の `amount` (0…1)。警告は口の名前・量・受け取れる範囲・渡した値・使った値を言い、口ごと (効果は効果と量ごと) に 1 度だけ出る。たとえば `fill(255, 400)` は「fill(): the opacity takes 0 to 255, but 400.0 was passed, so 255 was used」と言う。

絵は変わらず、締める先も同じ。範囲の内側の値と、締めない量 (`threshold`・`adjust`・負の `radius`・上へ突き抜ける彩度と明度) は何も言わない。端を越える値を意図して書いているときも 1 度は警告が出るので、気になるときは値を範囲の中へ収める。
