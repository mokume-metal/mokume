<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`beginShape` で組む形・曲線や丸い継ぎ目の線・寸法が変わる立体・`textOutline` を組む CPU の時間が、場面によって半分から数十分の 1 になりました。形を組む内部の処理が、点や三角形 1 つごとに「main actor の上で動いているか」の実行時の確かめを払っていたためです。たとえば 3D の `beginShape(.triangles)` 20 万三角形は 1 フレーム 134 ms → 57 ms、`curveVertex` の線 200 本は 79 ms → 35 ms になります。絵は 1 画素も変わりません。
