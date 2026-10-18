<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

立体の空間に線と点を置ける 6 つの数の `line(x1, y1, z1, x2, y2, z2)`・3 つの数の `point(x, y, z)` と、床の格子と 3 本の軸を出す `debugMode()` / `noDebugMode()` を追加した ([#2462](https://github.com/mokume-metal/mokume/issues/2462))。

`line` と `point` は数の個数で意味が変わる。4 つ・2 つの数で書けば今までどおり平面の図形で視点を通らず、6 つ・3 つの数で書くと奥行きを持ち、`camera()` や `orbitControl()` の視点から見た位置に描かれる。描き方は `beginShape(.lines)` / `beginShape(.points)` に `vertex(x, y, z)` を並べたのと同じである。`Canvas` にも同じ形がある。

`debugMode()` は、面の中心・奥行き 0 を通る水平の面に格子 (1 辺が面の短いほうの辺、10 分割) を出し、そこから x が赤・y が緑・z が青の軸を伸ばす。緑の軸が画面の下へ伸びるので、縦軸が下向きであることが読める。シーンの記述なので `draw()` の中で毎フレーム書く。p5.js のように `setup()` で 1 度書くと、警告して無視される。参照スケッチ `grid-and-axes` が、見下ろした格子の上で粒の速度を 3 次元の線で描く例である。
