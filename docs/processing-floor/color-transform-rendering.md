<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# 色・変換・光とカメラ・描画

Processing 本体のリファレンスのうち、色 (作る・読む・塗る)・変換 (行列)・光とカメラ (視点・座標・光・材質)・描画 (`PGraphics`・混ぜ方・切り抜き・シェーダ・`hint()`) の 69 件。内訳は、色 16 件、変換 13 件、視点 8 件、座標 6 件、光 9 件、材質 4 件、描画 13 件。表の形式・バージョン・数え直す式は [README](README.md) にある。照合したのは processing-website `f4acef8` (2026-10-29) と mokume の main `5b60ed75` (2026-11-24)。

| 区分 | 件数 |
| --- | --- |
| 同等 | 54 |
| 入れる | 1 |
| 作例待ち | 7 |
| 持たない | 7 |
| 計 | 69 |

この領域に共通すること:

- **色の型は `LinearRGBA`、素の数値は 0–255 の sRGB** ([ADR-0033](../decisions/0033-color-specification-surface.md) 決定 1・[#669])。Processing の `color` は `int` だが、mokume の `color()` は `LinearRGBA` を返す。作業空間は線形で、数を渡す口 (`fill(242, 115, 64)`) と `color(…)` は同じ目盛りと同じ変換を通る。`.display(red:green:blue:alpha:)` は 0–1 の目盛りの口。色相・彩度・明度は目盛りが量ごとに違う (色相は度・彩度と明度は百分率) ので、`colorMode()` を持たない
- **不透明度は 0–255 に締め、色の成分は締めない。** 締めたときは 1 度だけ注意する ([ADR-0033](../decisions/0033-color-specification-surface.md) 決定 3 の改訂・決定 6・[#1842])。数でない値は受けず、毎フレーム呼ぶ API が数でない色を返さない (ADR-0020 決定 5)
- **角度はラジアンで、`angleMode()` は持たない** ([ADR-0020](../decisions/0020-api-naming-and-surface.md) 決定 1 の `angleMode()` の項)。`rotate`・`rotateX`・`shearX` の引数も、`perspective()` の画角もラジアン
- **平面と立体は 1 つの変換・1 つの視点を通る** ([ADR-0021](../decisions/0021-solid-space-and-frame-assembly.md) 決定 1 の改訂 (2026-11-07)・[#3830])。`rect`・`circle` などの平面の図形も視点 (`camera`・`perspective`・`ortho`) と変換の奥行きを通り、画面に重ねる字や印は `camera()` で視点を戻してから描く。**光・視点・投影・材質・変換・切り抜きはフレームを越えない**ので、`draw()` の中で毎フレーム書く
- **6 つ以上の数を位置引数で並べる API には、ラベル付きの形が並ぶ** ([ADR-0020](../decisions/0020-api-naming-and-surface.md) 決定 1 の 2026-11-07 の改訂)。`camera(eye:center:up:)` ([#3778])・`perspective(fieldOfView:aspect:near:far:)`・`ortho(left:right:bottom:top:near:far:)` ([#3779])・`pointLight(color:position:)` ほか ([#3780])。位置引数の形も残る
- **`PImage.blendColor()` はこの表に数えない。** リファレンスの category は `color` だが、所属が `PImage` で、画像の表 ([image.md](image.md)・[#3686]) が数えている。式は README の「数え直す式」
- **書き出しのライブラリ (`processing.pdf`・`processing.svg`・`processing.dxf`) のページは数えず、描画先の種類 (PDF・SVG・DXF) は本体の行に書く** ([#3688 の決定](https://github.com/mokume-metal/mokume/issues/3688#issuecomment-6586703173))。`createGraphics(w, h, PDF)` の描画先の指定は、下の `createGraphics()` の行にある

## 色

16 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `color()` | `color(_:_:_:_:)`・`color(_:_:)` (灰色と不透明度)・`color(hex:)`・`color(hue:saturation:brightness:alpha:)`・`color(_:_:)` (色の値と不透明度) | 同等 | 灰色 (1 つ・2 つ)・赤緑青 (3 つ・4 つ) を 0–255 で渡す形は同じ並び。返すのは `int` でなく `LinearRGBA`。16 進で書く色 (`color(#FFCC00)`) は `color(hex: 0xFFCC00)` で、上位バイトの不透明度は読まない。HSB は `colorMode(HSB)` の代わりに、ラベルを付けた別の形 (色相は度・彩度と明度は百分率) で書く。色の値と不透明度の形は、不透明度を置き換えずに掛ける | [#669]・[#1553]・[#2422] |
| `red()`・`green()`・`blue()` (3 件) | `red(_:)`・`green(_:)`・`blue(_:)` | 同等 | 0–255 の sRGB の目盛りで返す。`red(color(255, 204, 0))` は 255 に戻る。範囲の外を丸めない (`red(color(510, 0, 0))` は 510)。不透明度が 0 の色は 0、数でない成分は 0 を返す。Processing は `colorMode()` の最大値で返す | [#669] |
| `alpha()` | `alpha(_:)` | 同等 | 0–255 で返す。不透明度は光の量でなく覆いの割合なので、伝達関数を通さない | [#669] |
| `hue()`・`saturation()`・`brightness()` (3 件) | `hue(_:)`・`saturation(_:)`・`brightness(_:)` | 同等 | 色相は 0 以上 360 未満の度、彩度と明度は 0–100 の百分率で返す。Processing は `colorMode()` の最大値 (既定 255) で返す。灰色の色相は 0。色域の外の色では 100 を超えることがある | [#669] |
| `lerpColor()` | `lerpColor(_:_:_:)`・`lerpColor(_:_:amount:)` | 同等 | 引数は始まり・終わり・割合の順。`amount` は 0…1 に締める (Processing も締める)。**中間の色は Processing と違う**: 線形の光の量で混ぜるので Processing より明るく (黒と白の真ん中は約 187.5)、乗算済みの値で混ぜるので透明へ寄せても暗くならない。HSB で混ぜる形は無い (`colorMode()` を持たないので混ぜる空間は 1 つ) | [#669] |
| `background()` | `background(_:_:)`・`background(_:_:_:_:)`・`background(_:)` (色の値)・`background(_:)` (`Surroundings`) | 同等 | 下地を置き換える。**不透明度は下地に重ならず、キャンバスをその色で置き換える** (`background(0, 20)` は残像にならない。Processing は本体のキャンバスで不透明度を使えない)。切り抜き (`clip`) の中で呼べばその中だけを置き換える。ウィンドウは半透明の下地を黒に重ねた色で出し、画像・動画は不透明度を保つ。無い形: 画像を渡す `background(image)` (`image(img, 0, 0, width, height)` で敷く) | [#669]・[#1550] |
| `clear()` | `background(.transparent)` | 持たない | キャンバスを透明で置き換える。Processing の `clear()` は `PGraphics` だけで働く (本体の面は不透明)。mokume は `createGraphics()` の `Canvas` も本体も同じ `background(_:)` で消せる。名前だけ違う API は足さない | — |
| `colorMode()` | — (`color(hue:saturation:brightness:)`・`.display(red:green:blue:alpha:)`) | 持たない | **決定済み**。モード状態を持つと「値だけ見て色が読めない」状態になるので、尺度は呼び出しの行で名乗る (ADR-0033 決定 4)。失うのは、p5 の HSB のコードをそのまま貼ると 0–255 の RGB として読まれて黙って違う色になること。0–1 で書くなら `.display(…)`、最大値を変えて書く形 (`colorMode(RGB, 1.0)`) は持たない | [#669] |
| `fill()`・`stroke()` (2 件) | `fill(_:_:)`・`fill(_:_:_:_:)`・`fill(_:)` (色の値)・`fill(_:_:)` (色の値と不透明度)・`stroke` も同じ形 | 同等 | 灰色・赤緑青を 0–255 で渡す形と、`color(…)` の値を渡す形は同じ。16 進の整数 (`fill(#CC0000)`) は `fill(color(hex: 0xCC0000))`。`fill` には勾配 (`Gradient`) を渡す形もある。不透明度の範囲外は 0–255 に締めて 1 度だけ注意する | [#669]・[#1553]・[#1842] |
| `noFill()`・`noStroke()` (2 件) | `noFill()`・`noStroke()` | 同等 | 塗り・輪郭を描かない状態にする。`pushStyle()` と `popStyle()` (または `push { }`) で戻す | [#669] |

## 変換

13 件。変換は 4×4 の行列に積まれ、平面の図形も立体も同じ状態を通る。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `translate()` | `translate(_:_:)`・`translate(_:_:_:)`・`translate(_:)` (`Vector2`・`Vector3`) | 同等 | 平面 (2 つ) と空間 (3 つ) の形は同じ。`Vector2`・`Vector3` を 1 つ渡す形もある | — |
| `rotate()` | `rotate(_:)` | 同等 | 平面の回転。引数はラジアン (Processing も同じで、`angleMode()` は持たない) | — |
| `rotateX()`・`rotateY()`・`rotateZ()` (3 件) | `rotateX(_:)`・`rotateY(_:)`・`rotateZ(_:)` | 同等 | 軸のまわりの回転。引数はラジアン。この後の平面の図形は、変換が写す空間の面に置かれて視点を通る | — |
| `scale()` | `scale(_:)`・`scale(_:_:)`・`scale(_:_:_:)` | 同等 | 1 つ (全軸)・2 つ (平面)・3 つ (空間) の形は同じ | — |
| `shearX()`・`shearY()` (2 件) | `shearX(_:)`・`shearY(_:)` | 同等 | 平面のせん断。引数はラジアン | — |
| `applyMatrix()` | `applyMatrix(_:)` (`Transform`) | 同等 | 渡すのは数でなく `Transform` の値で、`Transform.identity` に `translate`・`rotate`・`scale` を積んで作る (積む順も向きも `translate()` などを並べて呼ぶのと同じ)。**行列を数で書く形は無い**: 平面の 6 つ (`applyMatrix(n00, …, n12)`)・空間の 16 個の数を渡す形と、`PMatrix` を渡す形。行列を返す API が無いので、数から行列は作れない | — |
| `pushMatrix()`・`popMatrix()` (2 件) | `pushMatrix()`・`popMatrix()` | 同等 | 変換だけを積んで戻す。変換とスタイルの両方を戻す `push()`・`pop()` と、閉包を抜けると戻す `push { }` もある。積む段が無い `popMatrix()` は呼んだ場所を名指して 1 度だけ注意し、何もしない。積んだ変換もフレームを越えない | [#2399] |
| `resetMatrix()` | `resetMatrix()` | 同等 | 積み重ねた変換を捨てて何も変換しない状態へ戻す。積んである変換は捨てない | — |
| `printMatrix()` | — | 作例待ち | いまの変換を標準出力へ書く API。**いまの変換を読む口が無い**ので、書き方で選択が分かれる。`Transform` を返す API (`currentTransform`)・`modelX()` と同じ座標を返す関数・観測の面 (`observe`) の状態に載せる形のどれにするかは、読む側の作例が来てから決める (下の `modelX()` と同じ根) | — |

## 視点

8 件。視点 (`camera`) と投影 (`perspective`・`ortho`) は別の状態で、投影を決めたまま視点だけを戻せる。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `camera()` | `camera()`・`camera(_:_:_:_:_:_:_:_:_:)`・`camera(eye:center:up:)` | 同等 | 9 つの数 (見る位置・見ている先・上方向) と、引数なしで既定の視点へ戻す形は同じ。**引数なしは視点だけを戻し、投影 (`ortho()` で決めた写し方) は残す。** ラベル付きの形は `Vector3` を 3 つ取る。`setCamera(_:)` (`Camera` の値)・`currentCamera`・`orbitControl()` もある | [#3778] |
| `beginCamera()`・`endCamera()` (2 件) | `camera(eye:center:up:)`・`setCamera(_:)` | 持たない | カメラの行列を `translate`・`rotate` で動かす区間を開く API。mokume の視点は変換の積み方と別の状態で、位置・見ている先・上方向の 3 つで決める。`Camera` の値 (`eye`・`center`・`up`・`projection`) を書き換えて `setCamera(_:)` へ渡せば、行列を直に触らずに同じ視点が作れる | — |
| `frustum()` | — | 入れる | 手前の面の境界 6 つで、視線が錐台の中心を通らない (左右・上下が非対称な) 透視投影を決める。`perspective()` は対称な錐台だけで、片寄せは書けない。行列の計算だけで書け、`Camera` に統合でき、機材なしでテストできる。引数は Processing が決めていて `ortho()` と同じ 6 つ。持たせ方 (`Camera.Projection` の case を足すか、投影の内部の表現を境界 6 つに直すか) は Feature で決める | [#4195] |
| `ortho()`・`perspective()` (2 件) | `ortho()`・`ortho(_:_:_:_:_:_:)`・`ortho(left:right:bottom:top:near:far:)`・`perspective()`・`perspective(_:_:_:_:)`・`perspective(fieldOfView:aspect:near:far:)` | 同等 | 引数なしは既定の投影へ戻す。`perspective()` の画角 (`fovy`) はラジアンの縦方向。**`ortho()` の `bottom` は画面の下端・`top` は画面の上端で、縦軸が下向きなので `top` のほうが小さい数になる** (取り違えても警告は出ず絵が上下反転する)。無い形: 手前と奥を省く `ortho(left, right, bottom, top)` (4 つ) | [#3779] |
| `printCamera()`・`printProjection()` (2 件) | `print(currentCamera)`・`print(currentCamera.projection)` | 持たない | 視点・投影を標準出力へ書く API。`currentCamera` が `Camera` の値 (`eye`・`center`・`up`・`projection`) を返すので、Swift の `print`・`dump` で読める。書き出す専用の名前は足さない | [#3778] |

## 座標

6 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `screenX()`・`screenY()` (2 件) | `screenX(_:_:)`・`screenY(_:_:)`・`screenX(_:_:_:)`・`screenY(_:_:_:)` | 同等 | 点がいまの変換と視点で画面のどこへ移るか。平面の 2 つの数の形は、奥行き 0 の点として視点を通した位置 (`screenX(x, y, 0)` と同じ) を返し、平面の図形が描かれる位置と同じ式を通る。返すのは `Float` | [#3830] |
| `screenZ()` | `screenZ(_:_:_:)` | 同等 | 奥行きの値 (0 が手前の面・1 が奥の面)。3 つの数の形だけ (Processing も同じ)。逆向き (画面の座標から空間の座標) は `spacePosition(screenX:screenY:depth:)` | [#3830] |
| `modelX()`・`modelY()`・`modelZ()` (3 件) | — | 作例待ち | 点がいまの変換でどこへ移るか (視点を通す前の座標) を返す関数。**いまの変換を読む口が無い**ので、名前と形が分かれる。`modelX(x, y, z)` と同じ名前の関数を 3 つ足す形と、`Transform` を返す口 (`currentTransform.apply(x:y:z:)` は既にある) を足す形がある。`Transform` は積み上げて作る値で、現在の変換を返す API は無い (上の `printMatrix()` と同じ根) | — |

## 光

9 件。光は置いた順で溜まり、`lights()` か手で置いた光がフレームの中の立体を照らす。**平面の図形には光が当たらない。**

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `ambientLight()` | `ambientLight(_:_:_:)`・`ambientLight(_:)` (灰色)・`ambientLight(_:)` (`LinearRGBA`) | 同等 | 全体を底上げする光。素の数は 0–255 (`LinearRGBA` の形は 0…1 で、1 を超える明るさも書ける)。数の形は表示の目盛りを線形へ戻して掛けるので、Processing と同じ数から同じ明るさは出ない。無い形: 光の位置を渡す `ambientLight(v1, v2, v3, x, y, z)` (mokume の底上げの光は位置を持たない) | [#913] |
| `directionalLight()` | `directionalLight(_:_:_:_:_:_:)`・`directionalLight(_:_:_:_:)` (`LinearRGBA`)・`directionalLight(color:direction:)` | 同等 | 向きだけを持つ光。数の形は 0–255、色の値の形は 0…1。向きは光が進む向きで、いまの変換を通る | [#913]・[#3780] |
| `pointLight()` | `pointLight(_:_:_:_:_:_:)`・`pointLight(_:_:_:_:)` (`LinearRGBA`)・`pointLight(color:position:)` | 同等 | 位置を持つ光。**距離で弱まらない** (面から光源へ向かう向きだけで明るさが決まる)。位置はいまの変換を通る | [#913]・[#3780]・[#907] |
| `spotLight()` | `spotLight(_:_:_:_:_:_:_:_:_:angle:)`・`spotLight(color:position:direction:angle:)` | 同等 | 位置・向き・広がり (半頂角) を持つ光。`angle` は 0…π/2 に丸めて 1 度だけ注意し、既定は π/6。Processing の `angle` は位置引数で必須。**無い形: 中心から縁へ弱まる強さ `concentration`** (名前ではなく機能の話で、ADR-0020 の表が決めないと明記している) | [#3780] |
| `lightFalloff()` | — | 作例待ち | 点光源・スポットの距離による減衰 (一定・1 次・2 次の 3 つの係数) を決める。**mokume の点光源・スポットに距離減衰が無い**ことは、実需待ちとして記録されている (光の走査は距離を使わず、多数の光を扱う経路もこの減衰が決まるのを待っている)。係数の 3 つ組にするか減衰の形を名前で選ぶかは、光の明るさを式によって意味が変わる数にしない原則 (明るさの倍率は色そのもの) と合わせて、作例が来てから決める | [#907] |
| `lightSpecular()` | — | 作例待ち | 以降に置く光の艶の色を決める。mokume の艶は材質の `shininess` と `metalness` が決め、光の色が艶の色を兼ねる (式は 1 本で、指定がどれも黙って無視されない)。光ごとに艶の色を持たせると式が増え、`metalness` との役割が重なる。下の `specular()` とあわせて、艶の色を光・材質のどちらが持つかを作例で決める | [#320] |
| `lights()`・`noLights()` (2 件) | `lights()`・`noLights()` | 同等 | `lights()` は底上げの光と斜め上から差す平行光を置く。**Processing の既定の光組とは違い** (底上げは 0.35・平行光は 0.85 で斜め上から。Processing は 128 の灰色で正面から)、同じ指定でも陰影が明るく出る (説明文が名乗る)。`noLights()` は置いた光をすべて取り除く | [#913] |
| `normal()` | `normal(_:_:_:)` | 同等 | 以降の頂点の法線を決める。数でない値・無限・長さ 0 の向きは注意して「書かれていない」状態にし、その後の頂点の向きは形から求める | — |

## 材質

4 件。材質は塗りと光の式に常に全部が効く (式は 1 本)。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `ambient()`・`emissive()` (2 件) | `ambient(_:_:_:)`・`ambient(_:)` (灰色・`LinearRGBA`)・`emissive` も同じ形 | 同等 | `ambient` は周りの光をどれだけ返すか (既定は白で、遮蔽なし)、`emissive` は光が当たらなくても出る色。綴りは Processing に揃え、p5.js の `ambientMaterial`・`emissiveMaterial` は採らない | [#320]・ADR-0020 |
| `shininess()` | `shininess(_:)` | 同等 | 艶の鋭さで、**大きいほど鋭い** (粗さと逆向き)。0 なら艶を出さない。負の値・数でない値は断る。金属らしさは別の `metalness(_:)` | [#320] |
| `specular()` | — | 作例待ち | 材質の艶の色を決める。mokume の艶は `shininess` の鋭さと `metalness` (金属は拡散を持たず周りを映す) で決まり、艶の色を別に持たない。`specular` を足すと `metalness` と役割が重なり、「式は 1 本で指定が黙って無視されない」を保つ形が分かれる。上の `lightSpecular()` と同じ根で、作例が来てから決める | [#320] |

## 描画

13 件。`PGraphics` に当たる型は、画面と同じ `Canvas` である。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `PGraphics` | `Canvas` | 同等 | `createGraphics(_:_:)` が返す描き場所。**画面と同じ型**で、平面も立体も字も効果も、画面と同じように書ける (「効果に渡せる画像」と「自分で描ける画像」を分けない)。透明で始まり、`background(_:)` を呼ぶまで消えない。`draw(into:_:)` の中なら、画面向けの描く関数をそのままグラフィックスへ向けられる | [ADR-0023](../decisions/0023-frame-stages-and-outputs.md) 決定 1 |
| `PGraphics.beginDraw()`・`PGraphics.endDraw()` (2 件) | `Canvas.beginDraw()`・`Canvas.endDraw()` | 同等 | グラフィックスへ置けるのは、この 2 つの間だけ。**外で置くと 1 度注意して置かない** (`setup()` の中でも同じ)。`endDraw()` を忘れたフレームは次のフレームの頭で描かずに捨てる。閉じ忘れを防ぐ書き方は `draw(into:_:)`・`Canvas.draw(_:)` | [#1834]・[#2201] |
| `createGraphics()` | `createGraphics(_:_:)` | 同等 | 画面と別の描き場所を作る。`setup()` で作って持ち回る (`draw()` の中で毎フレーム作らない)。確保できない・幅か高さが 1 を割るときは `RenderFailure` を投げる。**無い形: 描画先の種類を渡す `createGraphics(w, h, renderer)` と、書き出すパスを足す `createGraphics(w, h, renderer, path)`**。`P2D`・`P3D` は種類として要らない (`Canvas` が平面も立体も描く)。**`PDF`・`SVG`・`DXF` を渡して描画命令を別の描き先へ流す形は採らない** ([ADR-0023](../decisions/0023-frame-stages-and-outputs.md) の改訂 (2026-10-23))。SVG は `save("plot.svg")` が書く (入出力の表の `beginRecord()` の行)。PDF と DXF は、作例が来たときに別の `Feature` で足す。`createGraphics(w, h, PDF, path)` はコンパイルエラーになる | [#3688 の決定](https://github.com/mokume-metal/mokume/issues/3688#issuecomment-6586703173)・[#1967]・[#3471] |
| `blendMode()` | `blendMode(_:)` (`BlendMode`) | 同等 | 10 のモードは全部ある (`.blend`・`.add`・`.subtract`・`.darkest`・`.lightest`・`.difference`・`.exclusion`・`.multiply`・`.screen`・`.replace`)。**線形の光の量で混ぜ、`.add` は 1.0 を超える明るさをそのまま残す** (飽和させるのは出力段だけ)。`.replace` 以外ではアルファ 0 の色は下地を変えない。混ぜ方もフレームを越える状態で、一部だけ変えるなら `push { }` で包む | [#1057]・[#1542] |
| `clip()` | `clip(_:_:_:_:)`・`clip(_:)` (`Rect`)・`clip { }` | 同等 | 描くものを矩形の中だけに収める。**視点と変換の奥行きは通らず**、呼んだ時点の変換の x・y でキャンバス上の範囲を決める (Processing の P3D の `clip()` も画面の範囲で切る)。`clip { }` の閉包は矩形でない形で切る | [ADR-0021](../decisions/0021-solid-space-and-frame-assembly.md) 決定 1 の改訂 (2026-11-07)・[#3830] |
| `noClip()` | `noClip()` | 同等 | 切り抜きを解く | [#3830] |
| `hint()` | — | 持たない | OpenGL の描画の調整 (`ENABLE_STROKE_PURE`・`DISABLE_OPENGL_ERRORS`・`DISABLE_DEPTH_TEST`・`ENABLE_DEPTH_SORT`・`DISABLE_TEXTURE_MIPMAPS` ほか) を選ぶ API。描画の基盤が Metal の mokume に、この設定は当たらない。**奥行きの比較を切る使い方** (立体を描いてから 2D の操作盤を重ねる) は、平面の図形が奥行きを読み書きせず呼び出し順で重なるので、`hint(DISABLE_DEPTH_TEST)` なしで書ける ([ADR-0021](../decisions/0021-solid-space-and-frame-assembly.md) 決定 2)。保存の非同期 (`ENABLE_ASYNC_SAVEFRAME`) に当たる「待たせるか落とすか」は、いまは書き出しが追いつかなければ頼む側を待たせる側だけで、落とす側を選ばせる日の形は ADR-0025 が置いている ([ADR-0025](../decisions/0025-determinism-levels.md))。半透明の並べ替え (`ENABLE_DEPTH_SORT`) は並べ替えず、奥から順に描く責任は作品側 (同 決定 2) | — |
| `loadShader()` | `loadShader(_:values:surfaces:numbers:)`・`createShader(_:name:values:surfaces:numbers:)` | 同等 | フラグメントシェーダを読んで `Shader` を返す。**書くのは GLSL でなく Metal Shading Language の `paint` 1 本**で、値・サーフェス・数の並びは作るときに名前で宣言する。保存を拾って組み直し、ビルドに失敗しても前のシェーダで描き続ける。読めない・組めないときは `ShaderFailure` を投げる。無い形: 頂点シェーダを渡す `loadShader(frag, vert)` (頂点の側は差し替えられない。実需待ちとして記録されている) | [#907] |
| `shader()` | `shader(_:)` | 同等 | 以降に置く図形へシェーダを当てる。シェーダは**フレームを越えて残り**、`resetShader()` か次の `shader(_:)` まで効く。無い形: 当てる図形の種類を選ぶ `shader(shader, kind)` (`POINTS`・`LINES`・`TRIANGLES`) | [#907] |
| `resetShader()` | `resetShader()` | 同等 | 組み込みの塗りへ戻す | [#907] |
| `PShader` | `Shader` | 同等 | `loadShader(_:values:surfaces:numbers:)` が返す、利用者が書いた塗り。保存の拾い直し (`url`・`failure`・`generation`) を持つ | [#907] |
| `PShader.set()` | `Shader.set(_:_:)` | 同等 | シェーダの値を名前で後から変える。渡せるのは `Float`・`Int`・`Double`・`Vector2`・`Vector3`・`LinearRGBA`・`Bool`・`Transform` の値と、サーフェス・数の並び (`Numbers`)。**宣言していない名前は断り、宣言と違う型の値は警告して拒否する** (名前を増やすと再ビルドになるので、読み込むときに宣言する)。成分を並べる形 (`set(name, x, y, z, w)`) は、`Vector3` などの値で渡す | [#907] |

## 入れる

「入れる」の API は、近いものごとに 1 つの `Feature` で入れる。

| Feature | API | 表の行 |
| --- | --- | --- |
| [#4195] 視錐台を片寄せる投影 | `frustum(left:right:bottom:top:near:far:)` と、位置引数の形 | `frustum()` |

[#320]: https://github.com/mokume-metal/mokume/pull/320
[#669]: https://github.com/mokume-metal/mokume/issues/669
[#907]: https://github.com/mokume-metal/mokume/issues/907
[#913]: https://github.com/mokume-metal/mokume/issues/913
[#1057]: https://github.com/mokume-metal/mokume/issues/1057
[#1550]: https://github.com/mokume-metal/mokume/issues/1550
[#1553]: https://github.com/mokume-metal/mokume/issues/1553
[#1542]: https://github.com/mokume-metal/mokume/issues/1542
[#1834]: https://github.com/mokume-metal/mokume/issues/1834
[#1842]: https://github.com/mokume-metal/mokume/issues/1842
[#1967]: https://github.com/mokume-metal/mokume/issues/1967
[#2201]: https://github.com/mokume-metal/mokume/issues/2201
[#2399]: https://github.com/mokume-metal/mokume/issues/2399
[#2422]: https://github.com/mokume-metal/mokume/issues/2422
[#3471]: https://github.com/mokume-metal/mokume/issues/3471
[#3686]: https://github.com/mokume-metal/mokume/issues/3686
[#3778]: https://github.com/mokume-metal/mokume/issues/3778
[#3779]: https://github.com/mokume-metal/mokume/issues/3779
[#3780]: https://github.com/mokume-metal/mokume/issues/3780
[#3830]: https://github.com/mokume-metal/mokume/issues/3830
[#4195]: https://github.com/mokume-metal/mokume/issues/4195
