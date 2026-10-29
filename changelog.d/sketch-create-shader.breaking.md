<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`Sketch` の文字列から断片を作る口を、`makeShader` から p5.js の `createShader` と同じ綴りの `createShader` に改めた。** `createGraphics`・`createImage`・`createShape` と並ぶ綴りで、旧い `makeShader` は残していない。引数 (`_ body:`・`name:`・`values:`・`surfaces:`)・返す `Shader`・投げる `ShaderFailure` は変わらない。

**移行**: スケッチと `SketchPart` の中の `makeShader(` を `createShader(` に置き換える。

```swift
// 前
stripes = try makeShader("float4 paint(Fragment in, Values values) { return float4(in.uv, 0, 1); }")
// 後
stripes = try createShader("float4 paint(Fragment in, Values values) { return float4(in.uv, 0, 1); }")
```

`Canvas.makeShader` (`canvas.makeShader(…)`・`createGraphics` で得た描き場所の `makeShader`) は変わらない — 下の層は Swift の慣行 (`make` で始める) のまま残す。`makeEffect`・`makeComputation`・`makeNumbers`・`makeParticles` も変えない。

走っていない所 (`init()` の中など) から呼んだときに投げる `ShaderFailure.notRunning(call:)` の `call` は、`"createShader(_:name:values:surfaces:)"` になる。

**絵は変わらない。** 名前が変わるだけで、描く結果は同じである。
