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
- ``Clock``
- ``SketchRuntime``
- ``SketchApplication``
- ``StartupReads``
- ``WorkDirectory``
- ``SourceStamp``
- ``RuntimeLoad``

### 描く

- ``Canvas``
- ``Shape``
- ``ShapeMode``
- ``ShapeEnd``
- ``StrokeCap``
- ``StrokeJoin``
- ``Transform``
- ``Placement``

### 色と混ぜ方

- ``LinearRGBA``
- ``BlendMode``
- ``ToneMapping``

### 文字

- ``TextStyle``
- ``TextFlow``
- ``TextContour``
- ``TextWrap``
- ``HorizontalTextAlign``
- ``VerticalTextAlign``

### 画像と画素

- ``Image``
- ``Pixels``
- ``PixelBuffer``
- ``DisplayImage``
- ``PNGFile``
- ``ImageFailure``
- ``ImageWriteFailure``

### 立体と光

- ``Model``
- ``Camera``
- ``Orbit``
- ``Surroundings``
- ``VertexKind``
- ``ModelFailure``

### GPU に計算させる

- ``Shader``
- ``EffectShader``
- ``ShaderValue``
- ``Effect``
- ``Computation``
- ``Numbers``
- ``Particles``
- ``Emitter``
- ``Force``
- ``Upscale``
- ``RenderDevice``
- ``RenderTarget``
- ``ShaderFailure``
- ``RenderFailure``

### 走らせたまま値を動かす

- ``Param(name:)``
- ``Param(_:name:)-4ddav``
- ``Param(_:name:)-4a6pu``
- ``Param(choices:name:)``
- ``ParamValue``
- ``ParamRange``
- ``ParamDeclaration``
- ``ParamBox``
- ``ParamRepresentable``

### 入力を受ける

- ``InputState``
- ``InputEvent``

### 出して観測する

- ``OutputStage``
- ``OutputFrame``
- ``Outlet``
- ``Inlet``
- ``FrameStats``
- ``ObservationRequest``
- ``ObservationReport``
- ``ExposedValue``

### 外から機能を足す

- ``Plugin``
- ``PluginRegistry``
