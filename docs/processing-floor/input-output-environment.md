<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# 入力・出力・環境

Processing 本体のリファレンスのうち、マウス・キー・時刻・ファイル・書き出し・ウィンドウにあたる 81 件。category が `environment` (27)・`input` (40)・`output` (20) の項目と、所属が `BufferedReader`・`PrintWriter` のメソッド (5) から、[データ: JSON・Table・XML](data-json-table-xml.md) が数えた `load`・`parse`・`save` の 11 件 (`loadJSONArray()` ほか) を除いたもの。表の形式・バージョン・数え直す式は [README](README.md) にある。照合したのは processing-website `f4acef8` (2026-10-29) と mokume の main `fe258089` (2026-11-02)。

| 区分 | 件数 |
| --- | --- |
| 同等 | 41 |
| 入れる | 0 |
| 作例待ち | 15 |
| 持たない | 25 |
| 計 | 81 |

この領域に共通すること:

- **ウィンドウを持つのが、スケッチを実行するプロセスとは限らない。** 直接実行した場合 (`mokume run`・バンドルした `.app`) はそのプロセスがウィンドウを持つが、`mokume watch` では監視するツール側がウィンドウを持ち、`SketchView` ではホストアプリが持ち、`mokume render` ではウィンドウが無い。ウィンドウを操作する API (`noCursor()`・`selectInput()`・`windowTitle()`) は、要求を描画結果と一緒に監視するツール側のウィンドウへ渡し、ウィンドウの無い実行では何も起きない。ウィンドウの API を足すときは、この 4 つの場面を行ごとに書く
- **描画サイズとウィンドウのサイズは別の数である。** `width`・`height` は起動時に決まり、ウィンドウを広げても変わらない ([ADR-0015](../decisions/0015-metalfx-role.md))。Processing の `windowResize()` はキャンバスの大きさを変えるので、API の意味がそのままでは対応づけられない
- **設定は関数として呼ばず、`settings` の値として返す。** `size()`・`frameRate()`・`fullScreen()` は、起動時に読む `Sketch.settings` の値にする
- **コールバックは、押した 1 回・離した 1 回・動いた 1 件ごとに呼ばれる。** `mouseDragged()` ほかの API ごとの違いは下の行に書く。`func mouseWheel()` のように引数を省くと、コンパイルは通るが一度も呼ばれない API がある (`mouseWheel(deltaX:deltaY:)`・`fileDropped(_:)`)
- **キーとボタンは数値ではなく型で指定する** ([ADR-0034](../decisions/0034-input-surface-units.md) 決定 1)。`keyCode == UP` は `keyCode == .arrowUp`、`mouseButton == LEFT` は `mouseButton == .left`
- **読めない・書けないときは投げる。** Processing は `null` を返す。mokume は `DataFailure` を投げ、`setup() throws` の `try` か `try?` で受ける

## 「入れる」の API をまとめた Feature

「入れる」の 6 件は、近い API ごとに 3 つの `Feature` で入れる。

| Feature | API | 件数 |
| --- | --- | --- |
| [#3707] 保存先とフォルダを選ばせる | `selectOutput()`・`selectFolder()` | 2 |
| [#3708] バイト列を読み書きする | `loadBytes()`・`saveBytes()` | 2 |
| [#3709] ウィンドウの題名を変え、ウィンドウが前にあるかを読む | `windowTitle()`・`focused` | 2 |

## 環境

27 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `size()` | `SketchSettings.size(_:_:frameRate:title:)`・`SketchSettings(width:height:)` | 同等 | `settings` で返す。1 画素がウィンドウ上の何ポイントに当たるかは `windowScale` (既定 0.5) で、Processing のように 1 画素 = 1 ポイントではない。無い形: レンダラーの指定 (`size(w, h, P3D)`。2D も 3D も同じキャンバスに描く) | [#2437] |
| `fullScreen()` | `SketchSettings.fullScreen(_:)` | 同等 | 番号でディスプレイを選び、省略すれば 1 (メニューバーのあるディスプレイ)。選んだディスプレイが無ければ別のディスプレイに出さず、起動時に拒否する。無い形: レンダラーの指定、複数のディスプレイにまたがる `SPAN` (マッピングの仕事) | [#2020]・[#2437] |
| `settings()` | `Sketch.settings` | 同等 | `settings` を返す計算プロパティにする。Processing が `settings()` の中でだけ変数を使えるのと同じく、`displays` など、`settings` の中から読める値で書く | [#2437] |
| `width`・`height` (2 件) | `width`・`height` | 同等 | `Float` (座標の単位)。画素密度 (`pixelDensity`) と書き出し倍率を変えても変わらない。スケッチの実行前に読むと 0 を返して 1 度だけ警告する | — |
| `pixelWidth`・`pixelHeight` (2 件) | `pixelWidth`・`pixelHeight` | 同等 | 実際にレンダリングしている画素数。画素密度が 1 で書き出し倍率が無ければ `width` と同じ。`pixels` の添字の範囲はこちらの数 | — |
| `pixelDensity()` | `SketchSettings.pixelDensity` | 持たない | **同じ名前で意味が逆**。Processing は 2 で細かく描くが、mokume は 0 より大きく 1 以下で粗く描いて拡大し、1 を超える指定は設定の組み立て時に拒否する ([ADR-0015](../decisions/0015-metalfx-role.md) が退けた案)。そのまま移した `pixelDensity(2)` は、型は通っても意味が違う。高解像度のディスプレイに鮮明に出すには、全画面表示が `Display.width` (画素) で描くので足りる | [ADR-0015](../decisions/0015-metalfx-role.md) |
| `displayDensity()` | — (`displays` の `width`・`height` が画素で返る) | 持たない | 主な使い道の `pixelDensity(displayDensity())` に当たる API が無い (上の行)。`Display.width` はポイント数に画素密度を掛けた画素数で返るので、密度を自分で掛ける場面が無い | — |
| `displayWidth`・`displayHeight` (2 件) | `displays.first?.width`・`displays.first?.height` | 同等 | メニューバーのあるディスプレイの、全画面表示にしたときの描画サイズ (画素)。Retina ではポイント数の 2 倍で、ノッチのあるディスプレイではその帯の分だけ低い。ディスプレイの無い実行では `displays` が空になる | [#2020] |
| `frameCount` | `frameCount` | 同等 | 最初の `draw()` の最中は 1 (Processing と同じ) | — |
| `frameRate()` | `SketchSettings.frameRate` | 同等 | 起動時に読み、1 以上。無い形: 実行中にフレームレートを変える `frameRate(n)`。代入してもフレームの間隔は変わらず、変更しようとしたことを 1 度だけ警告する | [#2437] |
| `frameRate` | — (`1 / deltaTime`) | 持たない | 実時間の時計では `deltaTime` が前のフレームからの秒数なので、`1 / deltaTime` が実測のフレームレートになる。書き出しや `ClockMode.frames` では `deltaTime` が設定したフレーム間隔のとおりで一定。測定したフレームレートは観測 (observe) が返す | — |
| `delay()` | `Thread.sleep(forTimeInterval:)` | 持たない | フレームの処理を止めて待つだけの API。絵を止めたいなら `noLoop()`・`pauseTime()` を使う | — |
| `cursor()` | `cursor()` | 同等 | 非表示にしたカーソルを、スケッチのキャンバスの上でも再び表示する。無い形: カーソルの形を選ぶ `cursor(HAND)` と画像を渡す `cursor(img, x, y)` (作例が来るまで作らないと決めた) | [#2439] |
| `noCursor()` | `noCursor()` | 同等 | ウィンドウが最前面にあり、ポインタがスケッチのキャンバスの上にあるあいだ非表示にする。`cursor()` を呼ぶまで続く | [#2439] |
| `smooth()`・`noSmooth()` (2 件) | — | 作例待ち | エッジのアンチエイリアスは描画経路ごとに違う (基本図形は解析的なカバレッジ、三角形の経路のエッジには AA が無い — [ADR-0039](../decisions/0039-pixel-grid-and-edge-antialiasing.md) 決定 3)。オフにする対象が全経路か基本図形のカバレッジだけかで選択が分かれ、段階を渡す `smooth(4)` の意味も決まっていない。エッジを滑らかにする側 (4x MSAA) は、実際に必要になるまで待つと決めてある | — |
| `focused` | `focused` | 同等 | ウィンドウが前面にある (キーウィンドウである) かの真偽値。前面から外れると、ウィンドウで押していたキーとボタンを離した扱いにし、その呼び出しの中からも `false` で読める ([#2443])。外部から注入した押下 (入力用のファイル・MCP 経由) は離さず、注入した側が解放して離れる (`false` の間も押されたままでありうる)。場面ごとの値: 直接実行した場合はそのウィンドウ、`mokume watch` では監視するツール側のウィンドウ (キーウィンドウの出入りを入力イベント `focusChanged` でスケッチのプロセスへ伝える)、`SketchView` はビューを載せたウィンドウ (載っていない間は `true`)、ウィンドウの無い実行と実行中でないときは `true`。Processing と違い、初めて前面に出るまで `false` にはしない (`if !focused { noLoop() }` が書き出しを止めない) | [#3709] |
| `windowTitle()` | `windowTitle(_:)` | 同等 | 実行中にウィンドウのタイトルを変える (起動時のタイトルは `SketchSettings.title`)。`noCursor()` と同じく、`mokume watch` では要求を描画結果と一緒に、監視するツール側のスケッチのウィンドウへ渡す (プレビューは変えない)。`SketchView` では何もせず 1 度だけ警告する (タイトルはホストアプリのもの)。ウィンドウの無い実行では何も起きない | [#3709] |
| `windowMove()`・`windowMoved()` (2 件) | — | 作例待ち | 座標の原点と単位の選択が分かれる (Processing はメインディスプレイの左上からの画素。mokume のウィンドウはポイントで、ディスプレイは番号で選び、閉じたときの位置を記憶して復元する)。ウィンドウを監視するツールやホストアプリが持つ場面もある。ディスプレイを選ぶだけなら `fullScreen(_:)` で済む | — |
| `windowResize()`・`windowResized()`・`windowResizable()`・`windowRatio()` (4 件) | — | 作例待ち | Processing はキャンバスの大きさを変えるが、mokume の `width`・`height` は起動時に決まり、ウィンドウの大きさは `windowScale` と、利用者が手で広げた大きさで別に決まる。API を足すなら、ウィンドウだけを変更するのかキャンバスを作り直すのか、広げたウィンドウの中での表示の収め方を先に決める | — |

## キーボード

6 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `key` | `key` | 同等 | `String`。文字を入力するキーでだけ変わり、矢印・ファンクション・Escape・Delete では更新されない | [ADR-0034](../decisions/0034-input-surface-units.md) |
| `keyCode` | `keyCode` | 同等 | `Key?`。`keyCode == .arrowUp` と書く。押しても離しても更新され、`keyReleased()` の中でも離したキーを指す。数値との比較はコンパイルエラーになる | [ADR-0034](../decisions/0034-input-surface-units.md) |
| `keyPressed` | — (キーごとは `keyboard.isPressed(_:)`) | 作例待ち | どれかのキーが押されているかを問う API が無い。Processing の変数 `keyPressed` は同じ名前の `keyPressed()` と同じスコープに定義できず採用できない ([ADR-0020](../decisions/0020-api-naming-and-surface.md) 決定 1 の改訂 (2026-10-20)「API が無いだけで、要るなら `Feature`」)。名前は、`isMousePressed` を `mouse.` へ移すときの形と合わせて選ぶ必要があり、まだ決まっていない | — |
| `keyPressed()` | `keyPressed()` | 同等 | **押した 1 回だけ呼ばれ、押しっぱなしでもキーリピートで繰り返し呼ばれない** (Processing は繰り返し呼ばれる。p5.js と同じ)。押している間は `draw()` で `keyboard.isPressed(_:)` を読む。修飾キーでは呼ばれない | [#2400]・[#2703] |
| `keyReleased()`・`keyTyped()` (2 件) | `keyReleased()`・`keyTyped()` | 同等 | `keyTyped()` は文字を入力するキーだけで、キーリピートも届く。ウィンドウが前面から外れたときは、押していたキーの数だけ `keyReleased()` が呼ばれる | [#2443] |

## マウス

12 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `mouseX`・`mouseY`・`pmouseX`・`pmouseY` (4 件) | `mouseX`・`mouseY`・`pmouseX`・`pmouseY` | 同等 | 単位は描画解像度の画素で、ウィンドウの大きさによらない。ウィンドウと縦横比が合わずに余白 (帯) ができる部分の上では、キャンバスの外の値になる (範囲内に収めない) | [ADR-0034](../decisions/0034-input-surface-units.md) |
| `mouseButton` | `mouseButton` | 同等 | `MouseButton?`。`mouseButton == .left` と書く。押しても離しても入れ替わる。数値との比較はコンパイルエラーになる | [#1555] |
| `mousePressed` | `isMousePressed` | 同等 | 変数 `mousePressed` は関数 `mousePressed()` と同じスコープに定義できない。p5.js の `mouseIsPressed` の語順に合わせ、`keyboard.isPressed` とも揃えた。ボタンごとに数え、ウィンドウが前面から外れると離した扱いになる | [ADR-0020](../decisions/0020-api-naming-and-surface.md) |
| `mousePressed()`・`mouseReleased()`・`mouseClicked()`・`mouseMoved()` (4 件) | `mousePressed()`・`mouseReleased()`・`mouseClicked()`・`mouseMoved()` | 同等 | 1 フレームに押して離しても両方呼ばれる。`mouseClicked()` は `mouseReleased()` の直後に呼ばれる。移動量が必要なら `mouseMoved(deltaX:deltaY:)` | [#723]・[#2443] |
| `mouseDragged()` | `mouseDragged()` | 同等 | 引数なしでも呼ばれる (`mouseMoved()` と同じ)。移動量が必要なら `mouseDragged(deltaX:deltaY:)`。中で `dragX` を読むと、その時点までの累計になる | [#3258]・[ADR-0034](../decisions/0034-input-surface-units.md) |
| `mouseWheel()` | `mouseWheel(deltaX:deltaY:)` | 同等 | 回転量は `event` ではなく引数で受ける。**引数なしの `func mouseWheel()` と書くと、コンパイルは通るが一度も呼ばれない。** 量はポイントで、慣性スクロールの続きも届く | [ADR-0034](../decisions/0034-input-surface-units.md) |

## 時刻

7 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `millis()` | `time` (秒)・`measure(_:_:)` | 持たない | 起動からの実時間を返す API は、描画の値にも使えてしまい、書き出しやテストが使う、フレーム番号から時刻を求める時計のもとでも、実時間で動く絵を警告なしに作ってしまう。絵を動かすには `time`、区間の時間を測るには `measure(_:_:)` を使う | [#1554] |
| `year()`・`month()`・`day()`・`hour()`・`minute()`・`second()` (6 件) | — (`Calendar.current.dateComponents(_:from:)`) | 作例待ち | 現在の日時をどの時計から読むかの選択が分かれる。実時間で読めば `millis()` と同じく、`ClockMode.frames` の書き出しで毎回同じ絵にならない ([ADR-0025](../decisions/0025-determinism-levels.md))。スケッチの時計 (`time`) から求める案もあり、その起点を何にするかを決める必要がある。時計を描く作例が来たら選ぶ。それまでは Foundation で書ける (実時間なので、書き出しの再現性は失われる) | — |

## ファイルの入力

9 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `loadStrings()` | `loadStrings(_:)`・`requestStrings(_:)` | 同等 | UTF-8 を 1 行ずつの `[String]` にする。名前が `http://` か `https://` で始まれば URL から読む。読めなければ `DataFailure` を投げる。無い形: `File` や `InputStream` を渡す形 | [#2470] |
| `loadBytes()` | `loadBytes(_:)`・`requestBytes(_:)` | 同等 | ファイルか URL の中身をそのまま `[UInt8]` にする (Swift 標準の型。`Data` は公開 API に出さない)。`loadStrings(_:)` と同じく、ファイルを探す場所を `loadImage(_:)` と揃え (`assetURL(_:)`)、URL も受け付け、読めなければ `DataFailure` を投げる | [#3708] |
| `selectInput()` | `selectInput(_:)` | 同等 | コールバックの代わりに `async` で `String?` を返し、キャンセルすれば `nil`。選べるのはファイル 1 つ | [#3062] |
| `selectFolder()` | `selectFolder(_:)` | 同等 | コールバックの代わりに `async` でフォルダの絶対パスの `String?` を返し、キャンセルすれば `nil`。仕組み (ウィンドウを持つ側がダイアログを出し、結果は入力イベント `fileSelected` の `paths` で届く) と、1 度に 1 つの待ちしか持てない制約を `selectInput(_:)`・`selectOutput(_:)` と共有し、後から要求した方が前の要求を `nil` で終了させる | [#3707]・[#3062] |
| `createInput()` | `loadBytes(_:)`・`FileHandle`・`InputStream` | 持たない | Java の `InputStream` を返す API。全体を読むなら `loadBytes`、少しずつなら Foundation の `FileHandle`・`InputStream` | — |
| `createReader()`・`BufferedReader`・`BufferedReader.readLine()` (3 件) | `loadStrings(_:)` | 持たない | 行を 1 つずつ読む Java の `BufferedReader`。ファイルを 1 行ずつ処理するなら `loadStrings(_:)` の結果を繰り返せばよい。大きすぎて全体をメモリに載せられないファイルは Foundation の `FileHandle` | — |
| `launch()` | `NSWorkspace.shared.open(_:)`・`Process` | 持たない | 他のアプリやファイルを OS の標準の機能で開く。スケッチのメソッドとしては持たず、AppKit の `NSWorkspace.shared.open(_:)` で同じことができる (`exec()` に当たるのは Foundation の `Process`) | — |

## ファイルの出力

15 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `saveStrings()` | `saveStrings(_:_:)` | 同等 | UTF-8・行末 LF で書き、書き込み途中のファイルを残さない。**引数は `saveStrings(lines, path)` で、Processing の `saveStrings(filename, data)` と逆** (p5.js と同じ順。型が違うのでコンパイルエラーになる) | [#2468]・[ADR-0020](../decisions/0020-api-naming-and-surface.md) |
| `saveBytes()` | `saveBytes(_:_:)` | 同等 | `[UInt8]` をそのままファイルに書く。`saveStrings(_:_:)` と同じく、途中のディレクトリも作成し、書き込み途中のファイルを残さず、書けなければ `DataFailure` を投げる。**引数は `saveBytes(bytes, path)` で、Processing の `saveBytes(filename, data)` と逆** (`saveStrings(_:_:)` と同じ順。型が違うのでコンパイルエラーになる) | [#3708] |
| `selectOutput()` | `selectOutput(_:)` | 同等 | コールバックの代わりに `async` で保存先の絶対パスの `String?` を返し、キャンセルすれば `nil`。まだ存在しないファイル名も選べ、書き込むのはスケッチ (`saveStrings(_:_:)` など)。仕組みと 1 度に 1 つの待ちを `selectInput(_:)`・`selectFolder(_:)` と共有する | [#3707]・[#3062] |
| `createOutput()` | `saveBytes(_:_:)`・`FileHandle`・`OutputStream` | 持たない | Java の `OutputStream` を返す API。全体を書くなら `saveBytes`、少しずつなら Foundation の `FileHandle`・`OutputStream` | — |
| `createWriter()`・`PrintWriter`・`PrintWriter.print()`・`println()`・`flush()`・`close()` (6 件) | `saveStrings(_:_:)`・`FileHandle` | 持たない | 行を 1 つずつ書き足す Java の `PrintWriter`。ためておいた `[String]` を `saveStrings(_:_:)` で書ける。追記し続けるログは Foundation の `FileHandle` | — |
| `saveStream()` | `loadBytes(_:)` と `saveBytes(_:_:)` | 持たない | `saveBytes(loadBytes(...))` を効率よく書く API、とリファレンス自身が書いている。URL を受け付ける `loadBytes` と組み合わせれば、ダウンロードしてファイルにできる | — |
| `beginRecord()`・`endRecord()` (2 件) | `save("plot.svg")` (SVG の 1 フレーム)。同じ名前の `beginRecord(_:)`・`endRecord()` は画素の動画か連番で、意味が違う | 持たない | **ベクター書き出し**。Processing は描画命令を PDF か SVG のレンダラーへ流し、呼んでから止めるまでを 1 つのファイルにする。**この形 (API の層で別の描画先へ流す) は [ADR-0023](../decisions/0023-frame-stages-and-outputs.md) の改訂 (2026-10-23) が採らないと決めた**。SVG は拡張子で振り分ける `save("plot.svg")` が書く (呼んだ時点から `draw()` の終わりまで。文字・画像・保持された図形・立体・効果は書き出さず、種類と数を 1 度警告する)。PDF は作例が来たときに別の `Feature` で足す (同改訂)。複数のフレームにまたがって 1 枚にまとめる API も無い。Processing の 2 つの引数を渡すとコンパイルエラーになる | [#1967]・[#3471]・PR [#3139] |
| `beginRaw()`・`endRaw()` (2 件) | `save("plot.svg")` | 持たない | **3D の頂点を PDF・DXF などへ流す API**で、上の行と同じく API の層で別の描画先へ流す形は採らない ([ADR-0023](../decisions/0023-frame-stages-and-outputs.md))。立体は SVG に書き出さない (種類と数を警告する)。DXF は、投影した 2D の線を先に書き、3D の線と面は作例が来てから別の `Feature` で足す (同改訂) | [#1967]・[#3471] |

## 画像の書き出し

2 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `save()` | `save(_:)` | 同等 | 形式は PNG で、色空間は作業色空間と同じ Display P3。**透明な部分は透明のまま残る** (Processing は不透明にして書く)。名前が `.svg` で終わるときだけ、ビットマップではなくベクター (線) を書き出す ([ADR-0023](../decisions/0023-frame-stages-and-outputs.md))。呼んだ時点では予約するだけで、書き込みはフレームの外で実行される。無い形: TIFF・TARGA・JPEG、拡張子を省いた名前。**名前が `.png`・`.svg` (大文字小文字を区別しない) で終わらなければ、PNG で書いたうえで 1 度だけ警告する** (毎フレーム呼ぶ `draw()` の中で止まらないよう、投げない・[#3723]) | [#3139]・[#3723] |
| `saveFrame()` | `beginRecord("out/f-####.png")` … `endRecord()`。1 枚なら `save("f-\(frameCount).png")` | 同等 | 連番は 2 つの API で囲む。**`####` は `frameCount` ではなく、記録中の通し番号 (0 から)**。名前が `.mov` で終われば 1 本の動画になる。連番の名前が `.png` で終わらなければ (`f-####.jpg`)、PNG で書いたうえで 1 度だけ警告する ([#3723])。無い形: 引数なしの `saveFrame()` (既定の名前 `screen-####.tif`)、`####` に `frameCount` を入れる書き方 | [#2437] |

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
