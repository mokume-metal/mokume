<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# 入力・出力・環境

Processing の本体の参照のうち、マウス・キー・時刻・ファイル・書き出し・ウィンドウにあたる 81 件。category が `environment` (27)・`input` (40)・`output` (20) の項目と、所属が `BufferedReader`・`PrintWriter` のメソッド (5) から、[データ: JSON・Table・XML](data-json-table-xml.md) が数えた `load`・`parse`・`save` の 11 件 (`loadJSONArray()` ほか) を除いたもの。形・バージョン・数え直す式は [README](README.md) にある。照合したのは processing-website `f4acef8` (2026-10-29) と mokume の main `fe258089` (2026-11-02)。

| 区分 | 件数 |
| --- | --- |
| 同等 | 37 |
| 入れる | 4 |
| 作例待ち | 15 |
| 持たない | 25 |
| 計 | 81 |

この領域に共通すること:

- **ウィンドウを持つのは本体とは限らない。** 直に走らせたウィンドウ (`mokume run`・束ねた `.app`) では本体がウィンドウを持つが、`mokume watch` の下では道具がウィンドウを持ち、`SketchView` ではホストが持ち、`mokume render` ではウィンドウが無い。ウィンドウに頼む API (`noCursor()`・`selectInput()`) は、頼みを絵と一緒に道具のウィンドウへ渡し、ウィンドウの無い実行では何も起きない。ウィンドウの API を足すときは、この 4 つの場面を行ごとに書く
- **描く大きさとウィンドウの大きさは別の数である。** `width`・`height` は起動のときに決まり、ウィンドウを広げても変わらない ([ADR-0015](../decisions/0015-metalfx-role.md))。Processing の `windowResize()` は描く面の大きさを変えるので、API の意味がそのままでは写らない
- **設定は呼ばずに `settings` で返す。** `size()`・`frameRate()`・`fullScreen()` は、起動のときに読む `Sketch.settings` の値にする
- **コールバックは、押した 1 回・離した 1 回・動いた 1 件ごとに呼ばれる。** `mouseDragged()` ほかの API ごとの違いは下の行に書く。`func mouseWheel()` のように引数を省くと、コンパイルは通るが一度も呼ばれない API がある (`mouseWheel(deltaX:deltaY:)`・`fileDropped(_:)`)
- **キーとボタンは数ではなく型で指す** ([ADR-0034](../decisions/0034-input-surface-units.md) 決定 1)。`keyCode == UP` は `keyCode == .arrowUp`、`mouseButton == LEFT` は `mouseButton == .left`
- **読めない・書けないときは投げる。** Processing は `null` を返す。mokume は `DataFailure` を投げ、`setup() throws` の `try` か `try?` で受ける

## 入れるの束

「入れる」の 6 件は、近い API ごとに 3 本の `Feature` で入れる。

| 束 | API | 件数 |
| --- | --- | --- |
| [#3707] 保存先とフォルダを選ばせる | `selectOutput()`・`selectFolder()` | 2 |
| [#3708] バイト列を読み書きする | `loadBytes()`・`saveBytes()` | 2 |
| [#3709] ウィンドウの題名を変え、ウィンドウが前にあるかを読む | `windowTitle()`・`focused` | 2 |

## 環境

27 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `size()` | `SketchSettings.size(_:_:frameRate:title:)`・`SketchSettings(width:height:)` | 同等 | `settings` で返す。1 画素をウィンドウの何点にするかは `windowScale` (既定 0.5) で、Processing のように 1 画素 = 1 点ではない。無い形: 描き手の指定 (`size(w, h, P3D)`。2D も 3D も同じ面に描く) | [#2437] |
| `fullScreen()` | `SketchSettings.fullScreen(_:)` | 同等 | 番号でディスプレイを選び、省けば 1 (メニューバーのある画面)。選んだ画面が無ければ別の画面へ出さず、起動で断る。無い形: 描き手の指定、複数の画面にまたがる `SPAN` (マッピングの仕事) | [#2020]・[#2437] |
| `settings()` | `Sketch.settings` | 同等 | `settings` を返す計算プロパティにする。Processing が `settings()` の中でだけ変数を使えるのと同じく、`displays` など、`settings` の中から読める値で書く | [#2437] |
| `width`・`height` (2 件) | `width`・`height` | 同等 | `Float` (座標の単位)。細かさ (`pixelDensity`) と書き出しの倍率を変えても動かない。走る前に読むと 0 を返して 1 度だけ警告する | — |
| `pixelWidth`・`pixelHeight` (2 件) | `pixelWidth`・`pixelHeight` | 同等 | 実際に刻んでいる画素。細かさが 1 で倍率が無ければ `width` と同じ。`pixels` の添字はこちらの数 | — |
| `pixelDensity()` | `SketchSettings.pixelDensity` | 持たない | **同じ名前で向きが逆**。Processing は 2 で細かく描くが、mokume は 0 より大きく 1 以下で粗く描いて拡大し、1 を超える指定は組み立てで断る ([ADR-0015](../decisions/0015-metalfx-role.md) が退けた案)。写した `pixelDensity(2)` は、型は通っても意味が違う。細かい画面に鮮明に出すのは、全画面が `Display.width` (画素) で描くことで済む | [ADR-0015](../decisions/0015-metalfx-role.md) |
| `displayDensity()` | — (`displays` の `width`・`height` が画素で返る) | 持たない | 主な使い道の `pixelDensity(displayDensity())` に当たる API が無い (上の行)。`Display.width` は点に画素密度を掛けた画素で返るので、密度を自分で掛ける場面が無い | — |
| `displayWidth`・`displayHeight` (2 件) | `displays.first?.width`・`displays.first?.height` | 同等 | メニューバーのある画面の、全画面にしたときに描く大きさ (画素)。Retina では点の 2 倍で、切り欠きのある画面ではその帯のぶん低い。画面の無い実行では `displays` が空になる | [#2020] |
| `frameCount` | `frameCount` | 同等 | 最初の `draw()` の最中は 1 (Processing と同じ) | — |
| `frameRate()` | `SketchSettings.frameRate` | 同等 | 起動のときに読み、1 以上。無い形: 走っている最中に速さを変える `frameRate(n)`。代入しても刻みは変わらず、変わったことを 1 度だけ警告する | [#2437] |
| `frameRate` | — (`1 / deltaTime`) | 持たない | 実時間の時計では `deltaTime` が前のフレームからの秒なので、`1 / deltaTime` が実測の速さになる。書き出しや `ClockMode.frames` では `deltaTime` が刻みどおりで一定。測った速さは観測が出す | — |
| `delay()` | `Thread.sleep(forTimeInterval:)` | 持たない | フレームを止めて待つだけの API。絵を止めたいなら `noLoop()`・`pauseTime()` を使う | — |
| `cursor()` | `cursor()` | 同等 | 隠したカーソルを作品の面の上でも見せる。無い形: 形を選ぶ `cursor(HAND)` と画像を渡す `cursor(img, x, y)` (作例が来るまで作らないと決めた) | [#2439] |
| `noCursor()` | `noCursor()` | 同等 | ウィンドウが前にあってポインタが作品の面の上にあるあいだ隠す。`cursor()` を呼ぶまで残る | [#2439] |
| `smooth()`・`noSmooth()` (2 件) | — | 作例待ち | 縁の滑らかさは経路ごとに違う (基本図形は解析的な被覆率、三角形の経路の縁には AA が無い — [ADR-0039](../decisions/0039-pixel-grid-and-edge-antialiasing.md) 決定 3)。切る対象が全経路か基本図形の被覆率だけかが割れ、段階を渡す `smooth(4)` の意味も決まっていない。縁を滑らかにする側 (4x MSAA) は実需を待つと決めてある | — |
| `focused` | — | 入れる | ウィンドウが前にあるかの真偽。ウィンドウが前から退いたときの扱い (押していたキーとボタンを離した扱いにする。[#2443]) は既にあり、状態は持っている。ウィンドウの無い実行・`SketchView` での答えは `Feature` が決める | [#3709] |
| `windowTitle()` | — (`SketchSettings.title` は起動のときだけ) | 入れる | 題名の変更は、`noCursor()` と同じく頼みを絵と一緒に道具のウィンドウへ渡せる。ウィンドウの無い実行では何も起きない | [#3709] |
| `windowMove()`・`windowMoved()` (2 件) | — | 作例待ち | 座標の原点と単位が割れる (Processing は主画面の左上からの画素。mokume のウィンドウは点で、ディスプレイは番号で選び、閉じたときの位置を覚えて戻す)。ウィンドウは道具やホストが持つ場面もある。画面を選ぶだけなら `fullScreen(_:)` で済む | — |
| `windowResize()`・`windowResized()`・`windowResizable()`・`windowRatio()` (4 件) | — | 作例待ち | Processing は描く面の大きさを変えるが、mokume の `width`・`height` は起動のときに決まり、ウィンドウの大きさは `windowScale` と手で広げた大きさで別に決まる。API を足すなら、ウィンドウだけを動かすのか描く面を替えるのか、広げたウィンドウの中でどう収めるかを先に決める | — |

## キーボード

6 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `key` | `key` | 同等 | `String`。文字を生むキーでだけ変わり、矢印・ファンクション・Escape・Delete では更新されない | [ADR-0034](../decisions/0034-input-surface-units.md) |
| `keyCode` | `keyCode` | 同等 | `Key?`。`keyCode == .arrowUp` と書く。押しても離しても入れ替わり、`keyReleased()` の中でも離したキーを指す。数との比較はコンパイルで止まる | [ADR-0034](../decisions/0034-input-surface-units.md) |
| `keyPressed` | — (キーごとは `keyboard.isPressed(_:)`) | 作例待ち | どれかのキーが押されているかを問う API が無い。Processing の変数 `keyPressed` は同じ名前の `keyPressed()` と並べて置けず採れない ([ADR-0020](../decisions/0020-api-naming-and-surface.md) 決定 1 の改訂 (2026-10-20)「API が無いだけで、要るなら `Feature`」)。名前は、`isMousePressed` を `mouse.` へ移す日の形と合わせて選ぶので割れる | — |
| `keyPressed()` | `keyPressed()` | 同等 | **押した 1 回だけ呼ばれ、押しっぱなしでも連射しない** (Processing は連射する。p5.js と同じ)。押している間は `draw()` で `keyboard.isPressed(_:)` を読む。修飾キーでは呼ばれない | [#2400]・[#2703] |
| `keyReleased()`・`keyTyped()` (2 件) | `keyReleased()`・`keyTyped()` | 同等 | `keyTyped()` は文字を生むキーだけで、キーリピートも届く。ウィンドウが前から退いたときは、押していたキーの数だけ `keyReleased()` が呼ばれる | [#2443] |

## マウス

12 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `mouseX`・`mouseY`・`pmouseX`・`pmouseY` (4 件) | `mouseX`・`mouseY`・`pmouseX`・`pmouseY` | 同等 | 単位は描く解像度の画素で、ウィンドウの大きさによらない。ウィンドウと縦横比が合わない帯の上では面の外の値になる (丸めない) | [ADR-0034](../decisions/0034-input-surface-units.md) |
| `mouseButton` | `mouseButton` | 同等 | `MouseButton?`。`mouseButton == .left` と書く。押しても離しても入れ替わる。数との比較はコンパイルで止まる | [#1555] |
| `mousePressed` | `isMousePressed` | 同等 | 変数 `mousePressed` は関数 `mousePressed()` と並べて置けない。p5.js の `mouseIsPressed` の語順にして `keyboard.isPressed` と合わせた。ボタンごとに数え、ウィンドウが前から退くと離した扱いになる | [ADR-0020](../decisions/0020-api-naming-and-surface.md) |
| `mousePressed()`・`mouseReleased()`・`mouseClicked()`・`mouseMoved()` (4 件) | `mousePressed()`・`mouseReleased()`・`mouseClicked()`・`mouseMoved()` | 同等 | 1 フレームに押して離しても両方呼ばれる。`mouseClicked()` は `mouseReleased()` の直後に続く。動いた量が要るなら `mouseMoved(deltaX:deltaY:)` | [#723]・[#2443] |
| `mouseDragged()` | `mouseDragged()` | 同等 | 引数なしでも呼ばれる (`mouseMoved()` と同じ)。動いた量が要るなら `mouseDragged(deltaX:deltaY:)`。中で `dragX` を読むと部分累計になる | [#3258]・[ADR-0034](../decisions/0034-input-surface-units.md) |
| `mouseWheel()` | `mouseWheel(deltaX:deltaY:)` | 同等 | 回した量は `event` ではなく引数で受ける。**引数なしの `func mouseWheel()` と書くと、通るが一度も呼ばれない。** 量は点で、慣性の続きも届く | [ADR-0034](../decisions/0034-input-surface-units.md) |

## 時刻

7 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `millis()` | `time` (秒)・`measure(_:_:)` | 持たない | 起動からの実時間を返す API は、描く値にも使えてしまい、書き出しやテストが使うフレーム番号から時刻を導く時計の下でも、実時間で動く絵を黙って作る。絵を動かすのは `time`、区間を測るのは `measure(_:_:)` | [#1554] |
| `year()`・`month()`・`day()`・`hour()`・`minute()`・`second()` (6 件) | — (`Calendar.current.dateComponents(_:from:)`) | 作例待ち | 現在の日時をどの時計から読むかが割れる。実時間で読めば `millis()` と同じく、`ClockMode.frames` の書き出しで同じ絵にならない ([ADR-0025](../decisions/0025-determinism-levels.md))。作者の時計 (`time`) から導く案もあり、その起点を何にするかを決める必要がある。時計の絵を書く作例が来たら選ぶ。それまでは Foundation で書ける (実時間なので、書き出しの再現は崩れる) | — |

## ファイルの入力

9 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `loadStrings()` | `loadStrings(_:)`・`requestStrings(_:)` | 同等 | UTF-8 を 1 行ずつの `[String]` にする。名前が `http://` か `https://` で始まれば URL から読む。読めなければ `DataFailure` を投げる。無い形: `File` や `InputStream` を渡す形 | [#2470] |
| `loadBytes()` | `loadBytes(_:)`・`requestBytes(_:)` | 同等 | ファイルか URL の中身をそのまま `[UInt8]` にする (Swift 標準の型。`Data` は面に出さない)。`loadStrings(_:)` と同じく、探す場所を `loadImage(_:)` と揃え (`assetURL(_:)`)、URL を受け、読めなければ `DataFailure` を投げる | [#3708] |
| `selectInput()` | `selectInput(_:)` | 同等 | コールバックの代わりに `async` で `String?` を返し、取り消せば `nil`。選べるのはファイル 1 つ | [#3062] |
| `selectFolder()` | — | 入れる | フォルダを選ばせる API が無い。仕組み (道具のウィンドウが出す・結果の入力の出来事 `fileSelected` の `paths`) は `selectInput(_:)` のものを使う。[ADR-0041](../decisions/0041-standard-scope-map.md) 決定 2 の「ファイルの受け渡し」が、同じ API の仲間として最低ラインに挙げている | [#3707]・[#3062] |
| `createInput()` | `loadBytes(_:)`・`FileHandle`・`InputStream` | 持たない | Java の `InputStream` を返す API。全体を読むなら `loadBytes`、少しずつなら Foundation の `FileHandle`・`InputStream` | — |
| `createReader()`・`BufferedReader`・`BufferedReader.readLine()` (3 件) | `loadStrings(_:)` | 持たない | 行を 1 つずつ読む Java の `BufferedReader`。ファイルを 1 行ずつ回すなら `loadStrings(_:)` の結果を回せる。大きすぎて全体を持てないファイルは Foundation の `FileHandle` | — |
| `launch()` | `NSWorkspace.shared.open(_:)`・`Process` | 持たない | 外のアプリやファイルを OS の標準の起動機能で開く。受け手の上に API を持たず、AppKit の `NSWorkspace.shared.open(_:)` で同じことができる (`exec()` に当たるのは Foundation の `Process`) | — |

## ファイルの出力

15 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `saveStrings()` | `saveStrings(_:_:)` | 同等 | UTF-8・行末 LF で書き、書きかけを残さない。**引数は `saveStrings(lines, path)` で、Processing の `saveStrings(filename, data)` と逆** (p5.js と同じ順。型が違うのでコンパイルで止まる) | [#2468]・[ADR-0020](../decisions/0020-api-naming-and-surface.md) |
| `saveBytes()` | `saveBytes(_:_:)` | 同等 | `[UInt8]` をそのままファイルに書く。`saveStrings(_:_:)` と同じく、途中のディレクトリを作り、書きかけを残さず、書けなければ `DataFailure` を投げる。**引数は `saveBytes(bytes, path)` で、Processing の `saveBytes(filename, data)` と逆** (`saveStrings(_:_:)` と同じ順。型が違うのでコンパイルで止まる) | [#3708] |
| `selectOutput()` | — | 入れる | 保存先を選ばせる API が無い。#3062 が「入れない」と決めて、この表に区分を預けた。仕組みは `selectInput(_:)` のものを使い、結果は `fileSelected` の `paths` で届く | [#3707]・[#3062] |
| `createOutput()` | `saveBytes(_:_:)`・`FileHandle`・`OutputStream` | 持たない | Java の `OutputStream` を返す API。全体を書くなら `saveBytes`、少しずつなら Foundation の `FileHandle`・`OutputStream` | — |
| `createWriter()`・`PrintWriter`・`PrintWriter.print()`・`println()`・`flush()`・`close()` (6 件) | `saveStrings(_:_:)`・`FileHandle` | 持たない | 行を 1 つずつ書き足す Java の `PrintWriter`。ためておいた `[String]` を `saveStrings(_:_:)` で書ける。追記し続けるログは Foundation の `FileHandle` | — |
| `saveStream()` | `loadBytes(_:)` と `saveBytes(_:_:)` | 持たない | `saveBytes(loadBytes(...))` を効率よく書く API、と参照自身が書く。URL を受ける `loadBytes` と組めば、ダウンロードしてファイルにできる | — |
| `beginRecord()`・`endRecord()` (2 件) | `save("plot.svg")` (SVG の 1 フレーム)。同じ名前の `beginRecord(_:)`・`endRecord()` は画素の動画か連番で、意味が違う | 持たない | **ベクター書き出し**。Processing は描く命令を PDF か SVG の描き手へ流し、呼んでから止めるまでを 1 つのファイルにする。**この形 (API の層で別の描き先へ流す) は [ADR-0023](../decisions/0023-frame-stages-and-outputs.md) の改訂 (2026-10-23) が採らないと決めた**。SVG は拡張子で振り分ける `save("plot.svg")` が書く (呼んだ時点から `draw()` の終わりまで。字・画像・保持した形・立体・効果は書かず、種類と数を 1 度知らせる)。PDF は作例が来たときに別の `Feature` で足す (同改訂)。複数のフレームにまたがって 1 枚に束ねる API も無い。手本の 2 つの引数を渡すとコンパイルで止まる | [#1967]・[#3471]・PR [#3139] |
| `beginRaw()`・`endRaw()` (2 件) | `save("plot.svg")` | 持たない | **3D の頂点を PDF・DXF などへ流す API**で、上の行と同じく API の層で別の描き先へ流す形は採らない ([ADR-0023](../decisions/0023-frame-stages-and-outputs.md))。立体は SVG に書かない (種類と数を知らせる)。DXF は、投影した 2D の線を先に書き、3D の線と面は作例が来てから別の `Feature` で足す (同改訂) | [#1967]・[#3471] |

## 画像の書き出し

2 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `save()` | `save(_:)` | 同等 | 形式は PNG で、色空間は作業空間と同じ Display P3。**透けたところは透けたまま残る** (Processing は不透明に書く)。名前が `.svg` で終わるときだけ、絵でなく線を書く ([ADR-0023](../decisions/0023-frame-stages-and-outputs.md))。呼んだ時点では予約するだけで、書き込みはフレームの外で走る。無い形: TIFF・TARGA・JPEG、拡張子を省いた名前。**名前が `.png`・`.svg` (大文字小文字を区別しない) で終わらなければ、PNG で書いたうえで 1 度だけ知らせる** (`draw()` の中で毎フレーム止めないよう、投げない・[#3723]) | [#3139]・[#3723] |
| `saveFrame()` | `beginRecord("out/f-####.png")` … `endRecord()`。1 枚なら `save("f-\(frameCount).png")` | 同等 | 連番は 2 つの API で挟む。**`####` は `frameCount` ではなく、録りの中の通し番号 (0 から)**。名前が `.mov` で終われば 1 本の動画になる。連番の名前が `.png` で終わらなければ (`f-####.jpg`)、PNG で書いたうえで 1 度だけ知らせる ([#3723])。無い形: 引数なしの `saveFrame()` (既定の名前 `screen-####.tif`)、`####` に `frameCount` を入れる書き方 | [#2437] |

## 文字の出力

3 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `print()`・`println()`・`printArray()` (3 件) | Swift の `print(_:)`・`print(_:terminator:)` | 持たない | Swift の標準ライブラリが同じことをする。`println()` は `print(_:)`、`print()` は `terminator: ""` を渡す形、`printArray()` は配列を渡す `print(array)` | — |

[#723]: https://github.com/mokume-metal/mokume/issues/723
[#1554]: https://github.com/mokume-metal/mokume/issues/1554
[#1555]: https://github.com/mokume-metal/mokume/issues/1555
[#1967]: https://github.com/mokume-metal/mokume/issues/1967
[#2020]: https://github.com/mokume-metal/mokume/issues/2020
[#2400]: https://github.com/mokume-metal/mokume/issues/2400
[#2437]: https://github.com/mokume-metal/mokume/issues/2437
[#2439]: https://github.com/mokume-metal/mokume/issues/2439
[#2443]: https://github.com/mokume-metal/mokume/issues/2443
[#2468]: https://github.com/mokume-metal/mokume/issues/2468
[#2470]: https://github.com/mokume-metal/mokume/issues/2470
[#2703]: https://github.com/mokume-metal/mokume/issues/2703
[#3062]: https://github.com/mokume-metal/mokume/issues/3062
[#3139]: https://github.com/mokume-metal/mokume/issues/3139
[#3258]: https://github.com/mokume-metal/mokume/issues/3258
[#3471]: https://github.com/mokume-metal/mokume/issues/3471
[#3707]: https://github.com/mokume-metal/mokume/issues/3707
[#3708]: https://github.com/mokume-metal/mokume/issues/3708
[#3709]: https://github.com/mokume-metal/mokume/issues/3709
[#3723]: https://github.com/mokume-metal/mokume/issues/3723
