<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# 画像

Processing 本体のリファレンスのうち、画像 (`PImage`・読み込みと表示・画素・テクスチャ) の 34 件。内訳は、`PImage` のクラスのページとメンバー (14) の 15 件、読み込みと表示の関数 7 件、画素の関数 9 件、テクスチャ 3 件。表の形式・バージョン・数え直す式は [README](README.md) にある。照合したのは processing-website `f4acef8` (2026-10-29) と mokume の main `fe258089` (2026-11-02)。

| 区分 | 件数 |
| --- | --- |
| 同等 | 26 |
| 入れる | 0 |
| 作例待ち | 1 |
| 持たない | 7 |
| 計 | 34 |

この領域に共通すること:

- **画像の型は `Image` で、参照型である。** カメラの `Capture.image` のように、毎フレーム同じ 1 枚が上書きされる画像がある。取っておくなら `Image.copy()` でコピーする ([#2449]・PR [#2893])。Processing の `PImage` も参照型で、ここは同じ
- **画素は作業色空間の値 (線形・乗算済み・半精度) で持ち、色は `LinearRGBA` で受け渡す** ([ADR-0011](../decisions/0011-color-model.md))。Processing の `int` (0xAARRGGBB) ではない。`pixels` の添字も通し番号 1 つではなく (x, y) の 2 つ
- **読み取りはクラッシュせず、範囲の外は透明を返す** ([ADR-0020](../decisions/0020-api-naming-and-surface.md) 決定 5)。読めない・書けないときは `ImageFailure` を投げる。Processing は `null` や `false` を返す
- **画素の書き換えは、描くときに自動で GPU へ送られる。** Processing の `updatePixels()` に当たる呼び出しは要らない
- **Processing の「画面」(`get()`・`set()`・`pixels[]` ほかの関数) は、mokume ではスケッチ (`Sketch`) と描画先 (`Canvas`、`createGraphics`) の両方にある。** 表の「画面」は両方を指す
- **新しい画像を返す操作は、Swift の過去分詞で名付ける** (`filtered`・`resized`・`cropped`。[#2580] の規則 3)。Processing の `resize` や `filter` は自分を変えるので、同じ名前で新しい画像を返すと、Processing の書き方をそのまま移した `img.resize(100, 100)` が警告だけで何もしない (同名異義・規則 2a)

## 「入れる」の API をまとめた Feature

「入れる」の API は、近いものごとに 6 つの `Feature` で入れる。表の「入れる」の行は当初 4 つ (いまは 0。[#3711] で入れた `PImage.resize()`、[#3713] で入れた `PImage.mask()`、[#3717] で入れた `textureMode()`・`textureWrap()` は「同等」に移した) で、欠けた形 (行は「同等」のまま、理由の欄に「無い形:」と書いたもの) も Feature に入れた。

| Feature | API | 表の行 |
| --- | --- | --- |
| [#3711] 切り出しと大きさの変更 (入れた) | `Image.cropped(x:y:width:height:)`・`Image.resized(width:height:)` | `PImage.get()` の領域の形・`PImage.resize()` |
| [#3713] マスク (入れた) | `Image.mask(_:)` | `PImage.mask()` |
| [#3714] 画面の写し (入れた) | `Sketch.get()`・`get(_:_:_:_:)`・`get(in:)` と、`Canvas` の同じもの | 関数 `get()` の領域と全体の形 |
| [#3715] URL からの読み込み (入れた) | `loadImage`・`requestImage` の URL と、種類を渡す `loadImage(_:extension:)`・`requestImage(_:extension:)` | `loadImage()`・`requestImage()` の URL の形 |
| [#3716] `filter` の残りの効果 (入れた) | `Effect` の `.posterize(levels:)`・`.erode`・`.dilate`・`.opaque` | `PImage.filter()`・関数 `filter()` の残りの 4 つ |
| [#3717] テクスチャの読み方 (入れた) | `textureMode(_:)`・`textureWrap(_:)` | `textureMode()`・`textureWrap()` |

## 外した 4 つ

[#2449] は `Image.copy()` と `Image.save(_:)` だけを入れ (PR [#2893])、ほかは「作例が来たとき、または下限の API が作例を待たないと決まったときに足す」として対象外にした。後者に当たった ([#2472]) ので、[#3133] の当初の条件 3 のとおり、ここで区分を付ける。下の表は他の節の行を別の見方で再掲したもので、件数には数えない (件数は、下の `PImage` ほかの節の行で数える)。

| 外した API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| 領域の切り出し `PImage.get(x, y, w, h)` | `Image.cropped(x:y:width:height:)` | 同等 | 新しい画像を返し、元の画像を変えない (名前は [#2449] と [#2580] の規則 3)。画像をはみ出す範囲は透明になり、重ならない範囲も投げずに透明の画像を返す。幅か高さが 1 未満なら `ImageFailure.unplaceable` を投げる。作業色空間の値のままコピーする | [#2449]・[#3711] |
| 領域の `PImage.copy(sx, sy, sw, sh, dx, dy, dw, dh)`・`copy(src, …)` | `image(src, dx, dy, dw, dh, sx, sy, sw, sh)` | 持たない | 画面と描画先へは、切り出し指定つきの `image()` で描ける。既存の描画内容を置き換えるなら `blendMode(.replace)`。画像へコピーするときは、描画先に描いて画面の `get()` ([#3714]) で受けるか、拡大縮小しないなら `dst.pixels.update { }` の中で `src.get` を読む。画像の中身を直接書き換える `copy(sx, …)` を足すと、新しい画像を返す `copy()` と同じ名前で働きが逆になる (規則 2a)。名前を変えて足すなら、作例を持つ別の `Feature` から | [#2449]・[#2580] |
| `PImage.resize()` | `Image.resized(width:height:)` | 同等 | Processing の `resize` は自分自身を変更するが、`Image` の大きさは `let` で、新しい画像を返す (名前は [#2449])。補間の方法は縦横それぞれで固定して決定論を保つ: 縮小する向きは作業色空間 (線形・乗算済み) のまま光の量で平均し (覆う面積の割合で混ぜる。PR [#3691] のカメラのフレームの縮小と同じく、エンコード後の値では混ぜない)、拡大する向きは `image()` が引き伸ばすときと同じく、画素の中心どうしの間を線形補間する (端は延長する) | [#2449]・[#3711] |
| `PImage.mask()` | `Image.mask(_:)` | 同等 | 別の画像の明るさ (`brightness(_:)` と同じ尺度で、0〜100 を 0〜1 として) を不透明度に掛ける。自身を書き換えるメソッドである点は `set`・`fill` と同じで、Processing と同名同義。不透明度は掛ける (置き換えない): 不透明な画像では Processing と同じ結果で、半透明の画素では違う (置き換えを再現できないのは不透明度 0 の画素だけ)。大きさの違うマスクは画像を変更せず、1 度だけ警告する | [#2449]・[#3713] |
| 画面の写しの `get()` | `get()`・`get(_:_:_:_:)`・`get(in:)` (`Sketch` と `Canvas`) | 同等 | 画面の全体か領域を新しい `Image` にして返し、後の描画で変わらない。領域も返す画像の大きさも座標の単位で数え (1 画素の `get(x, y)` は実際の画素)、書き出し倍率が掛かっているときは光の量で平均して縮小する。画面をはみ出す部分は透明で、幅か高さが 1 未満の領域は `ImageFailure.unplaceable` を投げる。3 つの形すべてが投げる (Processing は投げない)。`get(in: Rect)` は `rectMode`・`imageMode` に従わない。`Image` に密度 (Processing 4 の `PImage.pixelDensity`) は無い | [#2449]・[#3714] |

## PImage

15 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `PImage` (クラス) | `Image` | 同等 | 参照型で、大きさは作った後で変わらない。`createImage(_:_:)` で透明な画像を作る。Processing の `format` (RGB・ARGB・ALPHA) は無く、画素はいつも RGBA | [#2449] |
| `PImage.width`・`PImage.height` (2 件) | `Image.width`・`Image.height` | 同等 | `let` のプロパティ | — |
| `PImage.pixels[]` | `Image.pixels` | 同等 | 画像の画素そのものを指す `Pixels` (ビュー)。`pixels[x, y]` で読み書きし、`fill(_:)`・`update(_:)` で全画素を書き換える。値は `LinearRGBA`。無い形: 通し番号の添字 (`pixels[i]`。`count` はある) | [#2450]・PR [#3066] |
| `PImage.loadPixels()`・`PImage.updatePixels()` (2 件) | — (`Image.pixels` を直接読み書きする) | 持たない | `Image.pixels` はいつでも読め、書き換えは描画時に自動で GPU へ送られる。呼び忘れて画面が変わらない、という失敗が起きない。`updatePixels(x, y, w, h)` の領域指定の形も要らない | [#2450]・PR [#3066] |
| `PImage.get()` | `Image.get(_:_:)` | 同等 | 1 画素を `LinearRGBA` で返し、範囲の外は透明。引数なしの `get()` は `Image.copy()`。領域の `get(x, y, w, h)` は `Image.cropped(x:y:width:height:)` (範囲の外は透明) | [#2449]・[#3711] |
| `PImage.set()` | `Image.set(_:_:_:)` | 同等 | 1 画素を書く。範囲の外は何もしない。無い形: 画像を書き込む `set(x, y, img)` (画面へは `image(img, x, y)` で描ける。画像へは `pixels.update { }` の中で `img.get` を読む) | — |
| `PImage.copy()` | `Image.copy()` | 同等 | 元と画素もテクスチャも共有しない新しい画像を返す。作業色空間の値のままコピーし、8 ビットを経由しない。無い形: 領域の `copy(sx, …)` (持たない。上の「外した 4 つ」) | [#2449]・PR [#2893] |
| `PImage.save()` | `Image.save(_:)` | 同等 | 呼んだ時点で書き終えてから返る。書けなければ `ImageFailure.unwritable(path:reason:)` を投げる (Processing は `boolean`)。形式は PNG だけで、拡張子では選ばない。**名前が `.png` (大文字小文字を区別しない) で終わらなければ書かずに投げる** (`.svg`・`.jpg`・拡張子を省いた名前も。エラーの理由に PNG だけ対応と載る・[#3723])。保存先の決め方はスケッチの `save(_:)` と同じ。無い形: TIFF・TARGA・JPEG (入力・出力・環境の領域の表 ([#3688]) と同じ。スケッチの `save()` は `.png` 以外の名前でも PNG で書き、1 度だけ警告する) | [#2449]・PR [#2893]・[#3723] |
| `PImage.filter()` | `Image.filtered(_:)` | 同等 | Processing は自分自身を変更するが、`filtered` は新しい画像を返し、元の画像を変えない (規則 3・2a)。`THRESHOLD`・`GRAY`・`INVERT`・`BLUR` は `.threshold(level:)`・`.monochrome`・`.invert`・`.blur(radius:)`、`OPAQUE`・`POSTERIZE`・`ERODE`・`DILATE` は `.opaque`・`.posterize(levels:)`・`.erode`・`.dilate` に当たる ([#3716])。`POSTERIZE` は表示用の 8 ビットの値を Processing と同じ式で段階に分け、2 未満の段階数は投げず、効果を適用しない (Processing は 2〜255 の外で投げる)。`ERODE`・`DILATE` は Processing と同じ輝度の加重で近傍の画素をそのまま選ぶが、乗算済みのまま比較するので透明な画素は暗い側として扱う (Processing は不透明度を見ない)。`OPAQUE` は不透明度 0 の画素を黒にする (乗算済みで色が残らない) | [#2455]・PR [#3175]・[#3716] |
| `PImage.resize()` | `Image.resized(width:height:)` | 同等 | 新しい画像を返し、元の画像を変えない (「外した 4 つ」)。縮小する向きは光の量で平均し、拡大する向きは `image()` と同じ線形補間。無い形: 0 で縦横比を保つ `resize(150, 0)` (1 未満の指定を 1×1 に補正しない規則と衝突するので、`ImageFailure.unplaceable` を投げる) | [#2449]・[#3711] |
| `PImage.mask()` | `Image.mask(_:)` | 同等 | マスクの明るさ (`brightness(_:)` と同じ尺度) を不透明度に掛ける (「外した 4 つ」)。Processing はグレーを前提に青チャンネルを読み、不透明度を置き換える。グレーで不透明なマスクと画像では同じ結果になる。無い形: 整数の配列を渡す `mask(maskArray)` (必要になってから足す) | [#2449]・[#3713] |
| `PImage.blend()` | — (描画先へ `blendMode(_:)` と `image(src, dx, dy, dw, dh, sx, sy, sw, sh)`) | 持たない | ブレンド方法は描画 API の `blendMode` が持ち、画像同士を直接ブレンドする API は足さない (`copy(sx, …)` と同じ理由)。Processing の 14 のブレンドモードのうち 9 つ (BLEND・ADD・SUBTRACT・DARKEST・LIGHTEST・DIFFERENCE・EXCLUSION・MULTIPLY・SCREEN) は `BlendMode` にある。OVERLAY・HARD_LIGHT・SOFT_LIGHT・DODGE・BURN の 5 つは無く、`blendMode()` の行 (色・変換・描画の領域の表) で扱う | [#2449]・[#2580] |
| `PImage.blendColor()` | — | 作例待ち | 2 色をブレンドして 1 色を返す関数 (所属は `PImage` だが、category は `color` なので色の領域の表にも入る。数えるのはこの表だけにする)。選択が分かれる点: Processing は 8 ビットの整数の色を 0〜255 に収める (`ADD` は 255 で飽和する) が、mokume のブレンドは線形・乗算済みで、`.add` は 1.0 を超えた値を残す。CPU の関数を Processing の式に合わせるか、描画 API (`blendMode`) と同じ値を返すかで、同じモードの結果が変わる。残りの 5 つのモードも `BlendMode` に無く、`blendMode()` の行が先に決める。使う作例が来たら選ぶ | — |

## 読み込みと表示の関数

7 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `createImage()` | `createImage(_:_:)` | 同等 | 透明な画像を返す。幅か高さが 1 未満かテクスチャの大きさの上限を超えれば `ImageFailure.unplaceable` を投げ、1×1 に補正しない。無い形: `format` (RGB・ARGB・ALPHA)。画素はいつも RGBA | — |
| `image()` | `image(_:_:_:)`・`image(_:_:_:_:_:)` | 同等 | 描画先 (`Canvas`) も渡せる。引数の解釈は `imageMode(_:)` が決める。切り出し指定つきの 9 引数の形もある (リファレンスに無いので数えない) | — |
| `imageMode()` | `imageMode(_:)` | 同等 | `.corner`・`.corners`・`.center` が当たる。`.radius` もある (リファレンスに無い)。一度書けばフレームをまたいで残る | — |
| `loadImage()` | `loadImage(_:)`・`loadImage(_:extension:)` | 同等 | 読めなければ `ImageFailure` を投げる (Processing は `null`)。同じ名前の画像は一度しか読み込まない。名前が `http://` か `https://` で始まれば URL から取得し、実行中は URL ごとに 1 度だけ取得する (サーバ側での差し替えは反映しない)。取得できなければ `ImageFailure.unreachable(url:reason:)` を投げる。種類を渡す `extension` は ImageIO へのヒントで、中身から形式が判別できればそちらで読む | [#3715] |
| `noTint()` | `noTint()` | 同等 | tint (色の乗算) をやめる | — |
| `requestImage()` | `requestImage(_:)`・`requestImage(_:extension:)` | 同等 | `async` で、読み終えてから画像を返す (Processing は幅と高さが 0 の画像をすぐ返し、読み込めたら中身を入れる。読めなければ幅と高さを -1 にする)。読めなければ投げる。URL と種類を渡す `requestImage(_:extension:)` は `loadImage()` と同じ (Processing の `requestImage(filename, extension)`) | [#3715] |
| `tint()` | `tint(_:_:)`・`tint(_:_:_:_:)`・`tint(_:)` | 同等 | グレー・RGB・`LinearRGBA` で渡す。一度書けばフレームをまたいで残る | — |

## 画素の関数

9 件。画面の画素 (`Sketch` と `Canvas`) と、画面へ画像を描く関数。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `blend()` | — (`blendMode(_:)` と `image(src, dx, dy, dw, dh, sx, sy, sw, sh)`) | 持たない | 画像と画面の領域をブレンドする関数。ブレンド方法は描画 API の `blendMode` が持ち、同じことは `image()` で描いて実現できる。足りないモードは `PImage.blend()` の行と同じ | [#2449]・[#2580] |
| `copy()` | — (`image(src, dx, dy, dw, dh, sx, sy, sw, sh)`) | 持たない | 画像の領域を画面へコピーするには、切り出し指定つきの `image()` で描く。画面の領域を画面へコピーするには、画面の `get()` ([#3714]) で画像にして、`image(shot, …)` で描く (`copy(sx, sy, sw, sh, dx, dy, dw, dh)` は `image(try get(sx, sy, sw, sh), dx, dy, dw, dh)`)。半透明の画像は既存の描画内容と合成される (置き換えるなら `blendMode(.replace)`) | [#2449]・[#3714] |
| `filter()` | `filter(_:)` | 同等 | 呼んだ時点までに描いたものに掛かり、後から描くものには掛からない (Processing と同じ)。適用した結果は次のフレームへ引き継ぐ。`filter(shader)` の形は `makeEffect` で作った効果を `filter([.custom(…)])` に渡す。種類は `PImage.filter()` の行と同じ。フレームの終わりに画面全体へ掛ける `effects(_:)` は別 | [#2455]・PR [#3175]・[#3716] |
| `get()` | `get(_:_:)`・`get()`・`get(_:_:_:_:)`・`get(in:)` | 同等 | 1 画素の `get(x, y)` は `LinearRGBA` を返し、範囲の外は透明。引数なしの `get()` と領域の `get(x, y, w, h)` は、画面を新しい `Image` にして返す (「外した 4 つ」の画面の写しの行)。どれも、そのフレームでそこまでに描いた内容を読める。1 画素を返す形は実際の画素で、画像を返す形は座標の単位で数える | [#2449]・[#3714] |
| `loadPixels()` | `loadPixels()` | 同等 | 溜めた図形を描画し終え (フラッシュし)、画素を読める状態にする。`pixels`・`get`・`set` は必要に応じて内部で同じ処理を行うので、省いても結果は変わらない | — |
| `mask()` | — (`get()` で画面を画像にして `Image.mask(_:)` を掛け、`image()` で描く) | 持たない | 画面の描画結果に掛ける形は、画像の `mask(_:)` ([#3713]) と画面の写し ([#3714]) の組み合わせで書ける: `let part = try get(); part.mask(m); background(0); image(part, 0, 0)` | [#2449]・[#3713]・[#3714] |
| `pixels[]` | `pixels` | 同等 | 画面の画素を指す `Pixels`。添字は実際の画素で数え、画素密度を下げているときは `width` × `height` より小さく、書き出し倍率が掛かっているときは大きい (`pixelWidth` × `pixelHeight`)。値は `LinearRGBA` | PR [#3066] |
| `set()` | `set(_:_:_:)` | 同等 | 1 画素を書く。無い形: 画像を書き込む `set(x, y, img)` (`image(img, x, y)` で描ける。`blendMode(.replace)` で既存の描画内容を置き換える) | — |
| `updatePixels()` | — | 持たない | 書き換えは次に GPU が描画先を使う前に自動で反映される。呼び忘れて画面が変わらない、という失敗が起きない | [#2450]・PR [#3066] |

## テクスチャ

3 件。図形の頂点 (`vertex(x, y, u, v)`) の行は図形の領域の表 ([#3685]) にある。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `texture()` | `texture(_:)` (`Image` と `Canvas` の 2 つ) | 同等 | これから描く塗りに画像を貼る。`noTexture()` を呼ぶまで続き、`push()` / `pop()` で保存・復元できる (Processing は `beginShape()` と `endShape()` の間に呼ぶ)。テクスチャ座標は `vertex(x, y, u, v)` で貼る画像の画素で指定し、指定しなければ図形のバウンディングボックスから決まる | — |
| `textureMode()` | `textureMode(_:)` | 同等 | `IMAGE`・`NORMAL` は `.image` (既定)・`.normal`。Processing と同じく `vertex()` を呼んだ時点の単位で解釈し、描いた後に戻しても変わらない。描画先を貼ったときの `.image` は座標の大きさで解釈する。画像を貼っていない図形では、どちらの単位でも指定した値がそのままフラグメントシェーダの `in.uv` へ届く。描き方なのでフレームを越え、`push()` / `pop()` で保存・復元できる | [#3717] |
| `textureWrap()` | `textureWrap(_:)` | 同等 | `CLAMP`・`REPEAT` は `.clamp` (既定)・`.repeat`。塗りを描いた時点の設定で読み取る (Processing も設定を切り替えるたびに描画をフラッシュする)。内側の補間 (線形) は変えない。**効くのは組み込みの塗りが貼る画像を読むときだけ**で、シェーダの `mokume_sample` は端の色を延長したまま ([#3717] の決定。シェーダにも要る作例が来たら決め直す)。描き方なのでフレームを越え、`push()` / `pop()` で保存・復元できる | [#3717] |

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
