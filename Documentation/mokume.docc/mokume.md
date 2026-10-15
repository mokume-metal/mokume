# ``mokume``

<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT

帰属のヘッダは**題より後ろ**に置く。先頭に置くと docc が題を見つけられず、
「An article is expected to start with a top-level heading title」の警告 1 本を
残したまま、このページの説明も Topics も丸ごと落ちる (実測)。落ちても変換は
成功するので、気付けるのは公開物を見たときだけになる。
-->

スケッチを書くための面。絵を描く・音や入力を受ける・書き出す・観測する口がここに揃っている。

## Overview

利用者が書くのは `import mokume` の 1 行で、内部の層の割り方は書き味にも面にも漏れない。この面に並んでいるのは、その 1 行で書けるようになるものである。

```swift
import mokume

final class Hello: Sketch {
    func draw() {
        background(15, 18, 23)
        circle(width / 2, height / 2, 120)
    }
}
```

### 自作の型で語彙を使う

**自分で書いた型に `: SketchPart` を付けると、その中でも `fill()`・`circle()`・`mouseX`・`random()` がそのまま使える。** Processing でタブに書いたクラスの中から `fill()` を呼ぶのと同じ書き方になる。``Sketch`` は ``SketchPart`` を継いでいるので、スケッチの中では何も付けずに使える。

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

語彙は、呼んだ時点で走っているスケッチへ描き、そのスケッチの状態を読む。付けずに `fill()` を書くと「`fill` が見つからない」で止まる。色を作る ``color(_:_:)`` のような純粋な計算は、付けなくてもどこからでも呼べる。

**走る前 (部品の `init()` の中) に呼んでも落ちない。** 読み取りは 0 や空を返し (``SketchPart/width`` は 0)、描く口は何もしない。どちらも口ごとに 1 度だけ警告し、警告は観測の応答にも載る。面の大きさで決まる値は、``Sketch/setup()`` の中で部品を作り直して決める。後片付けの後と、``Sketch/draw()`` で起こした `Task` の中から呼んだときも同じである。面から作る資源 (``SketchPart/createGraphics(_:_:)``・``SketchPart/loadImage(_:)`` など) だけは、返すものを作れないので止まる。

### `import mokume` で通る語彙

**面に記号のページが無くても、この 1 行で書けるものがある。** 三角関数 7 本 — `sin` / `cos` / `tan` / `asin` / `acos` / `atan` / `atan2` — は名指しで通してあるので、`import Foundation` を足さずにそのまま呼べる。角度の単位は radian で、``SketchPart/rotate(_:)`` に渡す値と同じである。度で書きたいときは ``radians(_:)`` を通す (こちらは mokume 自身の口なので、下にページがある)。

```swift
circle(200 + cos(time) * 80, 150 + sin(time) * 80, 40)
```

**説明の正典は標準ライブラリの側にある**ので、この面はページを持たない。ここに書いてあるのは「通る」ことだけである。

[mokume の入口](../../) — 入れ方と最初の 1 本はこちら。

**この面に出ている説明は、すべてソースの `///` から組み立てられている。** 説明を直したいときは実装の隣を直す。機械が一度に読むための一覧が要るときは、版ごとの Release に載る公開 API の一覧を使う — こちらは人が読むための面で、同じ説明の別の配り方になっている。

### 状態の寿命

**書いた設定がいつまで効くかは、2 つに分かれる。**

| 種類 | 寿命 | 何が入るか |
| --- | --- | --- |
| **描き方** (どう描くか) | フレームを越える。一度書けば書き換えるまで残る | 塗り・線の色と太さ・端と折れ目の形・混ぜ方・座標の読み方・文字の設定・絵に掛ける色・貼る絵・断片・断片が読む数の並び・揺らぎの種と細かさ・露出 |
| **シーンの記述** (何を描くか) | 越えない。`draw()` の中で毎フレーム書く | 視点・投影・光・材質・変換・影・周囲の光・効果・切り抜き |

描き方は面ごとに持つ — 描き場所 (``SketchPart/createGraphics(_:_:)``) で塗りを変えても、画面の塗りは変わらない。**揺らぎの種と細かさだけはスケッチに 1 つ**で、画面と描き場所が同じものを読み書きする (``SketchPart/noiseSeed(_:)``)。断片の `mokume_noise` が、どの面でも ``SketchPart/noise(_:_:_:)`` と同じ模様を出すためである。

**乱数の種 (``SketchPart/randomSeed(_:)``) もスケッチに 1 つで、書き換えるまでフレームを越えて残る**が、上の 2 つには入らない — 描き方でもシーンの記述でもなく、引くたびに進む列の位置で、揺らぎと違って断片へは届かない。形の組み立て (``SketchPart/createShape(_:)``) の中で書いた種だけは、抜けると**最初に書く直前の列**へ戻る。

`setup()` は最初のフレームが始まる前に走るので、**そこに書いたシーンの記述はどのフレームにも属さない**。黙って捨てず、警告を出して無視する。

**置いたもの (図形・絵・背景・画素の書き込み) は設定ではなく、次に描くフレームに出る。** `setup()` と、止まっている間 (``SketchPart/noLoop()``) の入力のコールバックで置いたものは、次に描くフレームへ持ち越される — `setup()` だけで 1 枚を描ける。描き場所 (``SketchPart/createGraphics(_:_:)``) では ``Canvas/beginDraw()`` と ``Canvas/endDraw()`` の間でだけ置ける。それ以外 (描き場所の対の外・`Task` の続きなど) で置いたものは、警告を出して無視する。

**寿命と、積めるかどうかは別の話である。** 変換はフレームを越えないが ``SketchPart/pushMatrix()`` で積める。積んだものもフレームの頭で空に戻るので、`draw()` の中で戻し忘れても次のフレームへは残らない。

**どこに書けるかは寿命を表さない。** 切り抜き (``SketchPart/clip(_:_:_:_:)``) は塗りや線と同じところに書けるが、シーンの記述なので越えない。

一つひとつの寿命は、それぞれの説明に付けた `Note` が持つ。

### 作り直しを越えるもの

`mokume watch` で `.swift` を保存すると、スケッチは新しいプロセスで作り直されます。
資材の置き場 (`Sources/<名前>/assets/`) のファイルを足したり保存したりしたときも、ビルドが資材を写し直すので同じく作り直します。
**フレームを越える状態も、この作り直しでは最初から始まります。** 本体が引き継ぐのは次の2種類です。

| 残るもの | 引き継ぎ方 |
| --- | --- |
| ``Param(name:)`` の保存済みの値 | `.mokume/state/params.json` から、起動時に1回、名前と型が一致する値を戻します |
| `watch` が持つ作品の窓 | スケッチを入れ替えても窓は残るため、位置・全画面・置いた画面を保ちます |

それ以外は引き継ぎません。作者の変数や配列、`frameCount` と `time`、乱数の列、描いた絵、
``SketchPart/createGraphics(_:_:)`` の中身、粒や計算の状態、`orbitControl` で回した視点は、
新しいスケッチの初期状態から始まります。窓に絵が途切れず表示されていても、内部の状態を運んでいるわけではありません。

例えば、`@Param` で球の半径を調整し、自分の変数 `playhead` で再生位置を持っている作品で、
Swift の色を変えて保存すると、保存済みの半径と窓は残りますが、`playhead` はコードの初期値へ戻ります。
作者の任意の状態を作り直しの後へ運ぶ口は、いまの本体にはありません。

**`.metal` の断片を保存したときは、プロセスを作り直しません。** 走らせたまま断片を差し替えるので、
上に挙げたプロセス内の状態は残ります。

**保存された `@Param` の値は作品の正典ではありません。** 保存は手元の続きを返すためのものです。
作品として残したい値は、コードの既定値へ書き戻してください。

### 同じ時刻の絵を比較する

MCP の `observe` に `{"time": 3}` を渡すと、走っているスケッチを3秒目で1枚描き直して撮れます。
Swift の色などを編集して保存した後、もう一度同じ秒を指定すれば、同じ構図で比較できます。
適用できた応答には `appliedTime` があり、画像の時刻と一致します。古い版の作品が指定を無視した場合は、
MCP が作品側の mokume の更新を案内します。`time` を省けば、通常の観測です。

**時刻以外の状態は戻りません。** 時刻から絵が決まる作品向けで、変数の更新・乱数・描いた絵の蓄積など、
`draw()` の副作用は残ります。画面にも指定時刻の絵が出て、`deltaTime` は0、`frameCount` は1進みます。
次の通常フレームは元の時計に戻るため、保存後も自動でその場面に留まる機能ではありません。

撮れるのは1枚だけで、`count` と `every` は1に限ります。`noLoop()` 中も1枚描いて停止を保ちますが、
外部からの停止中、録画中では指定時刻の要求を断ります。指定の枚の中から連続録画を始めることもできません。

### 数の型

**変数を渡すときは型を気にしなくて構いません。** 描画へ渡す数は `Float`・`Double`・`Int` の
どれで持っていても通ります。

```swift
let gap = 120.0                      // Swift は Double に推論します
circle(gap, gap, 40)                 // そのまま渡せます
for i in 0..<255 { fill(i, 0, 0) }   // ループ変数 (Int) もそのまま
```

**中では `Float` として扱われます。** 面が返す数 — `width` / `height` / `time` / `random()` /
`noise()` / `map()` — はすべて `Float` です。GPU が 32 bit で動くので、そこに合わせてあります。

**変換が要るのは、面が返した数と自分の数を混ぜて計算するときだけです。** Swift は型の違う数
どうしの計算を許さないので、片方を揃えます。

```swift
let columns = 6                          // Int
let step = width / Float(columns)        // width は Float。Float へ揃えます
for index in 0..<columns {
    let ratio = Float(index) / Float(columns)
    circle(step * Float(index), height * ratio, 20)
}
```

**添字と `width` を混ぜる式は、誤りが `width` のほうを指します。** `i * width / count` のように
`Int` の添字と `Float` を同じ式に書くと通りません。ところが渡す先が型を決めなくなったので、
コンパイラは式を `Int` で解こうとして、**添字ではなく `width` を「`Int` ではない」と名指しします**。
言われたとおりに `width` を `Int` にするのではなく、直すのは添字の側です (`Float(i)`):

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

**添字を経ずに `Float` のまま回すなら、標準の `stride` が使えます。** 変換を書かずに済みます。

```swift
let step = width / 6
for x in stride(from: Float(0), to: width, by: step) {
    circle(x, height / 2, 10)
}
```

**個数・添字・細かさは `Int` のままです。** `sphere(半径, detail:)` の `detail`、画素の添字
(``SketchPart/get(_:_:)``)、乱数の種 (``SketchPart/randomSeed(_:)``) のような「数え上げ」は `Int` で
受けます。半分の個数や 1.5 番目の画素は無いからです。

**割り算を書くときは、片方に小数点を付けます。** 渡す先が型を決めなくなったので、整数だけで
書いた式は整数のまま計算されます。**通ってしまう**ので、描かれる絵で気付くことになります。

```swift
circle(width / 2, height / 2, 1 / 2)     // 直径が 0 になり、何も描かれません
circle(width / 2, height / 2, 1 / 2.0)   // 0.5 が渡ります
fill(255, 255 * 50 / 100)                // 127 になります
fill(255, 255 * 50 / 100.0)              // 127.5 が渡ります
```

`width` や `time` のように**面が返した数が式に入っていれば、そのまま書けます** — 全体が
`Float` として計算されるからです (上の `width / 2` がそれです)。

**`.pi` のような書き方は、型を名乗ります。** 渡す先が型を決めなくなったので、`.pi` だけでは
`Float` と `Double` のどちらか決まりません。

```swift
rotate(Float.pi / 2)                     // 型を名乗ります
let turn = width / 400                   // Float
rotate(turn * .pi)                       // 他の項が Float なら .pi のままで通ります
```

## Topics

### スケッチを書く

- ``Sketch``
- ``SketchPart``
- ``SketchSettings``
- ``Sketch/init()``
- ``Sketch/setup()``
- ``Sketch/draw()``
- ``Sketch/settings``
- ``Sketch/plugins``

### 面の大きさと時間

- ``SketchPart/width``
- ``SketchPart/height``
- ``SketchPart/pixelWidth``
- ``SketchPart/pixelHeight``
- ``SketchPart/canvas``
- ``SketchPart/frameCount``
- ``SketchPart/time``
- ``SketchPart/deltaTime``
- ``SketchPart/clock``
- ``Clock``
- ``SketchPart/usesFrameHistory``
- ``Upscale``

### 全画面で出す

- ``SketchSettings/fullScreen(_:)``
- ``SketchSettings/fullScreenDisplay``
- ``SketchPart/displays``
- ``Display``

### 下地と色

- ``SketchPart/background(_:)-9jeha``
- ``SketchPart/background(_:_:)``
- ``SketchPart/background(_:_:_:_:)``
- ``SketchPart/fill(_:)``
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
- ``BlendMode``
- ``ToneMapping``

### 色を作る・読む

素の数値は 0–255 の目盛りで、ラベル付きの口は名前が目盛りを名乗る ([ADR-0033](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md))。

- ``color(_:_:)``
- ``color(_:_:_:_:)``
- ``color(hex:)``
- ``color(hue:saturation:brightness:alpha:)``
- ``lerpColor(_:_:_:)``
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
- ``StrokeCap``
- ``StrokeJoin``

### 2D の図形

- ``SketchPart/rect(_:_:_:_:)``
- ``SketchPart/square(_:_:_:)``
- ``SketchPart/circle(_:_:_:)``
- ``SketchPart/ellipse(_:_:_:_:)``
- ``SketchPart/arc(_:_:_:_:_:_:)``
- ``SketchPart/triangle(_:_:_:_:_:_:)``
- ``SketchPart/quad(_:_:_:_:_:_:_:_:)``
- ``SketchPart/point(_:_:)``
- ``SketchPart/line(_:_:_:_:)``

### 座標の読み方

- ``SketchPart/rectMode(_:)``
- ``SketchPart/ellipseMode(_:)``
- ``SketchPart/imageMode(_:)``
- ``ShapeMode``

### 図形を値で持ち歩いて当てる

- ``Rect``
- ``Circle``
- ``Vector2``

### 自分で形を組む

- ``SketchPart/beginShape(_:)``
- ``SketchPart/vertex(_:_:)``
- ``SketchPart/vertex(_:_:_:)``
- ``SketchPart/vertex(_:_:_:_:)``
- ``SketchPart/vertex(_:_:_:_:_:)``
- ``SketchPart/index(_:)``
- ``SketchPart/normal(_:_:_:)``
- ``SketchPart/bezierVertex(_:_:_:_:_:_:)``
- ``SketchPart/quadraticVertex(_:_:_:_:)``
- ``SketchPart/curveVertex(_:_:)``
- ``SketchPart/curveDetail(_:)``
- ``SketchPart/curveTightness(_:)``
- ``SketchPart/beginContour()``
- ``SketchPart/endContour()``
- ``SketchPart/endShape(_:)``
- ``ShapeEnd``
- ``VertexKind``

### 形を保持して置く

- ``SketchPart/createShape(_:)``
- ``SketchPart/loadShape(_:)``
- ``SketchPart/requestShape(_:)``
- ``SketchPart/shape(_:_:_:)``
- ``SketchPart/shape(_:at:)``
- ``Shape``
- ``Placement``

### 座標を動かす

- ``SketchPart/translate(_:_:)``
- ``SketchPart/translate(_:_:_:)``
- ``SketchPart/rotate(_:)``
- ``SketchPart/rotateX(_:)``
- ``SketchPart/rotateY(_:)``
- ``SketchPart/rotateZ(_:)``
- ``SketchPart/scale(_:_:)``
- ``SketchPart/scale(_:_:_:)``
- ``SketchPart/shearX(_:)``
- ``SketchPart/shearY(_:)``
- ``SketchPart/applyMatrix(_:)``
- ``SketchPart/resetMatrix()``
- ``Transform``

### 積んで戻す

- ``SketchPart/pushMatrix()``
- ``SketchPart/popMatrix()``
- ``SketchPart/pushStyle()``
- ``SketchPart/popStyle()``
- ``SketchPart/push()``
- ``SketchPart/pop()``

### 切り抜く

- ``SketchPart/clip(_:_:_:_:)``
- ``SketchPart/noClip()``

### 文字を描く

- ``SketchPart/text(_:_:_:)``
- ``SketchPart/text(_:_:_:_:_:)``
- ``SketchPart/textSize(_:)``
- ``SketchPart/textFont(_:)``
- ``SketchPart/noTextFont()``
- ``SketchPart/textStyle(_:)``
- ``SketchPart/textAlign(_:_:)``
- ``SketchPart/textLeading(_:)``
- ``SketchPart/textWrap(_:)``
- ``SketchPart/textWidth(_:)``
- ``SketchPart/textAscent()``
- ``SketchPart/textDescent()``
- ``SketchPart/textOutline(_:_:_:)``
- ``SketchPart/textBounds(_:_:_:)``
- ``TextStyle``
- ``TextWrap``
- ``TextFlow``
- ``TextContour``
- ``TextBounds``
- ``HorizontalTextAlign``
- ``VerticalTextAlign``

### 絵を置く

- ``SketchPart/loadImage(_:)``
- ``SketchPart/requestImage(_:)``
- ``SketchPart/createImage(_:_:)``
- ``SketchPart/image(_:_:_:)-23fpf``
- ``SketchPart/image(_:_:_:_:_:)-4ch39``
- ``SketchPart/image(_:_:_:_:_:_:_:_:_:)-6fe4h``
- ``SketchPart/texture(_:)-c9g``
- ``SketchPart/noTexture()``
- ``Image``
- ``ImageFailure``
- ``DisplayImage``
- ``SketchPart/assetURL(_:)``
- ``AssetFailure``

### カメラを使う

- ``Sketch/createCapture(_:_:device:)``
- ``Sketch/createCapture(frames:)``
- ``Sketch/captureDevices()``
- ``Capture``
- ``CaptureDevice``

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
- ``SoundFile``

### 音を合成する

- ``Sketch/createSinOsc()``
- ``Sketch/createSqrOsc()``
- ``Sketch/createTriOsc()``
- ``Sketch/createSawOsc()``
- ``Sketch/createWhiteNoise()``
- ``Sketch/createPinkNoise()``
- ``Sketch/createEnv()``
- ``Sketch/createLowPass()``
- ``Sketch/createHighPass()``
- ``Sketch/createBandPass()``
- ``Sketch/createReverb()``
- ``Sketch/createDelay()``
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
- ``Env``
- ``SoundEffect``
- ``Filter``
- ``LowPass``
- ``HighPass``
- ``BandPass``
- ``Reverb``
- ``Delay``

### OSC で他の道具とやりとりする

- ``Sketch/createOSC(listen:send:)``
- ``Sketch/createOSC(messages:)``
- ``OSCPort``
- ``OSCMessage``
- ``OSCValue``
- ``OSCArgument``
- ``OSCFailure``

### TCP・UDP・WebSocket で他のアプリとやりとりする

- ``Sketch/createTCPServer(_:)``
- ``Sketch/createWebSocketServer(_:)``
- ``Sketch/createUDP(listen:send:)``
- ``Sketch/createTCPServer(messages:)``
- ``Sketch/createWebSocketServer(messages:)``
- ``Sketch/createUDP(messages:)``
- ``TextPort``
- ``TCPServer``
- ``WebSocketServer``
- ``UDPPort``
- ``NetworkFailure``

### 画素を読み書きする

- ``SketchPart/pixels``
- ``SketchPart/loadPixels()``
- ``SketchPart/get(_:_:)``
- ``SketchPart/set(_:_:_:)``
- ``Pixels``
- ``PixelBuffer``

### 別の描き場所に描く

- ``SketchPart/createGraphics(_:_:)``
- ``SketchPart/image(_:_:_:)-7psdx``
- ``SketchPart/image(_:_:_:_:_:)-666br``
- ``SketchPart/image(_:_:_:_:_:_:_:_:_:)-3q9cm``
- ``SketchPart/texture(_:)-6aozc``
- ``Canvas``

### 書き出す

- ``SketchPart/save(_:)``
- ``SketchPart/beginRecord(_:)``
- ``SketchPart/endRecord()``
- ``PNGFile``
- ``ImageWriteFailure``

### 文字列と表を読み書きする

- ``SketchPart/loadStrings(_:)``
- ``SketchPart/requestStrings(_:)``
- ``SketchPart/loadTable(_:header:)``
- ``SketchPart/requestTable(_:header:)``
- ``SketchPart/saveTable(_:_:)``
- ``Table``
- ``TableRow``
- ``DataFailure``

### JSON と XML をファイルと URL から読む

- ``SketchPart/loadJSONObject(_:)``
- ``SketchPart/requestJSONObject(_:)``
- ``SketchPart/loadXML(_:)``
- ``SketchPart/requestXML(_:)``
- ``JSONObject``
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
- ``SketchPart/currentCamera``
- ``SketchPart/setCamera(_:)``
- ``SketchPart/perspective()``
- ``SketchPart/perspective(_:_:_:_:)``
- ``SketchPart/ortho()``
- ``SketchPart/ortho(_:_:_:_:_:_:)``
- ``SketchPart/orbitControl(_:_:_:)``
- ``SketchPart/orbit``
- ``Camera``
- ``Orbit``

### 面の位置と空間の位置

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
- ``SketchPart/pointLight(_:_:_:_:)``
- ``SketchPart/pointLight(_:_:_:_:_:_:)``
- ``SketchPart/spotLight(_:_:_:_:_:_:_:angle:)``
- ``SketchPart/spotLight(_:_:_:_:_:_:_:_:_:angle:)``
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

### 乱数と揺らぎ

- ``SketchPart/random()``
- ``SketchPart/random(_:)``
- ``SketchPart/random(_:_:)``
- ``SketchPart/randomSeed(_:)``
- ``SketchPart/noise(_:_:_:)``
- ``SketchPart/noiseSeed(_:)``
- ``SketchPart/noiseDetail(_:_:)``

### 角度と数を直す

- ``radians(_:)``
- ``degrees(_:)``
- ``map(_:_:_:_:_:)``
- ``lerp(_:_:_:)``
- ``constrain(_:_:_:)``
- ``norm(_:_:_:)``
- ``smoothstep(_:_:_:)``

### GPU に計算させる

- ``SketchPart/loadShader(_:values:surfaces:)``
- ``SketchPart/makeShader(_:name:values:surfaces:)``
- ``SketchPart/shader(_:)``
- ``SketchPart/resetShader()``
- ``SketchPart/effects(_:)``
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
- ``ShaderSurface``
- ``ShaderFailure``

### 粒を飛ばす

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
- ``SketchPart/dragX``
- ``SketchPart/dragY``
- ``SketchPart/movedX``
- ``SketchPart/movedY``
- ``SketchPart/requestPointerLock()``
- ``SketchPart/exitPointerLock()``
- ``SketchPart/keyboard``
- ``Keyboard``
- ``SketchPart/key``
- ``SketchPart/keyCode``
- ``Key``
- ``Sketch/mousePressed()``
- ``Sketch/mouseReleased()``
- ``Sketch/mouseClicked()``
- ``Sketch/mouseWheel(deltaX:deltaY:)``
- ``Sketch/mouseMoved()``
- ``Sketch/mouseMoved(deltaX:deltaY:)``
- ``Sketch/mouseDragged(deltaX:deltaY:)``
- ``Sketch/keyPressed()``
- ``Sketch/keyReleased()``
- ``Sketch/keyTyped()``

### 走らせたまま値を動かす

- ``Sketch/params``
- ``Param(name:)``
- ``Param(_:name:)-4a6pu``
- ``Param(_:name:)-4ddav``
- ``Param(choices:name:)``
- ``ParamValue``
- ``ParamRange``
- ``ParamDeclaration``
- ``ParamRepresentable``

### 観測へ差し出す

- ``SketchPart/expose(_:_:)-42vn6``
- ``SketchPart/measure(_:_:)``

### 数を渡す

描画へ渡す数は `Float`・`Double`・`Int` のどれで持っていても構いません。受け口が広く取って
あり、中では `Float` として扱われます。

- ``ScalarConvertible``

### 外から機能を足す

- ``Plugin``
- ``PluginRegistry``
- ``Inlet``
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
