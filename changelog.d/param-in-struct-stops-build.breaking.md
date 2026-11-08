<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

struct の中に書いた `@Param` は、ビルドで止まるようになりました ([#3876](https://github.com/mokume-metal/mokume/issues/3876))。これまでは組めましたが、つまみ・外からの書き込み・保存のどれにも出ず、そのうえ値の置き場が 1 つしか無いので、struct を写すと写しどうしが同じ値を指していました (`var b = a; b.size = 99` で `a.size` も 99 になる)。これからは `@Param` の行で「@Param goes on the sketch class」と止まります。

止まるのは、struct に直に書いたものと、スケッチの class の中に入れ子にした struct に書いたものです。スケッチの class・その基底クラス・class の部品 (`final class Brush: SketchPart`) に書いた `@Param` は、今までどおり組めます (class の部品のものは、今までどおりつまみには出ません)。

移行: 調整する値はスケッチの class に `@Param` で置き、部品へは引数で渡してください。つまみとしての働きは、これまでも出ていなかったので何も失いません。

```swift
// これまで (組めたが、つまみに出ず、left と right の写しが値を共有しうる)
struct Brush: SketchPart {
    @Param(1...80) var size: Float = 12
    func display() { circle(200, 200, size) }
}

// これから
struct Brush: SketchPart {
    func display(size: Float) { circle(200, 200, size) }
}

final class Painting: Sketch {
    @Param(1...80) var leftSize: Float = 12
    @Param(1...80) var rightSize: Float = 12
    var left = Brush(), right = Brush()

    func draw() {
        left.display(size: leftSize)
        right.display(size: rightSize)
    }
}
```
