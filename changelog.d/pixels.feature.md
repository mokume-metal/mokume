<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

描いた結果を画素として読み書きできるようにした。`pixels[x, y]` で 1 画素を読み書きでき、`get(x, y)` / `set(x, y, color)` も使える。画素の面は**描画先そのもの**なので写しは作られず、書き換えは送り直しの手順なしにそのまま絵へ届く。読める値も書ける値も作業空間の `LinearRGBA` で、変換が挟まらないぶん `pixels[x, y] = pixels[x, y]` は半透明の画素でも絵を変えない。読めるのは**そのフレームでそこまでに描いたもの**で、GPU を待つのはフレームに 1 度きり。待つ時点を選びたいときは `loadPixels()` を先に呼ぶ。
