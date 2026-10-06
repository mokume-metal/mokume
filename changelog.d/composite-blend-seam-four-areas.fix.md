<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`blendMode(.lightest)` など下地を読む混ぜ方のうち、`.lightest` / `.screen` / `.darkest` / `.multiply` / `.difference` / `.exclusion` で、塗りと輪郭を両方持つ `rect` / `square` / `ellipse` / `circle` / `arc` を描くと、塗りと輪郭が接する継ぎ目で下地が透けていたのを直しました。黒地に白い塗りと白い輪郭の円を `.lightest` で描くと、太さ 1 の輪郭の継ぎ目が最大 24% 暗くなっていました。いまは `.blend` と同じく、画素の中の塗りだけ・塗りと輪郭の重なり・輪郭だけの所をそれぞれ混ぜた色を面積の比で足すので、継ぎ目に下地が混ざりません ([#1818](https://github.com/mokume-metal/mokume/issues/1818))。

そのどれかに丸ごと入る画素は、これまでどおり塗りだけの形と輪郭だけの形をこの順に描いた絵と同じです。縁と継ぎ目の画素だけが、分けて描いた絵と違う色になります。`.add` / `.subtract` は不透明な地の上では見た目が変わりません。透けた地 (`createGraphics` の透明な所など) では、継ぎ目の不透明度が塗りと輪郭の面積どおりになり、下地が透けなくなります。`.blend` と `.replace` の絵、塗りだけ・輪郭だけの形の絵は変わりません。
