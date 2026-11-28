<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# 構造・制御

Processing 本体のリファレンスのうち、構造 (structure)・制御 (control)・演算子の 76 件。内訳は、演算子 24 件 (算術・代入 11、ビット 4、比較 6、論理 3)、制御構文 10 件 (条件 8、繰り返し 2)、言語の構文 28 件 (コメント・記号・型・修飾ほか)、スケッチの進行・状態の退避・ウィンドウの API 14 件。表の形式・バージョン・数え直す式は [README](README.md) にある。照合したのは processing-website `f4acef8` (2026-10-29) と mokume の main `5b60ed75` (2026-11-24)。

| 区分 | 件数 |
| --- | --- |
| 同等 | 10 |
| 入れる | 0 |
| 作例待ち | 3 |
| 持たない | 63 |
| 計 | 76 |

この領域に共通すること:

- **言語の構文 (演算子・`if`・`for`・`class` ほか) は「持たない」にまとめ、理由の欄に Swift での書き方を書く** ([#3133] の決定 Q2・README「行の単位とまとめ方」)。62 件がこれに当たる (ほかに `thread()` が Swift の並行処理に当たる持たない 1 件)。mokume のスケッチは Swift で書くので、言語そのものは Swift が答える。Processing と同じ綴りで通るものも、綴りが違うものも、同じ区分にまとめた
- **演算子の 15 件 (category が `math` で subcategory が `Operators` 11・`Bitwise Operators` 4) は、この表で数える。** 数学・PVector・定数の表 ([#4176]) は数えない。演算子 24 件は、この 15 件と、category が `Control` の比較・論理の演算子 9 件を合わせた数
- **数の型を混ぜられない** ([ADR-0035](../decisions/0035-numeric-reception.md))。`Int` と `Float` を 1 つの式で混ぜると、Swift では型が合わず通らない (`i * width` は `Float(i) * width`)。Processing は混ぜた式を `float` へ寄せるので、この点は違う。mokume の API は `Int`・`Float`・`Double` をそのまま受ける
- **Swift の整数どうしの割り算は切り捨てる。** `1 / 2` は 0 で、Processing の `int` どうしの割り算と同じ。小数が要るなら `Float` へ直してから割る
- **スケッチの進行の API は `Sketch` のプロトコルの要求か `SketchPart` のメソッドで、`setup()`・`draw()`・入力のコールバックの中から呼ぶ。** それ以外 (`Task` の中や `init()` の中) からは、何もせず報告する

## 演算子

24 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `+ (addition)`・`- (minus)`・`* (multiply)`・`/ (divide)` (4 件) | — (Swift の `+`・`-`・`*`・`/`) | 持たない | Swift の演算子で、綴りは同じ。数の型を混ぜられない (上)。`Vector2`・`Vector3` にも `+`・`-`・`*`・`/` がある ([#4176] の表の `PVector.add()` ほか) | — |
| `% (modulo)` | — (Swift の `%`・`truncatingRemainder(dividingBy:)`・`mod(_:_:)`) | 持たない | `%` は整数だけで、`Float` には `truncatingRemainder(dividingBy:)` と書く (Processing の `%` は `float` にも使える)。負の数には負を返す点は Processing と同じ。0 以上に巡らせる剰余は `mod(_:_:)` ([#4176] の表) | [#2416] |
| `+= (add assign)`・`-= (subtract assign)`・`*= (multiply assign)`・`/= (divide assign)` (4 件) | — (Swift の `+=`・`-=`・`*=`・`/=`) | 持たない | Swift の演算子で、綴りは同じ | — |
| `++ (increment)`・`-- (decrement)` (2 件) | — (Swift の `x += 1`・`x -= 1`) | 持たない | Swift に `++`・`--` は無い。`x += 1`・`x -= 1` と書く | — |
| `& (bitwise AND)`・`\| (bitwise OR)`・`<< (left shift)`・`>> (right shift)` (4 件) | — (Swift の `&`・`\|`・`<<`・`>>`) | 持たない | Swift の演算子で、綴りは同じ。整数だけ。Processing の `^`・`~` はリファレンスに載らない | — |
| `== (equality)`・`!= (inequality)`・`< (less than)`・`<= (less than or equal to)`・`> (greater than)`・`>= (greater than or equal to)` (6 件) | — (Swift の `==`・`!=`・`<`・`<=`・`>`・`>=`) | 持たない | Swift の演算子で、綴りは同じ。型が違う値は比べられない (`Int` と `Float` は `Float(i)` で合わせる)。文字列の比較は `==` で値を比べる | — |
| `&& (logical AND)`・`\|\| (logical OR)`・`! (logical NOT)` (3 件) | — (Swift の `&&`・`\|\|`・`!`) | 持たない | Swift の演算子で、綴りは同じ。条件には `Bool` だけを置け、数や `nil` は置けない | — |

## 制御構文

10 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `if`・`else` (2 件) | — (Swift の `if`・`else`) | 持たない | 条件は丸括弧で囲まずに書ける。`Bool` だけを受ける | — |
| `?: (conditional)` | — (Swift の `?:`) | 持たない | Swift の三項演算子で、綴りは同じ | — |
| `switch`・`case`・`default` (3 件) | — (Swift の `switch`・`case`・`default`) | 持たない | 落ち込まず (各 `case` の終わりに `break` は要らない)、すべての値を覆う必要がある。続けるなら `fallthrough`。文字列・列挙・範囲も `case` に置ける | — |
| `break`・`continue` (2 件) | — (Swift の `break`・`continue`) | 持たない | Swift の文で、綴りは同じ。外側のループへ飛ぶには、ループに名前を付けて `break outer` と書く | — |
| `for`・`while` (2 件) | — (Swift の `for … in`・`while`) | 持たない | `for (int i = 0; i < n; i++)` の形は無く、`for i in 0..<n` と書く。`Float` で刻むなら `stride(from:to:by:)` ([ADR-0035](../decisions/0035-numeric-reception.md)) | — |

## 構文

28 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `// (comment)`・`/* */ (multiline comment)`・`/** */ (doc comment)` (3 件) | — (Swift の `//`・`/* */`・`/** */`・`///`) | 持たない | Swift のコメントで、綴りは同じ。`/* */` は入れ子にできる | — |
| `{} (curly braces)`・`() (parentheses)`・`; (semicolon)`・`, (comma)`・`. (dot)` (5 件) | — (Swift の記号) | 持たない | 綴りは同じ。文の終わりの `;` は要らない (1 行に 2 文を書くときだけ) | — |
| `= (assign)`・`[] (array access)` (2 件) | — (Swift の `=`・`[]`) | 持たない | `=` は式ではなく文で、`if (a = b)` のような書き方は通らない。添字は `Int` で、範囲の外は実行時に止まる (配列の領域の表 ([#4179]) で扱う) | — |
| `class`・`extends`・`implements`・`super`・`this`・`new` (6 件) | — (Swift の `class`・`struct`・`: 親`・プロトコルへの準拠・`super`・`self`) | 持たない | `extends`・`implements` は `class A: B, P` と並べて書く。`this` は `self` で、メンバーの前では省ける。`new` は要らず、`Foo()` と書く。値の型 (`struct`) もある | — |
| `static`・`final`・`public`・`private` (4 件) | — (Swift の `static`・`final`・`public`・`private`) | 持たない | 綴りは同じ。何も書かないときは `internal` (同じモジュールの中だけ)。定数は `let` と書く | — |
| `void`・`return` (2 件) | — (戻り値の型の省略・Swift の `return`) | 持たない | 戻り値が無い関数は型を書かない (`func f() { }`)。`return` は同じ綴り | — |
| `null` | — (Swift の `nil`) | 持たない | `nil` は `Optional` の型にだけ置ける。`String?` のような型にして、`if let`・`guard let` で取り出す | — |
| `true`・`false` (2 件) | — (Swift の `true`・`false`) | 持たない | 綴りは同じ。型は `Bool` | — |
| `try`・`catch` (2 件) | — (Swift の `do { try … } catch { }`) | 持たない | 投げる関数を呼ぶ側に `try` を書き、`do` の中に置く。mokume の読み込みの API は `ImageFailure` などの型のついた失敗を投げる (`setup() throws` なら `do` は要らない) | — |
| `import` | — (`import mokume`) | 持たない | Processing の `import processing.sound.*;` に当たるのは、ファイルの先頭の `import mokume`。音・カメラ・ネットワークなどの領域もこの 1 行で入る (`Sources/mokume/Umbrella.swift` が再輸出する) | — |

## スケッチの進行

7 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `setup()` | `Sketch.setup()` | 同等 | 1 度だけ呼ばれる。`throws` で書け、投げたら `draw()` を 1 度も呼ばずに起動の失敗として止まる (Processing の `setup()` は投げられない)。`async` にはできない。書かなければ何もしない | — |
| `draw()` | `Sketch.draw()` | 同等 | フレームごとに呼ばれる。書かなければ何もしない | — |
| `loop()` | `loop()` | 同等 | `noLoop()` で止めた進行を戻す。回っている間に呼んでも何もしない。戻った最初の 1 枚の `deltaTime` は目標の 1 フレーム分で、止まっていた間の時間は乗らない。`setup()`・`draw()`・入力のコールバックの中から呼ぶ | [#900] |
| `noLoop()` | `noLoop()` | 同等 | `draw()` を呼ぶ進行を止める。止まっている間も入力のコールバックは呼ばれ、フレーム番号も時刻も進まない。`setup()`・`draw()`・入力のコールバックの中から呼ぶ | [#900] |
| `redraw()` | `redraw()` | 同等 | 止まっている間に `draw()` を 1 度だけ呼ぶよう頼む。何度呼んでも 1 度。回っている間と `draw()` の中では何もしない。描き直しの 1 枚の `deltaTime` は目標の 1 フレーム分 | [#900]・[#1366] |
| `exit()` | — | 作例待ち | スケッチを終える API が無い。**終わらせ方が、ウィンドウを持つ所で割れる**: 直接実行 (`mokume run`・バンドルした `.app`)・`mokume watch` (ウィンドウは監視するツールが持つ)・`SketchView` (ホストアプリが持つ)・`mokume render` (ウィンドウが無い。書き出しを終えて止まる)。Swift 標準の `exit(_:)` はプロセスごと終わらせるので、`SketchView` ではホストアプリが終わる。作例 (一定時間のあとで終わる作品) が来たら選ぶ | — |
| `thread()` | — (Swift の `Task { }`・`Task.detached { }`) | 持たない | 名前の関数を別の thread で走らせる。Swift の並行処理が同じ働きで、`Task { await … }` と書く。スケッチの API は `setup()`・`draw()`・入力のコールバックの中から呼ぶもので、`Task` の中からは返り方が API ごとに決まる (待つ読み込みは `Task` から呼べる: `requestImage(_:)` ほか)。 | [#2760] |

## 状態の退避

4 件。Processing の `push()`・`pop()` は変換とスタイルの両方を積む。`pushMatrix()`・`popMatrix()` は変換の領域の表 (順 3 の「色・変換・光とカメラ・描画」) に属する。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `push()` | `push()`・`push { }` | 同等 | 変換とスタイル (色・線・文字などの設定) の両方を積む。対の `pop()` を通らないままフレームが終わると、`push()` を呼んだ行を名指しして 1 度だけ注意する。**閉包で戻す `push { }` は、途中で `return` しても投げても戻す。** 状態を退避する形のうち、`push { }` を正本にすると決めた ([#3817]) | [#3817]・[#3875] |
| `pop()` | `pop()` | 同等 | `push()` で積んだ変換とスタイルを戻す。積んだ履歴はフレームを越えない | [#3817] |
| `pushStyle()` | `pushStyle()` | 同等 | スタイル (塗り・線・混ぜ方・文字・矩形の読み方など) だけを積み、変換は積まない。積んだ履歴はフレームを越えない (降ろし忘れても次のフレームへ積み上がらない) | [#3817] |
| `popStyle()` | `popStyle()` | 同等 | `pushStyle()` で積んだスタイルを戻す | [#3817] |

## ウィンドウ

3 件。Processing ではウィンドウの面 (`PSurface`) のメソッドで、入力・出力・環境の表 ([#3688]) の `windowTitle()` などの行と同じ領域である。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `setTitle()` | `windowTitle(_:)` | 同等 | 実行中にウィンドウのタイトルを変える (起動時のタイトルは `SketchSettings.title`)。ウィンドウを持つ所ごとの振る舞いは `windowTitle()` の行と同じ | [#3709] |
| `setLocation()` | — | 作例待ち | 座標の原点と単位の選択が分かれる (`windowMove()` の行と同じ理由。入力・出力・環境の表の `windowMove()` の行)。ウィンドウは監視するツールや埋め込み先のホストが持つ場合がある | [#3688] |
| `setResizable()` | — | 作例待ち | ウィンドウの大きさを手で変えられるかの切り替え。mokume の `width`・`height` は起動時に決まり、ウィンドウの大きさは別の数で決まる。API の意味 (描画の大きさか、ウィンドウの大きさか) が `windowResizable()` の行と同じく割れる | [#3688] |

[#900]: https://github.com/mokume-metal/mokume/issues/900
[#1366]: https://github.com/mokume-metal/mokume/issues/1366
[#2416]: https://github.com/mokume-metal/mokume/issues/2416
[#2760]: https://github.com/mokume-metal/mokume/issues/2760
[#3133]: https://github.com/mokume-metal/mokume/issues/3133
[#3688]: https://github.com/mokume-metal/mokume/issues/3688
[#3709]: https://github.com/mokume-metal/mokume/issues/3709
[#3817]: https://github.com/mokume-metal/mokume/issues/3817
[#3875]: https://github.com/mokume-metal/mokume/issues/3875
[#4176]: https://github.com/mokume-metal/mokume/issues/4176
[#4179]: https://github.com/mokume-metal/mokume/issues/4179
