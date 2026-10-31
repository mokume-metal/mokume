<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

線の道を値として持ち歩く `Path` と、頂点を並べて道を記録する `createPath { }` が加わった。

`createPath { beginShape(); vertex(0, 0); vertex(100, 0); vertex(100, 100); vertex(0, 100); endShape(.close) }` で作った道は、`length` (400)・`point(at: 0.25)` (弧長で 4 分の 1 の点 `[100, 0]`)・`contains([50, 50])` (回り数が 0 でない所が内側) を問える。開いた形は閉じる辺を長さに数えず、`beginContour()` で逆向きに置いた穴は内側から抜ける。`Path(Circle(center: [0, 0], radius: 10))` で円からも作れ、描くのは `shape(path)` で、そのときの `fill` と `stroke` に従う。`rect()` などの基本図形・字・画像・立体は、`createPath { }` の中では描かれず道にも入らず、種類ごとに 1 度だけ知らせる。SwiftUI の `Path` と衝突するファイルでは `mokume.Path` と書く。
