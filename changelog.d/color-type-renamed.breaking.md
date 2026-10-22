<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

色の値の型 `LinearRGBA` が `Color` に改名されました ([#2595](https://github.com/mokume-metal/mokume/issues/2595))。入門で最初に触る型の名前としては難しく、手本 (p5.js・SwiftUI) の呼び方に近い普通の英単語に合わせるためです。別名 (`typealias LinearRGBA = Color`) は置かないので、綴りを直してください。型の意味は変わりません — 作業空間の値 (線形・乗算済み) を持ち、作り方の `.linear(…)`・`.display(…)` が目盛りを名乗ります。

移行は、`LinearRGBA` を `Color` に置き換えるだけです。ファイル全体を置換するなら `\bLinearRGBA\b` → `Color` で足ります。引数・戻り値・`@Param var ink: LinearRGBA`・`Rect(…, fill: LinearRGBA)` など、型を書いていた所すべてが対象です。`LinearRGBA.linear(red:green:blue:)`・`LinearRGBA.display(…)`・`LinearRGBA.transparent` は `Color.linear(…)` などになります。JSON の形は変わりません (キーは `red`・`green`・`blue`・`alpha` のまま)。

SwiftUI を取り込んだファイルで使うときは、`Color` が SwiftUI の `Color` と同名になります。曖昧になったら `mokume.Color` と書き、SwiftUI のほうは `SwiftUI.Color` と書いてください。

同じ版で、色の値の成分の名前も改まりました (`c.red` → `c.premultipliedRed`・書き換えは不可。[#2756](https://github.com/mokume-metal/mokume/issues/2756))。移行の対応は、その断片にあります。
