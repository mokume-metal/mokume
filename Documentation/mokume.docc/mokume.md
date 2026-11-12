# ``mokume``

<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT

帰属のヘッダは**題より後ろ**に置く。先頭に置くと docc が題を見つけられず、
「An article is expected to start with a top-level heading title」の警告 1 本を
残したまま、このページの説明も Topics も丸ごと消える (実測)。消えても変換は
成功するので、気付けるのは公開物を見たときだけになる。
-->

スケッチを書くための API の一覧。キャンバスへの描画・音や入力の受け取り・書き出し・観測 (MCP の `observe`) の API がここに揃っている。

## Overview

利用者が書くのは `import mokume` の 1 行で、内部のモジュールの分け方は、書き方にも公開 API にも表れない。このページに並んでいるのは、その 1 行で使えるようになる API である。

```swift
import mokume

final class Hello: Sketch {
    func draw() {
        background(15, 18, 23)
        circle(width / 2, height / 2, 120)
    }
}
```

### 最初の円の次に読む順

**最初の円が動いたら、次に読む節は、作品を作る順で選ぶ。** 下の Topics は API の種類ごとに多くの節へ分かれているので、どこから読むかは自分では決めにくい。ブロック崩しの作例 ([`Sketches/BricksAndBall.swift`](https://github.com/mokume-metal/mokume/blob/main/Sketches/BricksAndBall.swift)) は 3 段階に分けて書いてあり、段階の名前は `// MARK:` に付けてある。4 段階目は作例の次に、更新を値の型へ分ける段階である。段階ごとに、読む節と、`mokume examples` で開ける短い例を挙げる。

| 段階 | その段階で書くこと | 読む節 | `mokume examples` で開く例 |
| --- | --- | --- | --- |
| 1. 関数で描く | 画面とスコアを、`background`・`text` などの関数を呼んで描く | [スケッチを書く](#スケッチを書く)・[背景と色](#背景と色)・[文字を描く](#文字を描く) | `text(_:_:_:)#1` |
| 2. 値で判定し、描くときは `fill()` に従わせる | パドルと球を値で持ち、`intersects` で当たり判定をし、`fill()` で色を決めてから `draw()` で描く | [図形を値で持って当たり判定する](#図形を値で持って当たり判定する)・[入力を受ける](#入力を受ける)・[キャンバスの大きさと時間](#キャンバスの大きさと時間) | `Circle.intersects(_:)#2` |
| 3. 物体ごとに見た目を持たせる | ブロックごとに色を値へ持たせ、`draw()` だけで描く | [図形を値で持って当たり判定する](#図形を値で持って当たり判定する) | `Rect.fill` |
| 4. 更新を値の型へ分け、引数で確かめる | `Paddle` のような値に `update(horizontal:deltaTime:)` を持たせ、入力と経過時間は `draw()` が読んで引数で渡す。スケッチの API を読まないので、ウィンドウなしで確かめられる | [自作の型で API を使う](#自作の型で-API-を使う)・``SketchPart`` の説明の、更新を値の型へ分ける節 | なし (型の例は `mokume examples` で開けない。``SketchPart`` の説明を読む) |

**例は `mokume examples` が並べる名前で探す。** `mokume examples` で一覧を出し (`grep` で絞れる)、`mokume new <名前> --from <例>` で 1 本のスケッチにできる。番号を添えた名前はシェルで引用符が要る (`--from 'text(_:_:_:)#1'`)。`mokume examples` で開けるのは各 API のドキュメントコメントの例で、作例の全体ではない — 段階を通して読むときは、上のリンクの作例を開く。

節の中身はここには載せない。各 API の振る舞いと例は、リンク先の説明にある。

### 自作の型で API を使う

**自分で書いた型に `: SketchPart` を付けると、その中でも `fill()`・`circle()`・`mouseX`・`random()` がそのまま使える。** Processing でタブに書いたクラスの中から `fill()` を呼ぶのと同じ書き方になる。``Sketch`` は ``SketchPart`` を継承しているので、スケッチの中では何も付けずに使える。

```swift
struct Player: SketchPart {
    var x: Float = 240
    var y: Float = 200

    func display() {
        fill(255)
        circle(x, y, 20)
        text("HP 3", x, y - 16)
    }
}

final class Game: Sketch {
    var player = Player()

    func draw() {
        background(20)
        player.display()
    }
}
```

これらの API は、呼んだ時点で実行中のスケッチへ描き、そのスケッチの状態を読む。`: SketchPart` を付けずに `fill()` を書くと「`fill` が見つからない」というコンパイルエラーになる。色を作る ``color(_:_:_:_:)`` のような純粋な計算は、付けなくてもどこからでも呼べる。

**スケッチの API を使えるのは、実行中のスケッチの中 (``Sketch/setup()``・``Sketch/draw()``・入力のコールバック) である。** 部品の `init()` の中・終了処理の後・``Sketch/draw()`` で作った `Task` の中から呼んでもクラッシュしない — 読み取りは 0 や空を返し (``SketchPart/width`` は 0)、描く API は何もしない。どちらも API ごとに 1 度だけ警告し、警告は観測の応答にも載る。キャンバスの大きさで決まる値は、``Sketch/setup()`` の中で部品を作り直して決める。キャンバスから作るリソース (``SketchPart/createGraphics(_:_:)``・``SketchPart/loadImage(_:)`` など) は、返すものを作れないので、API ごとに 1 度だけ警告して型付きのエラー (``ImageFailure/notRunning(call:)`` など) を投げる。`try?` で受ければ `nil` になる。**プロセスが止まる (`fatalError`) のは、キャンバスそのもの (``SketchPart/canvas``) を外から読んだときだけである。** 音・通信・シリアルなど、API ごとの返り方は[実行中でないときに API を呼ぶと](#実行中でないときに-API-を呼ぶと)にある。

### `import mokume` で使える標準の関数

**このリファレンスにシンボルのページが無くても、この 1 行で使える関数がある。** 三角関数 7 本 — `sin` / `cos` / `tan` / `asin` / `acos` / `atan` / `atan2` — と、計算の関数 7 本 — `pow` / `sqrt` / `exp` / `log` / `floor` / `ceil` / `round` — は個別に再エクスポートしてあるので、`import Foundation` を足さずにそのまま呼べる。角度の単位はラジアンで、``SketchPart/rotate(_:)`` に渡す値と同じである。度で書きたいときは ``radians(_:)`` を通す (こちらは mokume 自身の関数なので、下にページがある)。

```swift
circle(200 + cos(time) * 80, 150 + sin(time) * 80, 40)
let level: Float = 3
circle(200, 150, 20 + pow(2, level))
```

**リテラルだけの `pow(2, 3)`・`exp(-1)`・`log(10)` は、型が決まらずコンパイルできない。** この 3 本は `Float` と `Double` の両方にオーバーロードがあり、どちらも同じだけ合うので、`ambiguous use of 'pow'` になる (`import Darwin` だけでも同じで、mokume の関数ではない)。片方に型を持たせる — `pow(2, level)` (`level` が `Float`)・`pow(2.0, 3)`・`exp(Float(-1))` はどれも通る。`sqrt(2)`・`floor(2.5)` のように型を決めなくても通るものもある。

**Processing・p5.js にあるが Darwin に無い (形が違う) 関数は、mokume が持つ。** ``dist(_:_:_:_:)``・``mag(_:_:)`` (3 次元は ``dist(_:_:_:_:_:_:)``・``mag(_:_:_:)``)・``sq(_:)``・``fract(_:)``・``mod(_:_:)`` で、下にページがある。``mod(_:_:)`` は負の値も 0 以上の範囲に収める剰余で、`%` が小数に使えない代わりに、周期的な値を、足して引き直さずに書ける。値型 `Vector2` の側の名前は `length` である — 関数の ``mag(_:_:)`` と `Vector2` の長さが並ぶのは、`circle()` と `Circle` の使い分けと同じである。

**説明は標準ライブラリの側にある**ので、個別に再エクスポートした関数はページを持たない。ここに書いてあるのは「使える」ことだけである。

[mokume のトップページ](../../) — インストールと最初の 1 本はこちら。

**ここに並ぶ API の例を開いて始めるなら**、`mokume examples` で一覧を出し、`mokume new <名前> --from <例>` で 1 本のスケッチにできる。例の名前は、このページの見出しと同じ表記である (`triangle` など)。

**このページ群の説明は、すべてソースの `///` から生成されている。** 説明を直したいときは実装の隣を直す。機械が一度に読むための一覧が要るときは、バージョンごとの Release に載る公開 API の一覧を使う — こちらは宣言の一覧で、API ごとの説明と例は載らない。説明と例は、MCP の `reference` に `symbol` を渡す (`reference(name: "api", symbol: "ambientLight")`) と、作品が依存しているのと同じバージョンのものを API ごとに調べられる。このページ群は人が読むためのもので、`main` のバージョンの説明になる。

### 状態の寿命

**書いた設定がいつまで効くかは、2 つに分かれる。**

| 種類 | 寿命 | 何が入るか |
| --- | --- | --- |
| **描き方** (どう描くか) | フレームを越える。一度書けば書き換えるまで残る | 塗り・線の色と太さ・線端と角の形・ブレンドモード・座標の読み方・文字の設定・画像に掛ける色 (tint)・テクスチャ・シェーダ・シェーダが読む数値の配列・ノイズのシードと詳細度・露出 |
| **シーンの記述** (何を描くか) | 越えない。`draw()` の中で毎フレーム書く | 視点・投影・光・マテリアル・変換・影・環境光・エフェクト・切り抜き |

描き方はキャンバスごとに持つ — オフスクリーンバッファ (``SketchPart/createGraphics(_:_:)``) で塗りを変えても、画面の塗りは変わらない。**ノイズのシードと詳細度だけはスケッチに 1 つ**で、画面とバッファが同じものを読み書きする (``SketchPart/noiseSeed(_:)``)。シェーダの `mokume_noise` が、どのキャンバスでも ``SketchPart/noise(_:_:_:_:)`` と同じ模様を出すためである。

**乱数のシード (``SketchPart/randomSeed(_:)``) もスケッチに 1 つで、書き換えるまでフレームを越えて残る**が、上の 2 つには入らない — 描き方でもシーンの記述でもなく、引くたびに進む乱数列の位置で、ノイズと違ってシェーダへは届かない。形の組み立て (``SketchPart/createShape(_:)``) の中で書いたシードだけは、抜けると**最初に書く直前の乱数列の位置**へ戻る。

`setup()` は最初のフレームが始まる前に実行され、止まっている間 (``SketchPart/noLoop()``) の入力のコールバックもフレームの外で実行されるので、**そこで書いたシーンの記述はどのフレームにも属さない**。警告なしに捨てるのではなく、警告を出して無視する。**ただし変換と、変換・スタイルの push / pop は例外である** — 描いたものには描いた時点の変換が適用されるので、`setup()` と止まっている間の入力のコールバックでは `translate()` や `push { }` が効き、その後に描いたものへ効く。呼び出しを抜けるときに変換と push したスタックは戻り、次のコールバックにも `draw()` にも持ち越さない (`setup()` で `translate()` だけ書いて何も描かないと、その旨を 1 度だけ警告する)。光・視点・マテリアル・切り抜きなど、描いた時点で適用されないシーンの記述は、そこでは従来どおり警告して無視する。**ループ中 (と、`redraw()` を呼んだ後) の入力のコールバックはフレームの内側で呼ばれ、そこでは光・視点・切り抜きなども効く**が、こちらも**コールバック 1 つごとに、書いたシーンの記述を抜けるときに戻す** — `mousePressed()` で書いた `translate()`・`lights()`・`clip()` は、そのコールバックの中で描いたものにだけ効き、同じフレームの `draw()` には効かない (`draw()` の頭で変換が既定へ戻る Processing・p5.js と同じ結果。[#3408](https://github.com/mokume-metal/mokume/issues/3408))。塗りや線などの描き方と乱数のシードは戻らない。**描画コマンドとして記録されず、フレームのフラッシュ時に読まれる影・エフェクト・デバッグ表示 (`debugMode()`) は、コールバックで書いたまま抜けると効かない** (1 度だけ警告する)。パーティクル・GPU の計算 (`force()`・`particles()`・`compute()`) は状態ではなく、そのフレームで実行する処理の予約なので戻さず、ループ中のコールバックで呼べばそのフレームで実行される。閉じずに抜けた形 (`beginShape()`) は、`draw()` へ持ち越さず捨てる。

```swift
// Processing の Basics/Color/ColorVariables と同じ形。setup() だけで 1 枚を描く
func setup() {
    background(51)
    noStroke()
    fill(204, 102, 0)
    pushMatrix()
    translate(80, 80)
    square(0, 0, 120)  // (80, 80) に出る
    popMatrix()
    fill(0, 102, 153)
    pushMatrix()
    translate(200, 80)
    square(0, 0, 120)  // (200, 80) に出る
    popMatrix()
}
```

オフスクリーンバッファ (``SketchPart/createGraphics(_:_:)``) では、視点・光・変換などのシーンの記述と、パーティクル・GPU の計算の呼び出しも ``Canvas/beginDraw()`` と ``Canvas/endDraw()`` の間でだけ効く — `draw()` の中にいても、その対の外で書けば同じ警告を出して無視する。

**描いたもの (図形・画像・背景・画素の書き込み・呼んだ時点でエフェクトを掛ける ``SketchPart/filter(_:)``) は設定ではなく、次に描くフレームに出る。** `setup()` と、止まっている間 (``SketchPart/noLoop()``) の入力のコールバックで描いたものは、次に描くフレームへ持ち越される — `setup()` だけで 1 枚を描ける。オフスクリーンバッファでは ``Canvas/beginDraw()`` と ``Canvas/endDraw()`` の間でだけ描ける。それ以外 (バッファの対の外・`Task` の続きなど) で描いたものは、警告を出して無視する。

**寿命と、スタックに積めるかどうかは別の話である。** 変換はフレームを越えないが ``SketchPart/pushMatrix(fileID:line:)`` で積める。積んだものもフレームの頭で空に戻るので、`draw()` の中で戻し忘れても次のフレームへは残らない。`setup()` と止まっている間のコールバックでも同じで、呼び出しを抜けるときに戻る。

**どこに書けるかは寿命を表さない。** 切り抜き (``SketchPart/clip(_:_:_:_:)``) は塗りや線と同じところに書けるが、シーンの記述なので越えない。

一つひとつの寿命は、それぞれの説明に付けた `Note` が持つ。

### 実行中でないときに API を呼ぶと

**実行中のスケッチの外 (部品の `init()` の中・終了処理の後・``Sketch/draw()`` で作った `Task` の中) から呼んだときの返り方は、API の種類で決まる。** どれもプロセスはクラッシュせず、API ごとに 1 度だけ警告する。

- **読み取りと描く API。** 読み取りは 0 や空を返し (``SketchPart/width`` は 0)、描く API は何もしない。警告は観測の応答にも載る。キャンバスの大きさで決まる値は、``Sketch/setup()`` の中で部品を作り直して決める
- **キャンバスから作るリソース** (``SketchPart/createGraphics(_:_:)``・``SketchPart/loadImage(_:)`` など)。返すものを作れないので、型付きのエラー (``ImageFailure/notRunning(call:)`` など) を投げる。`try?` で受ければ `nil` になる。投げない ``SketchPart/createShape(_:)`` は空の形を返す
- **音・通信・シリアルを作る API** (``Sketch/loadSound(_:)``・``Sketch/createTCPServer(_:)``・``Sketch/createSerial(_:baudRate:)`` など)。スケッチの `init()` などで呼ぶと、作ったものを実行中のスケッチへ追加できないので、同じく ``AudioFailure/notRunning(call:)``・``SerialFailure/notRunning(call:)`` などを投げる
- **投げない作る API** は、スケッチに追加されていないものを返す。合成音の API (``Sketch/createSinOsc()`` など) は、音声のストリームをまだ追加していなければ鳴らない音を (``Sketch/setup()`` などで先に合成音を作ってあれば、そのストリームに入って鳴る音を)、``Sketch/createAudioIn(device:)`` は何も聞かない入力を、記録したメッセージを流す 5 つの API (``Sketch/createTCPServer(messages:)``・``Sketch/createWebSocketServer(messages:)``・``Sketch/createUDP(messages:)``・``Sketch/createOSC(messages:)``・``Sketch/createSerial(lines:)``) は何も届かないポートを、ゲームパッドの API (``Sketch/gamepads()``・``Sketch/createGamepad(inputs:)``) は何も入力されないパッドを、MIDI の API (``Sketch/createMIDI(_:)``・``Sketch/createMIDI(messages:)``) は何も届かない入力を、手の関節点の API (``Sketch/createHandPose(results:)``) は何も届かない入力を返す
- **入力を止める API** (``AudioIn/stop()``・``Capture/stop()``・``Serial/stop()`` など)。外で呼ぶと何もせず、`AudioIn.stop()` のように型名を付けた名前で 1 度だけ警告する

**プロセスが止まる (`fatalError`) のは、キャンバスそのもの (``SketchPart/canvas``) を外から読んだときだけである。**

### 再起動の後に残るもの

`mokume watch` で `.swift` を保存すると、スケッチは新しいプロセスで再起動される。
アセットのディレクトリ (`Sources/<名前>/assets/`) のファイルを追加したり保存したりしたときも、ビルドがアセットをコピーし直すので同じく再起動する。

監視するのは次の 3 つで、これが仕様である。`Package.swift`、`Sources/` の下の `.swift` (隠しファイルとバンドルの中を除く)、`Sources/<名前>/assets/` の下の通常のファイル (隠しファイル・`.metal`・シンボリックリンクを除く)。

**範囲の外を変えても再起動しない。** `Package.swift` で `assets/` 以外に宣言したリソース (`.process("Resources")`・`.copy("data.json")`・`path:` を変えた target)、アセットのディレクトリの中のシンボリックリンク、`Package.resolved`、パスで指定した依存 (`--local` の mokume のチェックアウト) である。たとえば `resources: [.process("Resources")]` を宣言した作品で `Sources/<名前>/Resources/data.json` を保存しても、再起動は起きない。外を変えたときは `mokume watch` を再起動する。範囲を `Package.swift` の宣言から導く方法は、宣言を変えた作品が出てから決める。

**フレームを越える状態も、この再起動では最初から始まる。** 本体が引き継ぐのは次の2種類である。

| 残るもの | 引き継ぎ方 |
| --- | --- |
| ``Param(name:)`` の保存済みの値 | `.mokume/state/params.json` から、起動時に1回、名前と型が一致する値を戻す。ただしコードの既定値を保存したときから変えた値は、保存を捨ててコードの既定値で始まる |
| `watch` が持つ作品のウィンドウ | スケッチを入れ替えてもウィンドウは残るため、位置・全画面・表示するディスプレイを保つ |

それ以外は引き継がない。作者の変数や配列、`frameCount` と `time` (下の `--keep-time` を除く)、乱数列、描いた絵、
``SketchPart/createGraphics(_:_:)`` の中身、パーティクルや GPU の計算の状態、`orbitControl` で回した視点は、
新しいスケッチの初期状態から始まる。ウィンドウに絵が途切れず表示されていても、内部の状態を運んでいるわけではない。

例えば、`@Param` で球の半径を調整し、自分の変数 `playhead` で再生位置を持っている作品で、
Swift の色を変えて保存すると、保存済みの半径とウィンドウは残るが、`playhead` はコードの初期値へ戻る。
作者の任意の状態を再起動の後へ引き継ぐ API は、いまの本体には無い。

**`mokume watch --keep-time` なら、作者の時計だけは引き継ぐ。** 既定は上のとおり 0 秒から始まる。このフラグを付けると、
新しいプロセスの最初のフレームの `time` が、前のプロセスが描いていた秒の続きになり、`pauseTime()` で止めていれば止めた秒のまま出る。
12 秒で一巡する作品の 8 秒目で止めたまま、色を書き換えて保存して調整できる。引き継ぐのは**作者の時計の秒と、止めているか**
の 2 つだけである。`frameCount`・乱数列・`deltaTime` で積み上げた状態 (`Countdown` を含む)・作者の変数は引き継がない。
フレームの時計 (`SketchSettings` の `clock` を `.frames` にした作品) でも同じで、`time` は引き継いだ秒から `1/fps` ずつ進むが、
`frameCount` は 1 から数え直すので、`.frames` で状態を積み上げて書いたゲームでは時刻だけが続きになる。
`setup()` で `pauseTime()`・`playTime()`・`jumpTime(_:)` を呼べば、前のプロセスが止めていても回っていても、そちらが優先される
(`setup()` の中で読む `time` も、前のプロセスの続きの秒である)。前のプロセスがクラッシュして居なくなっているときや、`noLoop()` でフレームが止まっているときは、居なかった・止まっていた間を足さず、最後に
書いた秒・ウィンドウに出ているフレームの秒から始まる (静的な作品を眺めてから保存しても、保存のたびに絵が変わらない)。フラグの無い `watch`・`run`・`render` は変わらず 0 秒から始まり、
`mokume render` で書き出した絵は変わらない。

**`.metal` のシェーダを保存したときは、プロセスを再起動しない。** 実行したままシェーダを差し替えるので、
上に挙げたプロセス内の状態は残る。

**保存された `@Param` の値は、作品の一部ではない。** 保存は、手元で続きから再開するためのものである。
作品として残したい値は、コードの既定値へ書き戻す。

**コードの既定値を書き換えた値は、保存より優先される。** 保存は書いた時点の既定値を併記しているので、既定値を変えると、
つまみで合わせていた値は捨てられてコードの新しい既定値になる (捨てたことは標準エラーと、観測の最初の応答の
`discarded` に `defaultChanged` で出る)。触っていない値の既定値を変えたときと、合わせた値をそのまま既定値へ
書き戻したときは、失うものが無いので何も出さずに新しい既定値になる。代償として、**起動のたびに既定値が変わる宣言**
(`@Param var seed = Double.random(in: 0...1)` など) は、保存が毎回捨てられて効かない。

### 止めて変数を見る

**`draw()` の途中で止めて変数を読みたいときは、`mokume run -c debug` で起動したスケッチに `lldb` をアタッチする。** `mokume` に専用の機能は無い (エディタの設定も作らない)。`lldb` は Command Line Tools に入っている。構成は `-c debug` を明示する。debug の実行ファイルは、デバッガーのアタッチに要る entitlement (`com.apple.security.get-task-allow`) を持つ。確かめたのは debug だけである。

例として、`mokume new Ball` で作ったスケッチの `draw()` を次のように書き換える。`deltaTime` は `Float` なので、`x` も `Float` で持つ。

```swift
var x: Float = 0

func draw() {
    background(15, 18, 23)
    fill(242, 115, 51)
    x += 120 * deltaTime   // ← ここで止める (Ball.swift の 14 行目)
    circle(x, 200, 40)
}
```

1 つめのターミナルでスケッチを起動する。

```bash
mokume run -c debug
```

2 つめのターミナルで、スケッチの名前 (`mokume new` に渡した名前・実行ファイルの名前) を指定して `lldb` をアタッチする。アタッチした時点でウィンドウは止まる。止めたい行にブレークポイントを置いて、再開する。

```
$ lldb -n Ball
(lldb) breakpoint set -f Ball.swift -l 14
(lldb) continue
```

次のフレームの `draw()` が 14 行目に着くと止まる。止まったら、変数を読み、1 行進め、再開する (値は実行した時間で変わる)。

```
(lldb) frame variable
(Ball.Ball) self = 0x0000007b4340c0a0 (x = 8851.95214)
(lldb) p deltaTime
(Float) 0.166666672
(lldb) next
(lldb) p x
(Float) 8871.95214
(lldb) continue
```

`next` で `x += …` が 1 行進み、`x` が増える。`continue` でウィンドウが動き出し、次のフレームで同じ行にまた止まる。ブレークポイントを外して実行し続けるなら `breakpoint delete` の後に `continue` する。デバッガーを外すときは `process detach` を実行する (スケッチは実行され続ける)。同じ名前のスケッチを複数起動しているときは、`lldb -n` ではなく `lldb -p <PID>` で 1 つを指定する。

**調べている間は `mokume watch` を使わない。** `watch` は `.swift` を保存するたびに新しいプロセスを起動して入れ替える (上の「再起動の後に残るもの」)。アタッチしていたデバッガーは古いプロセスに残る。保存すると、古いプロセスは `lldb` の中で `stop reason = signal SIGTERM` のまま止まり、しばらくして `watch` が `Killed a sketch that would not stop` と表示して強制終了する。新しいプロセスにデバッガーはアタッチされておらず (`lldb` は古いプロセスの終了とともに終わる)、ブレークポイントも引き継がれないので、アタッチし直しになる。止めて調べるときは `mokume run -c debug` を使い、直したら再起動する。`.metal` のシェーダを保存したときは、プロセスが替わらない (上の「再起動の後に残るもの」)。

**速さを測るときは release を使う。** debug の数字を根拠にしない。構成を指定しない `mokume run` / `mokume watch` は release で組むので、そのまま起動する (`-c debug` を付けたときは測らない)。

### 同じ時刻の絵を比較する

MCP の `observe` に `{"time": 3}` を渡すと、実行中のスケッチを3秒目で1枚描き直してキャプチャできる。
Swift の色などを編集して保存した後、もう一度同じ秒を指定すれば、同じ構図で比較できる。
適用できた応答には `appliedTime` があり、画像の時刻と一致する。古いバージョンの mokume を使う作品が指定を無視した場合は、
MCP が作品側の mokume の更新を案内する。`time` を省けば、通常の観測である。

**時刻以外の状態は戻らない。** 時刻から絵が決まる作品向けで、変数の更新・乱数・描いた絵の蓄積など、
`draw()` の副作用は残る。画面にも指定時刻の絵が出て、`deltaTime` は0、`frameCount` は1進む。
次の通常フレームは元の時計に戻るため、保存後も自動でその場面に留まる機能ではない。

指定の秒を読むのは、そのフレームの `draw()` の中の `time` だけである。同じフレームで呼ばれる入力のコールバックが
読む `time` は作者の時計の秒で、`jumpTime(time + 0.25)` のように書いても観測の後に作者の時計が飛ばない。
再生している動画の再生位置と、そのフレームの `draw()` で作った録音の起点も作者の時計の秒で進み、観測の秒を
状態として積まない（表示するコマと音声のウィンドウだけが指定の秒で決まる）。

キャプチャできるのは1枚だけで、`count` と `every` は1に限る。`noLoop()` 中も1枚描いて停止を保つが、
外部からの停止中、録画中では指定時刻の要求を拒否する。指定のフレームの中から連続録画を始めることもできない。

### Swift で 3 つだけ違うこと

Processing や p5.js から来て最初につまずきやすい 3 つを挙げる。どれも、Swift の決まり (型推論・エラーの扱い) と、
mokume が API をどう選んだか (数は `Float` も `Double` も受ける・失敗はエラーを投げる) が組み合わさって起こる。
全部ではない — 数の型を混ぜる計算などは、次の節 (数の型) にある。

**1. `.pi` だけでは型が決まらず、コンパイルエラーになる。** 描く関数と数の関数は `Float` も `Double` も受けるので、
`.pi` がどちらか決まらないからである。`PI`・`HALF_PI`・`QUARTER_PI`・`TWO_PI`・`TAU` の定数を使うか、
`Float.pi` と書く。

<!-- example: 組めない `.pi` だけでは型が決まらずコンパイルエラーになることが主題の例 -->
```swift
rotate(.pi / 4)           // error: cannot infer contextual base in reference to member 'pi'
```

```swift
rotate(QUARTER_PI)        // 定数は Float で、そのまま渡せる
rotate(Float.pi / 4)      // 型を明示しても通る
```

`pow(2, 3)` のようにリテラルだけを渡す計算の関数も、同じ理由で型が決まらずコンパイルできない (上の「`import mokume` で使える標準の関数」)。

**2. 割り算は、片方に小数点を付ける。** 渡す先が型を決めない関数 (mokume の描く関数・数の関数) へ、
整数リテラルだけの式を渡すと、整数のまま計算され、`1 / 2` は 0 になる。型を明示した文脈
(`let r: Float = 1 / 2`) では、同じ式が小数で計算される。
**エラーにならず**、描かれる絵で気付くことになる。

```swift
let r: Float = 1 / 2                     // 0.5 (型を明示した文脈では小数で計算される)
circle(width / 2, height / 2, 1 / 2)     // 0 になり、直径が 0 で何も描かれない (渡す先が型を決めないので Int で計算される)
circle(width / 2, height / 2, 1.0 / 2)   // 0.5 が渡る
```

**3. 画像・オフスクリーンバッファ・シェーダなどを作る関数は、失敗するとエラーを投げるので `try` が要る。** Swift では、投げる関数を呼ぶ式の頭に
`try` を付ける。**無いと絵が成り立たないリソースは、`setup()` を `throws` で書いて、その中で `try` する。**
読み込めなければ ``Sketch/draw()`` を 1 度も呼ばずに、起動の失敗として止まり、`The sketch could not start.` に続けて
失敗の理由 (何を読めなかったか) が出る。`setup()` が成功したときだけ `draw()` が呼ばれるので、`Image!` で
宣言した変数は `draw()` の中で `nil` にならない。

```swift
var photo: Image!

func setup() throws {
    photo = try loadImage("assets/photo.png")   // 無ければ、起動の失敗として止まる
}

func draw() {
    image(photo, 0, 0)
}
```

**無くても絵が成り立つリソースは、`try?` で受ける。** `try?` は失敗の理由を捨てて `nil` にするので、読み込めなければ
そこだけ描かずに実行し続ける。`do` / `catch` なら理由を受け取れる。

```swift
var grain: Image?

func setup() {
    grain = try? loadImage("assets/grain.png")   // 無くても絵は成り立つので、読めなければ nil のまま
}

func draw() {
    background(20)
    if let grain { image(grain, 0, 0) }          // 無ければ、ここだけ描かない
}
```

```swift
do {
    let photo = try loadImage("assets/photo.png")
    image(photo, 0, 0)
} catch {
    print("読み込めなかった: \(error)")   // 理由を受け取れる
}
```

1 と 2 は、次の節 (数の型) に理由と周辺の書き方がある。

### 数の型

**変数を渡すときは型を気にしなくてよい。** 描画へ渡す数は `Float`・`Double`・`Int` の
どれで持っていても通る。

```swift
let gap = 120.0                      // Swift は Double に推論する
circle(gap, gap, 40)                 // そのまま渡せる
for i in 0..<255 { fill(i, 0, 0) }   // ループ変数 (Int) もそのまま
```

**中では `Float` として扱われる。** mokume の API が返す数 — `width` / `height` / `time` / `random()` /
`noise()` / `map()` — はすべて `Float` である。GPU が 32 bit で動くので、そこに合わせてある。

**変換が要るのは、API が返した数と自分の数を混ぜて計算するときだけである。** Swift は型の違う数
どうしの計算を許さないので、片方を揃える。

```swift
let columns = 6                          // Int
let step = width / Float(columns)        // width は Float。Float へ揃える
for index in 0..<columns {
    let ratio = Float(index) / Float(columns)
    circle(step * Float(index), height * ratio, 20)
}
```

**添字と `width` を混ぜる式は、エラーが `width` のほうを指す。** `i * width / count` のように
`Int` の添字と `Float` を同じ式に書くと通らない。ところが渡す先が型を決めなくなったので、
コンパイラは式を `Int` で解こうとして、**添字ではなく `width` を「`Int` ではない」と指摘する**。
言われたとおりに `width` を `Int` にするのではなく、直すのは添字の側である (`Float(i)`):

<!-- example: 組めない 通らないことが主題の例 (Int の添字と Float の width を混ぜると型の誤りになる) -->
```swift
let count = 6
for i in 0..<count {
    circle(i * width / count, height / 2, 10)
    // error: cannot convert value of type 'Float' to expected argument type 'Int'
    // (コンパイラが指すのは width。誤りの本当の場所は、Int のままの i と count)
}
```

```swift
let count = 6
for i in 0..<count {
    circle(Float(i) * width / Float(count), height / 2, 10)   // 添字を Float へ揃える
}
```

**添字を経ずに `Float` のまま回すなら、標準の `stride` が使える。** 変換を書かずに済む。

```swift
let step = width / 6
for x in stride(from: Float(0), to: width, by: step) {
    circle(x, height / 2, 10)
}
```

**個数・添字・詳細度は `Int` のままである。** `sphere(半径, detail:)` の `detail`、画素の添字
(``SketchPart/get(_:_:)``)、乱数のシード (``SketchPart/randomSeed(_:)``) のような「数え上げ」は `Int` で
受ける。半分の個数や 1.5 番目の画素は無いからである。

**割り算を書くときは、片方に小数点を付ける。** 渡す先が型を決めなくなったので、整数だけで
書いた式は整数のまま計算される。**通ってしまう**ので、描かれる絵で気付くことになる。

```swift
circle(width / 2, height / 2, 1 / 2)     // 直径が 0 になり、何も描かれない
circle(width / 2, height / 2, 1 / 2.0)   // 0.5 が渡る
fill(255, 255 * 50 / 100)                // 127 になる
fill(255, 255 * 50 / 100.0)              // 127.5 が渡る
```

`width` や `time` のように**API が返した数が式に入っていれば、そのまま書ける** — 全体が
`Float` として計算されるからである (上の `width / 2` がその例)。

**円周率は定数で書ける。** `PI`・`HALF_PI`・`QUARTER_PI`・`TWO_PI`・`TAU` は `Float` の定数で、
Processing・p5.js と同じ名前である。型が決まっているので、そのまま渡せる。

```swift
rotate(HALF_PI)                          // 90 度
let a = map(3, 0, 12, 0, TWO_PI)         // 12 等分した 3 つ目
```

**`.pi` のような書き方は、型を明示する。** 渡す先が型を決めなくなったので、`.pi` だけでは
`Float` と `Double` のどちらか決まらない。定数を使うか、`Float.pi` と書く。

```swift
rotate(Float.pi / 2)                     // 型を明示する
let turn = width / 400                   // Float
rotate(turn * .pi)                       // 他の項が Float なら .pi のままで通る
```

**Swift 標準の乱数は、シードに従わない。** `randomElement()`・`shuffled()`・`Float.random(in:)` は、引数を
省くと Swift が持つ別の乱数で引く。**コンパイルは通り、警告も出ず、実行するたびに絵が変わる** — 同じ入力から
同じ絵になる保証 (``SketchPart/randomSeed(_:)``) が、何も出さずに外れる。同じ乱数列で引かせるには、`using:` に
``SketchPart/randomSource`` を渡す。

```swift
randomSeed(7)
let palette = [color(240, 90, 60), color(250, 200, 80), color(80, 140, 220)]
fill(palette.randomElement(using: &randomSource)!)   // シードに従う。実行するたびに同じ色
fill(palette.randomElement()!)                       // シードに従わない。実行するたびに違う色
```

部品ごと・花ごとに別の乱数列が要るなら、値として持てる ``RandomSource`` を作る (`RandomSource(seed: 7, index: i)`)。
スケッチの乱数 (``SketchPart/random()``) を何回引いても、その乱数列は動かない。ノイズも同じで、シードと詳細度を
値として持つ ``NoiseField`` がある (``SketchPart/noiseSeed(_:)`` に触れずに、板ごとに別のシードで引ける)。

### Processing・p5.js の名前から探す

**Processing・p5.js の名前で書いて通らない・動きが違うときに、mokume のどの API へ直すかを探す表である。** 名前は Processing・p5.js から採っているので、多くはそのまま移植できる。ここに並ぶのは、移植すると何も出さずにずれるか、名前が変わる API だけである。違う理由と詳しい振る舞いは、リンク先の説明にある。

#### 通るのに呼ばれない

Processing・p5.js の形のまま書くとコンパイルは通るが、一度も呼ばれない。Swift は、名前が同じで引数の違うメソッドをエラーにしない。

| Processing・p5.js | mokume | 移植するときの直し方 |
| --- | --- | --- |
| `mouseWheel()` | ``Sketch/mouseWheel(deltaX:deltaY:)`` | `func mouseWheel(deltaX: Float, deltaY: Float)` と書く。回した量は引数で受け取る |

#### 数え方が違う

名前も形も Processing・p5.js と同じで、数える単位や範囲が違う。型では検出できない。

| Processing・p5.js | mokume | 移植するときの直し方 |
| --- | --- | --- |
| `saveFrame("f-####.png")` | ``SketchPart/beginRecord(_:)`` と ``SketchPart/endRecord()`` | 録画する範囲を 2 つで挟む。`####` はフレーム番号ではなく、録画の中の通し番号 (0 から) |
| p5 `deltaTime` (ミリ秒) | ``SketchPart/deltaTime`` (秒) | ミリ秒を前提にした係数を 1000 倍する (`x += 0.2 * deltaTime` → `x += 200 * deltaTime`) |
| Processing `clip(a, b, c, d)` (数を `imageMode` で読む) | ``SketchPart/clip(_:_:_:_:)`` (数を ``SketchPart/rectMode(_:)`` で読む) | 既定 (どちらも `.corner`) は同じ矩形。Processing で `imageMode(CENTER)` と組み合わせていたなら、角を渡す `clip(x - w / 2, y - h / 2, w, h)` と書く (`rectMode(.center)` を合わせると `rect`・`text` などの箱の読み方も変わる。`imageMode(.center)` だけを移植しても `clip` は左上から読む)。いまの変換の下で読むことと、負の幅・高さを裏返して読むことは Processing と同じ。回転・剪断の下では、回した・傾けた矩形そのもので切り抜く (形の切り抜き ``SketchPart/clip(_:)-(()->Void)`` と同じステンシルを使い、警告は出さない) |
| p5.js 2D の `background(0, 20)` (前の絵に薄く重ねて残像になる) | ``SketchPart/background(_:_:)`` (キャンバスを置き換える) | 残像にならない。薄い四角を `rect` で重ねて作る (作り方は ``SketchPart/background(_:_:)`` の例) |
| `setup()` で書いた `translate`・`rotate`・視点 (以降の `draw()` にも効く) | シーンの記述 (``SketchPart/translate(_:_:)`` など) はフレームを越えない | `setup()` の変換は、その後に `setup()` で描いたものへだけ効き (描いた時点で適用される)、`setup()` を抜けると戻る。`draw()` で描くものの変換は `draw()` の中で書く。視点・光は `setup()` で書くと警告して無視する。1 枚だけ描くなら `setup()` で描くか、`draw()` で描いて ``SketchPart/noLoop()`` で止める ([状態の寿命](#状態の寿命)) |
| p5 `movedX` (最新の 1 件) | ``SketchPart/movedX`` (フレームの合計) | `draw()` で読む。1 件ぶんは ``Sketch/mouseMoved(deltaX:deltaY:)`` の引数で受け取る |
| Processing `keyPressed()` (押したままで連射) | ``Sketch/keyPressed()`` (押した 1 回だけ) | 押している間ずっと効かせるものは、`draw()` で `keyboard.isPressed(_:)` を読む |

#### 書き方が変わる

型か書き方が違うので、移植するとコンパイルエラーになる。

| Processing・p5.js | mokume | 移植するときの直し方 |
| --- | --- | --- |
| p5 `keyIsDown(code)` | ``Keyboard/isPressed(_:)`` | `keyboard.isPressed(.arrowLeft)` と ``SketchPart/keyboard`` に問い合わせる |
| p5 `drop(callback)` (ドロップした `p5.File` を受ける) | ``Sketch/fileDropped(_:)`` | `func fileDropped(_ paths: [String])` と書く (ラベルを付けると呼ばれない)。渡るのは中身ではなく絶対パスで、`loadImage(paths[0])` のようにそのまま読む。ドロップした位置は ``SketchPart/mouseX``・``SketchPart/mouseY`` から読む |
| `selectInput(prompt, callback)` | ``SketchPart/selectInput(_:)`` | コールバックの代わりに `async` で結果を返す。`Task { if let path = await selectInput("CSV を選ぶ") { … } }` と書き、取り消せば `nil`。パスは絶対パスで、`loadTable(path)` などにそのまま渡せる |
| `selectOutput(prompt, callback)` | ``SketchPart/selectOutput(_:)`` | `Task { if let path = await selectOutput("保存先を選ぶ") { try? saveStrings(lines, path) } }` と書き、取り消せば `nil`。返るのはまだ無いファイルでもよい置き場の絶対パスで、書くのはスケッチ |
| `selectFolder(prompt, callback)` | ``SketchPart/selectFolder(_:)`` | `Task { if let folder = await selectFolder("フォルダを選ぶ") { … } }` と書き、取り消せば `nil`。待ちは `selectInput`・`selectOutput` と 1 つを共有し、後から呼んだ方が前を `nil` で終える |
| `keyCode == UP` | ``SketchPart/keyCode`` | `keyCode == .arrowUp` と ``Key`` で書く |
| `mouseButton == LEFT` | ``SketchPart/mouseButton`` | `mouseButton == .left` と ``MouseButton`` で書く |
| p5 `mouseIsPressed` | ``SketchPart/isMousePressed`` | `isMousePressed` を読む |
| `size(w, h)`・`frameRate(n)`・`fullScreen()` | ``Sketch/settings`` | 呼ばずに `settings` で返す (``SketchSettings/size(_:_:frameRate:title:)``・`SketchSettings(width: w, height: h, frameRate: n)`・``SketchSettings/fullScreen(_:)``) |
| `PVector`・`p5.Vector` と `mag()` | ``Vector2``・``Vector3`` と ``Vector2/length`` | `Vector2(x, y)`・`Vector3(x, y, z)` で作り、長さは `v.length` で読む (3 次元は ``Vector3/length``)。`heading()` は ``Vector2/angle``、`lerp()` は ``Vector2/interpolated(to:amount:)`` |
| `colorMode(HSB)` | ``color(hue:saturation:brightness:alpha:)`` | 色の体系を切り替えず、色相・彩度・明度で作る色にだけラベルを付ける |
| p5 `textToContours`・`textToPoints` | ``SketchPart/textOutline(_:_:_:)`` | 返る点は曲線を折れ線に分割したときの頂点で、間隔は揃っていない。等間隔の点は ``SketchPart/textOutline(_:_:_:spacing:)`` の `spacing:` に画素で渡す (`sampleFactor` はフォントの単位に対する比なので、画素へ換算する) |
| p5 `spotLight(…, angle, concentration)` | ``SketchPart/spotLight(_:_:_:_:_:_:_:angle:)`` | 角度に `angle:` を付ける。`concentration` は渡さない |

#### Processing・p5.js にあって mokume に無いもの

| Processing・p5.js | mokume | 移植するときの直し方 |
| --- | --- | --- |
| `noCursor()`・`cursor(HAND)` | ``SketchPart/noCursor()`` と ``SketchPart/cursor()`` | `noCursor()` はそのまま移植できる。形を選ぶ `cursor(HAND)` などは無く、`cursor()` は矢印へ戻すだけ |

## Topics

### スケッチを書く

- ``Sketch``
- ``SketchPart``
- ``SketchSettings``
- ``SketchSettings/size(_:_:frameRate:title:)``
- ``Sketch/init()``
- ``Sketch/setup()``
- ``Sketch/draw()``
- ``Sketch/settings``
- ``Sketch/plugins``
- ``SketchView``

### キャンバスの大きさと時間

- ``SketchPart/width``
- ``SketchPart/height``
- ``SketchPart/pixelWidth``
- ``SketchPart/pixelHeight``
- ``SketchPart/canvas``
- ``SketchPart/frameCount``
- ``SketchPart/time``
- ``SketchPart/phase(period:)``
- ``SketchPart/authorTime``
- ``SketchPart/deltaTime``
- ``SketchPart/clock``
- ``Clock``
- ``Countdown``
- ``SketchPart/usesFrameHistory``
- ``Upscale``

### 止める・進める・時刻を動かす

- ``SketchPart/noLoop()``
- ``SketchPart/loop()``
- ``SketchPart/redraw()``
- ``SketchPart/pauseTime()``
- ``SketchPart/playTime()``
- ``SketchPart/jumpTime(_:)``

### 全画面で出す

- ``SketchSettings/fullScreen(_:)``
- ``SketchSettings/fullScreenDisplay``
- ``SketchPart/displays``
- ``Display``

### 別のアプリへ絵を渡す

- ``SketchSettings/sharesFrames``

### 背景と色

- ``SketchPart/background(_:)-9jeha``
- ``SketchPart/background(_:_:)``
- ``SketchPart/background(_:_:_:_:)``
- ``SketchPart/fill(_:)-(LinearRGBA)``
- ``SketchPart/fill(_:)-(Gradient)``
- ``SketchPart/fill(_:_:)-(ScalarConvertible,_)``
- ``SketchPart/fill(_:_:)-(LinearRGBA,_)``
- ``SketchPart/fill(_:_:_:_:)``
- ``SketchPart/noFill()``
- ``SketchPart/stroke(_:)``
- ``SketchPart/stroke(_:_:)-(ScalarConvertible,_)``
- ``SketchPart/stroke(_:_:)-(LinearRGBA,_)``
- ``SketchPart/stroke(_:_:_:_:)``
- ``SketchPart/noStroke()``
- ``SketchPart/tint(_:)``
- ``SketchPart/tint(_:_:)``
- ``SketchPart/tint(_:_:_:_:)``
- ``SketchPart/noTint()``
- ``SketchPart/blendMode(_:)``
- ``SketchPart/exposure(_:)``
- ``SketchPart/toneMapping(_:)``
- ``LinearRGBA``
- ``Gradient``
- ``BlendMode``
- ``ToneMapping``

### 色を作る・読む

引数ラベルの無い数値は 0–255 の範囲で、ラベル付きの API はラベルが範囲を表す ([ADR-0033](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md))。

- ``color(_:_:)-(ScalarConvertible,_)``
- ``color(_:_:)-(LinearRGBA,_)``
- ``color(_:_:_:_:)``
- ``color(hex:)``
- ``color(hue:saturation:brightness:alpha:)``
- ``lerpColor(_:_:_:)``
- ``lerpColor(_:_:amount:)``
- ``paletteLerp(_:_:)``
- ``red(_:)``
- ``green(_:)``
- ``blue(_:)``
- ``alpha(_:)``
- ``hue(_:)``
- ``saturation(_:)``
- ``brightness(_:)``

### 線の引き方

- ``SketchPart/strokeWeight(_:)``
- ``SketchPart/strokeCap(_:)``
- ``SketchPart/strokeJoin(_:)``
- ``SketchPart/strokeDash(_:_:)``
- ``SketchPart/strokeDash(length:gap:)``
- ``SketchPart/noStrokeDash()``
- ``StrokeCap``
- ``StrokeJoin``

### 2D の図形

- ``SketchPart/rect(_:_:_:_:)``
- ``SketchPart/rect(_:_:_:_:_:)``
- ``SketchPart/square(_:_:_:)``
- ``SketchPart/circle(_:_:_:)``
- ``SketchPart/circle(_:_:)``
- ``SketchPart/ellipse(_:_:_:_:)``
- ``SketchPart/arc(_:_:_:_:_:_:)``
- ``SketchPart/arc(_:_:_:_:_:_:_:)``
- ``SketchPart/arc(in:start:stop:)``
- ``SketchPart/arc(in:start:stop:mode:)``
- ``ArcMode``
- ``SketchPart/triangle(_:_:_:_:_:_:)``
- ``SketchPart/quad(_:_:_:_:_:_:_:_:)``
- ``SketchPart/point(_:_:)``
- ``SketchPart/point(_:)-(Vector2)``
- ``SketchPart/line(_:_:_:_:)``
- ``SketchPart/line(_:_:)-(Vector2,_)``
- ``SketchPart/bezier(_:_:_:_:_:_:_:_:)``
- ``SketchPart/bezier(from:control1:control2:to:)-(Vector2,_,_,_)``
- ``SketchPart/bezier(_:_:_:_:_:_:_:_:_:_:_:_:)``
- ``SketchPart/bezier(from:control1:control2:to:)-(Vector3,_,_,_)``
- ``SketchPart/curve(_:_:_:_:_:_:_:_:)``
- ``SketchPart/curve(from:control1:control2:to:)-(Vector2,_,_,_)``
- ``SketchPart/curve(_:_:_:_:_:_:_:_:_:_:_:_:)``
- ``SketchPart/curve(from:control1:control2:to:)-(Vector3,_,_,_)``

### 座標の読み方

- ``SketchPart/rectMode(_:)``
- ``SketchPart/ellipseMode(_:)``
- ``SketchPart/imageMode(_:)``
- ``ShapeMode``

### 図形を値で持って当たり判定する

- ``Rect``
- ``Circle``
- ``Vector2``
- ``Vector3``

### 自分で形を作る

- ``SketchPart/beginShape(_:)``
- ``SketchPart/vertex(_:_:)``
- ``SketchPart/vertex(_:)-(Vector2)``
- ``SketchPart/vertex(_:_:_:)``
- ``SketchPart/vertex(_:)-(Vector3)``
- ``SketchPart/vertex(_:_:_:_:)``
- ``SketchPart/vertex(_:uv:)-(Vector2,_)``
- ``SketchPart/vertex(_:_:_:_:_:)``
- ``SketchPart/vertex(_:uv:)-(Vector3,_)``
- ``SketchPart/index(_:)``
- ``SketchPart/normal(_:_:_:)``
- ``SketchPart/bezierVertex(_:_:_:_:_:_:)``
- ``SketchPart/bezierVertex(control1:control2:to:)-(Vector2,_,_)``
- ``SketchPart/bezierVertex(_:_:_:_:_:_:_:_:_:)``
- ``SketchPart/bezierVertex(control1:control2:to:)-(Vector3,_,_)``
- ``SketchPart/quadraticVertex(_:_:_:_:)``
- ``SketchPart/quadraticVertex(control:to:)-(Vector2,_)``
- ``SketchPart/quadraticVertex(_:_:_:_:_:_:)``
- ``SketchPart/quadraticVertex(control:to:)-(Vector3,_)``
- ``SketchPart/curveVertex(_:_:)``
- ``SketchPart/curveVertex(_:_:_:)``
- ``SketchPart/curveDetail(_:)``
- ``SketchPart/curveTightness(_:)``
- ``bezierPoint(_:_:_:_:_:)``
- ``bezierTangent(_:_:_:_:_:)``
- ``SketchPart/curvePoint(_:_:_:_:_:)``
- ``SketchPart/curveTangent(_:_:_:_:_:)``
- ``SketchPart/beginContour()``
- ``SketchPart/endContour()``
- ``SketchPart/endShape(_:)``
- ``ShapeEnd``
- ``VertexKind``

### 形を保持して置く

- ``SketchPart/createShape(_:)``
- ``SketchPart/loadShape(_:)``
- ``SketchPart/requestShape(_:)``
- ``SketchPart/shape(_:_:_:)-(Shape,_,_)``
- ``SketchPart/shape(_:at:)``
- ``SketchPart/shape(_:at:layout:)``
- ``Shape``
- ``Placement``

### パスを測る

- ``SketchPart/createPath(_:)``
- ``SketchPart/shape(_:_:_:)-(Path,_,_)``
- ``Path``

### 座標を動かす

- ``SketchPart/translate(_:_:)``
- ``SketchPart/translate(_:_:_:)``
- ``SketchPart/translate(_:)-(Vector2)``
- ``SketchPart/translate(_:)-(Vector3)``
- ``SketchPart/rotate(_:)``
- ``SketchPart/rotateX(_:)``
- ``SketchPart/rotateY(_:)``
- ``SketchPart/rotateZ(_:)``
- ``SketchPart/scale(_:)``
- ``SketchPart/scale(_:_:)``
- ``SketchPart/scale(_:_:_:)``
- ``SketchPart/shearX(_:)``
- ``SketchPart/shearY(_:)``
- ``SketchPart/applyMatrix(_:)``
- ``SketchPart/resetMatrix()``
- ``Transform``

### 変換とスタイルの push / pop

- ``SketchPart/push(_:)``
- ``SketchPart/pushMatrix(fileID:line:)``
- ``SketchPart/popMatrix(fileID:line:)``
- ``SketchPart/pushStyle(fileID:line:)``
- ``SketchPart/popStyle(fileID:line:)``
- ``SketchPart/push(fileID:line:)``
- ``SketchPart/pop(fileID:line:)``

### 切り抜く

- ``SketchPart/clip(_:_:_:_:)``
- ``SketchPart/clip(_:)-(Rect)``
- ``SketchPart/noClip()``

### 文字を描く

- ``SketchPart/text(_:_:_:)``
- ``SketchPart/text(_:_:_:_:_:)``
- ``SketchPart/text(_:in:)``
- ``SketchPart/textSize(_:)``
- ``SketchPart/textFont(_:)-(String)``
- ``SketchPart/textFont(_:)-(Font)``
- ``SketchPart/noTextFont()``
- ``SketchPart/textStyle(_:)``
- ``SketchPart/textWeight(_:)``
- ``SketchPart/textAlign(_:_:)``
- ``SketchPart/textLeading(_:)``
- ``SketchPart/textWrap(_:)``
- ``SketchPart/textWidth(_:)``
- ``SketchPart/textAscent()``
- ``SketchPart/textDescent()``
- ``SketchPart/textOutline(_:_:_:)``
- ``SketchPart/textOutline(_:_:_:spacing:)``
- ``SketchPart/textBounds(_:_:_:)``
- ``SketchPart/shapedText(_:_:_:)``
- ``SketchPart/shapedTextWidth(_:)``
- ``SketchPart/shapedTextBounds(_:_:_:)``
- ``SketchPart/loadFont(_:)``
- ``Font``
- ``FontFailure``
- ``TextStyle``
- ``TextWrap``
- ``TextFlow``
- ``TextContour``
- ``TextBounds``
- ``HorizontalTextAlign``
- ``VerticalTextAlign``

### 画像を置く

- ``SketchPart/loadImage(_:)``
- ``SketchPart/loadImage(_:extension:)``
- ``SketchPart/requestImage(_:)``
- ``SketchPart/requestImage(_:extension:)``
- ``SketchPart/createImage(_:_:)``
- ``SketchPart/image(_:_:_:)-23fpf``
- ``SketchPart/image(_:_:_:_:_:)-4ch39``
- ``SketchPart/image(_:_:_:_:_:_:_:_:_:)-6fe4h``
- ``SketchPart/image(_:in:)-(Image,_)``
- ``SketchPart/image(_:in:from:)-(Image,_,_)``
- ``SketchPart/texture(_:)-c9g``
- ``SketchPart/noTexture()``
- ``SketchPart/textureMode(_:)``
- ``SketchPart/textureWrap(_:)``
- ``TextureMode``
- ``TextureWrap``
- ``Image``
- ``ImageFailure``
- ``DisplayImage``
- ``PixelSurface``
- ``SketchPart/assetURL(_:)``
- ``AssetFailure``

### カメラを使う

- ``Sketch/createCapture(_:_:device:mirrored:)``
- ``Sketch/createCapture(frames:mirrored:)``
- ``Sketch/captureDevices()``
- ``Capture``
- ``CaptureDevice``
- ``CaptureFormat``

### 動画を流す

- ``Sketch/createVideo(_:)``
- ``Movie``
- ``MovieFailure``

### 音を聞く

- ``Sketch/createAudioIn(device:)``
- ``Sketch/createAudioIn(file:)``
- ``Sketch/createAudioIn(samples:sampleRate:)``
- ``Sketch/audioInputDevices()``
- ``AudioIn``
- ``AudioDevice``
- ``AudioFailure``

### 音声ファイルを鳴らす

- ``Sketch/loadSound(_:)``
- ``Sketch/requestSound(_:)``
- ``SoundFile``

### 音を合成する

- ``Sketch/createSinOsc()``
- ``Sketch/createSqrOsc()``
- ``Sketch/createTriOsc()``
- ``Sketch/createSawOsc()``
- ``Sketch/createWhiteNoise()``
- ``Sketch/createPinkNoise()``
- ``Sketch/createBrownNoise()``
- ``Sketch/createEnv()``
- ``Sketch/createLowPass()``
- ``Sketch/createHighPass()``
- ``Sketch/createBandPass()``
- ``Sketch/createReverb()``
- ``Sketch/createDelay()``
- ``EffectInput``
- ``SynthSound``
- ``SynthSource``
- ``Oscillator``
- ``SinOsc``
- ``SqrOsc``
- ``TriOsc``
- ``SawOsc``
- ``Noise``
- ``WhiteNoise``
- ``PinkNoise``
- ``BrownNoise``
- ``Env``
- ``SoundEffect``
- ``Filter``
- ``LowPass``
- ``HighPass``
- ``BandPass``
- ``Reverb``
- ``Delay``

### OSC で他のアプリとやりとりする

- ``Sketch/createOSC(listen:send:)``
- ``Sketch/createOSC(send:)``
- ``Sketch/createOSC(messages:)``
- ``OSCPort``
- ``OSCMessage``
- ``OSCValue``
- ``OSCArgument``
- ``OSCFailure``

### TCP・UDP・WebSocket で他のアプリとやりとりする

- ``Sketch/createTCPServer(_:)``
- ``Sketch/createWebSocketServer(_:)``
- ``Sketch/createTCPClient(_:_:)``
- ``Sketch/createWebSocketClient(_:)``
- ``Sketch/createUDP(listen:send:)``
- ``Sketch/createTCPServer(messages:)``
- ``Sketch/createWebSocketServer(messages:)``
- ``Sketch/createTCPClient(messages:)``
- ``Sketch/createWebSocketClient(messages:)``
- ``Sketch/createUDP(messages:)``
- ``TextPort``
- ``TCPServer``
- ``WebSocketServer``
- ``TCPClient``
- ``WebSocketClient``
- ``UDPPort``
- ``NetworkFailure``

### シリアルで機器 (Arduino など) から受け取る

- ``Sketch/serialPorts()``
- ``Sketch/createSerial(_:baudRate:)``
- ``Sketch/createSerial(lines:)``
- ``Serial``
- ``SerialPort``
- ``SerialFailure``

### 画素を読み書きする

- ``SketchPart/pixels``
- ``SketchPart/loadPixels()``
- ``SketchPart/get(_:_:)``
- ``SketchPart/get()``
- ``SketchPart/get(_:_:_:_:)``
- ``SketchPart/get(in:)``
- ``SketchPart/set(_:_:_:)``
- ``SketchPart/set(x:y:to:)``
- ``Pixels``
- ``PixelBuffer``

### オフスクリーンバッファに描く

- ``SketchPart/createGraphics(_:_:)``
- ``SketchPart/image(_:_:_:)-7psdx``
- ``SketchPart/image(_:_:_:_:_:)-666br``
- ``SketchPart/image(_:_:_:_:_:_:_:_:_:)-3q9cm``
- ``SketchPart/image(_:in:)-(Canvas,_)``
- ``SketchPart/image(_:in:from:)-(Canvas,_,_)``
- ``SketchPart/texture(_:)-6aozc``
- ``Canvas``

### 書き出す

- ``SketchPart/save(_:)``
- ``SketchPart/beginRecord(_:)``
- ``SketchPart/endRecord()``
- ``PNGFile``
- ``ImageWriteFailure``

### 文字列・バイト列・表を読み書きする

- ``SketchPart/loadStrings(_:)``
- ``SketchPart/requestStrings(_:)``
- ``SketchPart/saveStrings(_:_:)``
- ``SketchPart/loadBytes(_:)``
- ``SketchPart/requestBytes(_:)``
- ``SketchPart/saveBytes(_:_:)``
- ``SketchPart/loadTable(_:header:)``
- ``SketchPart/requestTable(_:header:)``
- ``SketchPart/saveTable(_:_:)``
- ``Table``
- ``TableRow``
- ``DataFailure``

### JSON と XML をファイルと URL から読む

- ``SketchPart/loadJSONObject(_:)``
- ``SketchPart/requestJSONObject(_:)``
- ``SketchPart/parseJSONObject(_:)``
- ``SketchPart/saveJSONObject(_:_:)``
- ``SketchPart/loadJSONArray(_:)``
- ``SketchPart/requestJSONArray(_:)``
- ``SketchPart/parseJSONArray(_:)``
- ``SketchPart/saveJSONArray(_:_:)``
- ``SketchPart/loadXML(_:)``
- ``SketchPart/requestXML(_:)``
- ``SketchPart/parseXML(_:)``
- ``JSONObject``
- ``JSONArray``
- ``XML``

### 立体を置く

- ``SketchPart/box(_:)``
- ``SketchPart/box(_:_:_:)``
- ``SketchPart/sphere(_:detail:)``
- ``SketchPart/ellipsoid(_:_:_:detail:)``
- ``SketchPart/plane(_:_:)``
- ``SketchPart/cylinder(_:_:detail:)``
- ``SketchPart/cone(_:_:detail:)``
- ``SketchPart/torus(_:_:detail:)``
- ``SketchPart/loadModel(_:normalize:)``
- ``SketchPart/requestModel(_:normalize:)``
- ``SketchPart/model(_:)``
- ``Model``
- ``ModelFailure``

### 視点と投影

- ``SketchPart/camera()``
- ``SketchPart/camera(_:_:_:_:_:_:_:_:_:)``
- ``SketchPart/camera(eye:center:up:)``
- ``SketchPart/currentCamera``
- ``SketchPart/setCamera(_:)``
- ``SketchPart/perspective()``
- ``SketchPart/perspective(_:_:_:_:)``
- ``SketchPart/perspective(fieldOfView:aspect:near:far:)``
- ``SketchPart/ortho()``
- ``SketchPart/ortho(_:_:_:_:_:_:)``
- ``SketchPart/ortho(left:right:bottom:top:near:far:)``
- ``SketchPart/orbitControl(_:_:_:)``
- ``SketchPart/orbit``
- ``Camera``
- ``Orbit``

### 画面上の位置と空間の位置

- ``SketchPart/screenX(_:_:)``
- ``SketchPart/screenY(_:_:)``
- ``SketchPart/screenX(_:_:_:)``
- ``SketchPart/screenY(_:_:_:)``
- ``SketchPart/screenZ(_:_:_:)``
- ``SketchPart/spacePosition(screenX:screenY:depth:)``

### 光と質感

- ``SketchPart/ambientLight(_:)-9q8nf``
- ``SketchPart/ambientLight(_:)-9m0dl``
- ``SketchPart/ambientLight(_:_:_:)``
- ``SketchPart/directionalLight(_:_:_:_:)``
- ``SketchPart/directionalLight(_:_:_:_:_:_:)``
- ``SketchPart/directionalLight(color:direction:)``
- ``SketchPart/pointLight(_:_:_:_:)``
- ``SketchPart/pointLight(_:_:_:_:_:_:)``
- ``SketchPart/pointLight(color:position:)``
- ``SketchPart/spotLight(_:_:_:_:_:_:_:angle:)``
- ``SketchPart/spotLight(_:_:_:_:_:_:_:_:_:angle:)``
- ``SketchPart/spotLight(color:position:direction:angle:)``
- ``SketchPart/lights()``
- ``SketchPart/noLights()``
- ``SketchPart/shininess(_:)``
- ``SketchPart/metalness(_:)``
- ``SketchPart/ambient(_:)-8q7z3``
- ``SketchPart/ambient(_:)-4oh49``
- ``SketchPart/ambient(_:_:_:)``
- ``SketchPart/emissive(_:)-4sz2r``
- ``SketchPart/emissive(_:)-4v2ue``
- ``SketchPart/emissive(_:_:_:)``
- ``SketchPart/surroundings(_:)``
- ``SketchPart/background(_:)-15069``
- ``Surroundings``

### 影を落とす

- ``SketchPart/shadows(_:)``
- ``SketchPart/shadowRange(_:)``
- ``SketchPart/shadowDetail(_:)``
- ``SketchPart/shadowBias(_:)``
- ``SketchPart/castShadow(_:)``
- ``SketchPart/receiveShadow(_:)``

### 乱数とノイズ

- ``SketchPart/random()``
- ``SketchPart/random(_:)-(ScalarConvertible)``
- ``SketchPart/random(_:_:)``
- ``SketchPart/randomGaussian()``
- ``SketchPart/randomGaussian(_:_:)``
- ``SketchPart/randomGaussian(mean:standardDeviation:)``
- ``SketchPart/random(_:)-([Element])``
- ``SketchPart/shuffle(_:)``
- ``SketchPart/randomSeed(_:)``
- ``SketchPart/randomSource``
- ``RandomSource``
- ``SketchPart/noise(_:_:_:_:)``
- ``SketchPart/noiseSeed(_:)``
- ``SketchPart/noiseDetail(_:_:)``
- ``SketchPart/noiseDetail(octaves:falloff:)``
- ``NoiseField``

### 角度と数値の変換

- ``PI``
- ``HALF_PI``
- ``QUARTER_PI``
- ``TWO_PI``
- ``TAU``
- ``radians(_:)``
- ``degrees(_:)``
- ``map(_:_:_:_:_:)``
- ``map(_:fromLow:fromHigh:toLow:toHigh:)``
- ``lerp(_:_:_:)``
- ``lerp(_:_:amount:)``
- ``constrain(_:_:_:)``
- ``norm(_:_:_:)``
- ``smoothstep(_:_:_:)``
- ``smoothstep(_:_:x:)``
- ``damp(_:_:_:_:)``
- ``damp(_:toward:lambda:deltaTime:)``
- ``pingpong(_:_:)``
- ``lerpAngle(_:_:_:)``
- ``lerpAngle(_:_:amount:)``
- ``dist(_:_:_:_:)``
- ``dist(_:_:_:_:_:_:)``
- ``dist(_:_:)-(Vector2,_)``
- ``dist(_:_:)-(Vector3,_)``
- ``mag(_:_:)``
- ``mag(_:_:_:)``
- ``sq(_:)``
- ``fract(_:)``
- ``mod(_:_:)``

### GPU に計算させる

- ``SketchPart/loadShader(_:values:surfaces:)``
- ``SketchPart/createShader(_:name:values:surfaces:)``
- ``SketchPart/shader(_:)``
- ``SketchPart/resetShader()``
- ``SketchPart/effects(_:)``
- ``SketchPart/filter(_:)``
- ``SketchPart/loadEffect(_:values:)``
- ``SketchPart/makeEffect(_:name:values:)``
- ``SketchPart/makeNumbers(count:)``
- ``SketchPart/numbers(_:)``
- ``SketchPart/resetNumbers()``
- ``SketchPart/read(_:)``
- ``SketchPart/makeComputation(_:name:values:)``
- ``SketchPart/loadComputation(_:values:)``
- ``SketchPart/compute(_:over:reads:writes:)``
- ``SketchPart/compute(_:over:by:reads:writes:)``
- ``Shader``
- ``EffectShader``
- ``Effect``
- ``Computation``
- ``Numbers``
- ``ShaderValue``
- ``ShaderValueConvertible``
- ``ShaderSurface``
- ``ShaderFailure``

### パーティクル

- ``SketchPart/makeParticles(count:)``
- ``SketchPart/emit(_:from:toward:rate:speed:life:size:color:)``
- ``SketchPart/force(_:_:)``
- ``SketchPart/particles(_:)``
- ``Particles``
- ``Emitter``
- ``Heading``
- ``Force``

### 入力を受ける

- ``SketchPart/mouseX``
- ``SketchPart/mouseY``
- ``SketchPart/pmouseX``
- ``SketchPart/pmouseY``
- ``SketchPart/isMousePressed``
- ``SketchPart/mouseButton``
- ``MouseButton``
- ``SketchPart/scrollX``
- ``SketchPart/scrollY``
- ``SketchPart/pinch``
- ``SketchPart/dragX``
- ``SketchPart/dragY``
- ``SketchPart/movedX``
- ``SketchPart/movedY``
- ``SketchPart/requestPointerLock()``
- ``SketchPart/exitPointerLock()``
- ``SketchPart/noCursor()``
- ``SketchPart/cursor()``
- ``SketchPart/focused``
- ``SketchPart/windowTitle(_:)``
- ``SketchPart/keyboard``
- ``Keyboard``
- ``SketchPart/key``
- ``SketchPart/keyCode``
- ``Key``
- ``Sketch/mousePressed()``
- ``Sketch/mouseReleased()``
- ``Sketch/mouseClicked()``
- ``Sketch/mouseWheel(deltaX:deltaY:)``
- ``Sketch/fileDropped(_:)``
- ``SketchPart/selectInput(_:)``
- ``SketchPart/selectOutput(_:)``
- ``SketchPart/selectFolder(_:)``
- ``Sketch/mouseMoved()``
- ``Sketch/mouseMoved(deltaX:deltaY:)``
- ``Sketch/mouseDragged()``
- ``Sketch/mouseDragged(deltaX:deltaY:)``
- ``Sketch/keyPressed()``
- ``Sketch/keyReleased()``
- ``Sketch/keyTyped()``

### ゲームパッドで動かす

- ``Sketch/gamepads()``
- ``Sketch/createGamepad(inputs:)``
- ``Gamepad``
- ``GamepadButton``
- ``GamepadInput``

### MIDI 機器で動かす

- ``Sketch/midiDevices()``
- ``Sketch/createMIDI(_:)``
- ``Sketch/createMIDI(messages:)``
- ``MIDIPort``
- ``MIDIDevice``
- ``MIDIMessage``

### 映像から手を検出する

- ``Sketch/createHandPose(results:)``
- ``HandPose``
- ``HandPoseResult``
- ``Hand``
- ``HandJoint``
- ``HandJointName``
- ``Handedness``

### ゲームを作る

- ``Scene``
- ``ArcadeBody``
- ``Camera2D``

### 実行中に値を調整する

- ``Sketch/params``
- ``Param(name:)``
- ``Param(_:name:)-4a6pu``
- ``Param(_:name:)-4ddav``
- ``Param(_:step:name:)``
- ``Param(choices:name:)``
- ``ParamValue``
- ``ParamRange``
- ``ParamDeclaration``
- ``ParamRepresentable``

### 値を観測に公開する

- ``SketchPart/expose(_:_:)-42vn6``
- ``SketchPart/measure(_:_:)``

### 数を渡す

描画へ渡す数は `Float`・`Double`・`Int` のどれで持っていてもよい。受け取る型を広く
してあり、中では `Float` として扱われる。

- ``ScalarConvertible``

### プラグインで機能を追加する

- ``Plugin``
- ``PluginRegistry``
- ``Inlet``
- ``SoundSource``
- ``SoundWindow``
- ``Outlet``
- ``SketchPart/attach(_:)-7pu5o``
- ``SketchPart/attach(_:)-998z2``
- ``SketchPart/detach(_:)-6ouvr``
- ``SketchPart/detach(_:)-34bcb``
- ``ExternalInput``
- ``ExternalQueue``
- ``SourceState``
- ``SourceReport``
- ``Arrival``
- ``OutputFrame``
- ``RenderDevice``
- ``RenderTarget``
- ``RenderFailure``

### ウィンドウを出さずにスケッチを走らせる

道具・外のパッケージ・検査のための口で、`import MokumeHost` で使う。スケッチを 1 フレームずつ進め、
描いた絵を値で読み、入力を注入する。後始末は口が持つ。

- ``HeadlessRun``
- ``InputEvent``
