<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

組み込みの立体 (`box` / `sphere` / `plane` / `cylinder` / `cone` / `torus`) と読み込んだモデル (`model`) に、`stroke()` の線が引かれるようになりました。これまでは `stroke()` も `strokeWeight()` も受け取ったうえで黙って無視され、`noFill()` にすると何も出ませんでした。いまは塗りに線を重ねて引き、`noFill()` なら線だけになります。線は形の稜線 — 隣り合う面が折れているところと、平らな面の縁 — を通ります。箱なら 12 本、球と輪は緯線と経線の格子で、面を三角形に割った対角線は出ません。太さは平面の図形と同じく画面の画素で測られます ([#850](https://github.com/mokume-metal/mokume/issues/850))。

**`noStroke()` を書かずに立体を置いていたスケッチは、見た目が変わります。** 線は既定で有効 (白・太さ 1) なので、立体の稜線に白い線が載ります。

移行: これまでの見た目を保つには、立体を置く前に `noStroke()` を書きます。
