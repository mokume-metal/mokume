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
| 不透明な色の不透明度を置く (`var veil = color(255, 255, 255); veil.alpha = 0.3`) | `color(veil, 0.3 * 255)` (0–255)。不透明な色なら、掛けても置き換えと同じ値になる |
| **半透明**の色の不透明度を**置き換える** (`veil.alpha = 0.3`) | `color(red(veil), green(veil), blue(veil), 0.3 * 255)` — 乗算していない値を読んで作り直す。`color(veil, 0.3 * 255)` は**掛ける**口なので、半透明の色では別の値になる (0.5 の色なら 0.15) |
| 薄める (成分ごと縮めていた `fade` など) | `color(veil, 0.3 * 255)` — 色が持つ不透明度に掛ける。置き換えではない |
| 成分を書き換えて作り直す (`c.red = 0.2`) | `LinearRGBA(premultipliedRed: …, green: …, blue: …, alpha: …)` で作り直す |

作り直す口 (`color(_:_:_:_:)`) は、不透明度 0 の色から色みを取り戻せない (乗算済みの値は成分が 0 に潰れる)。そういう色の不透明度を置き換えても、黒の色が返る。

**JSON の形は変わりません。** キーは今までどおり `red`・`green`・`blue`・`alpha` で、`Rect`・`Circle` の `fill` に入れて保存した値も、つまみの JSON (`params.json` と `Schemas/` の `color`) も、そのまま読み書きできます。**ただし、この入口は乗算済みの値として受けます。** JSON から入る口 (`LinearRGBA` の `Codable` とつまみの JSON) は、どんな 4 つの数でも乗算済みとして受けるので、キーが `red` でも、乗算していない色を書くと半透明の色が明るくなります (書く側が乗算します)。これは変わらず、成分の名前だけが読む側で改まりました。`print(color)` などの既定の表示も、`LinearRGBA(red: …)` から `LinearRGBA(premultipliedRed: …)` に変わります。描く結果は変わりません。
