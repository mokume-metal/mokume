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
        background(.display(red: 0.06, green: 0.07, blue: 0.09))
        circle(width / 2, height / 2, 120)
    }
}
```

### `import mokume` で通る語彙

**面に記号のページが無くても、この 1 行で書けるものがある。** 三角関数 7 本 — `sin` / `cos` / `tan` / `asin` / `acos` / `atan` / `atan2` — は名指しで通してあるので、`import Foundation` を足さずにそのまま呼べる。角度の単位は radian で、``Sketch/rotate(_:)`` に渡す値と同じである。

```swift
circle(200 + cos(time) * 80, 150 + sin(time) * 80, 40)
```

**説明の正典は標準ライブラリの側にある**ので、この面はページを持たない。ここに書いてあるのは「通る」ことだけである。

[mokume の入口](../../) — 入れ方と最初の 1 本はこちら。

**この面に出ている説明は、すべてソースの `///` から組み立てられている。** 説明を直したいときは実装の隣を直す。機械が一度に読むための一覧が要るときは、版ごとの Release に載る公開 API の一覧を使う — こちらは人が読むための面で、同じ説明の別の配り方になっている。

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
- ``Sketch/fill(_:_:)``
- ``Sketch/fill(_:_:_:_:)``
- ``Sketch/noFill()``
- ``Sketch/stroke(_:)``
- ``Sketch/stroke(_:_:)``
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
- ``TextStyle``
- ``TextWrap``
- ``TextFlow``
- ``TextContour``
- ``HorizontalTextAlign``
- ``VerticalTextAlign``

### 絵を置く

- ``Sketch/loadImage(_:)``
- ``Sketch/requestImage(_:)``
- ``Sketch/createImage(_:_:)``
- ``Sketch/image(_:_:_:)-19wv0``
- ``Sketch/image(_:_:_:_:_:)-882gd``
- ``Sketch/image(_:_:_:_:_:_:_:_:_:)-2oyv8``
- ``Sketch/texture(_:)-9gngo``
- ``Sketch/noTexture()``
- ``Image``
- ``ImageFailure``
- ``DisplayImage``

### 画素を読み書きする

- ``Sketch/pixels``
- ``Sketch/loadPixels()``
- ``Sketch/get(_:_:)``
- ``Sketch/set(_:_:_:)``
- ``Pixels``
- ``PixelBuffer``

### 別の描き場所に描く

- ``Sketch/createGraphics(_:_:)``
- ``Sketch/image(_:_:_:)-54avl``
- ``Sketch/image(_:_:_:_:_:)-5wi02``
- ``Sketch/image(_:_:_:_:_:_:_:_:_:)-2crsz``
- ``Sketch/texture(_:)-5gdhl``
- ``Canvas``

### 書き出す

- ``Sketch/save(_:)``
- ``Sketch/beginRecord(_:)``
- ``Sketch/endRecord()``
- ``PNGFile``
- ``ImageWriteFailure``

### 立体を置く

- ``Sketch/box(_:)``
- ``Sketch/box(_:_:_:)``
- ``Sketch/sphere(_:detail:)``
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
- ``Sketch/ambientLight(_:)-8zz3g``
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
- ``Sketch/ambient(_:)-6gfzl``
- ``Sketch/ambient(_:_:_:)``
- ``Sketch/emissive(_:)-uyuh``
- ``Sketch/emissive(_:)-609c2``
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
- ``Sketch/emit(_:from:rate:speed:angle:life:size:color:)``
- ``Sketch/force(_:_:)``
- ``Sketch/particles(_:)``
- ``Particles``
- ``Emitter``
- ``Force``

### 入力を受ける

- ``Sketch/mouseX``
- ``Sketch/mouseY``
- ``Sketch/pmouseX``
- ``Sketch/pmouseY``
- ``Sketch/isMousePressed``
- ``Sketch/mouseButton``
- ``Sketch/scrollX``
- ``Sketch/scrollY``
- ``Sketch/dragX``
- ``Sketch/dragY``
- ``Sketch/isKeyDown(_:)``
- ``Sketch/key``
- ``Sketch/mousePressed()``
- ``Sketch/mouseReleased()``
- ``Sketch/mouseClicked()``
- ``Sketch/mouseMoved()``
- ``Sketch/mouseDragged()``
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

### 外から機能を足す

- ``Plugin``
- ``PluginRegistry``
- ``Inlet``
- ``Outlet``
- ``OutputFrame``
- ``RenderDevice``
- ``RenderTarget``
- ``RenderFailure``
