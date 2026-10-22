<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

色の値 (`LinearRGBA`) の成分が、`premultipliedRed`・`premultipliedGreen`・`premultipliedBlue` という名前の**読むだけ**のプロパティになりました ([#2756](https://github.com/mokume-metal/mokume/issues/2756))。`alpha` も読むだけで、外から書き換えられません。成分はアルファを掛けた線形の値で、`alpha` だけを書き換えると乗算済みの約束が壊れ、半透明にしたつもりの色が下地を越えて光っていました (`veil.alpha = 0.3` の後の `fill(veil)` など)。書き換えが組み上がらなくなり、名前も、sRGB の 0–255 を返す `red(_:)` と取り違えないものになりました。

移行は、使い方ごとに次のとおりです。

| これまで | これから |
| --- | --- |
| `c.red`・`c.green`・`c.blue` で作業空間の値を読む (`Sketches/NoiseAndSeed.swift` の `early.red` など) | `c.premultipliedRed`・`c.premultipliedGreen`・`c.premultipliedBlue`。値は同じ (アルファを掛けた線形の値) |
| 見た目の数 (sRGB の 0–255) として読むつもりで `c.red` と書いた | `red(c)`・`green(c)`・`blue(c)`。乗算していない sRGB の値が返る |
| `var veil = color(255, 255, 255); veil.alpha = 0.3` で不透明度を変える (作品の `fade` など) | `color(veil, 77)` — 不透明度を掛けて作り直す (0–255)。成分ごと縮めていたなら、これで足りる |
| 成分を書き換えて作り直す (`c.red = 0.2`) | `LinearRGBA(premultipliedRed: …, green: …, blue: …, alpha: …)` で作り直す |

`LinearRGBA` を JSON にした形は変わりません。キーは今までどおり `red`・`green`・`blue`・`alpha` で、`Rect`・`Circle` の `fill` に入れて保存した値も、つまみの JSON (`params.json` と `Schemas/` の `color`) も、そのまま読み書きできます。描く結果も変わりません。
