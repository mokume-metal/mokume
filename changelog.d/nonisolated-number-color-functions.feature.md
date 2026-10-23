<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

値だけを受けて値を返す数と色の関数が、`nonisolated` の文脈から呼べるようになりました ([#2389](https://github.com/mokume-metal/mokume/issues/2389))。`map`・`lerp`・`constrain`・`norm`・`smoothstep`・`radians`・`degrees`・`damp`・`pingpong`・`lerpAngle`・`dist`・`mag`・`sq`・`fract`・`mod`・`bezierPoint`・`bezierTangent`・`color` の各口・`lerpColor`・`paletteLerp`・色の成分の読み出し (`red`・`hue` ほか)・`LinearRGBA.display(...)`・円周率の定数 (`PI` ほか) が対象です。

画素を計算するループを、`DispatchQueue.concurrentPerform` や TaskGroup で分けて回せます。1920×1080 の全画素を `map` と `color` で埋めるループは、release で 1 本から 64 分割にすると、246 ms が 23 ms になり、約 10 倍速くなりました (`map` の説明文に例があります)。

```swift
DispatchQueue.concurrentPerform(iterations: 256) { x in
    _ = color(map(x, 0, 255, 0, 255), 64, 128)
}
```

スケッチを書くだけなら、何も変わりません。注釈を書かずに、いつもどおり書けます。数でない値を渡したときの注意は、複数のスレッドから同時に呼んでも 1 度だけ出ます。スケッチの状態を読む口 (`fill`・`circle` などのメンバーと、種を読む `noise`) は main actor のままで、分けた先の閉包からは呼べません。
