<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# 数学・PVector・定数

Processing 本体のリファレンスのうち、数学 (計算・三角関数・乱数)・定数・`PVector` の 64 件。内訳は、計算 17 件、三角関数 9 件、乱数 6 件、定数 5 件、`PVector` のクラスのページとメンバー (26) の 27 件。表の形式・バージョン・数え直す式は [README](README.md) にある。照合したのは processing-website `f4acef8` (2026-10-29) と mokume の main `c949c2b0` (2026-11-24)。

| 区分 | 件数 |
| --- | --- |
| 同等 | 52 |
| 入れる | 1 |
| 作例待ち | 2 |
| 持たない | 9 |
| 計 | 64 |

この領域に共通すること:

- **関数の層は Processing の名前のまま、値型 (`Vector2`・`Vector3`) のメンバーは Swift の慣行の名前で書く** ([ADR-0020](../decisions/0020-api-naming-and-surface.md) 決定 1)。`dist()` と `Vector2.distance(to:)`、`mag()` と `Vector2.length` が並ぶのは、`circle()` と `Circle` の使い分けと同じ。どちらの説明文ももう一方の名前を名乗る
- **数は `Float` が基本で、`Int`・`Double` もそのまま渡せる** ([ADR-0035](../decisions/0035-numeric-reception.md))。返すのはいつも `Float` で、Processing の `int` を返す関数 (`round()`・`floor()`・`ceil()`) も例外ではない
- **自前で書いた関数は、数でない値や無限の値を返さない。** `dist`・`mag`・`sq`・`lerp`・`norm`・`map`・`constrain` などは、数でない値が混じれば既定の値 (0 や範囲の端) を返し、注意を 1 度だけ言う。Processing は ±∞ や NaN を返すが、毎フレーム呼ぶ API が数でない値を返すと、描画が警告なしに消える ([ADR-0020](../decisions/0020-api-naming-and-surface.md) 決定 5)。Darwin から通した関数 (`pow`・`sqrt`・`sin` ほか) は C と同じ値を返す
- **Darwin の関数は、名指しで再輸出して通している** (`Sources/mokume/Umbrella.swift`)。`import Foundation` は要らない。`Float`・`Double` の多重定義のまま届く ([#2416])
- **`PVector` に当たる型は、値型の `Vector2` (平面) と `Vector3` (空間) の 2 つ。** Processing の `PVector` は 2 次元でも `z` を持つ 1 つの参照型で、`v.add(w)` は `v` を書き換える。mokume は値型なので、代入でコピーされ、共有による事故が起きない。書き換える形は `+=`・`-=`・`*=`・`/=`、新しい値を返す形は `+`・`-`・`*`・`/` ([ADR-0045](../decisions/0045-game-direction.md) 決定 8・[#2617])
- **Processing の `PVector` の静的メソッド (`PVector.add(v1, v2)`・`PVector.dist(v1, v2)` ほか) は、同じ働きの演算子かメソッドで書く。** `target` を渡して結果の置き場を指定する形は、値型なので要らない
- **カテゴリが `math` の演算子 15 件 (`+`・`%`・`<<` ほか。subcategory が `Operators`・`Bitwise Operators`) は、この表に数えない。** 言語の演算子で、構造・制御の表 ([#4180]) が扱う。式は README の「数え直す式」
- **`createVector()` は Processing に無い (p5.js の関数)。** リファレンスに載らないので数えない。`Vector2(x, y)`・`Vector3(x, y, z)` で作る

## 定数

5 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `PI`・`HALF_PI`・`QUARTER_PI`・`TWO_PI`・`TAU` (5 件) | `PI`・`HALF_PI`・`QUARTER_PI`・`TWO_PI`・`TAU` | 同等 | 手本の綴りのまま `Float` の定数で、`import mokume` だけで書ける。具体の `Float` なので、総称の受け口 (`map(i, 0, n, 0, TWO_PI)`) でも型が決まる。`TAU` は `TWO_PI` と同じ値。`Float.pi` と書いても同じ | [#2421] |

## 計算

17 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `abs()`・`max()`・`min()` (3 件) | Swift 標準の `abs`・`max`・`min` | 持たない | 標準ライブラリにあり、型を保つ (`Int` どうしは `Int` のまま)。`max(a, b, c)` のように 3 つ以上を渡す形も標準の `max`・`min` が受ける。配列を渡す `max(array)` は `array.max()` (空なら `nil`)。`Int` と `Float` は混ぜられず、`Float(i)` で合わせる ([ADR-0035](../decisions/0035-numeric-reception.md))。名前だけ違う API は足さない | [#2416] |
| `ceil()`・`floor()`・`round()` (3 件) | `ceil`・`floor`・`round` (Darwin を名指しで再輸出) | 同等 | Processing は `int` を返すが、mokume は `Float` (や `Double`) を返す。整数にするなら `Int(floor(x))`。`round` は 0.5 ちょうどを 0 から遠いほうへ丸める。Processing は 0.5 ちょうどを大きいほうへ丸めるので、負の値で違う (`round(-2.5)` は Processing が -2、mokume の `round` が -3) | [#2416] |
| `exp()`・`log()`・`pow()`・`sqrt()` (4 件) | `exp`・`log`・`pow`・`sqrt` (Darwin を名指しで再輸出) | 同等 | `log` は自然対数。値は C の関数と同じで、`sqrt(-1)` は数でない値になる (自前の関数と違い、返る値を直さない)。`pow(2, level)` が `import mokume` だけで書ける | [#2416] |
| `sq()` | `sq(_:)` | 同等 | 2 乗を `Float` で返す。結果が `Float` の範囲を越えれば ∞、数でない値や無限の値を渡せば 0 を返し、注意を 1 度だけ言う | [#2416] |
| `dist()` | `dist(_:_:_:_:)`・`dist(_:_:_:_:_:_:)`・`dist(_:_:)` (`Vector2` と `Vector3`) | 同等 | 2 点の距離。4 つ・6 つの数を渡す形 (平面・空間) と、`Vector2`・`Vector3` を 2 つ渡す形がある。2 乗が `Float` で溢れる距離でも有限で返る。値型の側は `distance(to:)` | [#2416]・[#3359] |
| `mag()` | `mag(_:_:)`・`mag(_:_:_:)` | 同等 | 原点からの距離 (平面・空間)。溢れても有限で返る。値型の側は `length` | [#2416] |
| `constrain()` | `constrain(_:_:_:)` | 同等 | 引数は値・下端・上端の順 (Processing と同じ)。上下を逆に渡せば入れ替えて締める。数でない値が混じれば範囲の端へクランプする | [#1281] |
| `lerp()` | `lerp(_:_:_:)`・`lerp(_:_:amount:)` | 同等 | 0…1 の外は締めない (Processing と同じ。外挿する)。数でない値が混じれば `start` を返す。`amount:` のラベルを付ける形もある | [#1281]・[#2255] |
| `map()` | `map(_:_:_:_:_:)`・`map(_:fromLow:fromHigh:toLow:toHigh:)` | 同等 | 範囲の外を丸めない (Processing と同じ)。逆向きの範囲も受ける。元の範囲の幅が 0 なら対応づけた先の下端を返す (Processing は ±∞ や NaN)。ラベルを付ける形は、どの値が元の端でどれが先の端かを呼び出しの行で読める | [#883]・[#2255] |
| `norm()` | `norm(_:_:_:)` | 同等 | 引数は値・範囲の始まりと終わり。範囲の外は締めない。範囲の幅が 0 なら 0 を返す (Processing は ±∞ や NaN) | [#1281]・[#2255] |

## 三角関数

9 件。角度はラジアンで渡す。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `sin()`・`cos()`・`tan()`・`asin()`・`acos()`・`atan()`・`atan2()` (7 件) | `sin`・`cos`・`tan`・`asin`・`acos`・`atan`・`atan2` (Darwin を名指しで再輸出) | 同等 | 角度はラジアンで、Processing と同じ。`atan2(y, x)` の並びも同じ。値は C の関数と同じ | [#883] |
| `degrees()`・`radians()` (2 件) | `degrees(_:)`・`radians(_:)` | 同等 | `Float` で返す。Darwin に無いので自前で書いた。`rotate(_:)` などの角度はラジアン | [#883]・[#2255] |

## 乱数

6 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `random()` | `random()`・`random(_:)` (上限か配列)・`random(_:_:)` | 同等 | 引数なしは 0 以上 1 未満 (Processing は引数なしの形が無い)。配列を渡す形 (p5.js の `random(choices)`) は要素 1 つを返し、空なら `nil`。**スケッチの種 (`randomSeed`) に従う。** Swift 標準の `randomElement()`・`shuffled()`・`Float.random(in:)` は種に従わず、走らせるたびに絵が変わる。値として持つ乱数源は `randomSource` ([#2418]) | [#2419]・[#2418] |
| `randomGaussian()` | `randomGaussian()`・`randomGaussian(_:_:)`・`randomGaussian(mean:standardDeviation:)` | 同等 | 引数なしは平均 0・標準偏差 1 (Processing と同じ)。平均と標準偏差を渡す形は p5.js の形。スケッチの種に従う | [#2419] |
| `randomSeed()` | `randomSeed(_:)` | 同等 | `Int` を渡す (Processing は `long`)。同じ種からは、同じ列が出る | [#2418] |
| `noise()` | `noise(_:_:_:_:)` | 同等 | 0…1 のなめらかな揺らぎ。引数は 1〜4 個 (Processing は 3 つまで。4 つ目の座標は、2 次元の場をループさせるのに使う)。同じ座標には何度呼んでも同じ値を返す。**同じ種でも、値は Processing と同じにならない** (実装が別)。シェーダからも `mokume_noise` で同じ値が引ける | [#2425] |
| `noiseDetail()` | `noiseDetail(_:_:)`・`noiseDetail(octaves:falloff:)` | 同等 | 重ねる枚数と、1 枚ごとの弱まり (既定 0.5)。一度書けばフレームをまたいで残り、シェーダにも届く。範囲の外や数でない値は、設定を変えずに 1 度だけ注意を言う | [#2425] |
| `noiseSeed()` | `noiseSeed(_:)` | 同等 | `Int` を渡す。シェーダにも同じ種が届く。`randomSeed` とは別に決める | [#2425] |

## PVector

27 件。クラスのページ 1、フィールド 3、メソッド 23。値型の `Vector2` と `Vector3` で書く。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `PVector` (クラス) | `Vector2`・`Vector3` | 同等 | 値型で、`Sendable`・`Hashable`・`Codable`。`Vector2(x, y)`・`Vector3(x, y, z)` で作り、配列リテラル (`[300, 300]`) からも作れる。平面と空間で型が分かれ、`Vector2` に `z` は無い。無い形: 引数なしの `PVector()` (`Vector2(0, 0)` と書く)・`float[]` から作る形 | [#2617]・[#3359] |
| `PVector.x`・`PVector.y` (2 件) | `Vector2.x`・`Vector2.y`・`Vector3.x`・`Vector3.y` | 同等 | 読み書きできる `Float`。縦は下向きが正 | [#2617] |
| `PVector.z` | `Vector3.z` | 同等 | 読み書きできる `Float`。平面の `Vector2` に `z` は無い | [#2617] |
| `PVector.add()` | `+`・`+=` | 同等 | `v += w` は自分を書き換え、`v + w` は新しい値を返す (Processing の `PVector.add(v, w)` は後者)。無い形: 成分を直接渡す `add(x, y, z)` (`v += Vector2(x, y)` と書く) | [#2617]・[#3359] |
| `PVector.sub()` | `-`・`-=` | 同等 | `add()` と同じ。符号を反転する `-v` もある | [#2617] |
| `PVector.mult()` | `*`・`*=` | 同等 | 数をかける。`v * 2` も `2 * v` も書ける。ベクトルどうしの成分ごとの積は無い (Processing の `mult()` も数だけ) | [#2617] |
| `PVector.div()` | `/`・`/=` | 同等 | 数で割る。`v / 2` の `2` は `Int` でも渡せる | [#2617]・[ADR-0035](../decisions/0035-numeric-reception.md) |
| `PVector.mag()` | `Vector2.length`・`Vector3.length` | 同等 | 長さ。2 乗が `Float` で溢れる大きさでも有限で返る。関数の `mag()` と並ぶ | [#3359] |
| `PVector.magSq()` | — (`v.dot(v)`) | 持たない | 長さの 2 乗は、自分との内積で書く。名前だけ違う API は足さない。`length` と違い平方根を取らないので、大きさの比べ合いが速い | — |
| `PVector.normalize()` | `Vector2.normalized()`・`Vector3.normalized()` | 同等 | 長さ 1 の値を返し、元の値は変えない (値型の慣行で過去分詞)。長さ 0 の値は 0 のまま返し、落ちない | [#3359] |
| `PVector.limit()` | `Vector2.limited(to:)`・`Vector3.limited(to:)` | 同等 | 長さを上限までに抑えた値を返す。上限より短い値はそのまま返す | [#3359] |
| `PVector.setMag()` | — (`v.normalized() * length`) | 持たない | 向きを保ったまま長さを決めるには、`normalized()` に長さをかける。値を書き換える `setMag` は足さない (値型は新しい値を作る) | — |
| `PVector.heading()` | `Vector2.angle` | 同等 | 向いている角度 (ラジアン。`-π`…`π`)。右が 0 で、正の角度は画面で時計回り (`rotate()` と同じ)。長さ 0 の値は 0 を返す。平面だけで、`Vector3` に `angle` は無い (Processing の `heading()` も平面の向き) | [#3359] |
| `PVector.setHeading()` | — (`Vector2(angle:length:)`) | 持たない | 長さを保って向きだけ変えるには、`Vector2(angle: newAngle, length: v.length)` と書く。`angle` は読むだけ | [#3359] |
| `PVector.rotate()` | `Vector2.rotated(by:)` | 同等 | 長さを保ったまま回した新しい値を返す。正の角度は `rotate()` と同じ向き。平面だけで、`Vector3` に回転は無い (Processing の `rotate()` も平面の回転) | [#3359] |
| `PVector.dist()` | `Vector2.distance(to:)`・`Vector3.distance(to:)`・`dist(_:_:)` | 同等 | 2 点の距離。値型のメンバー、関数の `dist(a, b)` のどちらでも書ける | [#3359] |
| `PVector.dot()` | `Vector2.dot(_:)`・`Vector3.dot(_:)` | 同等 | 内積。無い形: 成分を直接渡す `dot(x, y, z)` | [#3359] |
| `PVector.cross()` | `Vector3.cross(_:)` | 同等 | 外積 (右手系)。`Vector3` だけ。`Vector2` に外積は無い (Processing の `cross()` は平面の値にも 3 次元の値を返すが、`z` を持たない `Vector2` では成り立たない) | [#3359] |
| `PVector.lerp()` | `Vector2.interpolated(to:amount:)`・`Vector3.interpolated(to:amount:)` | 同等 | 成分ごとの `lerp()` と同じ値の新しい値を返す (値型の慣行で過去分詞)。無い形: 成分を直接渡す `lerp(x, y, z, amt)` | [#3359] |
| `PVector.fromAngle()` | `Vector2(angle:length:)` | 同等 | 角度 (ラジアン) と長さ (既定 1) から作る。静的メソッドではなくイニシャライザ。平面だけ | [#3359] |
| `PVector.angleBetween()` | — | 入れる | 2 つの値のあいだの角度 (ラジアン、0〜π)。`dot` と長さからは書けるが、長さ 0 の値と、丸めで `acos` の入力が 1 を超えるときの扱いを、毎回書くことになる。OS のフレームワークだけで書け、`Vector2`・`Vector3` に統合でき、機材なしでテストできる。名前と向きの選び方は `Feature` で決める | [#4188] |
| `PVector.random2D()`・`PVector.random3D()` (2 件) | — | 作例待ち | 向きがランダムな長さ 1 の値を返す静的メソッド。**乱数の列をどこから引くかが分かれる。** スケッチの列 (`randomSeed` に従う) は `SketchPart` が持ち、値型は静的メソッドから届かない。候補は、`SketchPart` の関数 (`random2D()`)・値型のイニシャライザに乱数源を渡す形 (`RandomNumberGenerator` を受ける)・`randomSource` を渡す形で、どれも名前と置き場が違う。乱数源を黙って別の列にすると、種を決めても絵が変わる ([ADR-0001](../decisions/0001-founding-principles.md) 原則 2)。使う作例が来たら選ぶ | [#2418] |
| `PVector.array()` | — (`[v.x, v.y]`・`v.simd`) | 持たない | `float[]` に当たる型を値型に足さない。成分を並べて `[v.x, v.y]` と書くか、`simd` で SIMD の値として取り出す | [#2617] |
| `PVector.copy()` | — (代入) | 持たない | 値型なので、`let w = v` がコピーになる。参照を共有する事故が起きず、`copy()` は要らない | [#2617] |
| `PVector.set()` | — (`v.x = …`・`v = Vector2(x, y)`) | 持たない | 値型の成分を書き換える `set` は足さない。成分は直接書け (`v.x = 3`)、まとめて決めるなら新しい値を代入する | [#2617] |

## 入れる

「入れる」の API は、近いものごとに 1 つの `Feature` で入れる。

| Feature | API | 表の行 |
| --- | --- | --- |
| [#4188] 2 つのベクトルのあいだの角度 | `Vector2` と `Vector3` の、2 つの値のあいだの角度を返すメンバー (名前は Feature で決める) | `PVector.angleBetween()` |

[#883]: https://github.com/mokume-metal/mokume/issues/883
[#1281]: https://github.com/mokume-metal/mokume/issues/1281
[#2255]: https://github.com/mokume-metal/mokume/issues/2255
[#2416]: https://github.com/mokume-metal/mokume/issues/2416
[#2418]: https://github.com/mokume-metal/mokume/issues/2418
[#2419]: https://github.com/mokume-metal/mokume/issues/2419
[#2421]: https://github.com/mokume-metal/mokume/issues/2421
[#2425]: https://github.com/mokume-metal/mokume/issues/2425
[#2617]: https://github.com/mokume-metal/mokume/issues/2617
[#3359]: https://github.com/mokume-metal/mokume/issues/3359
[#4180]: https://github.com/mokume-metal/mokume/issues/4180
[#4188]: https://github.com/mokume-metal/mokume/issues/4188
