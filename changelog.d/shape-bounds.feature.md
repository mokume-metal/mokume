<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`Shape.bounds` を追加した。** `createShape { }` で組んだ形や `loadShape` で読んだ SVG の、平面の部分の外接矩形を `Rect?` で返す。たとえば `createShape { rect(10, 20, 100, 50) }.bounds` は `Rect(left: 10, top: 20, width: 100, height: 50)`、`circle(0, 0, 40)` は `(-20, -20, 40, 40)` で、読み込んだ SVG の中心を原点へ寄せるなら `shape(read, -box.center.x, -box.center.y)` と書ける。ファイルを開いて確かめた viewBox の寸法をコードへ写さずに済む。

外接は幾何のもので、**線の太さを含まない** (`strokeWeight(8)` で描いても同じ)。基本図形はその形が描く幾何で外接する (`arc` は楕円全体ではなく中心と弧が作る扇の箱)。組み立ての中の変換は掛かった後の座標で外接し、`group(_:)` と `+` で繋いだ形は子の外接の和になる。立体は見ず、平面の部分が無い形 (`Shape.empty`・立体だけの形・塗りも線も描かない図形だけの形) は `nil` を返す。焼くときに求めて持つので、何度問うても費用は変わらない。参照スケッチ `shapes-from-svg` は、手で写していた viewBox の中心を `bounds` から求める形にした (絵は変わらない)。
