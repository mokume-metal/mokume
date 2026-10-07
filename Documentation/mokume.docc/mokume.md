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

### `import mokume` で通る語彙

**面に記号のページが無くても、この 1 行で書けるものがある。** 三角関数 7 本 — `sin` / `cos` / `tan` / `asin` / `acos` / `atan` / `atan2` — は名指しで通してあるので、`import Foundation` を足さずにそのまま呼べる。角度の単位は radian で、``Sketch/rotate(_:)`` に渡す値と同じである。度で書きたいときは ``radians(_:)`` を通す (こちらは mokume 自身の口なので、下にページがある)。

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

描き方は面ごとに持つ — 描き場所 (``Sketch/createGraphics(_:_:)``) で塗りを変えても、画面の塗りは変わらない。**揺らぎの種と細かさだけはスケッチに 1 つ**で、画面と描き場所が同じものを読み書きする (``Sketch/noiseSeed(_:)``)。断片の `mokume_noise` が、どの面でも ``Sketch/noise(_:_:_:)`` と同じ模様を出すためである。

**乱数の種 (``Sketch/randomSeed(_:)``) もスケッチに 1 つで、書き換えるまでフレームを越えて残る**が、上の 2 つには入らない — 描き方でもシーンの記述でもなく、引くたびに進む列の位置で、揺らぎと違って断片へは届かない。形の組み立て (``Sketch/createShape(_:)``) の中で書いた種だけは、抜けると**最初に書く直前の列**へ戻る。

`setup()` は最初のフレームが始まる前に走るので、**そこに書いたシーンの記述はどのフレームにも属さない**。黙って捨てず、警告を出して無視する。

**置いたもの (図形・絵・背景・画素の書き込み) は設定ではなく、次に描くフレームに出る。** `setup()` と、止まっている間 (``Sketch/noLoop()``) の入力のコールバックで置いたものは、次に描くフレームへ持ち越される — `setup()` だけで 1 枚を描ける。描き場所 (``Sketch/createGraphics(_:_:)``) では ``Canvas/beginDraw()`` と ``Canvas/endDraw()`` の間でだけ置ける。それ以外 (描き場所の対の外・`Task` の続きなど) で置いたものは、警告を出して無視する。

**寿命と、積めるかどうかは別の話である。** 変換はフレームを越えないが ``Sketch/pushMatrix()`` で積める。積んだものもフレームの頭で空に戻るので、`draw()` の中で戻し忘れても次のフレームへは残らない。

**どこに書けるかは寿命を表さない。** 切り抜き (``Sketch/clip(_:_:_:_:)``) は塗りや線と同じところに書けるが、シーンの記述なので越えない。

一つひとつの寿命は、それぞれの説明に付けた `Note` が持つ。

### 作り直しを越えるもの

`mokume watch` で `.swift` を保存すると、スケッチは新しいプロセスで作り直されます。
**フレームを越える状態も、この作り直しでは最初から始まります。** 本体が引き継ぐのは次の2種類です。

| 残るもの | 引き継ぎ方 |
| --- | --- |
| ``Param(name:)`` の保存済みの値 | `.mokume/state/params.json` から、起動時に1回、名前と型が一致する値を戻します |
| `watch` が持つ作品の窓 | スケッチを入れ替えても窓は残るため、位置・全画面・置いた画面を保ちます |

それ以外は引き継ぎません。作者の変数や配列、`frameCount` と `time`、乱数の列、描いた絵、
``Sketch/createGraphics(_:_:)`` の中身、粒や計算の状態、`orbitControl` で回した視点は、
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

**個数・添字・細かさは `Int` のままです。** `sphere(半径, detail:)` の `detail`、画素の添字
(``Sketch/get(_:_:)``)、乱数の種 (``Sketch/randomSeed(_:)``) のような「数え上げ」は `Int` で
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
- ``SketchSettings``
- ``Sketch/init()``
- ``Sketch/setup()``
- ``Sketch/draw()``
- ``Sketch/settings``
- ``Sketch/plugins``

### 面の大きさと時間

- ``Sketch/width``
- ``Sketch/height``
- ``Sketch/pixelWidth``
- ``Sketch/pixelHeight``
- ``Sketch/canvas``
- ``Sketch/frameCount``
- ``Sketch/time``
- ``Sketch/deltaTime``
- ``Sketch/usesFrameHistory``
- ``Upscale``

### 下地と色

- ``Sketch/background(_:)-2yb9n``
- ``Sketch/background(_:_:)``
- ``Sketch/background(_:_:_:_:)``
- ``Sketch/fill(_:)``
- ``Sketch/fill(_:_:)-(ScalarConvertible,_)``
- ``Sketch/fill(_:_:)-(LinearRGBA,_)``
- ``Sketch/fill(_:_:_:_:)``
- ``Sketch/noFill()``
- ``Sketch/stroke(_:)``
- ``Sketch/stroke(_:_:)-(ScalarConvertible,_)``
- ``Sketch/stroke(_:_:)-(LinearRGBA,_)``
- ``Sketch/stroke(_:_:_:_:)``
- ``Sketch/noStroke()``
- ``Sketch/tint(_:)``
- ``Sketch/tint(_:_:)``
- ``Sketch/tint(_:_:_:_:)``
- ``Sketch/noTint()``
- ``Sketch/blendMode(_:)``
- ``Sketch/exposure(_:)``
- ``Sketch/toneMapping(_:)``
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

- ``Sketch/strokeWeight(_:)``
- ``Sketch/strokeCap(_:)``
- ``Sketch/strokeJoin(_:)``
- ``StrokeCap``
- ``StrokeJoin``

### 2D の図形

- ``Sketch/rect(_:_:_:_:)``
- ``Sketch/square(_:_:_:)``
- ``Sketch/circle(_:_:_:)``
- ``Sketch/ellipse(_:_:_:_:)``
- ``Sketch/arc(_:_:_:_:_:_:)``
- ``Sketch/triangle(_:_:_:_:_:_:)``
- ``Sketch/quad(_:_:_:_:_:_:_:_:)``
- ``Sketch/point(_:_:)``
- ``Sketch/line(_:_:_:_:)``

### 座標の読み方

- ``Sketch/rectMode(_:)``
- ``Sketch/ellipseMode(_:)``
- ``Sketch/imageMode(_:)``
- ``ShapeMode``

### 自分で形を組む

- ``Sketch/beginShape(_:)``
- ``Sketch/vertex(_:_:)``
- ``Sketch/vertex(_:_:_:)``
- ``Sketch/vertex(_:_:_:_:)``
- ``Sketch/vertex(_:_:_:_:_:)``
- ``Sketch/index(_:)``
- ``Sketch/normal(_:_:_:)``
- ``Sketch/bezierVertex(_:_:_:_:_:_:)``
- ``Sketch/quadraticVertex(_:_:_:_:)``
- ``Sketch/curveVertex(_:_:)``
- ``Sketch/curveDetail(_:)``
- ``Sketch/curveTightness(_:)``
- ``Sketch/beginContour()``
- ``Sketch/endContour()``
- ``Sketch/endShape(_:)``
- ``ShapeEnd``
- ``VertexKind``

### 形を保持して置く

- ``Sketch/createShape(_:)``
- ``Sketch/loadShape(_:)``
- ``Sketch/requestShape(_:)``
- ``Sketch/shape(_:_:_:)``
- ``Sketch/shape(_:at:)``
- ``Shape``
- ``Placement``

### 座標を動かす

- ``Sketch/translate(_:_:)``
- ``Sketch/translate(_:_:_:)``
- ``Sketch/rotate(_:)``
- ``Sketch/rotateX(_:)``
- ``Sketch/rotateY(_:)``
- ``Sketch/rotateZ(_:)``
- ``Sketch/scale(_:_:)``
- ``Sketch/scale(_:_:_:)``
- ``Sketch/shearX(_:)``
- ``Sketch/shearY(_:)``
- ``Sketch/applyMatrix(_:)``
- ``Sketch/resetMatrix()``
- ``Transform``

### 積んで戻す

- ``Sketch/pushMatrix()``
- ``Sketch/popMatrix()``
- ``Sketch/pushStyle()``
- ``Sketch/popStyle()``
- ``Sketch/push()``
- ``Sketch/pop()``

### 切り抜く

- ``Sketch/clip(_:_:_:_:)``
- ``Sketch/noClip()``

### 文字を描く

- ``Sketch/text(_:_:_:)``
- ``Sketch/text(_:_:_:_:_:)``
- ``Sketch/textSize(_:)``
- ``Sketch/textFont(_:)``
- ``Sketch/noTextFont()``
- ``Sketch/textStyle(_:)``
- ``Sketch/textAlign(_:_:)``
- ``Sketch/textLeading(_:)``
- ``Sketch/textWrap(_:)``
- ``Sketch/textWidth(_:)``
- ``Sketch/textAscent()``
- ``Sketch/textDescent()``
- ``Sketch/textOutline(_:_:_:)``
- ``Sketch/textBounds(_:_:_:)``
- ``TextStyle``
- ``TextWrap``
- ``TextFlow``
- ``TextContour``
- ``TextBounds``
- ``HorizontalTextAlign``
- ``VerticalTextAlign``

### 絵を置く

- ``Sketch/loadImage(_:)``
- ``Sketch/requestImage(_:)``
- ``Sketch/createImage(_:_:)``
- ``Sketch/image(_:_:_:)-7x24``
- ``Sketch/image(_:_:_:_:_:)-4y6h0``
- ``Sketch/image(_:_:_:_:_:_:_:_:_:)-1n37``
- ``Sketch/texture(_:)-9gngo``
- ``Sketch/noTexture()``
- ``Image``
- ``ImageFailure``
- ``DisplayImage``
- ``Sketch/assetURL(_:)``
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

### 画素を読み書きする

- ``Sketch/pixels``
- ``Sketch/loadPixels()``
- ``Sketch/get(_:_:)``
- ``Sketch/set(_:_:_:)``
- ``Pixels``
- ``PixelBuffer``

### 別の描き場所に描く

- ``Sketch/createGraphics(_:_:)``
- ``Sketch/image(_:_:_:)-967ro``
- ``Sketch/image(_:_:_:_:_:)-3ps7b``
- ``Sketch/image(_:_:_:_:_:_:_:_:_:)-8kr2y``
- ``Sketch/texture(_:)-5gdhl``
- ``Canvas``

### 書き出す

- ``Sketch/save(_:)``
- ``Sketch/beginRecord(_:)``
- ``Sketch/endRecord()``
- ``PNGFile``
- ``ImageWriteFailure``

### 文字列と表を読み書きする

- ``Sketch/loadStrings(_:)``
- ``Sketch/requestStrings(_:)``
- ``Sketch/loadTable(_:header:)``
- ``Sketch/requestTable(_:header:)``
- ``Sketch/saveTable(_:_:)``
- ``Table``
- ``TableRow``
- ``DataFailure``

### JSON と XML をファイルと URL から読む

- ``Sketch/loadJSONObject(_:)``
- ``Sketch/requestJSONObject(_:)``
- ``Sketch/loadXML(_:)``
- ``Sketch/requestXML(_:)``
- ``JSONObject``
- ``XML``

### 立体を置く

- ``Sketch/box(_:)``
- ``Sketch/box(_:_:_:)``
- ``Sketch/sphere(_:detail:)``
- ``Sketch/ellipsoid(_:_:_:detail:)``
- ``Sketch/plane(_:_:)``
- ``Sketch/cylinder(_:_:detail:)``
- ``Sketch/cone(_:_:detail:)``
- ``Sketch/torus(_:_:detail:)``
- ``Sketch/loadModel(_:normalize:)``
- ``Sketch/requestModel(_:normalize:)``
- ``Sketch/model(_:)``
- ``Model``
- ``ModelFailure``

### 視点と投影

- ``Sketch/camera()``
- ``Sketch/camera(_:_:_:_:_:_:_:_:_:)``
- ``Sketch/currentCamera``
- ``Sketch/setCamera(_:)``
- ``Sketch/perspective()``
- ``Sketch/perspective(_:_:_:_:)``
- ``Sketch/ortho()``
- ``Sketch/ortho(_:_:_:_:_:_:)``
- ``Sketch/orbitControl(_:_:_:)``
- ``Sketch/orbit``
- ``Camera``
- ``Orbit``

### 面の位置と空間の位置

- ``Sketch/screenX(_:_:)``
- ``Sketch/screenY(_:_:)``
- ``Sketch/screenX(_:_:_:)``
- ``Sketch/screenY(_:_:_:)``
- ``Sketch/screenZ(_:_:_:)``
- ``Sketch/spacePosition(screenX:screenY:depth:)``

### 光と質感

- ``Sketch/ambientLight(_:)-fvb5``
- ``Sketch/ambientLight(_:)-51q6x``
- ``Sketch/ambientLight(_:_:_:)``
- ``Sketch/directionalLight(_:_:_:_:)``
- ``Sketch/directionalLight(_:_:_:_:_:_:)``
- ``Sketch/pointLight(_:_:_:_:)``
- ``Sketch/pointLight(_:_:_:_:_:_:)``
- ``Sketch/spotLight(_:_:_:_:_:_:_:angle:)``
- ``Sketch/spotLight(_:_:_:_:_:_:_:_:_:angle:)``
- ``Sketch/lights()``
- ``Sketch/noLights()``
- ``Sketch/shininess(_:)``
- ``Sketch/metalness(_:)``
- ``Sketch/ambient(_:)-9anin``
- ``Sketch/ambient(_:)-9pxes``
- ``Sketch/ambient(_:_:_:)``
- ``Sketch/emissive(_:)-uyuh``
- ``Sketch/emissive(_:)-55jid``
- ``Sketch/emissive(_:_:_:)``
- ``Sketch/surroundings(_:)``
- ``Sketch/background(_:)-1085h``
- ``Surroundings``

### 影を落とす

- ``Sketch/shadows(_:)``
- ``Sketch/shadowRange(_:)``
- ``Sketch/shadowDetail(_:)``
- ``Sketch/shadowBias(_:)``
- ``Sketch/castShadow(_:)``
- ``Sketch/receiveShadow(_:)``

### 乱数と揺らぎ

- ``Sketch/random()``
- ``Sketch/random(_:)``
- ``Sketch/random(_:_:)``
- ``Sketch/randomSeed(_:)``
- ``Sketch/noise(_:_:_:)``
- ``Sketch/noiseSeed(_:)``
- ``Sketch/noiseDetail(_:_:)``

### 角度と数を直す

- ``radians(_:)``
- ``degrees(_:)``
- ``map(_:_:_:_:_:)``
- ``lerp(_:_:_:)``
- ``constrain(_:_:_:)``
- ``norm(_:_:_:)``
- ``smoothstep(_:_:_:)``

### GPU に計算させる

- ``Sketch/loadShader(_:values:surfaces:)``
- ``Sketch/makeShader(_:name:values:surfaces:)``
- ``Sketch/shader(_:)``
- ``Sketch/resetShader()``
- ``Sketch/effects(_:)``
- ``Sketch/loadEffect(_:values:)``
- ``Sketch/makeEffect(_:name:values:)``
- ``Sketch/makeNumbers(count:)``
- ``Sketch/numbers(_:)``
- ``Sketch/resetNumbers()``
- ``Sketch/read(_:)``
- ``Sketch/makeComputation(_:name:values:)``
- ``Sketch/loadComputation(_:values:)``
- ``Sketch/compute(_:over:reads:writes:)``
- ``Sketch/compute(_:over:by:reads:writes:)``
- ``Shader``
- ``EffectShader``
- ``Effect``
- ``Computation``
- ``Numbers``
- ``ShaderValue``
- ``ShaderSurface``
- ``ShaderFailure``

### 粒を飛ばす

- ``Sketch/makeParticles(count:)``
- ``Sketch/emit(_:from:toward:rate:speed:life:size:color:)``
- ``Sketch/force(_:_:)``
- ``Sketch/particles(_:)``
- ``Particles``
- ``Emitter``
- ``Heading``
- ``Force``

### 入力を受ける

- ``Sketch/mouseX``
- ``Sketch/mouseY``
- ``Sketch/pmouseX``
- ``Sketch/pmouseY``
- ``Sketch/isMousePressed``
- ``Sketch/mouseButton``
- ``MouseButton``
- ``Sketch/scrollX``
- ``Sketch/scrollY``
- ``Sketch/dragX``
- ``Sketch/dragY``
- ``Sketch/movedX``
- ``Sketch/movedY``
- ``Sketch/requestPointerLock()``
- ``Sketch/exitPointerLock()``
- ``Sketch/isKeyDown(_:)``
- ``Sketch/key``
- ``Sketch/keyCode``
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

- ``Sketch/expose(_:_:)-19rp8``
- ``Sketch/measure(_:_:)``

### 数を渡す

描画へ渡す数は `Float`・`Double`・`Int` のどれで持っていても構いません。受け口が広く取って
あり、中では `Float` として扱われます。

- ``ScalarConvertible``

### 外から機能を足す

- ``Plugin``
- ``PluginRegistry``
- ``Inlet``
- ``Outlet``
- ``Sketch/attach(_:)-4awn``
- ``Sketch/attach(_:)-7p1nk``
- ``Sketch/detach(_:)-256sb``
- ``Sketch/detach(_:)-7cw8l``
- ``ExternalInput``
- ``SourceState``
- ``SourceReport``
- ``Arrival``
- ``OutputFrame``
- ``RenderDevice``
- ``RenderTarget``
- ``RenderFailure``
