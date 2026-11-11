<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# 画像

Processing の本体の参照のうち、画像 (`PImage`・読み込みと表示・画素・テクスチャ) の 34 件。内訳は、`PImage` のクラスの頁とメンバー (14) の 15 件、読み込みと表示の関数 7 件、画素の関数 9 件、テクスチャ 3 件。形・バージョン・数え直す式は [README](README.md) にある。照合したのは processing-website `f4acef8` (2026-10-29) と mokume の main `fe258089` (2026-11-02)。

| 区分 | 件数 |
| --- | --- |
| 同等 | 24 |
| 入れる | 2 |
| 作例待ち | 1 |
| 持たない | 7 |
| 計 | 34 |

この領域に共通すること:

- **画像の型は `Image` で、参照型である。** カメラの `Capture.image` のように、毎フレーム同じ 1 枚が上書きされる画像がある。取っておくなら `Image.copy()` で写す ([#2449]・PR [#2893])。Processing の `PImage` も参照型で、ここは同じ
- **画素は作業空間の値 (線形・乗算済み・半精度) で持ち、色は `LinearRGBA` で受け渡す** ([ADR-0011](../decisions/0011-color-model.md))。Processing の `int` (0xAARRGGBB) ではない。`pixels` の添字も通し番号 1 本ではなく (x, y) の 2 つ
- **読み取りは落ちず、範囲の外は透明を返す** ([ADR-0020](../decisions/0020-api-naming-and-surface.md) 決定 5)。読めない・書けないときは `ImageFailure` を投げる。Processing は `null` や `false` を返す
- **画素の書き換えは、描くときに自動で GPU へ送られる。** Processing の `updatePixels()` に当たる呼び出しは要らない
- **Processing の「画面」(`get()`・`set()`・`pixels[]` ほかの関数) は、mokume ではスケッチ (`Sketch`) と描き場所 (`Canvas`、`createGraphics`) の両方にある。** 表の「画面」は両方を指す
- **新しい画像を返す操作は、Swift の過去分詞で名付ける** (`filtered`・`resized`・`cropped`。[#2580] の規則 3)。Processing の `resize` や `filter` は自分を変えるので、同じ名前で新しい画像を返すと、Processing の書き方を写した `img.resize(100, 100)` が警告だけで何も起こさない (同名異義・規則 2a)

## 入れるの束

「入れる」の API は、近いものごとに 6 本の `Feature` で入れる。表の「入れる」の行は当初 4 つ (いまは 2 つ。[#3711] で入れた `PImage.resize()` と [#3713] で入れた `PImage.mask()` は「同等」に移した) で、欠けた形 (行は「同等」のまま、理由の欄に「無い形」と書いたもの) も束に入れた。

| 束 | API | 表の行 |
| --- | --- | --- |
| [#3711] 切り出しと大きさの変更 (入れた) | `Image.cropped(x:y:width:height:)`・`Image.resized(width:height:)` | `PImage.get()` の領域の形・`PImage.resize()` |
| [#3713] マスク (入れた) | `Image.mask(_:)` | `PImage.mask()` |
| [#3714] 画面の写し | `Sketch.get()`・`get(x, y, w, h)` と、`Canvas` の同じもの | 関数 `get()` の領域と全体の形 |
| [#3715] URL からの読み込み | `loadImage`・`requestImage` の URL と、種類を渡す引数 | `loadImage()`・`requestImage()` の URL の形 |
| [#3716] `filter` の残りの効果 | `Effect` の `.posterize`・`.erode`・`.dilate` と、不透明にする効果 | `PImage.filter()`・関数 `filter()` の残りの 4 つ |
| [#3717] テクスチャの読み方 | `textureMode`・`textureWrap` | `textureMode()`・`textureWrap()` |

## 外した 4 つ

[#2449] は `Image.copy()` と `Image.save(_:)` だけを入れ (PR [#2893])、ほかは「作例が来たとき、または下限の API が作例を待たないと決まったときに足す」として外した。後者に当たった ([#2472]) ので、[#3133] の当初の条件 3 のとおり、ここで区分を付ける。下の表は節の行の見方を変えたもので、件数には数えない (件数は、下の `PImage` ほかの節の行で数える)。

| 外した API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| 領域の切り出し `PImage.get(x, y, w, h)` | `Image.cropped(x:y:width:height:)` | 同等 | 新しい画像を返し、元を変えない (名前は [#2449] と [#2580] の規則 3)。画像をはみ出す範囲は透明になり、重ならない範囲も投げずに透明の画像を返す。幅か高さが 1 を割れば `ImageFailure.unplaceable` を投げる。作業空間の値のまま写す | [#2449]・[#3711] |
| 領域の `PImage.copy(sx, sy, sw, sh, dx, dy, dw, dh)`・`copy(src, …)` | `image(src, dx, dy, dw, dh, sx, sy, sw, sh)` | 持たない | 画面と描き場所へは、切り出しつきの `image()` で描ける。下地を置き換えるなら `blendMode(.replace)`。画像へ写すときは、描き場所に描いて画面の `get()` ([#3714]) で受けるか、拡縮しないなら `dst.pixels.update { }` の中で `src.get` を読む。画像の中を直に書き換える `copy(sx, …)` を足すと、新しい画像を返す `copy()` と同じ名前で働きが逆になる (規則 2a)。名前を変えて足すなら、作例を持つ別の `Feature` から | [#2449]・[#2580] |
| `PImage.resize()` | `Image.resized(width:height:)` | 同等 | Processing の `resize` は自分を変えるが、`Image` の大きさは `let` で、新しい画像を返す (名前は [#2449])。読み方は縦横それぞれで固定して決定論を保つ: 縮める向きは作業空間 (線形・乗算済み) のまま光の量で平均し (覆う面積の割合で混ぜる。PR [#3691] のコマの縮小と同じく、エンコードした値では混ぜない)、広げる向きは `image()` が引き伸ばすときと同じく中心どうしの間を直線で補う (端は延ばす) | [#2449]・[#3711] |
| `PImage.mask()` | `Image.mask(_:)` | 同等 | 別の画像の明るさ (`brightness(_:)` の物差しで 0〜100 を 0〜1) を不透明度に掛ける。自分を変える命令形は `set`・`fill` と同じで、Processing と同名同義。不透明度は掛ける (置き換えない): 不透明な画像では Processing と同じ結果で、半透明の画素では違う (置き換えを再現できないのは不透明度 0 の画素だけ)。大きさの違うマスクは何も変えず 1 度だけ警告する | [#2449]・[#3713] |
| 画面の写しの `get()` | — | 入れる | `Sketch.get()`・`get(x, y, w, h)` (と `Canvas` の同じもの) で入れる。いまは `createImage` と `pixels` の写しで書くしかなく、`pixels` は実際の画素で数えるので、細かさを変えた作品や書き出しの倍率の下で、座標とずれる | [#2449]・[#3714] |

## PImage

15 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `PImage` (クラス) | `Image` | 同等 | 参照型で、大きさは作った後で変わらない。`createImage(_:_:)` で透明な画像を作る。Processing の `format` (RGB・ARGB・ALPHA) は無く、画素はいつも RGBA | [#2449] |
| `PImage.width`・`PImage.height` (2 件) | `Image.width`・`Image.height` | 同等 | `let` のプロパティ | — |
| `PImage.pixels[]` | `Image.pixels` | 同等 | 画像の画素そのものへの `Pixels` (ウィンドウ)。`pixels[x, y]` で読み書きし、`fill(_:)`・`update(_:)` で全画素を書き換える。値は `LinearRGBA`。無い形: 通し番号の添字 (`pixels[i]`。`count` はある) | [#2450]・PR [#3066] |
| `PImage.loadPixels()`・`PImage.updatePixels()` (2 件) | — (`Image.pixels` を直接読み書きする) | 持たない | `Image.pixels` はいつでも読め、書き換えは描くときに自動で送られる。呼び忘れて画面が変わらない形が起きない。`updatePixels(x, y, w, h)` の領域の形も要らない | [#2450]・PR [#3066] |
| `PImage.get()` | `Image.get(_:_:)` | 同等 | 1 画素を `LinearRGBA` で返し、範囲の外は透明。引数なしの `get()` は `Image.copy()`。領域の `get(x, y, w, h)` は `Image.cropped(x:y:width:height:)` (範囲の外は透明) | [#2449]・[#3711] |
| `PImage.set()` | `Image.set(_:_:_:)` | 同等 | 1 画素を書く。範囲の外は何もしない。無い形: 画像を書き込む `set(x, y, img)` (画面へは `image(img, x, y)` で置ける。画像へは `pixels.update { }` の中で `img.get` を読む) | — |
| `PImage.copy()` | `Image.copy()` | 同等 | 元と画素もテクスチャも共有しない新しい画像を返す。作業空間の値のまま写し、8 ビットを経由しない。無い形: 領域の `copy(sx, …)` (持たない。上の「外した 4 つ」) | [#2449]・PR [#2893] |
| `PImage.save()` | `Image.save(_:)` | 同等 | 呼んだその場で書き終えて返る。書けなければ `ImageFailure.unwritable(path:reason:)` を投げる (Processing は `boolean`)。形式は PNG だけで、拡張子では選ばない。**名前が `.png` (大文字小文字を区別しない) で終わらなければ書かずに投げる** (`.svg`・`.jpg`・拡張子を省いた名前も。理由に PNG だけを書くことが載る・[#3723])。行き先の探し方はスケッチの `save(_:)` と同じ。無い形: TIFF・TARGA・JPEG (入力・出力・環境の領域の表 ([#3688]) と同じ。スケッチの `save()` は `.png` 以外の名前でも PNG で書き、1 度だけ知らせる) | [#2449]・PR [#2893]・[#3723] |
| `PImage.filter()` | `Image.filtered(_:)` | 同等 | Processing は自分を変えるが、`filtered` は新しい画像を返し、元を変えない (規則 3・2a)。`THRESHOLD`・`GRAY`・`INVERT`・`BLUR` は `.threshold(level:)`・`.monochrome`・`.invert`・`.blur(radius:)` に当たる。無い形: `OPAQUE`・`POSTERIZE`・`ERODE`・`DILATE` ([#3716] で入れる) | [#2455]・PR [#3175]・[#3716] |
| `PImage.resize()` | `Image.resized(width:height:)` | 同等 | 新しい画像を返し、元を変えない (「外した 4 つ」)。縮める向きは光の量で平均し、広げる向きは `image()` と同じ直線の補い。無い形: 0 で縦横比を保つ `resize(150, 0)` (1 を割る指定を 1×1 へ丸めない規則と衝突するので、`ImageFailure.unplaceable` を投げる) | [#2449]・[#3711] |
| `PImage.mask()` | `Image.mask(_:)` | 同等 | マスクの明るさ (`brightness(_:)` の物差し) を不透明度に掛ける (「外した 4 つ」)。Processing は灰色を前提に青のチャンネルを読み、不透明度を置き換える。灰色の不透明なマスクと画像では同じ結果になる。無い形: 整数の配列を渡す `mask(maskArray)` (必要になってから足す) | [#2449]・[#3713] |
| `PImage.blend()` | — (描き場所へ `blendMode(_:)` と `image(src, dx, dy, dw, dh, sx, sy, sw, sh)`) | 持たない | 混ぜ方は描画 API の `blendMode` が持ち、画像を直に混ぜる API は足さない (`copy(sx, …)` と同じ理由)。Processing の 14 のモードのうち 9 つ (BLEND・ADD・SUBTRACT・DARKEST・LIGHTEST・DIFFERENCE・EXCLUSION・MULTIPLY・SCREEN) は `BlendMode` にある。OVERLAY・HARD_LIGHT・SOFT_LIGHT・DODGE・BURN の 5 つは無く、`blendMode()` の行 (色・変換・描画の領域の表) で扱う | [#2449]・[#2580] |
| `PImage.blendColor()` | — | 作例待ち | 2 色を混ぜて 1 色を返す関数 (所属は `PImage` だが、category は `color` なので色の領域の式にも入る。数えるのはこの表だけにする)。割れる点: Processing は 8 ビットの整数の色を 0〜255 に収める (`ADD` は 255 で頭打ち) が、mokume の混ぜ方は線形・乗算済みで、`.add` は 1.0 を超えた値を残す。CPU の関数を Processing の式に寄せるか、描画 API (`blendMode`) と同じ値を返すかで、同じモードの結果が変わる。残りの 5 つのモードも `BlendMode` に無く、`blendMode()` の行が先に決める。使う作例が来たら選ぶ | — |

## 読み込みと表示の関数

7 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `createImage()` | `createImage(_:_:)` | 同等 | 透明な画像を返す。幅か高さが 1 を割るかテクスチャの大きさの上限を越えれば `ImageFailure.unplaceable` を投げ、1×1 へ丸めない。無い形: `format` (RGB・ARGB・ALPHA)。画素はいつも RGBA | — |
| `image()` | `image(_:_:_:)`・`image(_:_:_:_:_:)` | 同等 | 描き場所 (`Canvas`) も渡せる。引数の読み方は `imageMode(_:)` が決める。切り出しつきの 9 引数の形もある (参照に無いので数えない) | — |
| `imageMode()` | `imageMode(_:)` | 同等 | `.corner`・`.corners`・`.center` が当たる。`.radius` もある (参照に無い)。一度書けばフレームを越える | — |
| `loadImage()` | `loadImage(_:)` | 同等 | 読めなければ `ImageFailure` を投げる (Processing は `null`)。同じ名前の画像は一度しか読まない。無い形: `http(s)` の URL と、種類を渡す `extension` ([#3715] で入れる) | [#3715] |
| `noTint()` | `noTint()` | 同等 | 色掛けをやめる | — |
| `requestImage()` | `requestImage(_:)` | 同等 | `async` で、読み終えてから画像を返す (Processing は幅と高さが 0 の画像をすぐ返し、読めたら埋める。読めなければ幅と高さを -1 にする)。読めなければ投げる。無い形: `loadImage()` と同じ ([#3715]) | [#3715] |
| `tint()` | `tint(_:_:)`・`tint(_:_:_:_:)`・`tint(_:)` | 同等 | グレー・RGB・`LinearRGBA` で渡す。一度書けばフレームを越える | — |

## 画素の関数

9 件。画面の画素 (`Sketch` と `Canvas`) と、画面へ画像を置く関数。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `blend()` | — (`blendMode(_:)` と `image(src, dx, dy, dw, dh, sx, sy, sw, sh)`) | 持たない | 画像と画面の領域を混ぜる関数。混ぜ方は描画 API の `blendMode` が持ち、同じことを `image()` で描いて書ける。モードの欠けは `PImage.blend()` の行と同じ | [#2449]・[#2580] |
| `copy()` | — (`image(src, dx, dy, dw, dh, sx, sy, sw, sh)`) | 持たない | 画像の領域を画面へ写すには、切り出しつきの `image()` で描く。画面の領域を画面へ写すには、画面の `get()` ([#3714]) で画像にして、`image(shot, …)` で置く。透けた画像は下地と混ざる (置き換えるなら `blendMode(.replace)`) | [#2449]・[#3714] |
| `filter()` | `filter(_:)` | 同等 | 呼んだ時点までに描いたものに掛かり、後から描くものには掛からない (Processing と同じ)。焼き込んだ分は次のフレームへ持ち越す。`filter(shader)` の形は `makeEffect` で作った効果を `filter([.custom(…)])` に渡す。種類は `PImage.filter()` の行と同じ。フレームの終わりに画面全体へ掛ける `effects(_:)` は別 | [#2455]・PR [#3175]・[#3716] |
| `get()` | `get(_:_:)` | 同等 | 1 画素を `LinearRGBA` で返し、範囲の外は透明。そのフレームでそこまでに描いたものが読める。無い形: 領域の `get(x, y, w, h)` と、引数なしの `get()` ([#3714] で入れる) | [#2449]・[#3714] |
| `loadPixels()` | `loadPixels()` | 同等 | 溜めた図形を描き切り、画素を読める状態にする。`pixels`・`get`・`set` が必要なら自分で呼ぶので、省いても結果は変わらない | — |
| `mask()` | — (`get()` で画面を画像にして `Image.mask(_:)` を掛け、`image()` で置く) | 持たない | 画面の描いた結果に掛ける形は、画像の `mask(_:)` ([#3713]) と画面の写し ([#3714]) の組み合わせで書ける | [#2449]・[#3713]・[#3714] |
| `pixels[]` | `pixels` | 同等 | 画面の画素への `Pixels`。索引は実際の画素で数え、細かさを下げているときは `width` × `height` より小さく、書き出しの倍率の下では大きい (`pixelWidth` × `pixelHeight`)。値は `LinearRGBA` | PR [#3066] |
| `set()` | `set(_:_:_:)` | 同等 | 1 画素を書く。無い形: 画像を書き込む `set(x, y, img)` (`image(img, x, y)` で置ける。`blendMode(.replace)` で下地を置き換える) | — |
| `updatePixels()` | — | 持たない | 書き換えは次に GPU が描画先へ触る前に自動で戻される。呼び忘れて画面が変わらない形が起きない | [#2450]・PR [#3066] |

## テクスチャ

3 件。形の頂点 (`vertex(x, y, u, v)`) の行は形の領域の表 ([#3685]) にある。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `texture()` | `texture(_:)` (`Image` と `Canvas` の 2 つ) | 同等 | これから置く塗りに画像を貼る。`noTexture()` を呼ぶまで続き、`push()` / `pop()` で積める (Processing は `beginShape()` と `endShape()` の間に呼ぶ)。読み取り位置は `vertex(x, y, u, v)` で貼る画像の画素で書き、書かなければ形の囲みの箱から決まる | — |
| `textureMode()` | — | 入れる | 読み取り位置は画素の単位 (Processing の `IMAGE`) だけで、0〜1 の `NORMAL` が無い。いまは `u * image.width` と掛けて書くしかない。描き場所を貼ったときは座標の大きさで読む。単位を選ぶ状態を足す | [#3717] |
| `textureWrap()` | — | 入れる | 画像を読むサンプラーは端の外を端の色で延ばす (`CLAMP`) 固定で、繰り返す `REPEAT` が無い。`u` を画像の幅より大きく書いても、端の色で延びるだけで、繰り返しは `shader()` の断片でしか書けない。断片から画像を読む `mokume_sample` と読み方をそろえるかは [#3717] で決める | [#3717] |

[#2449]: https://github.com/mokume-metal/mokume/issues/2449
[#2450]: https://github.com/mokume-metal/mokume/issues/2450
[#2455]: https://github.com/mokume-metal/mokume/issues/2455
[#2472]: https://github.com/mokume-metal/mokume/issues/2472
[#2580]: https://github.com/mokume-metal/mokume/issues/2580
[#2893]: https://github.com/mokume-metal/mokume/pull/2893
[#3066]: https://github.com/mokume-metal/mokume/pull/3066
[#3133]: https://github.com/mokume-metal/mokume/issues/3133
[#3175]: https://github.com/mokume-metal/mokume/pull/3175
[#3685]: https://github.com/mokume-metal/mokume/issues/3685
[#3688]: https://github.com/mokume-metal/mokume/issues/3688
[#3691]: https://github.com/mokume-metal/mokume/pull/3691
[#3711]: https://github.com/mokume-metal/mokume/issues/3711
[#3713]: https://github.com/mokume-metal/mokume/issues/3713
[#3714]: https://github.com/mokume-metal/mokume/issues/3714
[#3715]: https://github.com/mokume-metal/mokume/issues/3715
[#3716]: https://github.com/mokume-metal/mokume/issues/3716
[#3717]: https://github.com/mokume-metal/mokume/issues/3717
[#3723]: https://github.com/mokume-metal/mokume/issues/3723
